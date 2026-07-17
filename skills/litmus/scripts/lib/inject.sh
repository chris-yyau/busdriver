#!/bin/bash
# Assemble a review prompt by substituting {{PLACEHOLDER}} tokens with literal
# values in a SINGLE forward pass over the template.
#
# Avoids two corruption classes that silently mangled the reviewer's copy of the
# code and manufactured phantom findings (findings that cite real line numbers,
# so they look genuine and are easy to "fix" by editing correct code):
#
#   1. bash >=5.2 rewrites an unescaped `&` in a ${var/pat/repl} *replacement* to
#      the matched text, so a diff/context block containing `&` (URL query strings
#      ?a=1&b=2, shell &&, C/Go bitwise &, HTML entities) had every `&` replaced
#      by the literal placeholder token. Quoted prefix/suffix removal inserts the
#      value verbatim on every bash version — no `&`/`\` reinterpretation, and no
#      `\&` escaping (which would itself break bash <=5.1). (#393)
#
#   2. Substituting one placeholder at a time re-scans the whole string each pass,
#      so a value injected earlier — e.g. a staged diff of THIS file, which
#      contains the literal token {{SMART_CONTEXT}} — would be matched by a LATER
#      substitution, corrupting both. A single forward pass over the TEMPLATE
#      freezes each injected value into the output so it can never be re-read as a
#      placeholder. Only placeholders present in the ORIGINAL template are ever
#      substituted. (Surfaced reviewing #393's own diff.)

# render_prompt TEMPLATE PLACEHOLDER VALUE [PLACEHOLDER VALUE ...]
#
# Replaces the FIRST occurrence of each placeholder with its literal value,
# earliest-in-template first (so injected values are appended to the output and
# never re-scanned). Each placeholder is substituted at most once (matches the
# prior single-substitution `/` — not `//` — semantics); placeholders absent from
# the template are ignored; all other text is emitted verbatim.
render_prompt() {
  local template=$1; shift
  local -a phs=() vals=() used=()
  while [[ "$#" -ge 2 ]]; do
    phs+=("$1"); vals+=("$2"); used+=(0); shift 2
  done

  local out=""
  while :; do
    # Pick the not-yet-used placeholder occurring earliest in the remaining
    # template (shortest prefix before it).
    local best=-1 bidx=-1 i prefix
    for ((i = 0; i < ${#phs[@]}; i++)); do
      [[ "${used[i]}" == 1 ]] && continue
      case "$template" in
        *"${phs[i]}"*)
          prefix=${template%%"${phs[i]}"*}
          if [[ "$best" -lt 0 || "${#prefix}" -lt "$best" ]]; then
            best=${#prefix}; bidx=$i
          fi
          ;;
      esac
    done
    [[ "$bidx" -lt 0 ]] && break
    out+=${template%%"${phs[bidx]}"*}${vals[bidx]}
    template=${template#*"${phs[bidx]}"}
    used[bidx]=1
  done
  printf '%s%s' "$out" "$template"
}
