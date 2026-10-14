# shellcheck shell=bash
# Sourced first by every tests/test-*.sh that invokes git (#967; the #890 guard).
# Git honors an inherited GIT_DIR / GIT_WORK_TREE over -C, and the GIT_CONFIG_* family can inject
# settings such as core.hooksPath, so a suite run from a hook, `git rebase --exec` or any wrapper
# that exports them would act on the caller's checkout. tests/test-git-env-isolation.sh enforces it.
# Git's own list of repository-local variables (GIT_SHALLOW_FILE, GIT_REPLACE_REF_BASE, ...), the core
# of it spelled out in case git is missing, plus two it omits that still redirect a fixture.
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_CONFIG GIT_CONFIG_PARAMETERS \
  GIT_NAMESPACE GIT_CEILING_DIRECTORIES
for _v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
