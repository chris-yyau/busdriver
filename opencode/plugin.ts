/**
 * Busdriver — Opencode Adapter Plugin
 *
 * Translates opencode's tool.execute.before/after hooks into Claude Code's
 * PreToolUse/PostToolUse gate-script protocol. The gate-scripts (bash) stay
 * unchanged in hooks/gate-scripts/ — this adapter pipes Claude-format JSON
 * to their stdin and parses decision:block from stdout.
 *
 * Env vars set for gate-scripts and skill scripts:
 *   BUSDRIVER_PLUGIN_ROOT — path to repo root (replaces CLAUDE_PLUGIN_ROOT)
 *   BUSDRIVER_STATE_DIR   — state directory name (replaces hardcoded .claude/)
 *
 * Gate-scripts use backward-compatible fallbacks:
 *   PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-<relative>}}"
 *   STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
 *
 * Block protocol: opencode has no decision:block return value. Instead,
 * throw new Error(reason) from tool.execute.before — opencode aborts the
 * tool call and feeds the error message back to the LLM.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { spawn } from "node:child_process"
import { writeFileSync, mkdirSync, existsSync } from "node:fs"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
// Resolve plugin root: env var override → relative path from this file.
// When copied to .opencode/plugins/, __dirname is the plugins dir, NOT the
// busdriver checkout. Users must set BUSDRIVER_PLUGIN_ROOT to point at the
// busdriver repo root so gate-scripts can be found.
const PLUGIN_ROOT = process.env.BUSDRIVER_PLUGIN_ROOT || resolve(__dirname, "..")
const STATE_DIR = process.env.BUSDRIVER_STATE_DIR || ".opencode"

// ── Tool name mapping: opencode (lowercase) → Claude (PascalCase) ──────
const TOOL_MAP: Record<string, string> = {
  bash: "Bash",
  write: "Write",
  edit: "Edit",
  read: "Read",
  patch: "Edit",
  apply_patch: "Edit", // opencode's patch tool — extract paths from patchText
  delete: "Edit",
}

// ── Gate configurations ────────────────────────────────────────────────
interface GateConfig {
  script: string
  tool: string | "*" // opencode tool name or "*" for any
  match?: RegExp // command pattern (for bash tool)
  type: "pre" | "post"
}

const GATES: GateConfig[] = [
  // ── Litmus: pre-gates ──
  // Match git commit in all forms including no-arg globals: git commit, git -C dir commit, git --no-pager commit
  { script: "pre-commit-gate.sh", tool: "bash", match: /git\s+(?:-\S+(?:\s+\S+)?\s+)*commit/, type: "pre" },
  // Match gh pr create in all forms: gh pr create, gh -R owner/repo pr create
  { script: "pre-pr-gate.sh", tool: "bash", match: /gh\s+(?:-\S+(?:\s+\S+)?\s+)*pr\s+create/, type: "pre" },
  // ── Litmus: post-gates (marker consumption) ──
  { script: "post-commit-consume-marker.sh", tool: "bash", match: /git\s+(?:-\S+(?:\s+\S+)?\s+)*commit/, type: "post" },
  { script: "post-pr-consume-marker.sh", tool: "bash", match: /gh\s+(?:-\S+(?:\s+\S+)?\s+)*pr\s+create/, type: "post" },
  // ── Blueprint Review: pre-gate ──
  { script: "pre-implementation-gate.sh", tool: "*", type: "pre" },
  // ── Blueprint Review: post-gate (design doc detection) ──
  { script: "check-design-document.sh", tool: "*", type: "post" },
  // ── Pr-Grind: pre-gate ──
  { script: "pre-merge-gate.sh", tool: "bash", match: /gh\s+(?:-\S+(?:\s+\S+)?\s+)*pr\s+merge/, type: "pre" },
  // ── Pr-Grind: post-gate (bypass confirmation) ──
  { script: "post-merge-confirm-bypass.sh", tool: "bash", match: /gh\s+(?:-\S+(?:\s+\S+)?\s+)*pr\s+merge/, type: "post" },
]

// ── Plugin ─────────────────────────────────────────────────────────────
// Default export for opencode plugin loader (expects callable export)
export default async function Busdriver({ directory, worktree }: { directory: string; worktree?: string }) {
  const projectRoot = worktree || directory

  return {
    // Inject env vars for skill scripts run via bash tool
    // opencode provides mutable output.env — must mutate, not return
    "shell.env": async (_input: any, output: { env: Record<string, string> }) => {
      output.env.BUSDRIVER_PLUGIN_ROOT = PLUGIN_ROOT
      output.env.BUSDRIVER_STATE_DIR = STATE_DIR
    },

    // Pre-tool: run pre-gates, throw on block
    "tool.execute.before": async (input, output) => {
      // Normalize apply_patch args: extract file paths from patchText so
      // gate scripts receive file_path like they do for Write/Edit
      let gateArgs = output.args
      if (input.tool === "apply_patch" && output.args?.patchText) {
        const paths = extractPatchPaths(output.args.patchText)
        gateArgs = { ...output.args, file_path: paths.join(", "), filePath: paths.join(", ") }
      }

      for (const gate of GATES.filter((g) => g.type === "pre")) {
        if (!matchesGate(gate, input.tool, gateArgs)) continue
        let result
        try {
          result = await runGateScript(gate, input, gateArgs, projectRoot)
        } catch (e) {
          // Adapter error — log and continue (fail-open for adapter bugs, not for gate decisions)
          console.error(`[busdriver] gate ${gate.script} error:`, e)
          continue
        }
        // Gate decision: throw to block the tool call (opencode aborts on throw)
        if (result.blocked) throw new Error(result.reason ?? `Gate ${gate.script} blocked`)
      }
    },

    // Post-tool: run post-gates (no throw), handle pr-created bridge
    "tool.execute.after": async (input, output) => {
      // Normalize apply_patch args for post-gates too (design doc detection)
      // Run post-gates once per path so check-design-document.sh sees each file
      let postGateCalls: { gate: GateConfig; args: any }[] = []
      if (input.tool === "apply_patch" && input.args?.patchText) {
        const paths = extractPatchPaths(input.args.patchText)
        for (const p of paths) {
          for (const gate of GATES.filter((g) => g.type === "post")) {
            if (!matchesGate(gate, input.tool, { ...input.args, file_path: p, filePath: p })) continue
            postGateCalls.push({ gate, args: { ...input.args, file_path: p, filePath: p } })
          }
        }
      } else {
        for (const gate of GATES.filter((g) => g.type === "post")) {
          if (!matchesGate(gate, input.tool, input.args)) continue
          postGateCalls.push({ gate, args: input.args })
        }
      }

      for (const { gate, args } of postGateCalls) {
        try {
          await runGateScript(gate, input, args, projectRoot, output.output)
        } catch (e) {
          console.error(`[busdriver] post-gate ${gate.script} error:`, e)
        }
      }

      // Pr-Grind bridge: after gh pr create, write pending-grind marker
      // Use same regex pattern as gates to catch flagged forms (gh -R owner/repo pr create)
      if (input.tool === "bash" && /gh\s+(?:-\S+(?:\s+\S+)?\s+)*pr\s+create/.test(input.args?.command ?? "")) {
        try {
          handlePrCreated(output.output, projectRoot)
        } catch (e) {
          console.error(`[busdriver] pr-created bridge error:`, e)
        }
      }
    },
  }
}

// ── Gate matching ──────────────────────────────────────────────────────
function matchesGate(gate: GateConfig, tool: string, args: any): boolean {
  if (gate.tool !== "*" && gate.tool !== tool) return false
  if (gate.match && tool === "bash") {
    const cmd = args?.command ?? ""
    return gate.match.test(cmd)
  }
  return true
}

// ── Extract file paths from apply_patch patchText ──────────────────────
// opencode's apply_patch tool sends a patch body with *** Begin Patch / 
// *** Add File: <path> / *** Update File: <path> / *** Delete File: <path>
// markers. Extract the file paths so gate scripts can evaluate them.
function extractPatchPaths(patchText: string): string[] {
  const paths: string[] = []
  const lines = patchText.split("\n")
  for (const line of lines) {
    // Match Add/Update/Delete File and Move to markers
    const m = line.match(/^\*\*\* (?:Add|Update|Delete) File: (.+)$/)
    const moveM = line.match(/^\*\*\* Move to: (.+)$/)
    if (m) paths.push(m[1].trim())
    if (moveM) paths.push(moveM[1].trim())
  }
  return paths
}

// ── Gate-script runner ─────────────────────────────────────────────────
async function runGateScript(
  gate: GateConfig,
  input: { tool: string; sessionID: string; callID: string },
  args: any,
  projectRoot: string,
  postOutput?: string,
): Promise<{ blocked: boolean; reason?: string }> {
  const scriptPath = resolve(PLUGIN_ROOT, "hooks/gate-scripts", gate.script)

  // Translate opencode JSON → Claude JSON format for gate-script stdin
  const claudeJSON = JSON.stringify({
    tool_name: TOOL_MAP[input.tool] ?? input.tool,
    tool_input: args,
    tool_output: postOutput,
    cwd: projectRoot,
  })

  return new Promise((resolvePromise) => {
    const proc = spawn("bash", [scriptPath], {
      cwd: projectRoot,
      env: {
        ...process.env,
        BUSDRIVER_PLUGIN_ROOT: PLUGIN_ROOT,
        BUSDRIVER_STATE_DIR: STATE_DIR,
      },
      stdio: ["pipe", "pipe", "pipe"],
    })

    let stdout = ""
    let stderr = ""

    proc.stdout.on("data", (data: Buffer) => {
      stdout += data.toString()
    })
    proc.stderr.on("data", (data: Buffer) => {
      stderr += data.toString()
    })

    proc.on("error", (err) => {
      // Adapter error — fail-open (don't block on our own bugs)
      console.error(`[busdriver] failed to spawn ${gate.script}:`, err)
      resolvePromise({ blocked: false })
    })

    proc.on("close", (exitCode: number | null) => {
      // Parse Claude protocol: decision:block in stdout
      const trimmed = stdout.trim()
      if (trimmed.includes('"decision"') && trimmed.includes('"block"')) {
        try {
          const parsed = JSON.parse(trimmed)
          resolvePromise({
            blocked: true,
            reason: parsed.reason ?? `Gate ${gate.script} blocked`,
          })
        } catch {
          resolvePromise({ blocked: true, reason: trimmed })
        }
      } else if (exitCode !== 0 && gate.type === "pre") {
        // Gate-scripts are fail-closed by contract: non-zero exit on a pre-gate
        // without a decision:block message means an error occurred. Block rather
        // than fail-open, matching the gate-scripts' own ERR trap behavior.
        resolvePromise({
          blocked: true,
          reason: `Gate ${gate.script} exited with code ${exitCode} (fail-closed). stderr: ${stderr.slice(0, 500)}`,
        })
      } else {
        resolvePromise({ blocked: false })
      }
    })

    // Pipe Claude-format JSON to gate-script stdin
    proc.stdin.write(claudeJSON)
    proc.stdin.end()
  })
}

// ── Pr-Grind bridge: write pending-grind marker after gh pr create ─────
function handlePrCreated(toolOutput: string, projectRoot: string): void {
  // Extract PR URL from gh pr create output
  const urlMatch = toolOutput?.match(/https?:\/\/\S+\/pull\/\d+/)
  if (!urlMatch) return

  const prUrl = urlMatch[0]
  const stateDir = resolve(projectRoot, STATE_DIR)

  if (!existsSync(stateDir)) {
    mkdirSync(stateDir, { recursive: true })
  }

  // Write pending-grind marker
  writeFileSync(resolve(stateDir, "pr-pending-grind.local"), prUrl)

  // Clear stale clean marker (new PR needs grinding)
  const cleanMarker = resolve(stateDir, "pr-grind-clean.local")
  if (existsSync(cleanMarker)) {
    writeFileSync(cleanMarker, "") // truncate — gate checks existence + content
  }
}

// Named export for environments that prefer named imports
export { Busdriver }
