#!/bin/bash
# grok-auth-ready.sh — will grok's login outlive this dispatch? (#882)
#
# INVOKED ONLY BY resolve-cli.sh's grok_auth_ready, after grok_sandbox_preflight
# passed, as `/usr/bin/env -i /bin/bash -p <this file> <home> <pinned-path>
# <budget-seconds>`. <home> and <pinned-path> are the values that preflight
# derived and verified; nothing else is inherited.
#
# WHY. The busdriver-review profile denies **/.grok, so grok inside the sandbox
# cannot take ~/.grok/auth.json.lock and cannot renew its access token. grok
# renews only once the token has EXPIRED (6h lifetime), so a review that starts
# with an expired token, or outlives it, gets 401s until the dispatch timeout
# and leaves no review JSON. Widening the sandbox to write ~/.grok would let the
# grok that reads untrusted content rewrite the operator's credentials, so the
# sandbox stays as it is and this check runs OUTSIDE it instead:
#   * expired  -> run `grok models` once, unsandboxed, to let grok's own login
#                 code renew the token, then check again;
#   * expires before now + budget -> refuse now, not after the budget is spent.
#
# Contract: prints `OK` and exits 0 when the earliest expires_at in auth.json
# is later than now + budget + 60s (measured after any renewal); otherwise
# prints `WHY=auth` (no usable login, or renewal failed) or `WHY=auth-expiring`
# (valid now, expires mid-run) and exits 1. Never prints anything read from
# auth.json or config.toml. A default model that does not use the session token
# at all (#970) prints `OK` without looking at auth.json.

set -u
PATH=/usr/bin:/bin
home="${1:-}"
pinned="${2:-}"
budget="${3:-}"

[[ "${home#/}" != "$home" && -n "$pinned" ]] || { printf 'WHY=auth\n'; exit 1; }
# At most 9 significant digits after any leading zeros (the parent allows those
# too), and base 10 forced: a leading zero would otherwise be read as octal
# (01200 -> 640s, and 08 an arithmetic error).
[[ "$budget" =~ ^0*[0-9]{1,9}$ ]] || { printf 'WHY=auth\n'; exit 1; }
budget=$((10#$budget))
auth="$home/.grok/auth.json"
cfg="$home/.grok/config.toml"

# #970: grok resolves a model's credential as api_key -> env_key -> cached
# auth_provider token (a miss is terminal) -> session token -> XAI_API_KEY. The
# dispatch runs grok under `env -i`, so env_key and XAI_API_KEY never resolve,
# and auth.json matters only when the default model's [model.<name>] table has
# neither api_key nor auth_provider. (dispatch never passes -m, so the default
# is the model that runs.) Prints `key` only on a positive match, from a
# deliberately small TOML subset: [models] and [model.<one key>] headers, and
# single-line key = "..." / '...' values without escapes. Anything else (no
# config, no [models] default, a dotted model name, a multiline string anywhere)
# prints nothing and keeps the session-token check, so a misread can only cost
# the stall #882 already guards against, never a refusal it would not make.
selected_model_auth() {
  [[ -f "$cfg" && ! -L "$cfg" ]] || return 0
  /usr/bin/perl -e '
    open my $f, "<", $ARGV[0] or exit 1;
    my ($tbl, $model, $default, %has) = ("");
    while (my $l = <$f>) {
      # A multiline string can hold lines that look like headers or keys.
      exit 0 if $l =~ /"""|\x27\x27\x27/;
      if ($l =~ /^\s*\[\s*([^\[\]]*?)\s*\]\s*(?:#.*)?$/) {
        $tbl = $1;
        $model = $tbl =~ /^model\.(?:([A-Za-z0-9_-]+)|"([^"\\]+)"|\x27([^\x27]+)\x27)$/ ? ($1 // $2 // $3) : undef;
        next;
      }
      ($tbl, $model) = ("", undef), next if $l =~ /^\s*\[/;
      next unless $l =~ /^\s*([A-Za-z0-9_-]+)\s*=\s*(?:"([^"\\]*)"|\x27([^\x27]*)\x27)\s*(?:#.*)?$/;
      my ($k, $v) = ($1, $2 // $3);
      if ($tbl eq "models" && $k eq "default") { $default = $v }
      elsif (defined $model && ($k eq "api_key" || $k eq "auth_provider") && length $v) { $has{$model} = 1 }
    }
    print "key" if defined $default && length $default && $has{$default};
  ' "$cfg" 2>/dev/null
}
# grok runs in this same cwd and also loads a checkout's .grok/config.toml,
# which can change the default model. Any such file in this directory or an
# ancestor other than $home keeps the session-token check, as does an
# unreadable cwd.
project_config() {
  local d homereal
  # The trailing x keeps $(...) from stripping a newline that ends a dir name.
  homereal="$(cd -P -- "$home" 2>/dev/null && pwd -P && printf x)" && homereal="${homereal%$'\n'x}" || homereal=""
  d="$(pwd -P 2>/dev/null && printf x)" || return 0
  d="${d%$'\n'x}"
  [[ "$d" == /* ]] || return 0
  while :; do
    if [[ "$d" != "$homereal" ]] && [[ -e "$d/.grok/config.toml" || -L "$d/.grok/config.toml" ]]; then return 0; fi
    [[ "$d" == / ]] && return 1
    d="${d%/*}"
    [[ -n "$d" ]] || d=/
  done
}
if ! project_config; then
  model_auth="$(selected_model_auth)" || model_auth=""
  [[ "$model_auth" == key ]] && { printf 'OK\n'; exit 0; }
fi

# Earliest expires_at across scope entries, as epoch seconds (conservative when
# there are several). Prints nothing, so the caller refuses, unless the file is
# a regular non-symlink holding a JSON object whose every scope entry has a key
# and an expires_at that is a real UTC date: a truncated file, a keyless entry
# or an impossible date must not read as a login.
# Years are pinned to 2xxx because timegm reads small years by the legacy
# two-digit rule (0040 would become 2040).
# perl, not jq or date: JSON::PP and Time::Local are core on both macOS and
# Linux, and BSD and GNU date parse dates differently.
earliest() {
  [[ -f "$auth" && ! -L "$auth" ]] || return 0
  /usr/bin/perl -MJSON::PP -MTime::Local=timegm -e '
    open my $f, "<", $ARGV[0] or exit 1;
    my $d = eval { local $/; JSON::PP->new->decode(<$f>) };
    ref $d eq "HASH" or exit 1;
    my $min;
    for my $v (values %$d) {
      next unless ref $v eq "HASH";
      # Every scope entry must carry a usable key and its expiry: an entry
      # missing either cannot be judged, so it refuses rather than being skipped.
      my $k = $v->{key};
      defined $k && !ref $k && length $k or exit 1;
      my $e = $v->{expires_at};
      defined $e && !ref $e && $e =~ /\A(2\d{3})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?Z\z/ or exit 1;
      my $t = eval { timegm($6, $5, $4, $3, $2 - 1, $1) };
      defined $t or exit 1;
      $min = $t if !defined $min || $t < $min;
    }
    defined $min or exit 1;
    print $min;
  ' "$auth" 2>/dev/null
}

now="$(/bin/date +%s)"
[[ "$now" =~ ^[0-9]+$ ]] || { printf 'WHY=auth\n'; exit 1; }
exp="$(earliest)"
if [[ "$exp" =~ ^[0-9]+$ ]] && (( exp <= now )); then
  # Expired. No prompt, no repo content, an empty cwd and the operator's own
  # verified grok: only grok's login code touches the operator's own file.
  # Bounded so a hook waiting for approval (#560) cannot hang the dispatch.
  # The callers do not count this against their budget, so it is kept short:
  # min(15s, budget), against ~1.3s measured for a plain `grok models`.
  cap=15
  (( budget < cap )) && cap="$budget"
  (( cap >= 1 )) || cap=1
  tmp="$(/usr/bin/mktemp -d)" || { printf 'WHY=auth\n'; exit 1; }
  # A perl supervisor rather than timeout(1) or a bare alarm+exec: grok runs in
  # its own process group, and the supervisor, not grok, owns the alarm, so a
  # child that ignores signals is still SIGKILLed, descendants included.
  (cd "$tmp" && /usr/bin/perl -MPOSIX -e '
    my $cap = shift;
    my $pid;
    # Installed before the fork, and on cancellation too: grok is in its own
    # process group, so a TERM/INT/HUP that ends only the supervisor would
    # otherwise leave a hung renewal running with no alarm left to stop it.
    my $stop = sub { my $rc = shift; if ($pid) { kill "KILL", -$pid, $pid; waitpid $pid, 0 } exit $rc };
    $SIG{ALRM} = sub { $stop->(124) };
    $SIG{$_} = sub { $stop->(130) } for qw(TERM INT HUP);
    # Those signals stay blocked until $pid is known and its group exists
    # (setpgid from both sides), so no handler can run against a child it
    # cannot name or a group not yet created.
    my $set = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP, SIGALRM);
    sigprocmask(SIG_BLOCK, $set) or exit 127;
    $pid = fork;
    defined $pid or exit 127;
    if (!$pid) { setpgrp(0, 0); sigprocmask(SIG_UNBLOCK, $set); exec @ARGV; exit 127 }
    setpgrp($pid, $pid);
    sigprocmask(SIG_UNBLOCK, $set);
    alarm $cap;
    waitpid $pid, 0;
    exit($? >> 8);
  ' "$cap" /usr/bin/env -i PATH="$pinned" HOME="$home" \
    GROK_HOME="$home/.grok" GROK_CLAUDE_HOOKS_ENABLED=0 \
    GROK_CURSOR_HOOKS_ENABLED=0 HINDSIGHT_DISABLED=1 \
    grok models) </dev/null >/dev/null 2>&1 || :
  /bin/rm -rf -- "$tmp" 2>/dev/null || :
  exp="$(earliest)"
  # The review starts after the renewal, so its deadline does too.
  now="$(/bin/date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || { printf 'WHY=auth\n'; exit 1; }
fi

if ! [[ "$exp" =~ ^[0-9]+$ ]] || (( exp <= now )); then printf 'WHY=auth\n'; exit 1; fi
(( exp > now + budget + 60 )) || { printf 'WHY=auth-expiring\n'; exit 1; }
printf 'OK\n'
exit 0
