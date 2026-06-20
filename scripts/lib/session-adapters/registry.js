'use strict';

const { createClaudeHistoryAdapter } = require('./claude-history');
const { createDmuxTmuxAdapter } = require('./dmux-tmux');
const { createCodexWorktreeAdapter } = require('./codex-worktree');

// Optional adapter — busdriver does not ship the opencode session adapter by
// default. Load it lazily so a missing ./opencode module degrades to
// "opencode targets unsupported" instead of throwing MODULE_NOT_FOUND at
// registry-init time (which would crash every consumer, e.g. session-inspect).
let createOpencodeAdapter = null;
try {
  ({ createOpencodeAdapter } = require('./opencode'));
} catch (err) {
  // Tolerate ONLY the adapter module itself being absent (busdriver does not
  // ship it). A syntax error, or a missing transitive dependency once
  // ./opencode IS present, must surface rather than be silently downgraded to
  // "opencode unsupported" — otherwise a real failure hides behind this catch.
  const isMissingOpencodeModule =
    err && err.code === 'MODULE_NOT_FOUND' &&
    typeof err.message === 'string' &&
    err.message.includes("'./opencode'");
  if (!isMissingOpencodeModule) throw err;
  createOpencodeAdapter = null;
}

const TARGET_TYPE_TO_ADAPTER_ID = Object.freeze({
  plan: 'dmux-tmux',
  session: 'dmux-tmux',
  'claude-history': 'claude-history',
  'claude-alias': 'claude-history',
  'session-file': 'claude-history',
  'codex-worktree': 'codex-worktree',
  codex: 'codex-worktree',
  opencode: 'opencode'
});

function buildDefaultAdapterOptions(options, adapterId) {
  const sharedOptions = {
    loadStateStoreImpl: options.loadStateStoreImpl,
    persistSnapshots: options.persistSnapshots,
    recordingDir: options.recordingDir,
    stateStore: options.stateStore
  };

  return {
    ...sharedOptions,
    ...(options.adapterOptions && options.adapterOptions[adapterId]
      ? options.adapterOptions[adapterId]
      : {})
  };
}

function createDefaultAdapters(options = {}) {
  const adapters = [
    createClaudeHistoryAdapter(buildDefaultAdapterOptions(options, 'claude-history')),
    createDmuxTmuxAdapter(buildDefaultAdapterOptions(options, 'dmux-tmux')),
    createCodexWorktreeAdapter(buildDefaultAdapterOptions(options, 'codex-worktree'))
  ];
  // opencode adapter is optional (see lazy require above). Only register it
  // when the module is present; otherwise opencode targets are unsupported.
  if (typeof createOpencodeAdapter === 'function') {
    adapters.push(createOpencodeAdapter(buildDefaultAdapterOptions(options, 'opencode')));
  }
  return adapters;
}

function coerceTargetValue(value) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Error('Structured session targets require a non-empty string value');
  }

  return value.trim();
}

function normalizeStructuredTarget(target, context = {}) {
  if (!target || typeof target !== 'object' || Array.isArray(target)) {
    return {
      target,
      context: { ...context }
    };
  }

  const value = coerceTargetValue(target.value);
  const type = typeof target.type === 'string' ? target.type.trim() : '';
  if (type.length === 0) {
    throw new Error('Structured session targets require a non-empty type');
  }

  const adapterId = target.adapterId || TARGET_TYPE_TO_ADAPTER_ID[type] || context.adapterId || null;
  const nextContext = {
    ...context,
    adapterId
  };

  if (type === 'claude-history' || type === 'claude-alias') {
    return {
      target: `claude:${value}`,
      context: nextContext
    };
  }

  if (type === 'codex-worktree' || type === 'codex') {
    return {
      target: `codex:${value}`,
      context: nextContext
    };
  }

  if (type === 'opencode') {
    return {
      target: `opencode:${value}`,
      context: nextContext
    };
  }

  return {
    target: value,
    context: nextContext
  };
}

function createAdapterRegistry(options = {}) {
  const adapters = options.adapters || createDefaultAdapters(options);

  return {
    adapters,
    getAdapter(id) {
      const adapter = adapters.find(candidate => candidate.id === id);
      if (!adapter) {
        throw new Error(`Unknown session adapter: ${id}`);
      }

      return adapter;
    },
    listAdapters() {
      return adapters.map(adapter => ({
        id: adapter.id,
        description: adapter.description || '',
        targetTypes: Array.isArray(adapter.targetTypes) ? [...adapter.targetTypes] : []
      }));
    },
    select(target, context = {}) {
      const normalized = normalizeStructuredTarget(target, context);
      const adapter = normalized.context.adapterId
        ? this.getAdapter(normalized.context.adapterId)
        : adapters.find(candidate => candidate.canOpen(normalized.target, normalized.context));
      if (!adapter) {
        throw new Error(`No session adapter matched target: ${target}`);
      }

      return adapter;
    },
    open(target, context = {}) {
      const normalized = normalizeStructuredTarget(target, context);
      const adapter = this.select(normalized.target, normalized.context);
      return adapter.open(normalized.target, normalized.context);
    }
  };
}

function inspectSessionTarget(target, options = {}) {
  const registry = createAdapterRegistry(options);
  return registry.open(target, options).getSnapshot();
}

module.exports = {
  createAdapterRegistry,
  createDefaultAdapters,
  inspectSessionTarget,
  normalizeStructuredTarget
};
