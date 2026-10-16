#!/usr/bin/env python3
"""needs-shipping-selftest.py — assertion rows for scripts/needs-shipping.py (#952).

Usage:
    /usr/bin/python3 -I tests/needs-shipping-selftest.py    prints needs_shipping_selftest_ok

Loads the classifier by absolute path; the classifier never loads this file, so it stays one
file under `python3 -I`. Run by tests/test-needs-shipping.sh. Kept Python 3.9-compatible.
"""
import importlib.util
import os
import re
import time

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "scripts", "needs-shipping.py")
_SPEC = importlib.util.spec_from_file_location("needs_shipping", _PATH)
_NS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_NS)
globals().update({k: v for k, v in vars(_NS).items() if not k.startswith("__")})  # the rows use the classifier's bare names


def selftest_structured():
    """#950 structured_config asserts, kept out of selftest() to bound its complexity."""
    for p in (".claude/settings.json", "A/.CLAUDE/Settings.Local.JSON", ".cursor/mcp.json", "x/.mcp.json",
              ".codex/config.toml", ".agents/a.yml", ".claude/x/y.yaml", ".cursor/a.jsonc"):
        assert structured_config(p), p
    for p in ("settings.json", ".cursor/environment.json", "X/.Cursor/Environment.json", ".claude/x.md",
              ".claude/hook.sh", "docs/a.json"):
        assert not structured_config(p), p


def selftest_frontmatter():
    """#950 frontmatter_trips asserts, kept out of selftest() to bound its complexity."""
    fm = "---\n%s\n---\nbody"
    for t in ("no frontmatter\nhooks: x", fm % "name: s\ndescription: d", fm % "# c\nname: s",
              fm % "metadata:\n  hooks: x", "body\n---\nhooks: x\n---"):
        assert not frontmatter_trips(t), t
    for t in (fm % "hooks: x", fm % "mcpServers: {}", "\ufeff" + fm % "hooks: x", "---  \nhooks: x\n---",
              "---\r\nhooks: x\r\n---\r\n", "---\rhooks: x\r---", "---\nname: s\nhooks: x",
              "---\nname: s\n...\nhooks: x\n---", fm % '"hooks": x', fm % "!!str hooks: x",
              fm % "{hooks: x}", fm % "<<: *a", fm % "- x", fm % "  hooks: x", "  ---\nhooks: x\n---"):
        assert frontmatter_trips(t), t
    assert frontmatter_trips(fm % "hooks: x") == "hook or MCP server in frontmatter"
    for k in ("lspServers", "monitors", "settings"):
        assert frontmatter_trips(fm % (k + ": x")) == "hook or MCP server in frontmatter", k
    assert frontmatter_trips(fm % "- x") == "unreadable frontmatter"


def selftest_shell():
    """#950 injects_shell asserts, kept out of selftest() to bound its complexity."""
    for t in ("!`x`", "Diff: !`git diff`", "- PR diff: !`gh pr diff`", "a\r!`x`", "\t!`x`", "\ufeff!`x`",
              "```!\nx\n```", "  ````!\nx", "- ```!\nx\n```", "> ```!\nx", "see ```! x```", "$unused!`x`",
              "${CLAUDE_SKILL_DIR}!`x`", "a $ARGUMENTS[0]!`x`", "$1!`x`", "!`a`b!`c`", "\u3000!`x`",
              "!$unused`./x.sh`", "!$ARGUMENTS`x`", "``$unused`!\nx", "x$a!`y`", "prefix$0!`./x.sh`",
              "x$a!$b`./x.sh`", "x$a\ufeff!$b`cmd`"):
        assert injects_shell(t), t
    for t in ("plain ! text", "```bash\nx\n```", "use `println!` here", "KEY=!`cmd`", "$x then `println!` here", "price $5!", "c!$d`x`", "$a `b` !c"):
        assert not injects_shell(t), t


def selftest_shell_paths():
    """#950 shell_scope and shell_path asserts, kept out of selftest() to bound its complexity."""
    assert shell_scope(".claude/skills/s/SKILL.md") and shell_scope(".claude/Commands/c.md")
    assert not shell_scope("CLAUDE.md") and not shell_scope(".claude/agents/x.md")
    for p in (".claude/skills/ !`bash x.sh`/SKILL.md", ".claude/skills/foo !/SKILL.md", ".claude/skills/x```/SKILL.md",
              ".cursor/commands/a!b.md"):
        assert shell_path(p), p
    for p in (".claude/skills/s/SKILL.md", ".claude/notes/a!.md"):
        assert not shell_path(p), p


def first(text):
    return parse(text)[0]


def selftest_classify():
    for routed in (["src/app/page.tsx"], ["docs/a.md", "src/x.ts"], ["docs/a.ts", "src/a.ts"], [],
                   ["foo/README.md"], [".claude/settings.json"], [".cursor/skills/verify-x/SKILL.md"],
                   ["src/app/a.test.ts\ndocs/x"], [".github/lighthouse.baseline.json.bak"], ["docs"],
                   ["x/docs/a.md"], [".claude/CLAUDE.md"], ["AGENTS.md"], ["CLAUDE.md"], ["docs/AGENTS.md"],
                   ["docs/.agents/skills/x/SKILL.md"], ["tests/.cursorrules"], ["tests/.cursor/rules/x.mdc"],
                   [".claude/agents/verifier.md"]):
        assert needs_shipping(routed, len(routed)), routed
    assert needs_shipping(["docs/a.md"] * FILES_CAP, FILES_CAP)
    assert not needs_shipping(["docs/a.md", "docs/b.md"] * 1500, 1500)  # 1500 renames = 1500 records
    for skipped in (["docs/a/b.md", "README.md"], ["client/x.test.tsx"], ["docs/claude/skills.md"],
                    [".github/lighthouse.baseline.json"], ["tests/e2e/a.spec.ts", "__tests__/b.js"]):
        assert not needs_shipping(skipped, len(skipped)), skipped
    for p in (".cursor/skills/x/SKILL.md", "apps/web/.cursor/skills/x/SKILL.md", ".claude/settings.json",
              ".codex/agents/x.md", ".agents/skills/x/SKILL.md", "AGENTS.md", "docs/CLAUDE.md",
              ".cursorignore", "web/.cursorindexingignore", ".Claude/x.md", "CLAUDE.local.md",
              "apps/web/CLAUDE.local.md", ".mcp.json"):
        assert agent_config(p), p
    for p in ("src/skills/x.ts", "docs/claude/skills.md", "src/my.claude.ts", ".gitignore", "src/claude.md.bak"):
        assert not agent_config(p), p
    assert skills_field(["verify-a", "verify-b"]) == "verify-a,verify-b"
    assert skills_field(["verify-a", "verify-a$b"]) == "-"


def selftest_parse():
    """#936 import walk: the parser's token budget and code-span flags."""
    assert first("see @docs/a.md.") == (["docs/a.md.", "docs/a.md"], False, False)
    assert parse("a@b.com serve@14") == []
    assert len(parse("@@a")) == 2 and len(parse("@x " * 1000)) == 1000
    try:
        parse("@" * 20000)
        raise AssertionError("an @-run past the token budget must make the walk incomplete")
    except Incomplete:
        pass
    assert not first("`\r\r@../docs/a.md `")[1] and not first("`\r\n\r\n@../docs/a.md `")[1]
    assert not parse("a `b\n" + chr(0xA0) + "\n`@../docs/a.md`")[0][1]  # a no-break-space line is not blank
    assert first("`@x` `@y`")[1] and parse("`@x` `@y` @z")[2][1] is False
    big = "`x` " * 120000 + "@a " * 10000  # one ~500 KiB line: 120k spans x 10k tokens, linear time
    t0 = time.monotonic()
    assert len(parse(big)) == 10000 and time.monotonic() - t0 < 20
    try:
        parse("@a " * (MAX_TOKENS + 1))
        raise AssertionError("more than MAX_TOKENS tokens must make the walk incomplete")
    except Incomplete:
        pass


def selftest_spans_fuzz():
    def spans_ref(line):  # the quadratic pairing the linear code_spans must reproduce
        runs = [(m.start(), m.end()) for m in re.finditer(r"`+", line)]
        out, i, ok = [], 0, True
        while i < len(runs):
            n = runs[i][1] - runs[i][0]
            j = next((k for k in range(i + 1, len(runs)) if runs[k][1] - runs[k][0] == n), None)
            if j is None:
                ok, i = False, i + 1
            else:
                out.append((runs[i][0], runs[j][1]))
                i = j + 1
        return out, ok
    import random
    rnd = random.Random(936)  # seeded fuzz against brute-force oracles: no token lost, spans exact
    for _ in range(3000):
        s = "".join(rnd.choice("`@x/. \n\r\t\"'\\<a") for _ in range(rnd.randrange(40)))
        eligible = [k for k, ch in enumerate(s) if ch == "@" and not (k and s[k - 1].isalnum())]
        try:
            got = parse(s)
        except Incomplete:
            continue
        assert len(got) == len(eligible), s
        line = s.replace("\n", "").replace("\r", "")
        spans, ok = spans_ref(line)
        assert code_spans(line) == (spans, ok), line
        if line.strip(" \t") and line == s:
            plain = ok and not any(u in line for u in SPAN_UNSAFE)
            assert [t[1] for t in got] == [plain and any(a < k < b for a, b in spans) for k in eligible], s


def selftest_tokens():
    try:
        Clock(0).remaining()
        raise AssertionError("a spent clock must make the walk incomplete")
    except Incomplete:
        pass
    assert first("@my\\ notes.md")[0] == ["my notes.md"]
    assert "docs/x.md" in first("[**@docs/x.md**](docs/x.md)")[0]
    assert "docs/x.md" in first("[@docs/x.md](docs/x.md)")[0]
    assert "docs/policy.md" in first("@docs/policy.md#rules")[0]
    assert first("`@/*`")[0] == ["/*`"] and first("@.")[0] == ["."] and first("@./")[0] == ["./"]
    assert first("@/.,")[0] == ["/.,"]  # neither "/." nor the root-only "/" comes back
    for opener in ("(", "[", "{", "<", ")", ">", "\\", "*", "_", "~", '"', "'", "`"):
        assert len(parse(opener + "@x")) == 1, opener
    assert first("`@/x`")[1] and not first("<a> `@/x`")[1] and not first("[a](b) `@/x`")[1]
    assert not first("| x `y | @../docs/a.md z` |")[1]
    assert first("x a/b` @../docs/a.md `")[1]  # control: the same pair without a URL is a span
    assert not first("x www.example.com/a` @../docs/a.md `")[1] and not first("x https://e.com/a` @a `")[1]
    names = suffix_index(["docs/a.md", "src/docs/a.md", "xdocs/a.md", "docs"])
    assert sorted(by_name(names, "docs/a.md")) == ["docs/a.md", "src/docs/a.md"] and by_name(names, "docs") == ["docs"]
    assert not parse("a `b\n`code @x literal`\n` end")[0][1]
    assert not parse("```\n@x\n```")[0][1]
    assert first('"@docs/a"')[2] and not first("don't @docs/a")[2]
    assert not first('"see @docs/a"')[2] and not first('"done" @docs/a')[2] and not first('\\"@docs/a')[2]


def selftest_resolve():
    """#936 import walk: readers, resolver, query text, predicate."""
    for path, who in (("CLAUDE.md", "both"), ("AGENTS.md", "both"), ("frontend/agents.md", "both"),
                      (".claude/CLAUDE.md", "claude"), (".claude/rules/x.md", "claude"),
                      (".claude/skills/s/SKILL.md", "both"), (".claude/agents/a.md", "both"),
                      (".cursor/rules/r.mdc", "cursor"), (".cursor/CLAUDE.md", "both"),
                      (".claude/rules/.cursor/x.md", "both"), ("pkg/.agents/skills/s/SKILL.md", "cursor"),
                      ("pkg/.cursorrules", "cursor"), (".codex/agents/b.md", "cursor")):
        assert reader(path) == who, path
    z = "0" * 40
    tm = {"docs": ("tree", "040000", z, None), "docs/a.md": ("blob", "100644", z, 1),
          "docs/link": ("blob", SYMLINK, z, 1), "sub": ("commit", "160000", z, None)}
    try:
        resolve(tm, "docs/link/../a.md", True)
        raise AssertionError("a live symlink prefix must make the walk incomplete")
    except Incomplete:
        pass
    assert resolve(tm, "docs/link/../a.md", False).path is DROPPED
    r = resolve(tm, "sub/../docs/a.md", True)
    assert (r.path, r.under_gitlink, r.gitlinks) == ("docs/a.md", False, ["sub"])
    assert resolve(tm, "sub/x.md", False).under_gitlink
    for below in ("sub/x.md", "sub/link/../../docs/a.md"):
        try:
            resolve(tm, below, True)
            raise AssertionError("a live path below a gitlink must make the walk incomplete: " + below)
        except Incomplete:
            pass
    assert resolve(tm, "a/../../docs/a.md", True).path is OUTSIDE
    long_c = "./" * 2045 + "docs/a.md"  # 4099 bytes that normalise to docs/a.md
    assert len(list(candidate_targets(tm, {}, "CLAUDE.md", long_c[4:], True, "claude"))) == 1  # 4095 bytes
    assert list(candidate_targets(tm, {}, "CLAUDE.md", long_c, False, "claude")) == []
    try:
        list(candidate_targets(tm, {}, "CLAUDE.md", long_c, True, "claude"))
        raise AssertionError("a live candidate of PATH_MAX bytes or more must make the walk incomplete")
    except Incomplete:
        pass
    assert resolve(tm, "./", True).path is ROOT
    assert resolve(tm, "new/../docs/a.md", True).missing == "new"
    assert resolve(tm, "docs/new/x.md", True).missing == "docs/new"
    assert blob_query(2) == ("query($owner: String!, $name: String!, $o0: GitObjectID!, $o1: GitObjectID!) "
                             "{ repository(owner: $owner, name: $name) { "
                             "f0: object(oid: $o0) { ... on Blob { byteSize isBinary isTruncated text } } "
                             "f1: object(oid: $o1) { ... on Blob { byteSize isBinary isTruncated text } } } }")
    assert is_config("Docs/A.md", ({"docs/a.md"}, set())) and is_config("docs/n/x", (set(), {"docs/n"}))
    assert is_config("docs/n", (set(), {"docs/n"})) and not is_config("docs/nx", (set(), {"docs/n"}))
    assert is_config("src/x.ts", INCOMPLETE) and not is_config("src/x.ts", None)


def selftest():
    selftest_classify()
    selftest_parse()
    selftest_spans_fuzz()
    selftest_tokens()
    selftest_resolve()
    selftest_structured()
    selftest_frontmatter()
    selftest_shell()
    selftest_shell_paths()
    print("needs_shipping_selftest_ok")


if __name__ == "__main__":
    selftest()
