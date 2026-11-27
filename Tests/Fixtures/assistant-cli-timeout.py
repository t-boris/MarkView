#!/usr/bin/python3 -I
"""Local fake ACP, Codex and Claude processes for timeout and cancellation tests."""
import json
import os
import signal
import sys
import time
import uuid

fixture_root = os.path.dirname(os.path.realpath(__file__))
if not os.path.realpath(os.getcwd()).startswith(fixture_root + os.sep):
    sys.exit(64)

with open(os.path.join(fixture_root, "children.pid"), "a", encoding="utf-8") as registry:
    registry.write(str(os.getpid()) + "\n")


def send(value):
    print(json.dumps(value), flush=True)


def stubborn():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open("stubborn-ready", "w", encoding="utf-8") as marker:
        marker.write("ready")
    time.sleep(30)


if "--acp" in sys.argv:
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        identifier = message["id"]
        method = message.get("method")
        if method == "session/new":
            send({"id": identifier, "result": {"sessionId": "fixture"}})
        elif method == "session/prompt":
            text = message["params"]["prompt"][0].get("text", "")
            if "[ignores-term]" in text:
                stubborn()
            if "[provider-error]" in text:
                send({"id": identifier, "error": {"code": -32000, "message": "fixture provider error"}})
                continue
            time.sleep(0.35)
            send({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": '{"ok":true}'}}}})
            send({"id": identifier, "result": {"stopReason": "end_turn"}})
        else:
            send({"id": identifier, "result": {}})
elif sys.argv[1:3] == ["delete", "--force"] and len(sys.argv) == 4:
    # `codex delete --force <id>`: removes the session's rollout and notes the delete.
    thread = sys.argv[3]
    sessions = os.path.join(fixture_root, "home", ".codex", "sessions")
    found = False
    for folder, _, files in os.walk(sessions):
        for name in files:
            if name.endswith("-" + thread + ".jsonl"):
                os.remove(os.path.join(folder, name))
                found = True
    with open(os.path.join(fixture_root, "codex-deleted.txt"), "a", encoding="utf-8") as log:
        log.write(thread + "\n")
    if not found:
        print("Error: failed to delete session", file=sys.stderr)
        sys.exit(1)
    print("Deleted session " + thread + ".")
elif "exec" in sys.argv:
    text = sys.stdin.read()
    if "--ephemeral" not in sys.argv:
        # A run that keeps its session writes a rollout, as codex 0.172 does, and names it first.
        thread = str(uuid.uuid4())
        folder = os.path.join(fixture_root, "home", ".codex", "sessions", time.strftime("%Y/%m/%d"))
        os.makedirs(folder, exist_ok=True)
        meta = {"type": "session_meta", "payload": {"id": thread, "originator": "codex_exec", "source": "exec", "cwd": os.getcwd()}}
        with open(os.path.join(folder, "rollout-" + time.strftime("%Y-%m-%dT%H-%M-%S") + "-" + thread + ".jsonl"), "w",
                  encoding="utf-8") as rollout:
            rollout.write(json.dumps(meta) + "\n")
        send({"type": "thread.started", "thread_id": thread})
    with open(os.path.join(fixture_root, "codex-runs.jsonl"), "a", encoding="utf-8") as log:
        log.write(json.dumps({"ephemeral": "--ephemeral" in sys.argv, "agents_off": "agents.enabled=false" in sys.argv,
                              "asks_for_subagents": "start subagents" in text}) + "\n")
    if "[ignores-term]" in text:
        stubborn()
    if "[slow]" in text:
        time.sleep(5)
    time.sleep(0.35)
    send({"type": "item.completed", "item": {"type": "agent_message", "text": '{"ok":true}'}})
    send({"type": "turn.completed"})
elif "-p" in sys.argv:
    sys.stdin.read()
    time.sleep(0.35)
    send({"type": "result", "structured_output": {"ok": True}, "result": "", "is_error": False})
else:
    sys.exit(64)
