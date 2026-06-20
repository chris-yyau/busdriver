# Legacy Counter Approach (Deprecated)

> **This approach is fully deprecated.** The `execute_review.sh` script has been removed.
> Use the state-based approach instead (see SKILL.md):
> ```bash
> bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh 10
> bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh
> ```

## Why State-Based is Better

1. **Automatic increment** - No manual counter management
2. **State persistence** - Survives crashes and restarts
3. **Rich metadata** - Tracks timestamps, status, last result
4. **YAML frontmatter** - Easy to parse and inspect
5. **Automatic cleanup** - Removed on PASS, no manual rm needed
6. **Completion promises** - Semantic exit criteria support
7. **Better debugging** - State file shows full loop history

## Migration Guide

### From Legacy to State-Based

**Before (legacy — no longer supported):**
```bash
echo "1" > /tmp/litmus-iteration.txt
# execute_review.sh has been removed
rm /tmp/litmus-iteration.txt
```

**After (state-based):**
```bash
bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/init-review-loop.sh 10
bash ${BUSDRIVER_PLUGIN_ROOT}/skills/litmus/scripts/run-review-loop.sh
# One review pass per invocation — caller handles fix→re-stage→re-run
# State file tracks iteration count; cleaned up on PASS
```
