# shellcheck shell=bash
# Sourced first by every tests/test-*.sh that invokes git (#967; the #890 guard).
# Git honors an inherited GIT_DIR / GIT_WORK_TREE over -C, and the GIT_CONFIG_* family can inject
# settings such as core.hooksPath, so a suite run from a hook, `git rebase --exec` or any wrapper
# that exports them would act on the caller's checkout. tests/test-git-env-isolation.sh enforces it.
# Any inherited GIT_* variable can steer a fixture (GIT_DIR, GIT_NAMESPACE, GIT_DEFAULT_HASH, the
# GIT_CONFIG_* family, ...), so all of them are cleared rather than a list that review keeps extending.
for _v in $(compgen -e | grep '^GIT_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
