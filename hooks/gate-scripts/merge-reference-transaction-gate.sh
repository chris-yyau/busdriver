#!/bin/bash -p
# reference-transaction prepared: refuse unreviewed merge tip updates (#622).
set -euo pipefail
unset BASH_ENV ENV GIT_SHALLOW_FILE
export PATH=/usr/bin:/bin
[[ "${1:-}" == "prepared" || "${1:-}" == "aborted" ]] || exit 0
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
REPO_DIR="${GIT_WORK_TREE:-$PWD}"
GD=$(git --no-replace-objects -c core.hooksPath=/dev/null rev-parse --absolute-git-dir 2>/dev/null) || GD=""
[[ -n "$GD" ]] || { echo "merge reference-transaction gate: cannot resolve git directory." >&2; exit 1; }
SPENT="$GD/busdriver-merge-litmus-spent"
CLAIM="$REPO_DIR/$STATE_DIR/merge-litmus-pending.local"
ARM="$GD/busdriver-merge-litmus-armed"
G=(git --no-replace-objects -c core.hooksPath=/dev/null)
[[ -n "${GIT_DIR:-}" ]] || G+=(-C "$REPO_DIR")
refuse() { echo "merge reference-transaction gate: $1" >&2; exit 1; }
if [[ "${1:-}" == "aborted" ]]; then
  [[ -f "$SPENT" ]] || exit 0
  prev=$(tr -d '[:space:]' <"$SPENT" || true); match=0
  while read -r o n r _; do case "$r" in HEAD|refs/heads/*) [[ "$n" == "$prev" ]] && match=1 ;; esac; done
  [[ "$match" -eq 1 ]] && rm -f "$SPENT"; exit 0
fi
hs() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
OLD=""; NEW=""; N=0; BRANCH=""; FOREIGN=0
while read -r o n r _; do
  case "$r" in HEAD) tip=2 ;; ORIG_HEAD|AUTO_MERGE) tip=-1 ;; refs/heads/*) tip=1 ;; *) tip=2 ;; esac
  [[ "$o" == "$n" ]] && continue
  if [[ "$tip" -eq 2 ]]; then FOREIGN=1; continue; fi
  [[ "$tip" -eq -1 ]] && continue
  [[ -z "$n" || "$n" =~ ^0+$ ]] && { FOREIGN=1; continue; }
  [[ "$o" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$n" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || { FOREIGN=1; continue; }
  [[ -z "$BRANCH" || "$BRANCH" == "$r" ]] || refuse 'refusing multi-branch merge update.'
  BRANCH=$r; [[ -n "$NEW" && "$NEW" != "$n" ]] && refuse 'refusing multi-tip merge update.'
  N=$((N + 1)); NEW=$n; [[ -z "$OLD" || "$OLD" == "$o" ]] || refuse 'refusing multi-tip merge update.'; OLD=$o
done
[[ "$N" -eq 0 ]] && exit 0
[[ "$N" -eq 1 && -n "$BRANCH" ]] || refuse 'refusing multi-tip merge update.'
typ=$("${G[@]}" cat-file -t "$NEW" 2>/dev/null) || refuse 'refusing unauthorized merge commit.'
[[ "$typ" == "commit" ]] || refuse 'refusing unauthorized merge commit.'
parsed=$("${G[@]}" cat-file -p "$NEW" 2>/dev/null | python3 -I -S -c '
import sys
nt=fp=None; got=[]; n=0; total=0
for raw in sys.stdin.buffer:
    if raw in (b"\n", b"\r\n"): break
    total += len(raw)
    if total > 65536: sys.exit(2)
    line=raw.decode("utf-8","replace").rstrip("\n")
    if line.startswith("tree "):
        if nt is not None: sys.exit(3)
        nt=line[5:]
    elif line.startswith("parent "):
        p=line[7:]; n+=1
        if fp is None: fp=p
        else: got.append(p)
print("|".join([nt or "", fp or "", str(n), " ".join(got)]))
') || refuse 'refusing unauthorized merge commit.'
IFS='|' read -r NT FP parents GOT <<<"$parsed"
[[ -n "$NT" ]] || refuse 'refusing unauthorized merge commit.'
if [[ ! -f "$GD/MERGE_HEAD" ]]; then
  [[ -e "$ARM" || -f "$CLAIM" ]] && refuse 'missing MERGE_HEAD for armed merge authorization.'
  # Ordinary successor first — no branch enumeration while ref locks are held.
  if [[ ! "$OLD" =~ ^0+$ && "$parents" -lt 2 && -n "$FP" && "$FP" == "$OLD" ]]; then
    exit 0
  fi
  # Amend/replace tip: same first parent as OLD, still no merge introduction.
  if [[ ! "$OLD" =~ ^0+$ && "$parents" -lt 2 && -n "$FP" ]]; then
    old_fp=$("${G[@]}" cat-file -p "$OLD" 2>/dev/null | python3 -I -S -c '
import sys
fp=""
for raw in sys.stdin.buffer:
    if raw in (b"\n", b"\r\n"): break
    line=raw.decode("utf-8","replace").rstrip("\n")
    if line.startswith("parent "):
        fp=line[7:]; break
print(fp)
') || old_fp=""
    [[ -n "$old_fp" && "$FP" == "$old_fp" ]] && exit 0
  fi
  # Root tip (zero parents) cannot smuggle a merge — allow create/amend without witnesses.
  if [[ "$parents" -eq 0 ]]; then
    if [[ "$OLD" =~ ^0+$ ]]; then
      exit 0
    fi
    old_parents=$("${G[@]}" cat-file -p "$OLD" 2>/dev/null | python3 -I -S -c '
import sys
n=0
for raw in sys.stdin.buffer:
    if raw in (b"\n", b"\r\n"): break
    line=raw.decode("utf-8","replace").rstrip("\n")
    if line.startswith("parent "): n+=1
print(n)
') || refuse 'refusing unauthorized merge commit.'
    [[ "$old_parents" -eq 0 ]] && exit 0
    refuse 'refusing unauthorized merge commit.'
  fi
  # Exact tip witness: stream heads, bound cardinality, stop on first match.
  tip_witnessed() {
    local want="$1" tip otype symref ref n=0
    while IFS='|' read -r tip otype symref ref; do
      n=$((n + 1))
      [[ "$n" -le 4096 ]] || return 2
      [[ -n "${ref:-}" ]] || continue
      [[ "$ref" == "$BRANCH" ]] && continue
      [[ -z "${symref:-}" ]] || continue
      [[ "${otype:-}" == "commit" ]] || continue
      [[ "$tip" == "$want" ]] && return 0
    done < <("${G[@]}" for-each-ref --format='%(objectname)|%(objecttype)|%(symref)|%(refname)' refs/heads 2>/dev/null || true)
    return 1
  }
  # mode=linear: every node until OLD must be a single-parent commit (no merge smuggle).
  # mode=ancestor: commit-typed DAG walk only (witnessed merge tip FF).
  # Single cat-file --batch process; type-checked; size-capped.
  walk_to_old() {
    python3 -I -S -c '
import subprocess, sys
mode, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
git = sys.argv[4:]
budget, size_lim = 1024, 65536
proc = subprocess.Popen(
    git + ["cat-file", "--batch"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)

def parents_of(oid):
    proc.stdin.write(oid.encode() + b"\n")
    proc.stdin.flush()
    header = proc.stdout.readline()
    if not header:
        return None
    parts = header.split()
    if len(parts) < 3 or parts[1] == b"missing":
        return None
    typ, size = parts[1], int(parts[2])
    # Refuse oversized/non-commits without draining — finally kills the batch proc.
    if typ != b"commit" or size > size_lim:
        return None
    body = proc.stdout.read(size)
    nl = proc.stdout.read(1)
    if nl not in (b"\n", b""):
        return None
    ps = []
    for line in body.splitlines():
        if line == b"":
            break
        if line.startswith(b"parent "):
            ps.append(line[7:].decode())
    if mode == "linear" and len(ps) >= 2:
        return False
    return ps

try:
    seen = set()
    q = [new]
    visited = 0
    while q:
        cur = q.pop(0)
        if cur == old:
            raise SystemExit(0)
        if cur in seen:
            continue
        seen.add(cur)
        visited += 1
        if visited > budget:
            raise SystemExit(1)
        ps = parents_of(cur)
        if ps is None or ps is False:
            raise SystemExit(1)
        q.extend(ps)
    raise SystemExit(1)
finally:
    try:
        proc.stdin.close()
    except Exception:
        pass
    proc.kill()
' "$1" "$2" "$3" "${G[@]}"
  }
  # Linear multi-commit FF: single-parent chain from NEW back to OLD (no merges).
  if [[ ! "$OLD" =~ ^0+$ && "$parents" -lt 2 ]]; then
    set +e
    walk_to_old linear "$OLD" "$NEW"
    walk_rc=$?
    set -e
    [[ "$walk_rc" -eq 0 ]] && exit 0
    refuse 'refusing unauthorized merge commit.'
  fi
  # New branch (zero OLD): exact tip republish only (no merge-base/grafts).
  if [[ "$OLD" =~ ^0+$ ]]; then
    set +e
    tip_witnessed "$NEW"
    tw_rc=$?
    set -e
    [[ "$tw_rc" -eq 0 ]] && exit 0
    refuse 'refusing unauthorized merge commit.'
  fi
  # Multi-parent NEW: must be another direct-head tip AND OLD ancestor of NEW (true FF).
  if [[ "$parents" -ge 2 ]]; then
    set +e
    tip_witnessed "$NEW"
    tw_rc=$?
    set -e
    [[ "$tw_rc" -eq 0 ]] || refuse 'refusing unauthorized merge commit.'
    set +e
    walk_to_old ancestor "$OLD" "$NEW"
    walk_rc=$?
    set -e
    [[ "$walk_rc" -eq 0 ]] && exit 0
    refuse 'refusing unauthorized merge commit.'
  fi
  refuse 'refusing unauthorized merge commit.'
fi
# Live merge only: MERGE_HEAD with a non-merge tip is stale/hostile.
[[ "$parents" -ge 2 ]] || refuse 'refusing unauthorized merge commit.'
[[ "$FOREIGN" -eq 0 ]] || refuse 'refusing unrelated ref update in merge transaction.'
[[ -e "$SPENT" ]] && refuse 'refusing reuse of spent merge authorization.'
[[ -f "$CLAIM" && -f "$ARM" ]] || refuse 'refusing unauthorized merge commit.'
load() { python3 -I -S -c '
import os,shlex,stat,sys
path,limit,n=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]); names=sys.argv[4:]
fd=os.open(path, os.O_RDONLY|getattr(os,"O_NOFOLLOW",0))
try:
  st=os.fstat(fd)
  if not stat.S_ISREG(st.st_mode) or st.st_size>limit: sys.exit(1)
  data=os.read(fd, limit+1)
finally: os.close(fd)
if len(data)>limit: sys.exit(1)
lines=data.decode("utf-8","replace").splitlines()
if len(lines)!=n or len(names)!=n: sys.exit(1)
for a,b in zip(names,lines): print(f"{a}={shlex.quote(b)}")
' "$1" "$2" "$3" "${@:4}"; }
claim_env=$(load "$CLAIM" 65536 4 CH CM CT CJ)
[[ -n "${claim_env:-}" ]] || refuse 'refusing unauthorized merge commit.'
arm_env=$(load "$ARM" 4096 3 AH AD AR)
[[ -n "${arm_env:-}" ]] || refuse 'refusing unauthorized merge commit.'
eval "$claim_env"
eval "$arm_env"
CH=${CH//[[:space:]]/}; CT=${CT//[[:space:]]/}
AH=${AH//[[:space:]]/}; AD=${AD//[[:space:]]/}; AR=${AR//[[:space:]]/}
DG=$(printf '%s\n' "$CH" "$CM" "$CT" "$CJ" | hs); [[ -n "$DG" ]] || exit 1
MH=""
while read -r mh_line; do
  [[ -z "$mh_line" ]] && continue
  peeled=$("${G[@]}" rev-parse "${mh_line}^{commit}" 2>/dev/null) || refuse 'refusing unauthorized merge commit.'
  MH="${MH:+$MH }${peeled//[[:space:]]/}"
done <"$GD/MERGE_HEAD"
EXP=$(printf '%s' "$CJ" | python3 -I -S -c 'import json,sys; print(" ".join(json.load(sys.stdin)))' 2>/dev/null || true)
ok=1
[[ "$CH" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ && "$AH" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || ok=0
[[ "$AR" == "$BRANCH" && "$CH" == "$AH" && "$OLD" == "$CH" && "$AD" == "$DG" && "$FP" == "$CH" && "$NT" == "$CT" ]] || ok=0
[[ -n "$MH" && -n "$EXP" && "$GOT" == "$EXP" && "$GOT" == "$MH" ]] || ok=0
[[ "$ok" -eq 1 ]] || refuse 'refusing unauthorized merge commit.'
(set -C; printf '%s\n' "$NEW" >"$SPENT") || refuse 'refusing reuse of spent merge authorization.'
exit 0
