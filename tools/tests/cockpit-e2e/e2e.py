#!/usr/bin/python3
"""Cockpit end-to-end checks in the real Debug MarkView app, driven through its UI, with a scripted planner and step agent.

    python3 tools/tests/cockpit-e2e/e2e.py --app <path to a Debug MarkView.app> [--work DIR] [--keep] S5 S1 S2 S4 S3 S6

For every scenario: a fresh fixture project, a COPY of the app (own bundle id, empty HOME, own control-socket folder, every window
transparent and click-through), `fake-claude.py` as the `claude` command, a probe script that clicks through the Cockpit tab, and
checks on the files the app and the fake agent left behind. See README.md.
"""
import argparse, glob, json, os, plistlib, shlex, shutil, signal, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
BUNDLE_ID = "com.markview.CockpitE2E"


# Extra defaults for the app copy (`--app-args "-AppleInterfaceStyle Light -appFontScalePercent 150"`), to look at a screen in another
# appearance or at a larger text size. Empty by default.
EXTRA_APP_ARGS = []


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


class Context:
    """What one scenario run left behind, for the checks."""

    def __init__(self, name, work):
        self.name = name
        self.dir = os.path.join(work, name)
        # A folder name of its own: the window is picked by its title, and a name shared with an earlier scenario would match its window.
        self.fx = os.path.join(self.dir, "fx-%s-e2e" % name.lower())
        self.home = os.path.join(self.dir, "home")
        # A unix socket path is limited to 104 bytes, which a deep work folder exceeds: the control socket lives in a short folder.
        self.sock = "/tmp/cke-" + name
        self.e2e = os.path.join(self.dir, "e2e")
        self.out = os.path.join(self.dir, "out")
        self.checks = []

    # --- evidence readers ---
    def runs(self):
        found = []
        for path in sorted(glob.glob(os.path.join(self.fx, ".dde/cockpit/runs/*.json"))):
            with open(path) as f:
                found.append(json.load(f))
        return found

    def agent_log(self):
        path = os.path.join(self.e2e, "agent.log")
        if not os.path.exists(path):
            return []
        return [json.loads(line) for line in open(path) if line.strip()]

    def actions(self):
        return [e for e in self.agent_log() if e.get("event") == "action"]

    def result_of(self, tool, nth=0):
        hits = [e for e in self.actions() if e["action"].get("call") == tool]
        return hits[nth]["result"] if len(hits) > nth else None

    def supervisor_calls(self):
        path = os.path.join(self.e2e, "supervisor.log")
        return [json.loads(line) for line in open(path) if line.strip()] if os.path.exists(path) else []

    def supervisor_prompt(self, n):
        path = os.path.join(self.e2e, "supervisor-prompt-%d.txt" % n)
        return open(path).read() if os.path.exists(path) else ""

    def step_prompts(self):
        return [open(p).read() for p in sorted(glob.glob(os.path.join(self.e2e, "step-prompt-*.txt")))]

    def wait_for_log(self, needle, seconds):
        """Block until the agent log mentions `needle` (used by a `during` hook)."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                if any(needle in json.dumps(e) for e in self.agent_log()):
                    return True
            except ValueError:
                pass  # a line is half written
            time.sleep(1)
        return False

    def probe_log(self):
        path = os.path.join(self.out, "log.txt")
        return open(path).read() if os.path.exists(path) else ""

    def dump(self, name):
        path = os.path.join(self.out, name)
        return open(path).read() if os.path.exists(path) else ""

    def git(self, *args):
        return sh("git", *args, cwd=self.fx).stdout

    # --- recording ---
    def check(self, title, ok, evidence):
        self.checks.append({"check": title, "ok": bool(ok), "evidence": str(evidence)})
        print("  [%s] %s -- %s" % ("PASS" if ok else "FAIL", title, str(evidence)[:300]))
        return ok


def prepare_app(app_src, work):
    app = os.path.join(work, "MarkViewE2E.app")
    if not os.path.exists(app):
        print("copying", app_src)
        subprocess.run(["ditto", app_src, app], check=True)
        plist_path = os.path.join(app, "Contents/Info.plist")
        with open(plist_path, "rb") as f:
            info = plistlib.load(f)
        info["CFBundleIdentifier"] = BUNDLE_ID
        with open(plist_path, "wb") as f:
            plistlib.dump(info, f)
    dylib = os.path.join(work, "e2eprobe.dylib")
    source = os.path.join(HERE, "e2eprobe.m")
    if not os.path.exists(dylib) or os.path.getmtime(dylib) < os.path.getmtime(source):
        subprocess.run(["clang", "-dynamiclib", "-fobjc-arc", "-arch", "arm64", "-framework", "AppKit", "-framework", "QuartzCore",
                        "-w", "-o", dylib, source], check=True)
    return app, dylib


def kill_strays(home):
    """Every process that carries this run's HOME in its environment (the app's children included)."""
    ps = sh("ps", "eww", "-A", "-o", "pid=,command=").stdout.splitlines()
    pids = [int(line.split(None, 1)[0]) for line in ps if "CFFIXED_USER_HOME=" + home in line]
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return pids


def run_scenario(sc, app, dylib, work, keep):
    ctx = Context(sc["name"], work)
    shutil.rmtree(ctx.dir, ignore_errors=True)
    # The app reopens the last project it had (`workspace.lastFolder` in its preferences): every scenario starts from none.
    subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
    shutil.rmtree(ctx.sock, ignore_errors=True)
    assert len(ctx.sock) + len("/mv-browser-99999.sock") < 100
    for d in (ctx.home, ctx.sock, ctx.e2e, ctx.out, os.path.join(ctx.dir, "bin")):
        os.makedirs(d)
    os.makedirs(os.path.join(ctx.home, "Library"))
    subprocess.run([os.path.join(HERE, "make-fixture.sh"), ctx.fx], check=True, capture_output=True)
    if sc.get("prepare"):
        sc["prepare"](ctx)
    claude = os.path.join(ctx.dir, "bin", "claude")
    os.symlink(os.path.join(HERE, "fake-claude.py"), claude)
    with open(os.path.join(ctx.e2e, "plans.json"), "w") as f:
        json.dump(sc["plans"], f)
    script = os.path.join(ctx.dir, "probe.txt")
    with open(script, "w") as f:
        f.write(sc["script"](ctx))
    env = dict(os.environ, HOME=ctx.home, CFFIXED_USER_HOME=ctx.home, MARKVIEW_SOCKET_DIR=ctx.sock, DYLD_INSERT_LIBRARIES=dylib,
               MV_PROBE_SCRIPT=script, MV_PROBE_OUT=ctx.out, MV_PROBE_SECONDS=str(sc["seconds"]), E2E_DIR=ctx.e2e)
    for key in ("CLAUDECODE", "NO_COLOR"):
        env.pop(key, None)
    print("== %s: %s (up to %ds)" % (sc["name"], sc["title"], sc["seconds"]))
    started = time.time()
    ctx.app_binary = os.path.join(app, "Contents/MacOS/MarkView")
    ctx.external = {}
    hook = threading.Thread(target=sc["during"], args=(ctx,), daemon=True) if sc.get("during") else None
    if hook:
        hook.start()
    with open(os.path.join(ctx.out, "stdout.txt"), "w") as out:
        proc = subprocess.Popen([os.path.join(app, "Contents/MacOS/MarkView"), "-ApplePersistenceIgnoreState", "YES",
                                 "-settings.cli.claudePath", claude] + EXTRA_APP_ARGS, env=env, stdout=out, stderr=subprocess.STDOUT, cwd=ctx.dir)
        try:
            proc.wait(timeout=sc["seconds"] + 20)
        except subprocess.TimeoutExpired:
            proc.kill()
    if hook:
        hook.join(timeout=30)
    time.sleep(1)
    strays = kill_strays(ctx.home)
    ctx.elapsed = round(time.time() - started)
    print("  app ended after %ds, strays killed: %s" % (ctx.elapsed, strays or "none"))
    ctx.check("probe script ran to its end", "script finished" in ctx.probe_log() or "terminate" in ctx.probe_log(), ctx.probe_log().strip().splitlines()[-1:])
    ctx.check("no probe step failed (NOT FOUND / TIMEOUT)", "NOT FOUND" not in ctx.probe_log() and "TIMEOUT" not in ctx.probe_log(),
              [l for l in ctx.probe_log().splitlines() if "NOT FOUND" in l or "TIMEOUT" in l])
    sc["verify"](ctx)
    with open(os.path.join(ctx.out, "result.json"), "w") as f:
        json.dump(ctx.checks, f, indent=1)
    shutil.rmtree(ctx.sock, ignore_errors=True)
    subprocess.run(["defaults", "delete", BUNDLE_ID], capture_output=True)
    if not keep and all(c["ok"] for c in ctx.checks):
        shutil.rmtree(os.path.join(ctx.dir, "home"), ignore_errors=True)
    return ctx


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="a Debug build of MarkView.app (it is copied, never run in place)")
    parser.add_argument("--work", default="/tmp/cockpit-e2e")
    parser.add_argument("--keep", action="store_true")
    parser.add_argument("--app-args", default="", help='extra defaults for the app copy, e.g. "-AppleInterfaceStyle Light -appFontScalePercent 150"')
    parser.add_argument("names", nargs="+")
    args = parser.parse_args()
    EXTRA_APP_ARGS.extend(shlex.split(args.app_args))
    import scenarios
    os.makedirs(args.work, exist_ok=True)
    app, dylib = prepare_app(args.app, args.work)
    summary = {}
    for name in args.names:
        ctx = run_scenario(scenarios.ALL[name], app, dylib, args.work, args.keep)
        summary[name] = [c for c in ctx.checks if not c["ok"]]
    print("\n== summary")
    for name, failed in summary.items():
        print("%s: %s" % (name, "PASS" if not failed else "FAIL (%d)" % len(failed)))
        for c in failed:
            print("    -", c["check"], "::", c["evidence"][:200])
    sys.exit(0 if not any(summary.values()) else 1)


if __name__ == "__main__":
    main()
