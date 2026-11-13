#!/usr/bin/env python3
"""#1085 checks for cmdword: rows and timing through the real hook, fuzz in process.

  cmdword_1085.py rows   <armed-repo>          reproducers must block, controls must allow
  cmdword_1085.py fuzz   <armed-repo> [--full] generated commands bash runs; none that writes may be allowed
                         [--baseline <main's lib>/cmdword.py]  and none main blocks may be allowed
  cmdword_1085.py timing <armed-repo>          32k adversarial inputs: the hook decides within 4.0 s (10.0 s on GitHub)

Every write is first executed under bash >= 5 in a scratch tree: a fixture that does not
write proves nothing about the guard. No bash >= 5 is a FAILURE, not a skip.
"""
import json, os, random, re, shlex, shutil, subprocess, sys, tempfile, textwrap, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GATE = os.path.join(ROOT, "hooks", "gate-scripts", "pre-implementation-gate.sh")
LIB = os.path.join(ROOT, "hooks", "gate-scripts", "lib")
NL, BS, SQ, CR = chr(10), chr(92), chr(39), chr(13)
PASS = FAIL = 0


def ok(label):
    global PASS
    PASS += 1
    print("  ok    " + label)


def no(label, why):
    global FAIL
    FAIL += 1
    print("  FAIL  " + label + " :: " + why)


def bash5():
    for cand in (shutil.which("bash"), "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash", "/bin/bash"):
        if cand and os.path.exists(cand):
            try:
                v = subprocess.run([cand, "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True, timeout=5)
                if v.stdout.strip().isdigit() and int(v.stdout.strip()) >= 5:
                    return cand
            except (OSError, subprocess.TimeoutExpired):
                pass
    print("  FAIL  no bash >= 5 found -- the reproducers cannot be proven")
    sys.exit(2)


BASH = None


def writes(cmd):
    """True when bash, run in a scratch tree, removes src/ or creates src/f."""
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, "src"))
        open(os.path.join(d, "src", "keep"), "w").close()
        try:
            # bash 5's own directory first: a nested `bash -c` must be bash 5 too, or a macOS
            # host measures /bin/bash 3.2's reading of the inner program.
            subprocess.run([BASH, "-c", cmd], cwd=d, capture_output=True, timeout=5, stdin=subprocess.DEVNULL,
                           env={"PATH": os.path.dirname(BASH) + ":/usr/bin:/bin", "HOME": d})
        except subprocess.TimeoutExpired:
            pass                         # a write made before the hang still counts
        s = os.path.join(d, "src")
        return not os.path.isdir(s) or os.path.exists(os.path.join(s, "f"))
    finally:
        shutil.rmtree(d, ignore_errors=True)


def hook(repo, cmd, timeout=30):
    """(decision, seconds): 'block', 'allow' or 'error:<why>' from the real hook."""
    payload = json.dumps({"tool_name": "Bash", "cwd": repo, "tool_input": {"command": cmd}})
    t = time.perf_counter()
    try:
        p = subprocess.run(["bash", GATE], input=payload, cwd=repo, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "error:timeout", time.perf_counter() - t
    dt = time.perf_counter() - t
    # The gate's ERR trap also prints a block; that is a gate failure, and a row must not
    # pass on it. Every other block is a classifier decision (cmdword or marker_check).
    if "Pre-implementation gate error" in p.stdout:
        return "error:gate ERR trap", dt
    if '"block"' in p.stdout:
        return "block", dt
    return ("allow" if p.returncode == 0 else "error:exit %d" % p.returncode), dt


def gate_redirect_check():
    """The gate's own raw redirect check, read out of pre-implementation-gate.sh -- not copied."""
    src = open(GATE).read()
    a = src.rindex("\n", 0, src.index("# Check for shell redirects")) + 1   # whole line, for dedent
    b = src.index("is_mod = True", a) + len("is_mod = True")
    block = textwrap.dedent(src[a:b].replace(SQ + BS + SQ + SQ, SQ))
    if "no_single" not in block or ">{1,2}" not in block:
        print("  FAIL  the gate's redirect check changed shape -- update gate_redirect_check")
        sys.exit(2)
    ns = {"re": re}
    code = compile("def check(cmd):\n    is_mod = False\n" + textwrap.indent(block, "    ") + "\n    return is_mod\n",
                   "gate-redirect", "exec")
    # The source is this repo's own gate script, the code under test, never outside input.
    exec(code, ns)  # nosemgrep: python.lang.security.audit.exec-detected.exec-detected
    return ns["check"]


# ── rows ─────────────────────────────────────────────────────────────────────
W_RM, W_RE = "rm -rf src", "echo x > src/f"
DQPROG = 'bash -c "eval ' + BS + '$""' + SQ  # opener hidden by quote concatenation


def enc(p):    # a program written as a $'…' body: #, ', \ and newlines as escapes
    return p.replace(BS, BS + BS).replace(SQ, BS + SQ).replace("#", BS + "x23").replace(NL, BS + "n")


def dq(p):     # the same body inside double quotes
    return "".join(BS + c if c in BS + '"$`' else c for c in p)


def repro():
    rows = []
    for w in (W_RM, W_RE):
        rows += [
            ': "$(echo ${v%)}; ' + w + ')"',
            ': "$(# )' + NL + w + ')"',
            ': "$(cat <<E' + NL + ")" + NL + "E" + NL + w + ')"',
            "echo ${v%<<E #}; " + w,
            "echo `echo # `echo ; " + w,
            "echo #" + BS + NL + w,
            "bash -c " + shlex.quote("echo # x" + NL + w),
            "sh -c " + shlex.quote("echo # x" + NL + w),
            "eval " + shlex.quote("echo # x" + NL + w),
            "bash -c " + shlex.quote(': "$(echo # it' + SQ + 's' + NL + w + ')"'),
            "bash -c $'" + enc("echo # x" + NL + w) + "'",
            "sh -c $'" + enc("echo # x" + NL + w) + "'",
            "eval $'" + enc("echo # x" + NL + w) + "'",
            "bash -c $'echo " + BS + "x23 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "043 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "u0023 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "U00000023 x" + BS + "n" + w + "'",
            "bash -c $'echo " + BS + "x23 x" + BS + "r" + BS + "n" + w + "'",
            ': "$(bash -c $' + SQ + "echo " + BS + "x23 x" + BS + "n" + w + SQ + ')"',
            "bash -c $" + BS + NL + "'echo " + BS + "x23 x" + BS + "n" + w + "'",
            DQPROG + dq("echo " + BS + "x23 x" + BS + "n" + w) + SQ + '"',
            DQPROG + dq("echo $((1<<2))" + BS + "n" + "echo " + BS + "x23" + BS + BS + BS + "n" + w) + SQ + '"',
            "bash -c $'echo # x" + NL + w + "'",                       # a literal newline inside $'…'
            "sh -c $'echo # x" + NL + w + "'",
            "eval $'echo # x" + NL + w + "'",
            "bash -c 'echo $''{v%<<E #}; " + w + "'",
            "echo ${v:-$" + BS + NL + "{x#}<<E #}; " + w,
            "echo $" + BS + NL + "{v%<<E #}; " + w,
            "echo ${v" + BS + NL + ":-$" + BS + NL + "{x}<<E #}; " + w,
            "cat <(echo ${v%)}; " + w + ")",
            "cat >(echo ${v%)}; " + w + "); wait $!",   # bash does not wait for >( ) itself
            "cat ${v:-<(echo ${v%)}; " + w + ")}",   # procsub inside ${…} runs; cat waits for it
            "bash -c $'echo # x" + BS + "c" + BS * 3 + "n" + w + "'",   # `\c\\` is one escape
            # `\c` then a LITERAL newline is control-newline, a newline: no NUL ends the program.
            "bash -c $'echo # a" + BS + "c" + NL + BS + "n" + w.replace("rm ", BS + "x72m ") + "'",
            # A `$'E\tF'` heredoc delimiter, a comment (so the third reading runs), then the verb
            # split by a line continuation: every lexer scan must decode the delimiter as bash
            # does, or the third reading's continuation join misses it.
            "bash -c " + shlex.quote("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "echo # x" + NL + w[0] + BS + NL + w[1:]),
            # A `<( )` inside `${…}`: its `}` is its own, so the `${` does not end in its comment.
            "echo ${v:-<(# }" + NL + "true) #}; " + w,
            "echo ${v:-<(# }" + NL + "true)<<E #}; " + w,
            # A continuation inside a heredoc delimiter: `<<E\<nl>OF` delimits on EOF.
            "bash -c $'" + enc("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ) + "'",
            "bash -c " + shlex.quote("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # A newline quoted inside `${…}` is a newline in the program bash -c / eval runs.
            'bash -c "echo # x "${v:-' + SQ + NL + w + SQ + "}",
            'eval "echo # x" ${v:-' + SQ + NL + w + SQ + "}",
            # A continuation right after `<<`, then a blank: bash joins it, so it is `<< EOF`.
            "bash -c $'" + enc("cat <<" + BS + NL + " EOF" + NL + "it" + SQ + "s" + NL + "EOF" + NL + w + NL + "echo # " + SQ) + "'",
            "bash -c " + shlex.quote("cat <<" + BS + NL + " EOF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # ... and inside a double-quoted delimiter word.
            "bash -c " + shlex.quote("cat <<" + chr(34) + "E" + BS + NL + "OF" + chr(34) + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + w + NL + "echo # " + SQ),
            # Past-Unicode escape: bash emits bytes, so `#` is mid-word. `\x72m` hides the verb
            # from main's reading; a decoder that deleted the escape allowed it.
            "bash -c $'" + BS + "U00110000#; " + w.replace("rm ", BS + "x72m ") + "'",
            # `\c` masks a BYTE: `\cĀ` is 04 80, not a NUL that would end the program.
            "bash -c $'echo # x" + BS + "c" + chr(0x100) + BS + "n" + w.replace("rm ", BS + "x72m ") + "'",
            # CR is a word character to bash, so this `#` is mid-word, not a comment.
            "echo " + CR + "#; " + w,
            "bash -c " + shlex.quote("echo a" + CR + "#; " + w),
            # Ends in an UNCLOSED quote: unreadable at depth 0, so it blocks. The closed-quote
            # variant has no `#` or `$` and stays allowed (Deviations 4).
            "cat <<EOF" + NL + "it" + SQ + "s" + NL + "EOF" + NL + w + NL + "echo " + SQ + "a",
        ]
    rows.append('echo ${v%<<E #}; "r' + BS + NL + 'm" -rf src')
    rows.append("bash -c $'echo " + BS + "x23 x" + BS + "n" + BS + "x72m -rf src'")   # verb spelled with escapes
    return rows


CONTROLS = [
    "echo ${v%)}", ': "$(echo ${v%)})"', "echo $'it" + BS + "'s'",
    "echo $(case ${v#x} i" + BS + NL + "n x) :;; esac)",
    "echo hi # note", "echo #" + BS + NL + "ls", "git log --oneline -1 # x" + BS + NL,
    "echo $((n+1))", "echo $(echo a)#" + BS + NL + "b",
    "echo 'a # b" + NL + "c'", "bash -c 'echo \"a # b" + NL + "c\"'",
    "echo $'" + BS + "x23 not a comment'; ls", "bash -c $'echo " + BS + "x23 x" + BS + "nls'",
    "printf $'a" + BS + "nb" + BS + "x23c" + BS + "n'",
    "echo $" + BS + NL + "{HOME}", "echo '$" + BS + NL + "'", "echo ${v:-$" + BS + NL + "{x#}}; ls",
    'bash -c "echo # x' + BS + NL + 'ls"', 'echo "' + BS + "$HOME costs " + BS + "`x" + BS + '`"',
    "git status --short # see" + NL + "git log -1",
    "cat <<'E'" + NL + "it" + SQ + "s # a note" + NL + "E",
    'git commit --dry-run -m "fix: x' + NL + NL + "# keep this line" + NL + 'body"',
    "git status" + CR + NL + "git log -1" + CR + NL, "echo hi # x" + CR + NL + "ls",   # CRLF
    "printf $'a" + BS + "c?b'",
    "bash -c $'echo # a" + BS + "c" + NL + BS + "nls'",
    "bash -c " + shlex.quote("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "echo # x" + NL + "l" + BS + NL + "s"),
    "echo ${v:-<(# }" + NL + "true) #}; ls",
    "bash -c " + shlex.quote("cat <<E" + BS + NL + "OF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + "ls" + NL + "echo # " + SQ),
    'bash -c "echo # x "${v:-' + SQ + NL + "ls" + SQ + "}",
    "bash -c " + shlex.quote("cat <<" + BS + NL + " EOF" + NL + "hello" + NL + "EOF" + NL + "echo # " + SQ + NL + "ls" + NL + "echo # " + SQ),
]
STATED_OVER_BLOCK = [": $(" + NL + "# " + BS + NL + "echo hi)"]   # spec Residuals: _lex_bodies over-block


LEX = [  # shell_lex._subst_bodies directly: shapes the hook rows cannot isolate
    ("echo <(true)#$(echo HI)", (["true", "echo HI"], True)),     # `#` after `)` is mid-word
    ("cat <(echo ${v%)}; ls)", (["echo ${v%)}; ls"], True)),     # `)` inside ${…} closes nothing
    ("((true); cat <(rm -rf src))", (["rm -rf src"], True)),     # a bare `((` bash runs as subshells
]


def switch_off(shell_lex):
    """Deviations 7 and 11: every Task 1 lexer change reads as on main with the switch off,
    and marker_check keeps the block main has on the command that the ungated arm unblocked."""
    def on(f, *a):
        shell_lex._cmdword_on[0] = True
        try:
            return f(*a)
        finally:
            shell_lex._cmdword_on[0] = False
    Q = chr(34)
    p = "${v:-<(echo })}"
    checks = [
        ("<( ) bodies read with the switch on", on(shell_lex._subst_bodies, "cat <(rm -rf src) >(tee x)")
         == (["rm -rf src", "tee x"], True)),
        ("<( ) bodies not read with it off", shell_lex._subst_bodies("cat <(rm -rf src) >(tee x)") == ([], True)),
        ("<( ) inside double quotes is text", on(shell_lex._subst_bodies, "echo " + Q + "<(rm x)" + Q) == ([], True)),
        ("_param_span: the procsub owns its } (on)", on(shell_lex._param_span, p, 0) == len(p)),
        ("_param_span: ends at that } (off)", shell_lex._param_span(p, 0) == 13),
    ]
    for w in ("<<" + BS + NL + " EOF", "<<-" + BS + NL + " EOF", "<<E" + BS + NL + "OF", "<<" + Q + "E" + BS + NL + "OF" + Q):
        want = (("EOF", "-" in w), len(w))
        checks.append(("heredoc word joins continuations (on): " + repr(w), on(shell_lex._heredoc_delim, w, 0) == want))
        checks.append(("heredoc word as on main (off): " + repr(w), shell_lex._heredoc_delim(w, 0) != want))
    for esc in ("t", "cI"):
        c = ": " + Q + "$(cat <<$" + SQ + "E" + BS + esc + "F" + SQ + NL + ")" + NL + "E" + chr(9) + "F" + NL + "rm -rf src)" + Q
        bodies, good = on(shell_lex._subst_bodies, c)
        checks.append(("$'E\\%sF' delimiter closes (on)" % esc, good and any("rm -rf src" in b for b in bodies)))
        checks.append(("$'E\\%sF' delimiter gives up as on main (off)" % esc, shell_lex._subst_bodies(c) == ([], False)))
    for label, good in checks:
        ok("switch: " + label) if good else no("switch: " + label, "differs")
    c = ": " + Q + "$(echo ${v:-<(# it" + SQ + "s" + NL + "true)}; echo lease_slot.py)" + Q
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run([sys.executable, "-I", os.path.join(LIB, "marker_check.py")], cwd=d, text=True,
                           capture_output=True, input=json.dumps({"tool_name": "Bash", "cwd": d, "tool_input": {"command": c}}))
    label = "marker_check keeps main's block on Deviation 7's command"
    ok(label) if r.stdout.startswith("BLOCK_MARKER_SCRIPT") else no(label, repr(r.stdout[:80]))


def rows(repo):
    sys.path.insert(0, LIB)
    import shell_lex
    import cmdword
    # Deviation 11: the full delimiter decode is off for marker_check, so off outside is_file_mod.
    before = list(shell_lex._cmdword_on)
    cmdword.is_file_mod("cat <<$'E" + BS + "tF'" + NL + "x" + NL + "E\tF" + NL + "ls")
    label = "shell_lex._cmdword_on is off outside is_file_mod"
    ok(label) if before == shell_lex._cmdword_on == [False] else no(label, repr((before, shell_lex._cmdword_on)))
    switch_off(shell_lex)
    # Deviation 3: in the third reading a raw NUL is restored as a newline, so inside a quoted
    # program it ends that program's comment. In-process: the hook's stdin cannot carry a NUL.
    for cmd, want in (("bash -c " + SQ + "echo # x" + chr(0) + W_RM + SQ, True),
                      ("bash -c " + SQ + "echo # x" + chr(0) + "ls" + SQ, False)):
        label = "raw NUL in a program: " + repr(cmd)
        ok(label) if cmdword.is_file_mod(cmd) == want else no(label, "is_file_mod said " + repr(not want))
    for cmd, want in LEX:
        shell_lex._cmdword_on[0] = True     # as is_file_mod runs it: `<(` reads only then
        try:
            got = shell_lex._subst_bodies(cmd)
        finally:
            shell_lex._cmdword_on[0] = False
        label = "lex: " + repr(cmd)
        ok(label) if got == want else no(label, "got " + repr(got))
    for cmd in repro():
        label = "block: " + repr(cmd)[:90]
        if not writes(cmd):
            no(label, "bash does not write -- not a reproducer")
            continue
        got, _ = hook(repo, cmd)
        ok(label) if got == "block" else no(label, "hook said " + got)
    for cmd in CONTROLS:
        label = "allow: " + repr(cmd)[:90]
        if writes(cmd):
            no(label, "bash writes -- not a control")
            continue
        got, _ = hook(repo, cmd)
        ok(label) if got == "allow" else no(label, "hook said " + got)
    for cmd in STATED_OVER_BLOCK:
        got, _ = hook(repo, cmd)
        label = "stated over-block still blocks: " + repr(cmd)
        ok(label) if got == "block" else no(label, "hook said " + got + " -- update spec Residuals")


# ── fuzz ─────────────────────────────────────────────────────────────────────
FR = ["echo ${v%)}", "echo ${v:-)}", "echo ${v#)}", "echo ${v//)/x}", "echo ${#v}", "echo ${v%<<E #}",
      "echo $'\\)'", "echo $'\\''", "echo $')'", "echo ')'", 'echo ")"', "echo \\)", "echo a#)",
      "# )\n", "echo # )\n", "echo #\\\n", "cat <<E\n)\nE\n", "cat <<'E'\n) #\nE\n", "cat <<-E\n\t)\n\tE\n",
      "echo `echo )`", "echo `echo # `", "echo $((1<<2))", "echo $(( (1) ))", "(( x = (1) ))",
      "[[ x == ) ]] 2>/dev/null", "case x in x) :;; esac", "case x in (x) echo );; esac", "f() { :; }",
      "echo $(echo ))", "echo \"$(echo ')')\"", "echo ${v-$(echo ))}", ":", "true", "echo x\\\ny",
      "ca\\\nse x in x) :;; esac", "e\\\ncho )", "echo $\\\n{v%)}", "echo `echo \\`echo )\\``",
      "echo \"${v%\")\"}\"", "echo ${v:-`echo )`}", "echo ${v:-$(echo '#')}", "echo \"#)\"", "echo x#\\\ny",
      "echo # it's\n", "echo hi # x\n", "cat <(echo ))", "echo $\"a)\"", "echo $'\\x23 )'", "echo $'a\\nb'",
      "echo ${v:-$\\\n{x#}<<E #}", "echo $\\\n{HOME}"]
FORMS = {
    "subst": lambda m, w: ': "$(' + m + "\n" + w + ')"',
    "substs": lambda m, w: ': "$(' + m + "; " + w + ')"',
    "substu": lambda m, w: ": $(" + m + "\n" + w + ")",
    "top": lambda m, w: m + "; " + w,
    "topnl": lambda m, w: m + "\n" + w,
    "bashc": lambda m, w: "bash -c " + shlex.quote(m + "\n" + w),
    "bashca": lambda m, w: "bash -c $'" + enc(m + "\n" + w) + "'",
    "bashcj": lambda m, w: "bash -c $\\\n'" + enc(m + "\n" + w) + "'",
    "bashce": lambda m, w: DQPROG + dq(enc(m + "\n" + w)) + SQ + '"',
}


def load_baseline(path):
    """is_file_mod of another cmdword.py (e.g. main's), importing its OWN lib/ siblings.

    The branch's modules are hidden from sys.modules while it loads, or its `import shell_lex`
    would bind the branch copy and the baseline would be half this branch (#1105)."""
    lib = baseline_lib(path)
    names = [f[:-3] for f in os.listdir(lib) if f.endswith(".py")]
    saved = {n: sys.modules.pop(n) for n in names if n in sys.modules}
    sys.path.insert(0, lib)
    try:
        import cmdword as mod
        import shell_lex as lex
    finally:
        sys.path.remove(lib)
        for n in names:
            sys.modules.pop(n, None)
        sys.modules.update(saved)
    check_own_lex(mod, lex, lib)
    return mod.is_file_mod


def baseline_lib(path):
    """The lib/ dir of a baseline cmdword.py that is not this branch's."""
    lib = os.path.dirname(os.path.abspath(path))
    # `import cmdword` reads lib/cmdword.py, so any other name would be silently ignored.
    if os.path.basename(path) != "cmdword.py" or not os.path.isfile(path):
        raise RuntimeError("baseline must be an existing cmdword.py: " + path)
    if os.path.samefile(lib, LIB):
        raise RuntimeError("baseline resolved to this branch's cmdword")
    return lib


def check_own_lex(mod, lex, lib):
    if os.path.dirname(os.path.abspath(lex.__file__)) != lib or mod.shell_lex is not lex:
        raise RuntimeError("baseline did not load its own shell_lex: " + lex.__file__)


def fuzz(full, baseline=None):
    sys.path.insert(0, LIB)
    from cmdword import is_file_mod
    redirect = gate_redirect_check()
    base = load_baseline(baseline) if baseline else None
    plan = [(19, 1500), (20, 1500)] if full else [(19, 300)]
    floor = 30000 if full else 2500   # commands that write; fewer means the generator broke
    runs = misses = regress = 0
    for seed, per_form in plan:
        for form, build in FORMS.items():
            for w in (W_RM, W_RE):
                rnd = random.Random("%d/%s/%s" % (seed, form, w))
                for _ in range(per_form):
                    parts = [rnd.choice(FR) for _ in range(rnd.randint(1, 4))]
                    mid = "".join(p if p.endswith("\n") else p + rnd.choice(["; ", "\n", " && ", " | "]) for p in parts)
                    cmd = build(mid.rstrip("; &|\n"), w)
                    verdict = is_file_mod(cmd) or redirect(cmd)
                    if base is not None and not verdict and (base(cmd) or redirect(cmd)):
                        regress += 1      # every candidate, writing or not: additive only
                        no("fuzz", "baseline blocks, this allows: " + repr(cmd))
                    if not writes(cmd):
                        continue
                    runs += 1
                    if not verdict:
                        misses += 1
                        no("fuzz", "bash writes, the gate allows: " + repr(cmd))
    if runs < floor:
        no("fuzz", "only %d commands wrote, floor %d -- the generator or bash broke" % (runs, floor))
    elif misses == 0 and regress == 0:
        ok("fuzz: %d commands that write, none allowed%s (%s)" % (
            runs, ", no block->allow vs baseline" if base else "", "full" if full else "ci"))


# ── timing ───────────────────────────────────────────────────────────────────
CAP = 32768                     # cmdword._LEX_READING_MAX: the third reading's worst case
# 4.0 s locally (the meaningful number, under the 5 s hook deadline); 10.0 s on a GitHub
# runner, the 2.5x calibration #553 measured there. Keyed on GITHUB_ACTIONS only, as #553 is.
LIMIT = 10.0 if os.environ.get("GITHUB_ACTIONS", "").strip().lower() == "true" else 4.0
TRIG = "# x\\\n$'\\''\n"
UNITS = ["${v}", "${v%)}", "$(", "${", "`", "#\\\n", "case x in ", "$(case x in x) ", "x) ", "<<E\n",
         "\\\n", "'a\n# b\n'", "bash -c 'x # y\n'", "$(( (1) ))", "<<<x ", "$(echo ${v%)}; ", '"', "'",
         "$'\\x23\\n'", "# "]
TAILS = ["", ")", "\nE\n", "'"]
# marker_check alone exceeds 5 s on these on main, before cmdword runs. Tracked separately.
MC_OVER = {"$(", "`"}


def timing(repo):
    for u in UNITS:
        for tail in TAILS:
            if u in MC_OVER:
                continue
            cmd = (': "$(' + TRIG + "echo " + u * ((CAP - 60) // len(u)) + tail + '; ls)"')[:CAP]
            got, dt = hook(repo, cmd, timeout=10)
            label = "timing %r %r: %s in %.2fs" % (u, tail, got, dt)
            ok(label) if got in ("block", "allow") and dt <= LIMIT else no(label, "over %.1f s or no decision" % LIMIT)
    # Over the cap: a read-only command holding `$` blocks, fast, without the third reading.
    # A shape main allows, so only the cap can block it (the in-process pair below proves that).
    cmd = "echo " + "a" * (CAP + 7232) + " $HOME"
    got, dt = hook(repo, cmd, timeout=10)
    label = "over _LEX_READING_MAX: a %d-char read-only command with $ blocks, in %.2fs" % (len(cmd), dt)
    ok(label) if got == "block" and dt <= LIMIT else no(label, "hook said " + got)
    sys.path.insert(0, LIB)
    import cmdword
    real = cmdword._LEX_READING_MAX
    try:
        cmdword._LEX_READING_MAX = len(cmd) + 1
        uncapped = cmdword.is_file_mod(cmd)
    finally:
        cmdword._LEX_READING_MAX = real
    label = "the over-cap block comes from the cap: allowed with the cap raised, blocked with it"
    ok(label) if real == CAP and not uncapped and cmdword.is_file_mod(cmd) else no(
        label, "cap %r, raised %r" % (real, uncapped))
    print("  skip  marker_check over budget on main (#1095): " + ", ".join(sorted(MC_OVER)))


def main():
    global BASH
    if len(sys.argv) < 3 or sys.argv[1] not in ("rows", "fuzz", "timing"):
        print(__doc__)
        return 2
    BASH = bash5()
    mode, repo = sys.argv[1], sys.argv[2]
    if mode == "rows":
        rows(repo)
    elif mode == "fuzz":
        base = sys.argv[sys.argv.index("--baseline") + 1] if "--baseline" in sys.argv else None
        fuzz("--full" in sys.argv, base)
    else:
        timing(repo)
    print("SUMMARY %d %d" % (PASS, FAIL))
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
