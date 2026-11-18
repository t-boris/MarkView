#!/usr/bin/python3 -I
"""Local fake ACP, Codex and Claude processes for timeout and cancellation tests."""
import json
import os
import signal
import sys
import time

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
elif "exec" in sys.argv:
    text = sys.stdin.read()
    if "[ignores-term]" in text:
        stubborn()
    time.sleep(0.35)
    send({"type": "item.completed", "item": {"type": "agent_message", "text": '{"ok":true}'}})
    send({"type": "turn.completed"})
elif "-p" in sys.argv:
    sys.stdin.read()
    time.sleep(0.35)
    send({"type": "result", "structured_output": {"ok": True}, "result": "", "is_error": False})
else:
    sys.exit(64)
