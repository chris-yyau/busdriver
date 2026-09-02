#!/usr/bin/env bash
# tests/test-trusted-review-cli.sh — #789: planted in-checkout review CLIs are unavailable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Portable temp root: BD789_TEST_TMP_ROOT -> RUNNER_TEMP -> TMPDIR -> /tmp.
# The previous chain hardcoded one operator's /Volumes path and then hard-failed,
# so this suite could not run anywhere else (measured: it aborted with "no usable
# temp root" on a runner that had neither that path nor RUNNER_TEMP). Each
# candidate must be an ABSOLUTE, non-symlink, writable directory — the fixtures
# plant executables and symlinks under this root, so a relative root or a
# symlinked one could redirect the whole fixture tree out from under the asserts.
# Every guard is written `|| continue` (never `&& continue`) so a false test does
# not trip `set -e`.
_BD789_TMP_ROOT=""
for _bd789_cand in "${BD789_TEST_TMP_ROOT:-}" "${RUNNER_TEMP:-}" "${TMPDIR:-}" /tmp; do
  [[ -n "$_bd789_cand" ]] || continue
  _bd789_cand="${_bd789_cand%/}"
  [[ -n "$_bd789_cand" ]] || _bd789_cand=/
  [[ "$_bd789_cand" == /* ]] || continue
  [[ ! -L "$_bd789_cand" ]] || continue
  [[ -d "$_bd789_cand" && -w "$_bd789_cand" ]] || continue
  _BD789_TMP_ROOT="$_bd789_cand"
  break
done
if [[ -z "$_BD789_TMP_ROOT" ]]; then
  echo "bd-789 focused test: no usable temp root (set BD789_TEST_TMP_ROOT to an absolute, non-symlink, writable directory)" >&2
  exit 1
fi
WORK=$(mktemp -d "$_BD789_TMP_ROOT/bd-789-ftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# #803: review lib pin latches at trusted source load.
set +e
pin_check=$(
  cd "$ROOT" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; canon=\$(_bd803_canonical_file_path \"$LIB\"); _bd803_ensure_staged_lib >/dev/null 2>&1; printf 'PIN=%s\nCANON=%s\nSHA=%s\n' \"\${_BD803_REVIEW_LIB_PIN:-}\" \"\$canon\" \"\${_BD803_REVIEW_LIB_SHA:-}\""
)
set -e
pin_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^PIN=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
canon_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^CANON=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
sha_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^SHA=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
if [[ "$pin_val" == /* && -n "$pin_val" && ( "$pin_val" == "$canon_val" || "$pin_val" -ef "$canon_val" ) ]]; then
  ok "#803: _BD803_REVIEW_LIB_PIN latched at source load"
else
  bad "#803: _BD803_REVIEW_LIB_PIN latch failed: pin='$pin_val' canon='$canon_val'"
fi
if [[ "$sha_val" =~ ^[0-9a-f]{64}$ ]]; then
  ok "#803: _BD803_REVIEW_LIB_SHA latched after ensure_staged_lib (64-char hex)"
else
  bad "#803: _BD803_REVIEW_LIB_SHA latch failed: sha='$sha_val'"
fi


REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm base

mkdir -p "$REPO/bin"
printf '#!/bin/sh\necho FORGED_PASS\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"

EXT=$(mktemp -d "$WORK/ext.XXXXXX")
printf '#!/bin/sh\necho REAL\n' > "$EXT/codex"
chmod +x "$EXT/codex"

DROID_EXT=$(mktemp -d "$WORK/droid-ext.XXXXXX")
printf '#!/bin/sh\necho REAL_DROID\n' > "$DROID_EXT/droid"
chmod +x "$DROID_EXT/droid"



LINKDIR=$(mktemp -d "$WORK/link.XXXXXX")
ln -s "$REPO/bin/codex" "$LINKDIR/codex"

run_avail() {
  local path="$1"
  ( cd "$REPO" && PATH="$path" bash -c ". \"$LIB\" >/dev/null 2>&1; is_trusted_review_cli_available codex" )
}

set +e
run_avail "$REPO/bin:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then ok "in-checkout planted codex is not available"; else bad "in-checkout planted codex was treated as available"; fi

set +e
run_avail "$EXT:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then ok "external mktemp stub remains available"; else bad "external mktemp stub was refused"; fi

set +e
run_avail "$LINKDIR:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then ok "outside symlink into the checkout is not available"; else bad "outside symlink into the checkout was treated as available"; fi

resolved=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" BUSDRIVER_REVIEW_CLI=codex \
    bash -c ". \"$LIB\" >/dev/null 2>&1; resolve_review_cli"
)
if [[ "$resolved" == "missing:codex" ]]; then ok "BUSDRIVER_REVIEW_CLI=codex with planted binary yields missing:codex"; else bad "expected missing:codex, got '$resolved'"; fi

pinned=$(
  cd "$REPO" && PATH="$EXT:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex"
)
ext_phys=""
ext_phys="$(CDPATH='' cd -P -- "$EXT" 2>/dev/null && pwd -P)" || ext_phys=""
want="${ext_phys}/codex"
if [[ "$pinned" == "$want" ]]; then ok "trusted resolver returns the external absolute path, not the planted one"; else bad "expected pinned=$want, got '$pinned'"; fi

printf '#!/bin/sh\necho PLANTED_TIMEOUT\n' > "$REPO/bin/timeout"
chmod +x "$REPO/bin/timeout"
to_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 1 /bin/echo SAFE"
)
if [[ "$to_out" == *PLANTED_TIMEOUT* ]]; then
  bad "checkout-planted timeout wrapped the review command"
elif [[ "$to_out" == *SAFE* ]]; then
  ok "portable timeout ignores checkout-planted timeout wrapper"
else
  bad "portable timeout produced neither SAFE nor PLANTED_TIMEOUT: '$to_out'"
fi


# Empty PATH component is CWD for shell lookup — plant ./codex at checkout root.
cp "$REPO/bin/codex" "$REPO/codex"
set +e
run_avail ":$EXT:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  ok "empty PATH component (CWD) with planted ./codex is not available"
else
  bad "empty PATH component skipped planted CWD codex and blessed an external binary"
fi

# Shim dir on PATH resolves to a different physical bindir — dispatch PATH must
# still include the outside-checkout shim dir so bare `codex` remains findable
# (companion lookup), without using $HOME.
PHYS=$(mktemp -d "$WORK/phys.XXXXXX")
SHIM=$(mktemp -d "$WORK/shim.XXXXXX")
printf '#!/bin/sh\necho REAL_PHYS\n' > "$PHYS/codex.js"
chmod +x "$PHYS/codex.js"
ln -s "$PHYS/codex.js" "$SHIM/codex"
disp=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex"
)
shim_phys="$(CDPATH='' cd -P -- "$SHIM" 2>/dev/null && pwd -P)"
phys_dir="$(CDPATH='' cd -P -- "$PHYS" 2>/dev/null && pwd -P)"
want_phys="${phys_dir}/codex.js"
pinned_shim=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex"
)
if [[ "$pinned_shim" == "$want_phys" ]] \
  && [[ ":$disp:" == *":$shim_phys:"* ]] \
  && [[ ":$disp:" != *":$HOME:"* ]] \
  && [[ "$disp" != *"\$HOME"* ]]; then
  ok "dispatch PATH keeps outside-checkout shim dir for bare-name lookup"
else
  bad "shim launchdir missing or HOME leaked: pinned='$pinned_shim' want='$want_phys' disp='$disp' shim='$shim_phys'"
fi

# Checkout-planted shim to the same physical target must not put the checkout on DISP.
ln -sf "$PHYS/codex.js" "$REPO/bin/codex"
disp_plant=$(
  cd "$REPO" && PATH="$REPO/bin:$SHIM:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || { echo REFUSED; exit 0; }; _review_dispatch_path \"\$b\" codex"
)
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$disp_plant" == "REFUSED" ]]; then
  ok "checkout-planted shim to external physical target is refused"
elif [[ ":$disp_plant:" == *":${repo_phys}/"* ]] || [[ ":$disp_plant:" == *":${repo_phys}:"* ]]; then
  bad "dispatch PATH included checkout after planted shim: '$disp_plant'"
else
  # Resolver may skip planted first hit if launchdir-in-checkout refuses — then
  # fall through to SHIM. Either refuse or external-only DISP is acceptable;
  # checkout must never appear.
  ok "checkout-planted shim does not place checkout on dispatch PATH"
fi

# Earlier PATH dir with a non-codex alias to the same physical target must not
# steal launchdir — only "$d/codex" counts.
ALIAS=$(mktemp -d "$WORK/alias.XXXXXX")
ln -s "$PHYS/codex.js" "$ALIAS/notcodex"
disp_alias=$(
  cd "$REPO" && PATH="$ALIAS:$SHIM:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex"
)
alias_phys="$(CDPATH='' cd -P -- "$ALIAS" 2>/dev/null && pwd -P)"
if [[ ":$disp_alias:" == *":$shim_phys:"* ]] && [[ ":$disp_alias:" != *":$alias_phys:"* ]]; then
  ok "launchdir ignores non-codex alias to the same physical target"
else
  bad "alias stole or omitted shim launchdir: disp='$disp_alias' shim='$shim_phys' alias='$alias_phys'"
fi


# Physical bindir decoy named `codex` must lose to the shim launchdir on DISP.
printf '#!/bin/sh\necho DECOY\n' > "$PHYS/codex"
chmod +x "$PHYS/codex"
found=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; PATH=\$(_review_dispatch_path \"\$b\" codex) command -v codex"
)
shim_dir=""
shim_dir="$(CDPATH='' cd -P -- "$SHIM" 2>/dev/null && pwd -P)" || shim_dir=""
shim_codex="${shim_dir}/codex"
if [[ "$found" == "$shim_codex" ]]; then
  ok "dispatch PATH prefers shim launchdir over physical-bindir decoy codex"
else
  bad "decoy won bare-name lookup: found='$found' want='$shim_codex'"
fi

# --- (a) BASH_FUNC_local%% / BASH_FUNC_return%% must not bless in-checkout planted CLI ---
printf '#!/bin/sh\necho FORGED_PASS\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"
rm -f "$REPO/bin/node"
set +e
shadow_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    env 'BASH_FUNC_local%%=() { :; }' 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; out=\$(_resolve_trusted_cli_bin codex); rc=\$?; printf 'OUT=%s\nRC=%s\n' \"\$out\" \"\$rc\""
)
set -e
if [[ "$shadow_out" == OUT=/* ]] || [[ "$shadow_out" == *$'\nRC=0'* ]] || [[ "$shadow_out" == RC=0* ]]; then
  bad "BASH_FUNC shadow allowed planted codex: '$shadow_out'"
else
  ok "BASH_FUNC_local/return shadowing cannot make planted in-checkout codex available"
fi

# Litmus HIGH: BASH_FUNC must not collapse dispatch PATH into checkout CWD
set +e
poison_disp=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    /usr/bin/env 'BASH_FUNC_local%%=() { :; }' 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; out=\$(_review_dispatch_path \"\$b\" codex); rc=\$?; printf 'OUT=%s\nRC=%s\n' \"\$out\" \"\$rc\""
)
set -e
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$poison_disp" == *"OUT=$repo_phys"* ]] || [[ "$poison_disp" == *"OUT=$REPO"* ]]; then
  bad "BASH_FUNC shadow made dispatch PATH include checkout: '$poison_disp'"
else
  ok "BASH_FUNC_local/return cannot collapse dispatch PATH into checkout"
fi

# --- (b) approved env-node shim with decoy node beside it ---
NODEDIR=$(mktemp -d "$WORK/node.XXXXXX")
printf '#!/bin/sh\necho TRUSTED_NODE\n' > "$NODEDIR/node"
chmod +x "$NODEDIR/node"
node_phys="$(CDPATH='' cd -P -- "$NODEDIR" 2>/dev/null && pwd -P)"

ENVPHYS=$(mktemp -d "$WORK/envphys.XXXXXX")
ENVSHIM=$(mktemp -d "$WORK/envshim.XXXXXX")
printf '%s\n' '#!/usr/bin/env node' 'console.log("ENVNODE")' > "$ENVPHYS/codex.js"
chmod +x "$ENVPHYS/codex.js"
ln -sf "$ENVPHYS/codex.js" "$ENVSHIM/codex"
printf '#!/bin/sh\necho PLANTED_NODE\n' > "$REPO/bin/node"
chmod +x "$REPO/bin/node"
ln -sf "$REPO/bin/node" "$ENVSHIM/node"

found_node=$(
  cd "$REPO" && PATH="$NODEDIR:$ENVSHIM:$REPO/bin:/usr/bin:/bin" \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; PATH=\$(_review_dispatch_path \"\$b\" codex) || exit 3; command -v node"
)
want_node="${node_phys}/node"
if [[ "$found_node" == "$want_node" ]]; then
  ok "env-node shim: validated nodedir beats decoy node beside approved shim"
else
  bad "env-node decoy node won: found='$found_node' want='$want_node'"
fi

# require-node / env-node fail-closed: absolute bash; inner PATH excludes system node dirs
set +e
disp_req=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$ENVSHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex require-node; echo DISP_RC=\$?"
)
set -e
if [[ "$disp_req" == *DISP_RC=1* ]]; then
  ok "require-node mode fails closed when validated node is absent"
else
  bad "require-node did not fail closed: '$disp_req'"
fi

set +e
disp_env=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$ENVSHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex; echo DISP_RC=\$?"
)
set -e
if [[ "$disp_env" == *DISP_RC=1* ]]; then
  ok "env-node shebang fails closed when validated node is absent"
else
  bad "env-node shebang did not fail closed: '$disp_env'"
fi

set +e
disp_shell=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$SHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; out=\$(_review_dispatch_path \"\$b\" codex); echo DISP_RC=\$?; printf 'DISP_OUT=%s\n' \"\$out\""
)
set -e
if [[ "$disp_shell" == *DISP_RC=0* ]] && [[ "$disp_shell" == *"$shim_phys"* ]]; then
  ok "shell/native shim dispatch succeeds without trusted node"
else
  bad "shell/native dispatch unexpectedly failed closed: '$disp_shell'"
fi

# Bare timed dispatch pins but must NOT scrub CODEX_HOME; --review must.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf "CHILD_CODEX_HOME=%s\n" "$CODEX_HOME"' > "$EXT/codex"
chmod +x "$EXT/codex"
# #803: inside a checkout, bare timed codex/agy/droid pin argv0 but keep
# ambient env (no env -i) so write-capable dispatch retains API keys / CODEX_HOME.
# Outside a checkout, ambient env is preserved as well.
bare_ck_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 2 codex"
)
if [[ "$bare_ck_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  ok "bare timeout inside checkout preserves CODEX_HOME"
else
  bad "bare timeout inside checkout scrubbed CODEX_HOME: '$bare_ck_out'"
fi
BARE_NONGIT="$WORK/bare-nongit"
mkdir -p "$BARE_NONGIT"
bare_out=$(
  cd "$BARE_NONGIT" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 2 codex"
)
if [[ "$bare_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  ok "bare timeout outside checkout preserves CODEX_HOME"
else
  bad "bare timeout outside checkout scrubbed CODEX_HOME: '$bare_out'"
fi
rev_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$rev_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  bad "--review did not scrub CODEX_HOME: '$rev_out'"
else
  ok "--review scrubs CODEX_HOME"
fi


# --- Litmus HIGH regressions (#789 out12) ---
# 1) --review must clear DYLD fallback/versioned loader vars
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "FB=%s\n" "${DYLD_FALLBACK_LIBRARY_PATH-<unset>}"' \
  'printf "VER=%s\n" "${DYLD_VERSIONED_LIBRARY_PATH-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
loader_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    DYLD_FALLBACK_LIBRARY_PATH=/evil-fb DYLD_VERSIONED_LIBRARY_PATH=/evil-ver \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$loader_out" == *'FB=<unset>'* || "$loader_out" == *'FB='*$'\n'* ]] && [[ "$loader_out" != *FB=/evil-fb* ]] \
   && [[ "$loader_out" != *VER=/evil-ver* ]]; then
  ok "--review scrubs DYLD fallback/versioned loader vars"
else
  # Empty string after scrub is also acceptable (exported empty)
  if [[ "$loader_out" == *FB=* && "$loader_out" != *FB=/evil-fb* && "$loader_out" != *VER=/evil-ver* ]]; then
    ok "--review scrubs DYLD fallback/versioned loader vars"
  else
    bad "--review leaked DYLD fallback/versioned vars: '$loader_out'"
  fi
fi

# 2) is_cli_available from non-Git directory uses ordinary PATH lookup
NONGIT="$WORK/nongit"
mkdir -p "$NONGIT"
printf '#!/bin/sh\necho ok\n' > "$NONGIT/codex"
chmod +x "$NONGIT/codex"
set +e
( cd "$NONGIT" && PATH="$NONGIT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; is_cli_available codex" )
nongit_rc=$?
set -e
if [[ "$nongit_rc" -eq 0 ]]; then
  ok "is_cli_available works from non-Git directory"
else
  bad "is_cli_available failed from non-Git directory (rc=$nongit_rc)"
fi

# 3) _resolve_trusted_cli_bin must not clear caller LD_PRELOAD
set +e
preload_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" LD_PRELOAD=/sentinel-preload \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex >/dev/null; printf 'LP=%s\n' \"\${LD_PRELOAD-<unset>}\""
)
preload_rc=$?
set -e
if [[ "$preload_rc" -eq 0 && "$preload_out" == *LP=/sentinel-preload* ]]; then
  ok "_resolve_trusted_cli_bin preserves caller LD_PRELOAD"
else
  bad "_resolve_trusted_cli_bin mutated LD_PRELOAD: rc=$preload_rc out='$preload_out'"
fi


# 4) --review scrubs GIT_EXTERNAL_DIFF / GIT_DIR
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "GD=%s\n" "${GIT_DIR-<unset>}"' \
  'printf "GE=%s\n" "${GIT_EXTERNAL_DIFF-<unset>}"' \
  'printf "NR=%s\n" "${GIT_NO_REPLACE_OBJECTS-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
git_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    GIT_DIR=/evil-gitdir GIT_EXTERNAL_DIFF=/evil-diff \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$git_out" != *GD=/evil-gitdir* && "$git_out" != *GE=/evil-diff* && "$git_out" == *NR=1* ]]; then
  ok "--review scrubs GIT_* and sets GIT_NO_REPLACE_OBJECTS=1"
else
  bad "--review leaked GIT_* or missed NO_REPLACE: '$git_out'"
fi

# 4b) --review must not inherit HTTPS_PROXY / SSL_CERT_FILE
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "PX=%s\n" "${HTTPS_PROXY-<unset>}"' \
  'printf "SC=%s\n" "${SSL_CERT_FILE-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
proxy_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    HTTPS_PROXY=http://evil-proxy SSL_CERT_FILE=/evil-ca.pem \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$proxy_out" != *PX=http://evil-proxy* && "$proxy_out" != *SC=/evil-ca.pem* ]]; then
  ok "--review drops HTTPS_PROXY and SSL_CERT_FILE"
else
  bad "--review leaked proxy/CA overrides: '$proxy_out'"
fi


# 5) ordinary is_cli_available still sees planted PATH entry (dispatch-cli mode)
set +e
( cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; is_cli_available codex" )
ord_rc=$?
set -e
if [[ "$ord_rc" -eq 0 ]]; then
  ok "ordinary is_cli_available accepts PATH hit inside Git checkout"
else
  bad "ordinary is_cli_available unexpectedly refused PATH hit (rc=$ord_rc)"
fi


# 7) --review node keeps sanitized ambient PATH (companion dispatch)
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf "PATH_HAS=%s\n" "$PATH"' > "$EXT/node"
chmod +x "$EXT/node"
node_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review node 2 \"$EXT/node\""
)
ext_phys="$(CDPATH='' cd -P -- "$EXT" 2>/dev/null && pwd -P)"
if [[ "$node_out" == *PATH_HAS="$ext_phys"* || "$node_out" == *"PATH_HAS=$ext_phys:"* ]]; then
  ok "--review node preserves sanitized ambient dispatch PATH"
else
  bad "--review node dropped ambient dispatch PATH: '$node_out'"
fi


# 8) PATH directory with metacharacters must not inject into phys_dir
EVIL="$WORK/evil;injected;dir"
mkdir -p "$EVIL"
printf '#!/bin/sh\necho EVIL\n' > "$EVIL/codex"
chmod +x "$EVIL/codex"
set +e
inj=$(
  cd "$REPO" && PATH="$EVIL:$EXT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex; echo RC=\$?"
)
set -e
if [[ "$inj" != *EVIL* ]] && { [[ "$inj" == *RC=0* ]] || [[ "$inj" == *RC=1* ]]; }; then
  ok "PATH dir with metacharacters cannot inject into review dispatch"
else
  bad "PATH metachar injection result: '$inj'"
fi


# 9) BASH_FUNC_local/return must not make --review node accept checkout PATH
printf '#!/bin/sh\necho FORGED_NODE\n' > "$REPO/bin/node"
chmod +x "$REPO/bin/node"
printf '#!/bin/sh\necho FORGED_CODEX\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"
set +e
sarp_node=$(
  cd "$REPO" && PATH="$REPO/bin:$EXT:/usr/bin:/bin" \
    /usr/bin/env 'BASH_FUNC_local%%=() { raw=/; target=/; dir=/; phys=/; out=/; }' \
                 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review node 2 \"$EXT/node\"; echo RC=\$?"
)
set -e
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$sarp_node" == *"$repo_phys"* ]] || [[ "$sarp_node" == *"$REPO/bin"* && "$sarp_node" == *FORGED* ]]; then
  bad "--review node accepted checkout PATH under BASH_FUNC poison: '$sarp_node'"
else
  ok "BASH_FUNC poison cannot force --review node onto checkout PATH"
fi

# 10) The SURGICAL BASH_FUNC_local shape that actually bypassed containment.
# Test 9's poison blanks every name at once, which fails CLOSED: the upstream
# phys_dir helper breaks first and the predicate refuses. The shape that bypassed
# performs every assignment EXCEPT the one naming `dir`, so upstream still works
# and only the containment input is emptied — the walk never runs and the trailing
# `return 1` reports "outside the checkout". RC=0 means IN-CHECKOUT (refused).
set +e
# shellcheck disable=SC2016 # the BASH_FUNC body is a literal passed to env, never expanded here
tcdic=$(
  cd "$REPO" && /usr/bin/env \
    'BASH_FUNC_local%%=() { for _a in "$@"; do case "$_a" in dir=*) dir= ;; *=*) eval "$_a" ;; esac; done; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$REPO/bin\"; echo RC=\$?"
)
set -e
if [[ "$tcdic" == *RC=0* ]]; then
  ok "surgical BASH_FUNC_local cannot make the checkout look external"
else
  bad "containment predicate bypassed by surgical BASH_FUNC_local: '$tcdic'"
fi


# 11) The predicate physicalizes a FILE argument, which is what lets the
# trusted-directory `timeout` lookup reject a wrapper symlinked into the reviewed
# tree without searching ambient PATH. The symlink itself lives OUTSIDE the
# checkout, so only symlink resolution can catch it.
printf '#!/bin/sh\necho FORGED_TIMEOUT\n' > "$REPO/bin/timeout"
chmod +x "$REPO/bin/timeout"
ln -s "$REPO/bin/timeout" "$EXT/timeout"
set +e
tphys=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$EXT/timeout\"; echo RC=\$?"
)
set -e
if [[ "$tphys" == *RC=0* ]]; then
  ok "outside symlink to an in-checkout file is refused by physicalization"
else
  bad "in-checkout symlink target accepted via an outside path: '$tphys'"
fi


# 12) ORDINARY agy dispatch must not inherit the review-only resolver's
# outside-a-checkout refusal. A 1.0.x agy on ambient PATH, probed from a non-Git
# directory, must be read as LEGACY (RC=1, stdin transport) with a CONCLUSIVE
# probe — not defaulted to argv because the trusted resolver declined to answer.
AGYDIR=$(mktemp -d "$WORK/agy.XXXXXX")
NONGIT=$(mktemp -d "$WORK/nongit.XXXXXX")
# shellcheck disable=SC2016 # $1 belongs to the generated stub script, not this shell
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.7; exit 0; fi\necho AGY\n' > "$AGYDIR/agy"
chmod +x "$AGYDIR/agy"
set +e
agy_ord=$(
  cd "$NONGIT" && PATH="$AGYDIR:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _agy_wants_argv_prompt; echo RC=\$? CONCLUSIVE=\$_AGY_PROBE_CONCLUSIVE"
)
set -e
if [[ "$agy_ord" == *"RC=1"* && "$agy_ord" == *"CONCLUSIVE=1"* ]]; then
  ok "ordinary agy probe outside a checkout reads the real version (stdin transport)"
else
  bad "ordinary agy probe outside a checkout: '$agy_ord'"
fi

# 13) A shadowed `return` must not turn a --review refusal into a launch. The
# refusal block calls `return 1`; with BASH_FUNC_return%% exported that call runs
# the ATTACKER's function — which can assign _pt_bin — and then falls THROUGH to
# the dispatch. Measured before the _pt_refuse latch: the refusal printed, the
# planted in-checkout codex executed, and the call returned 0.
set +e
ret_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { _pt_bin=$REPO/bin/codex; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex --version; echo RC=\$?"
)
set -e
if [[ "$ret_out" != *FORGED_CODEX* && "$ret_out" == *"RC=1"* ]]; then
  ok "shadowed return cannot turn a --review refusal into a launch"
else
  bad "shadowed return produced a launch or a zero status: '$ret_out'"
fi

# 14) The shape that defeated the round-3 latch: the shadow `return` resets the
# GUARD variable as well as _pt_bin. Any parent-shell latch is writable by the very
# shadow it guards against — measured: refusal printed, planted codex executed,
# status 0. The refusal now has no latch to reset; it records a message and falls
# to an absolute /usr/bin/false, and _portable_timeout calls no shadowable builtin
# at all, so the shadow never runs inside it.
set +e
ret2=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { _pt_refuse=0; _pt_err=; _pt_bin=$REPO/bin/codex; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex --version; echo RC=\$?"
)
set -e
if [[ "$ret2" != *FORGED_CODEX* && "$ret2" == *"RC=1"* ]]; then
  ok "shadowed return cannot reset refusal state and launch"
else
  bad "shadowed return defeated the refusal: '$ret2'"
fi


# 15) FORCE-ASSIGNMENT `local` poison. The shadow does not merely drop the
# assignment — it substitutes an attacker value (`target=/`, `home=/`), which is
# the shape that actually reddens: measured against the pre-fix bytes this printed
# "/" and exited 0, so `/` became $HOME for every --review launch and redirected
# companion-cache resolution with it. Assert the real password-DB home comes back:
# absolute, an existing directory, and NOT "/".
set +e
# shellcheck disable=SC2016 # the BASH_FUNC body is a literal passed to env
toh=$(
  cd "$REPO" && /usr/bin/env \
    'BASH_FUNC_local%%=() { for _a in "$@"; do case "$_a" in target=*) target=/ ;; home=*) home=/ ;; *=*) eval "$_a" ;; esac; done; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_operator_home"
)
set -e
toh_first=$(/usr/bin/printf '%s\n' "$toh" | /usr/bin/head -1)
if [[ "$toh_first" == /* && "$toh_first" != "/" && -d "$toh_first" ]]; then
  ok "force-assignment local poison cannot redirect the trusted operator home"
else
  bad "operator home under force-assignment local poison: '$toh_first'"
fi

# 16) Exhausting the 32-hop symlink budget is UNRESOLVABLE, not "resolved to
# something outside". A chain longer than 32 that LIVES outside the checkout but
# TERMINATES inside it used to leave the path still symlinked, so the containment
# check examined the link chain's own (external) directory and accepted a planted
# in-checkout binary. Measured RC=1 (accepted) before the guard, RC=0 after.
CHAIN="$WORK/chain"
mkdir -p "$CHAIN"
ln -s "$REPO/bin/codex" "$CHAIN/l0"
i=1
while [[ "$i" -le 40 ]]; do ln -s "$CHAIN/l$((i-1))" "$CHAIN/l$i"; i=$((i+1)); done
set +e
sym=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$CHAIN/l40\"; echo RC=\$?"
)
set -e
if [[ "$sym" == *"RC=0"* ]]; then
  ok "symlink chain past the hop budget fails closed (unresolvable is not outside)"
else
  bad "long symlink chain terminating in the checkout was accepted: '$sym'"
fi

# 17) A BASH_FUNC_local%% shadow can mark a variable READONLY, not merely assign
# it — a shape the earlier probes missed. Pinning _CODEX_COMPANION readonly to a
# checkout path made every later assignment in the resolver fail; _execute_codex
# calls that resolver BARE (its status is ignored) and hands the pinned path to
# trusted node as an ARGUMENT, which _portable_timeout's argv0 containment check
# does not cover. The resolver no longer calls `local`, so the shadow never fires.
printf 'console.log("FORGED_COMPANION");\n' > "$REPO/evil.mjs"
set +e
comp=$(
  cd "$REPO" && /usr/bin/env \
    "BASH_FUNC_local%%=() { readonly _CODEX_COMPANION=$REPO/evil.mjs 2>/dev/null; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_codex_companion; echo GOT=\$_CODEX_COMPANION"
)
set -e
if [[ "$comp" != *"evil.mjs"* ]]; then
  ok "readonly-pinned local cannot force a checkout-controlled codex companion"
else
  bad "companion was pinned to a checkout-controlled script: '$comp'"
fi

# 18) #803: shadowed return must not turn _execute_codex refusal into a launch.
set +e
codex803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _execute_codex 'probe prompt' 5 2>&1; echo RC=\$?"
)
set -e
if [[ "$codex803" != *FORGED_PASS* && "$codex803" == *"RC=1"* ]]; then
  ok "#803: _execute_codex refusal survives shadowed return"
else
  bad "#803: _execute_codex launched under shadowed return: '$codex803'"
fi

# 19) #803: execute_review agy arm must refuse in-checkout agy under shadowed return.
printf '#!/bin/sh\necho FORGED_AGY\n' > "$REPO/bin/agy"
chmod +x "$REPO/bin/agy"
set +e
agy803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" "BASH_FUNC_local%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; execute_review agy 'probe' 2 2>&1; echo RC=\$?"
)
set -e
if [[ "$agy803" != *FORGED_AGY* && "$agy803" == *"RC=1"* ]]; then
  ok "#803: execute_review agy refusal survives BASH_FUNC shadow"
else
  bad "#803: execute_review agy launched under shadow: '$agy803'"
fi

# 20) #803: execute_review droid arm must refuse in-checkout droid under shadowed return.
printf '#!/bin/sh\necho FORGED_DROID\n' > "$REPO/bin/droid"
chmod +x "$REPO/bin/droid"
set +e
droid803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; execute_review droid 'probe' 2 2>&1; echo RC=\$?"
)
set -e
if [[ "$droid803" != *FORGED_DROID* && "$droid803" == *"RC=1"* ]]; then
  ok "#803: execute_review droid refusal survives shadowed return"
else
  bad "#803: execute_review droid launched under shadow: '$droid803'"
fi

# 21) #803: should_escalate_to_droid must stay false for grok under shadowed return.
set +e
setd803=$(
  cd "$REPO" && /usr/bin/env "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; should_escalate_to_droid grok 1 /dev/null; echo RC=\$?"
)
set -e
if [[ "$setd803" == *"RC=1"* ]]; then
  ok "#803: should_escalate_to_droid grok stays false under shadowed return"
else
  bad "#803: should_escalate_to_droid grok escalated under shadow: '$setd803'"
fi

# 22) #803: clean should_escalate_to_droid behavior intact (codex timeout still escalates).
set +e
setd_clean=$(
  cd "$REPO" && PATH="$DROID_EXT:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; should_escalate_to_droid codex 124 /dev/null; echo RC=\$?"
)
set -e
if [[ "$setd_clean" == *"RC=0"* ]]; then
  ok "#803: should_escalate_to_droid codex timeout still escalates when clean"
else
  bad "#803: clean should_escalate_to_droid codex timeout broken: '$setd_clean'"
fi




# 23) #803: BD803_REVIEW_LIB must resolve to resolve-cli.sh (not arbitrary script).
printf '#!/bin/sh\necho EVIL_PIN\n' > "$WORK/evil.sh"
chmod +x "$WORK/evil.sh"
set +e
pt803=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" BD803_REVIEW_LIB="$WORK/evil.sh" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 1 codex 2>&1; echo RC=\$?"
)
set -e
if [[ "$pt803" != *EVIL_PIN* && "$pt803" == *RC=[1-9]* && ( "$pt803" == *BD803_REVIEW_LIB* || "$pt803" == *refusing* ) ]]; then
  ok "#803: BD803_REVIEW_LIB evil.sh refused for --review"
else
  bad "#803: BD803_REVIEW_LIB evil.sh not refused: '$pt803'"
fi

# 24) #803: _bd803_canonical_file_path sanity; poisoned /bin/sh pin refused.
set +e
canon=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _bd803_canonical_file_path \"$LIB\""
)
canon_rc=$?
set -e
if [[ "$canon_rc" -eq 0 && ( "$canon" == "$LIB" || "$canon" -ef "$LIB" ) ]]; then
  ok "#803: _bd803_canonical_file_path sanity on LIB"
else
  bad "#803: _bd803_canonical_file_path sanity failed: rc=$canon_rc out='$canon'"
fi
set +e
shpin=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" BD803_REVIEW_LIB=/bin/sh \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 1 codex 2>&1; echo RC=\$?"
)
set -e
if [[ "$shpin" == *RC=[1-9]* && ( "$shpin" == *BD803_REVIEW_LIB* || "$shpin" == *refusing* ) ]]; then
  ok "#803: BD803_REVIEW_LIB=/bin/sh refused"
else
  bad "#803: BD803_REVIEW_LIB=/bin/sh not refused: '$shpin'"
fi

# 25) #803: latched pin survives post-source canonical stub (no live BASH_SOURCE re-resolve).
/usr/bin/printf '%s\n' '#!/bin/sh' 'echo REAL' > "$EXT/codex"
chmod +x "$EXT/codex"
set +e
canon_miss=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" /bin/bash --norc -c \
    ". \"$LIB\" >/dev/null 2>&1; _bd803_canonical_file_path() { :; }; _portable_timeout --review codex 1 codex --version 2>&1; echo RC=\$?"
)
set -e
if [[ "$canon_miss" == *REAL* && "$canon_miss" == *RC=0* ]]; then
  ok "#803: latched pin survives post-source canonical stub for --review"
else
  bad "#803: latched pin did not survive post-source canonical stub: '$canon_miss'"
fi

# 26) #803: staged-lib verify uses one held FD (pread) then exec /dev/fd/4 — no dual pathname open.
if /usr/bin/grep -F 'exec 5<' "$LIB" | /usr/bin/grep -F 'staged' >/dev/null; then
  bad "#803: staged-lib still dual-opens pathname on fd 5"
elif ! /usr/bin/grep -F 'os.pread(4,' "$LIB" >/dev/null; then
  bad "#803: staged-lib missing os.pread(4) hash of held fd"
else
  ok "#803: staged-lib hashes held fd via os.pread (no dual pathname open)"
fi
set +e
staged_cli=$(
  cd "$ROOT" && PATH="$EXT:/usr/bin:/bin:$PATH" /bin/bash --norc -c \
    ". \"$LIB\" >/dev/null 2>&1; _bd803_bash_staged_lib_ambient --print-trusted-cli codex; echo RC=\$?"
)
set -e
if [[ "$staged_cli" == *RC=0* && "$staged_cli" == /* ]]; then
  ok "#803: _bd803_bash_staged_lib_ambient --print-trusted-cli succeeds via held fd"
else
  bad "#803: staged-lib ambient print-trusted-cli failed: '$staged_cli'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
