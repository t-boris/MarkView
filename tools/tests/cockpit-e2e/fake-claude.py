#!/usr/bin/python3
"""A scripted stand-in for the `claude` command line, used by the Cockpit end-to-end checks.

MarkView runs `claude` in two ways and this file answers both without a model:

* Planning (`claude -p … --json-schema …`, prompt on stdin): prints the next plan of $E2E_DIR/plans.json as the structured answer.
  The prompt MarkView sent is kept in $E2E_DIR/planner-prompt-<n>.txt.
* The supervisor (`claude -p … --system-prompt "You are the supervisor of a Copilot Cockpit run …"`): answers by keywords in the
  question, as a structured {answer, outOfScope}. "deploy", "production", "secret" or "password" -> outOfScope; "FAIL-EXIT" always
  exits 1, "FAIL-GARBAGE" prints an answer that is not the schema, "FAIL-ONCE" exits 1 the first time it is asked. Every call is
  appended to $E2E_DIR/supervisor.log and its prompt kept in $E2E_DIR/supervisor-prompt-<n>.txt.
* A Cockpit step (an interactive terminal: `claude update && claude … --mcp-config <json>`): reads the pasted assignment, takes the
  actions listed in the step's assignment after the marker `E2E:` and ends. Each action is one JSON object:
    {"call": "<markview tool>", "args": {…}}   one MarkView tool call through `MarkView --project-call`, from this process
    {"write": "<file>", "text": "…"}           write a file in the project (append with "append": true)
    {"commit": "<message>"}                    git add -A and commit
    {"sleep": <seconds>}                       work for a while
    {"progress": {…}}                          markview_cockpit_report_progress with the ticket of this step
    {"complete": {"passed": true, "detail": "…", "build": ""}}   markview_cockpit_complete_step with the ticket of this step
    {"ask_many": {"template": "Question {i}?", "start": 1, "count": 26}}   markview_cockpit_ask once per i, results summarised
    {"note": "…"}                              only logged
  Every action and its outcome is appended to $E2E_DIR/agent.log (one JSON object per line).

The process is a child of the step's terminal shell, so a tool call it makes reaches MarkView with the same process ancestry as the
MCP server of a real agent (`--project-call` asks the same app socket with the same ancestor pids).
"""
import json, os, re, select, subprocess, sys, termios, time, tty

E2E = os.environ.get("E2E_DIR", "")


def log(entry):
    entry["t"] = round(time.time(), 2)
    with open(os.path.join(E2E, "agent.log"), "a") as f:
        f.write(json.dumps(entry) + "\n")


def supervisor():
    prompt = sys.stdin.read()
    counter = os.path.join(E2E, "supervisor.count")
    n = (int(open(counter).read()) if os.path.exists(counter) else 0) + 1
    open(counter, "w").write(str(n))
    open(os.path.join(E2E, "supervisor-prompt-%d.txt" % n), "w").write(prompt)
    m = re.search(r"The agent's question: (.*)", prompt)
    question = m.group(1) if m else ""
    entry = {"event": "supervisor", "n": n, "question": question}
    lowered = question.lower()
    once = os.path.join(E2E, "supervisor.failed-once")
    if "fail-exit" in lowered or ("fail-once" in lowered and not os.path.exists(once)):
        if "fail-once" in lowered:
            open(once, "w").write("1")
        entry["mode"] = "exit 1"
        slog(entry)
        sys.stderr.write("fake supervisor failure\n")
        sys.exit(1)
    if "fail-garbage" in lowered:
        entry["mode"] = "garbage"
        slog(entry)
        print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "I think so", "total_cost_usd": 0.0,
                          "usage": {"input_tokens": 1, "output_tokens": 1}}), flush=True)
        return
    outside = any(word in lowered for word in ("deploy", "production", "secret", "password"))
    answer = {"answer": "Do not do this; record it as a blocker." if outside else "Take the conservative option for: " + question[:60],
              "outOfScope": outside}
    entry["mode"] = "outOfScope" if outside else "answered"
    slog(entry)
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "", "structured_output": answer,
                      "total_cost_usd": 0.0, "usage": {"input_tokens": 1, "output_tokens": 1}}), flush=True)


def slog(entry):
    entry["t"] = round(time.time(), 2)
    with open(os.path.join(E2E, "supervisor.log"), "a") as f:
        f.write(json.dumps(entry) + "\n")


def planner():
    prompt = sys.stdin.read()
    counter = os.path.join(E2E, "planner.count")
    n = int(open(counter).read()) if os.path.exists(counter) else 0
    open(counter, "w").write(str(n + 1))
    open(os.path.join(E2E, "planner-prompt-%d.txt" % (n + 1)), "w").write(" ".join(sys.argv[1:]) + "\n---\n" + prompt)
    plans = json.load(open(os.path.join(E2E, "plans.json")))
    plan = plans[min(n, len(plans) - 1)]
    log({"event": "plan", "call": n + 1})
    print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "", "structured_output": plan,
                      "total_cost_usd": 0.0, "usage": {"input_tokens": 1, "output_tokens": 1}}), flush=True)


def read_assignment():
    """The pasted prompt of the step: bracketed paste, then Enter. The terminal is put in raw mode, as a real agent does."""
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        print("Fake Claude Code ready\r\n> ", end="", flush=True)
        data = b""
        while True:
            ready, _, _ = select.select([fd], [], [], 120)
            if not ready:
                return None
            chunk = os.read(fd, 65536)
            if not chunk:
                return None
            data += chunk
            if b"\x1b[201~" in data and (data.endswith(b"\r") or data.endswith(b"\n")):
                break
        text = data.decode("utf-8", "replace").replace("\x1b[200~", "").replace("\x1b[201~", "")
        return text
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


def markview_binary():
    args = sys.argv[1:]
    if "--mcp-config" in args:
        config = json.loads(args[args.index("--mcp-config") + 1])
        for server in config.get("mcpServers", {}).values():
            return server["command"]
    return None


def call(binary, root, tool, args, ticket=""):
    env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_") and not k.startswith("MV_PROBE")}
    args = dict(args)
    args.setdefault("project_folder", root)
    if tool == "markview_cockpit_ask":
        args.setdefault("ticket", ticket)
    try:
        done = subprocess.run([binary, "--project-call", tool, json.dumps(args)], capture_output=True, text=True, timeout=90, env=env, cwd=root)
        return {"exit": done.returncode, "output": (done.stdout + done.stderr).strip()[:600]}
    except subprocess.TimeoutExpired:
        return {"exit": -1, "output": "timed out"}


def step():
    text = read_assignment()
    if text is None:
        log({"event": "no assignment"})
        return
    kept = len([f for f in os.listdir(E2E) if f.startswith("step-prompt-")]) + 1
    open(os.path.join(E2E, "step-prompt-%d.txt" % kept), "w").write(text)
    ticket = re.search(r"ticket ([0-9A-Fa-f-]{36})", text)
    root = re.search(r"project_folder ([^\s,]+)", text)
    marker = text.index("Assignment and prior results (JSON):")
    start = text.index("{", marker)
    task, _ = json.JSONDecoder().raw_decode(text[start:])
    title = task["step"]["title"]
    assignment = task["step"]["assignment"]
    actions = json.loads(assignment[assignment.index("E2E:") + 4:]) if "E2E:" in assignment else []
    binary = markview_binary()
    ticket = ticket.group(1) if ticket else ""
    root = root.group(1) if root else os.getcwd()
    log({"event": "step start", "argv": [a[:80] for a in sys.argv[1:]], "step": title, "ticket": bool(ticket), "root": root, "binary": bool(binary), "controls": task.get("controls")})
    for action in actions:
        entry = {"event": "action", "step": title, "action": action}
        # Logged before it runs: a step that is stopped in the middle of an action still leaves this line.
        log({"event": "action start", "step": title, "action": action})
        if "call" in action:
            entry["result"] = call(binary, root, action["call"], action.get("args", {}), ticket)
        elif "ask_many" in action:
            spec = action["ask_many"]
            results = []
            for i in range(spec.get("start", 1), spec.get("start", 1) + spec["count"]):
                r = call(binary, root, "markview_cockpit_ask", {"question": spec["template"].format(i=i)}, ticket)
                results.append([i, r["exit"], r["output"][:110]])
            entry["result"] = {"asked": spec["count"], "results": results}
        elif "write" in action:
            path = os.path.join(root, action["write"])
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "a" if action.get("append") else "w") as f:
                f.write(action.get("text", ""))
            entry["result"] = {"written": action["write"]}
        elif "commit" in action:
            done = subprocess.run("git add -A && git commit -q -m %s" % json.dumps(action["commit"]), shell=True, capture_output=True, text=True, cwd=root)
            entry["result"] = {"exit": done.returncode, "output": (done.stdout + done.stderr).strip()[:300]}
        elif "sleep" in action:
            time.sleep(action["sleep"])
            entry["result"] = {"slept": action["sleep"]}
        elif "progress" in action:
            entry["result"] = call(binary, root, "markview_cockpit_report_progress", dict(action["progress"], ticket=ticket))
        elif "complete" in action:
            body = dict(action["complete"], ticket=ticket)
            body.setdefault("build", "")
            entry["result"] = call(binary, root, "markview_cockpit_complete_step", body)
        else:
            entry["result"] = {"note": action.get("note", "")}
        log(entry)
    log({"event": "step end", "step": title})
    # A real agent's session ends with its report; a step without a `complete` action leaves the terminal open until it is closed.
    if not any("complete" in a for a in actions):
        time.sleep(3600)


if __name__ == "__main__":
    argv = sys.argv[1:]
    if argv[:1] == ["update"]:
        sys.exit(0)
    if "-p" in argv:
        system = argv[argv.index("--system-prompt") + 1] if "--system-prompt" in argv else ""
        if system.startswith("You are the supervisor of a Copilot Cockpit run"):
            supervisor()
        else:
            planner()
    else:
        try:
            step()
        except Exception:
            import traceback
            log({"event": "step crashed", "trace": traceback.format_exc()})
            raise
