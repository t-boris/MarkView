#!/usr/bin/python3 -I
"""Local ACP peer for continuation and permission checks; never contacts a provider."""
import json
import os
import sys

fixture_root = os.path.dirname(os.path.realpath(__file__))
if not os.path.realpath(os.getcwd()).startswith(fixture_root + os.sep):
    sys.exit(64)
with open(os.path.join(fixture_root, "children.pid"), "a", encoding="utf-8") as registry:
    registry.write(str(os.getpid()) + "\n")
if "--acp" not in sys.argv:
    sys.exit(64)

expected = " ".join(f"prototype-markup-{i} section" for i in range(40)) + " end"
full = '{"body":"' + expected + '"}'
pretty = '{\n  "body": "' + expected + '"\n}'
split = 300
narration = "I'll read the key source files first. The tokens file holds " + '{"color":{"brand":"#0b5"},"radius":4} and the shell layout follows it.\n\n'
scenarios = ["[resume]", "[repeat-tail]", "[restart]", "[complete-max-tokens]", "[never-ends]", "[no-progress]", "[plain-cut-off]", "[narrated-complete]", "[narrated]", "[internal-restart-continued]", "[internal-restart]", "[pretty-restart]", "[pretty-restart-continued]", "[declines]", "[permission]"]
scenario = ""
turn = 0
sent = ""


def send(value):
    print(json.dumps(value), flush=True)


def chunk(text):
    send({"method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def finish(identifier, reason="end_turn"):
    send({"id": identifier, "result": {"stopReason": reason}})


for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    identifier = message["id"]
    if message.get("method") != "session/prompt":
        result = {"sessionId": "fixture"} if message.get("method") == "session/new" else {}
        send({"id": identifier, "result": result})
        continue
    text = message["params"]["prompt"][0].get("text", "")
    if turn == 0:
        scenario = next((item for item in scenarios if item in text), "")
    turn += 1
    head = full[:split]
    if scenario == "[pretty-restart]":
        chunk(head + "\nLet me provide the complete JSON:\n" + pretty if turn == 1 else "The answer is complete.")
    elif scenario == "[pretty-restart-continued]":
        chunk(head + "\n" + pretty[:split] if turn == 1 else pretty[split:])
    elif scenario == "[internal-restart]":
        if turn != 1:
            send({"id": identifier, "error": {"code": -1, "message": "no continuation turn may be spent"}})
            continue
        chunk(head)
        chunk(full)
    elif scenario == "[internal-restart-continued]":
        if turn == 1:
            chunk(head)
            chunk(head)
        else:
            chunk(full[split:])
    elif scenario == "[permission]":
        folder = text.split("[permission]|")[-1].splitlines()[0]
        asks = [("read-inside", "read", {"path": folder + "/notes/a.md"}),
                ("read-relative", "read", {"path": "notes/b.md"}),
                ("read-outside", "read", {"path": folder + "/../outside.md"}),
                ("search", "search", {}), ("edit", "edit", {"path": folder + "/notes/a.md"})]
        answers = []
        for index, (label, kind, data) in enumerate(asks):
            send({"jsonrpc": "2.0", "id": 900 + index, "method": "session/request_permission", "params": {
                "toolCall": {"kind": kind, "rawInput": data},
                "options": [{"optionId": "yes", "kind": "allow_once"}, {"optionId": "no", "kind": "reject_once"}]}})
            reply = json.loads(sys.stdin.readline())
            outcome = reply.get("result", {}).get("outcome", {}).get("optionId", "none")
            answers.append(label + "=" + outcome)
        chunk(",".join(answers))
    elif scenario == "[declines]":
        chunk(head if turn == 1 else ("The answer is complete." if turn == 2 else "Nothing further to add."))
    elif scenario in ("[resume]", "[repeat-tail]", "[restart]", "[no-progress]"):
        if turn == 1:
            sent = head
            chunk(head)
        elif scenario == "[resume]":
            chunk(full[split:])
        elif scenario == "[repeat-tail]":
            chunk(sent[-200:] + full[split:])
        elif scenario == "[restart]":
            chunk(full)
    elif scenario == "[complete-max-tokens]":
        chunk('{"body":"done"}' if turn == 1 else '{"body":"continued after a finished answer"}')
        finish(identifier, "max_tokens" if turn == 1 else "end_turn")
        continue
    elif scenario == "[never-ends]":
        chunk('{"body":"segment-1 ' + "x" * 200 if turn == 1 else f" segment-{turn} " + "y" * 200)
    elif scenario == "[plain-cut-off]":
        chunk("first part" if turn == 1 else " second part")
        finish(identifier, "max_tokens" if turn == 1 else "end_turn")
        continue
    elif scenario == "[narrated]":
        chunk(narration + "```json\n" + head if turn == 1 else full[split:] + "\n```")
    elif scenario == "[narrated-complete]":
        chunk(narration + '```json\n{"body":"narrated"}\n```')
    finish(identifier)
