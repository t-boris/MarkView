"""The Cockpit end-to-end scenarios: plan, probe script and checks. Run by e2e.py.

S5   happy path, the base run (no supervisor involved)
S7   an agent asks one question and gets the supervisor's answer; logged in the run, shown in the tab
S8   a question about deploying to production is answered "outside the plan"
S9   the supervisor control is off: nobody answers, the agent is told so
S10  a repeated question is answered once; the 25-question cap; a new step starts a new count
S11  the supervisor fails (exit, garbage, once): the agent gets the instruction to decide alone, the run goes on
S12  a wrong ticket, from inside a step and from a process outside any step
S13  a step's model reaches the agent's command line; the run records a timeline with times
S14  pictures of both screens (plan, step editor, running, finished, each tab) for a look; checks only that the run finished
S15  the instrument panel: a lever switched off mid-step refuses the agent's next call, a note reaches the supervisor and the next step
S16  the instrument panel with a failed step and a paused run (lamps, banners, Pause)
S17  the toolbar marks of the singleton tabs: current, open in the background, closed
"""
import glob, json, os, re, subprocess, time

AGENT = "Claude Code"


# ---- plan and script builders ---------------------------------------------------------------------------------------------

def step(title, actions, condition="The step reports passed with its evidence."):
    return {"title": title, "agent": AGENT, "assignment": "Work as scripted.\nE2E: " + json.dumps(actions), "completionCondition": condition,
            "isPrerequisite": False, "qaScenarioID": ""}


def plan(*steps, criteria=("Every step reported passed.",)):
    return {"scenarios": [], "steps": list(steps), "successCriteria": list(criteria), "unavailableOutcomes": [], "alternatives": []}


def opening(ctx, goal, controls=()):
    """Open the fixture, the Cockpit tab, write the goal and set controls. `controls`: probe lines."""
    lines = ["wait 2", "key", "openurl " + ctx.fx, "wait 4", "picktitle " + os.path.basename(ctx.fx),
             "press label:Copilot Cockpit", "waitfor 20 label:Propose plan",
             "settext role:AXTextArea#0 | " + goal, "value role:AXTextArea#0"]
    lines += list(controls)
    lines += ["dump %s/dump-controls.txt" % ctx.out]
    return lines


def propose_and_approve(ctx, tag=""):
    return ["press label:Propose plan", "waitfor 60 label:Review and approve",
            "dump %s/dump-plan%s.txt" % (ctx.out, tag),
            "press label:Review and approve", "waitfor 10 label:Approve and start",
            "press label:Approve and start"]


# A window tall enough for the whole run screen: the radio and switch panels sit below the fold of a 900 px window, and a lazy grid
# keeps what is not on the screen out of the accessibility tree, so the checks that read their text need the full height.
BIG = "size 2200 2400"

PHASES = {"finished": "Finished", "stopped": "Stopped", "paused": "Paused", "interrupted": "Interrupted"}


def finish(ctx, status_label, seconds, tag=""):
    """Wait for the run screen's status chip, then take the picture of the tab and quit."""
    return ["waitfor %d has:%s" % (seconds, PHASES[status_label]), "wait 3", "dump %s/dump-end%s.txt" % (ctx.out, tag)]


def quit_app():
    return ["terminate"]


def script(lines):
    return "\n".join(lines) + "\n"


def only_run(ctx):
    runs = ctx.runs()
    return runs[-1] if runs else None


def step_detail(run, index):
    return run["steps"][index].get("detail", "") if run else ""


# ---- S5 happy path ------------------------------------------------------------------------------------------------------------

S5_PLAN = plan(
    step("Investigate", [
        {"call": "markview_project", "args": {}},
        {"call": "markview_list_bugs", "args": {}},
        {"call": "markview_create_bug", "args": {"title": "Greeting lacks punctuation", "summary": "greet() returns no exclamation mark."}},
        {"write": "docs/notes.md", "text": "notes\n"},
        {"progress": {"passNumber": 1, "activity": "Investigated", "latestChange": "none", "bugs": [], "fixes": [], "blockers": []}},
        {"complete": {"passed": True, "detail": "Investigation done; one bug filed.", "build": ""}}]),
    step("Verify", [
        {"call": "markview_list_bugs", "args": {}},
        {"progress": {"passNumber": 2, "activity": "Verified", "latestChange": "none", "bugs": [], "fixes": [], "blockers": [],
                      "criteriaResults": [{"criterion": "Every step reported passed.", "met": True, "evidence": "both steps passed"}]}},
        {"complete": {"passed": True, "detail": "Final verification passed.", "build": ""}}]),
    criteria=("Every step reported passed.",))


def s5_script(ctx):
    return script(opening(ctx, "Investigate the fixture and verify it.") + propose_and_approve(ctx)
                  + finish(ctx, "finished", 150) + quit_app())


def s5_verify(ctx):
    run = only_run(ctx)
    ctx.check("one run record saved", len(ctx.runs()) == 1, "%d records" % len(ctx.runs()))
    if not run:
        return
    ctx.check("run finished with both steps passed", run["status"] == "finished" and [s["status"] for s in run["steps"]] == ["passed", "passed"],
              "status=%s steps=%s" % (run["status"], [s["status"] for s in run["steps"]]))
    calls = [(e["action"].get("call"), e["result"]["exit"]) for e in ctx.actions() if "call" in e["action"]]
    ctx.check("every allowed MarkView call succeeded (exit 0)", calls and all(c[1] == 0 for c in calls), calls)
    ctx.check("no refusal and no audit text in the step results",
              not any("refused" in r["detail"] or "violation" in r["detail"] for r in run["results"]), [r["detail"][:80] for r in run["results"]])
    ctx.check("time was measured (activeSeconds > 5)", (run.get("activeSeconds") or 0) > 5, run.get("activeSeconds"))
    ctx.check("no limit reason, no waiting reason", run["waitingReason"] == "", run["waitingReason"])
    end = ctx.dump("dump-end.txt")
    ctx.check("the run screen shows the success outcome", "Success against the stated criteria" in end,
              [l for l in end.splitlines() if "Success" in l or "Finished" in l][:4])
    ctx.check("the bug the agent filed exists", len(os.listdir(os.path.join(ctx.fx, "docs/bugs"))) == 1 if os.path.isdir(os.path.join(ctx.fx, "docs/bugs")) else False,
              os.listdir(os.path.join(ctx.fx, "docs")) if os.path.isdir(os.path.join(ctx.fx, "docs")) else "no docs")
    ctx.check("git working tree has no source change", ctx.git("status", "--porcelain", "--", "src", "README.md").strip() == "", ctx.git("status", "--porcelain"))


ALL = {
    "S5": {"name": "S5", "title": "happy path, default controls", "seconds": 180, "plans": [S5_PLAN], "script": s5_script, "verify": s5_verify},
}


# ---- supervisor scenarios -----------------------------------------------------------------------------------------------------

SUP_TOGGLE = "Supervisor answers the agents' questions"
ASK = "markview_cockpit_ask"
DISABLED_TEXT = ("No supervisor is active in this Cockpit run. Do not wait for an answer: decide conservatively inside the controls "
                 "and say what you decided in your step report, or record the question as a blocker.")


def ask(question, **extra):
    return {"call": ASK, "args": dict({"question": question}, **extra)}


def done(detail="Done."):
    return {"complete": {"passed": True, "detail": detail, "build": ""}}


def supervisor_scenario(name, title, plans, controls=(), seconds=150, verify=None, during=None):
    def run_script(ctx):
        return script(opening(ctx, "Work the scripted step and ask the supervisor.", controls) + [BIG, "wait 1"] + propose_and_approve(ctx)
                      + finish(ctx, "finished", seconds - 40) + quit_app())
    return {"name": name, "title": title, "seconds": seconds, "plans": plans, "script": run_script, "verify": verify, "during": during}


def the_run(ctx):
    run = only_run(ctx)
    ctx.check("the run finished, every step passed", bool(run) and run["status"] == "finished" and all(x["status"] == "passed" for x in run["steps"]),
              (run["status"], [x["status"] for x in run["steps"]]) if run else "no run record")
    return run


def asked(ctx, nth=0):
    """The nth markview_cockpit_ask call of the agent: (exit code, output)."""
    hits = [e["result"] for e in ctx.actions() if e["action"].get("call") == ASK]
    return (hits[nth]["exit"], hits[nth]["output"]) if len(hits) > nth else (None, "no such call")


# S7 ------------------------------------------------------------------------------------------------------------------------------

S7_QUESTION = "Should the greeting use a comma or a dash?"
S7_PLAN = plan(step("Ask once", [ask(S7_QUESTION, options=["comma", "dash"], proposed="comma"), done("Asked one question.")]))


def s7_verify(ctx):
    run = the_run(ctx)
    code, output = asked(ctx)
    ctx.check("the tool result is the supervisor's answer", code == 0 and output == "Supervisor: Take the conservative option for: " + S7_QUESTION[:60],
              (code, output))
    exchanges = (run or {}).get("exchanges") or []
    ctx.check("the run JSON has exactly one exchange with question, answer, outOfScope false, failed false",
              len(exchanges) == 1 and exchanges[0]["question"] == S7_QUESTION and exchanges[0]["answer"].startswith("Take the conservative option")
              and exchanges[0]["outOfScope"] is False and exchanges[0]["failed"] is False, exchanges)
    calls = ctx.supervisor_calls()
    ctx.check("the supervisor model was called once, by the project's assistant", len(calls) == 1, calls)
    prompt = ctx.supervisor_prompt(1)
    ctx.check("its prompt carries the goal, the controls, the assignment, the question, the options and the proposed answer",
              all(t in prompt for t in ("Goal of the run:", "Controls (JSON", '"supervisor":true', "Its assignment:", S7_QUESTION, "- comma", "- dash",
                                        "The answer it would give itself: comma")), prompt[:200])
    tickets = [t for p in ctx.step_prompts() for t in re.findall(r"ticket ([0-9A-Fa-f-]{36})", p)]
    ctx.check("the step ticket (a credential) is not in the supervisor prompt", tickets and not any(t in prompt for t in tickets), tickets[:1])
    ctx.check("the step prompt tells the agent about markview_cockpit_ask", any(ASK in p and "There is no supervisor" not in p for p in ctx.step_prompts()),
              "step prompts: %d" % len(ctx.step_prompts()))
    planner = open(os.path.join(ctx.e2e, "planner-prompt-1.txt")).read()
    ctx.check("the planner was told about the supervisor", ASK in planner and "supervisor" in planner.lower(), "planner prompt %d chars" % len(planner))
    end = ctx.dump("dump-end.txt")
    ctx.check("the control room shows '1 asked'", "1 asked" in end,
              [l for l in end.splitlines() if "Supervisor" in l][:4])


# S8 ------------------------------------------------------------------------------------------------------------------------------

S8_QUESTION = "May I deploy to production now?"
S8_PLAN = plan(step("Ask out of scope", [ask(S8_QUESTION), done("Asked about deploying.")]))


def s8_verify(ctx):
    run = the_run(ctx)
    code, output = asked(ctx)
    ctx.check("the result tells the agent not to act and to record a blocker",
              code == 0 and "Do not act on the question" in output and "blocker in your step report" in output and output.startswith("Supervisor: this is outside"),
              (code, output))
    exchanges = (run or {}).get("exchanges") or []
    ctx.check("the exchange is saved with outOfScope true", len(exchanges) == 1 and exchanges[0]["outOfScope"] is True and exchanges[0]["failed"] is False, exchanges)
    ctx.check("the tab shows '1 outside the plan'", "1 outside the plan" in ctx.dump("dump-end.txt"),
              [l for l in ctx.dump("dump-end.txt").splitlines() if "Supervisor" in l][:3])
    ctx.check("no deployment happened (the question is advice only, the gate stays authoritative)",
              not any(e["action"].get("call", "").startswith("markview_deployments") for e in ctx.actions()), "no deployment call")


# S9 ------------------------------------------------------------------------------------------------------------------------------

S9_PLAN = plan(step("Ask with no supervisor", [ask("Should I use a comma?"), done("Asked with the supervisor off.")]))


def s9_verify(ctx):
    run = the_run(ctx)
    code, output = asked(ctx)
    ctx.check("the result is the 'No supervisor is active' text", code == 0 and output == DISABLED_TEXT, (code, output))
    ctx.check("the supervisor model was never called", ctx.supervisor_calls() == [], ctx.supervisor_calls())
    ctx.check("the run has no exchanges", not (run or {}).get("exchanges"), (run or {}).get("exchanges"))
    prompts = ctx.step_prompts()
    ctx.check("the step prompt says 'There is no supervisor in this run' and does not offer the tool",
              prompts and "There is no supervisor in this run" in prompts[0] and "call markview_cockpit_ask" not in prompts[0], prompts[0][:80] if prompts else "no prompt")
    ctx.check("the approved plan has the control off", bool(run) and run["plan"]["controls"].get("supervisor") is False,
              (run or {}).get("plan", {}).get("controls"))
    ctx.check("the plan screen says the supervisor is off", "Off: step agents cannot ask anything" in ctx.dump("dump-plan.txt"), [l for l in ctx.dump("dump-plan.txt").splitlines() if "Supervisor" in l][:2])
    ctx.check("the control room says the supervisor is off", "Off. Step agents cannot ask anything" in ctx.dump("dump-end.txt"), "")


# S10 -----------------------------------------------------------------------------------------------------------------------------

S10_FIRST = "Cap question 1?"
S10_PLAN = plan(
    step("Repeat and cap", [ask(S10_FIRST), ask("  CAP   Question 1?  "), {"ask_many": {"template": "Cap question {i}?", "start": 2, "count": 25}},
                            done("Asked 26 distinct questions and one repeat.")]),
    step("A new step", [ask(S10_FIRST), ask("A fresh question in step two?"), done("Asked again in a new step.")]))


def s10_verify(ctx):
    run = the_run(ctx)
    asks = [e["result"] for e in ctx.actions() if e["action"].get("call") == ASK]
    first, repeat = asks[0], asks[1]
    ctx.check("a question asked again (other case and spacing) gets the same reply", first["exit"] == 0 and repeat["exit"] == 0 and first["output"] == repeat["output"]
              and first["output"].startswith("Supervisor: "), (first["output"][:70], repeat["output"][:70]))
    many = next(e["result"] for e in ctx.actions() if "ask_many" in e["action"])
    answered = [r for r in many["results"] if r[2].startswith("Supervisor: ")]
    exhausted = [r for r in many["results"] if "answers at most 25 questions" in r[2]]
    ctx.check("questions 2-25 are answered and question 26 gets the 'at most 25 questions' text",
              len(answered) == 24 and [r[0] for r in exhausted] == [26], "answered=%d exhausted=%s" % (len(answered), [r[0] for r in exhausted]))
    exchanges = [x for x in ((run or {}).get("exchanges") or [])]
    # Counted per step from the run's own log: step 2 may legitimately ask "Cap question 1?" again.
    first_step = exchanges[0]["stepID"] if exchanges else None
    step1_calls = [x for x in exchanges if x["stepID"] == first_step]
    ctx.check("step 1 made exactly 25 supervisor calls (25 distinct questions, 0 for the repeat)", len(step1_calls) == 25, len(step1_calls))
    ctx.check("the run logged one exchange per supervisor call", len(exchanges) == len(ctx.supervisor_calls()), (len(exchanges), len(ctx.supervisor_calls())))
    # The ledger is documented as per step ("What one step has asked"): a new step must be able to ask again.
    again = asks[-2]
    new_calls = [c for c in ctx.supervisor_calls() if c["question"] in (S10_FIRST, "A fresh question in step two?")]
    ctx.check("a NEW step starts with a fresh count: its repeated question and its fresh question each reach the supervisor",
              len(new_calls) >= 3 and "answers at most" not in asks[-1]["output"],
              "step 2 answers: %r / %r ; supervisor calls for those questions: %d" % (again["output"][:90], asks[-1]["output"][:90], len(new_calls)))


# S11 -----------------------------------------------------------------------------------------------------------------------------

S11_PLAN = plan(step("Supervisor failures", [
    ask("FAIL-ONCE which branch should I use?"), ask("FAIL-ONCE which branch should I use?"),
    ask("FAIL-GARBAGE what is the format?"), ask("FAIL-EXIT may I rename the file?"), ask("A normal question afterwards?"),
    done("Survived supervisor failures.")]))


def s11_verify(ctx):
    run = the_run(ctx)
    outputs = [asked(ctx, i) for i in range(5)]
    ctx.check("the first failure tells the agent to decide alone, not to wait",
              outputs[0][0] == 0 and "The supervisor could not answer" in outputs[0][1] and "Do not wait" in outputs[0][1], outputs[0])
    ctx.check("the same question asked again is asked of the supervisor again and succeeds", outputs[1][0] == 0 and outputs[1][1].startswith("Supervisor: "), outputs[1])
    ctx.check("garbage and a non-zero exit are failures too", all("The supervisor could not answer" in o[1] for o in outputs[2:4]), [o[1][:90] for o in outputs[2:4]])
    ctx.check("a normal question afterwards is answered", outputs[4][1].startswith("Supervisor: "), outputs[4])
    exchanges = (run or {}).get("exchanges") or []
    flags = [(x["failed"], x["outOfScope"]) for x in exchanges]
    ctx.check("the exchanges record failed true for the three failures and false for the answers",
              flags == [(True, False), (False, False), (True, False), (True, False), (False, False)], flags)
    ctx.check("the supervisor was called once per ask (5), the failed one again after the failure", len(ctx.supervisor_calls()) == 5, len(ctx.supervisor_calls()))
    ctx.check("the control room shows '5 asked' and '3 unanswered'", "5 asked" in ctx.dump("dump-end.txt") and "3 unanswered" in ctx.dump("dump-end.txt"),
              [l for l in ctx.dump("dump-end.txt").splitlines() if "Supervisor" in l][:3])


# S12 -----------------------------------------------------------------------------------------------------------------------------

STRANGER = "7D4B2F0E-5A55-4C1E-9D3B-2E6A1F9C8B77"
S12_PLAN = plan(step("Wrong tickets", [
    ask("Anything?", ticket=STRANGER), ask("Anything?", ticket="not-a-ticket"), {"note": "waiting for the outside caller"}, {"sleep": 12},
    ask("A real question with the real ticket?"), done("Used wrong tickets.")]))


def s12_during(ctx):
    """From outside every step (this harness, no Cockpit shell among its ancestors): a ticket nobody issued."""
    if not ctx.wait_for_log("waiting for the outside caller", 200):
        ctx.external["error"] = "the step never started"
        return
    sockets = sorted(glob.glob(os.path.join(ctx.sock, "mv-browser-*.sock")))
    env = {k: v for k, v in os.environ.items() if not k.startswith("DYLD_") and not k.startswith("MV_PROBE")}
    env.update(HOME=ctx.home, MARKVIEW_SOCKET_DIR=ctx.sock)
    body = json.dumps({"project_folder": ctx.fx, "ticket": STRANGER, "question": "Is this an outside caller?"})
    done_ = subprocess.run([ctx.app_binary, "--project-call", ASK, body, "--socket", sockets[0]] if sockets else ["false"], capture_output=True, text=True,
                           timeout=60, env=env, cwd=ctx.fx)
    ctx.external.update(exit=done_.returncode, output=(done_.stdout + done_.stderr).strip(), sockets=len(sockets))


def s12_verify(ctx):
    the_run(ctx)
    inside = [asked(ctx, 0), asked(ctx, 1)]
    ctx.check("a ticket nobody issued is refused from inside a step",
              inside[0][0] == 1 and "The ticket is invalid, expired, or belongs to another project." in inside[0][1], inside[0])
    ctx.check("a malformed ticket is refused", inside[1][0] == 1 and "A valid ticket and a question are required." in inside[1][1], inside[1])
    ctx.check("a process outside every step with an unknown ticket gets the same error",
              ctx.external.get("exit") == 1 and "The ticket is invalid, expired, or belongs to another project." in ctx.external.get("output", ""), ctx.external)
    questions = [c["question"] for c in ctx.supervisor_calls()]
    ctx.check("none of the wrong-ticket calls reached the supervisor; the real one did", questions == ["A real question with the real ticket?"], questions)


# S13 -----------------------------------------------------------------------------------------------------------------------------

def modelled(title, actions, model):
    return dict(step(title, actions), model=model)


S13_PLAN = plan(
    modelled("With a model", [
        {"progress": {"passNumber": 1, "activity": "Reading the fixture", "latestChange": "none", "bugs": [], "fixes": [], "blockers": []}},
        ask("Should the greeting use a comma?", options=["comma", "dash"], proposed="comma"),
        done("The first step is done.")], "opus"),
    step("Without a model", [done("The second step is done.")]))


def s13_verify(ctx):
    run = the_run(ctx)
    starts = [e for e in ctx.agent_log() if e.get("event") == "step start"]
    argv = [e["argv"] for e in starts]
    ctx.check("the step with a model starts the agent with --model opus", len(argv) == 2 and "--model" in argv[0] and argv[0][argv[0].index("--model") + 1] == "opus", argv)
    ctx.check("the step without a model starts the agent with no --model flag", len(argv) == 2 and "--model" not in argv[1], argv[1:] )
    plan_text = ctx.dump("dump-plan.txt")
    ctx.check("the plan screen shows the agent and the model on the step card", "Claude Code · Opus" in plan_text,
              [l for l in plan_text.splitlines() if "Claude Code" in l][:4])
    if not run:
        return
    events = run.get("events") or []
    kinds = [e["kind"] for e in events]
    ctx.check("the timeline holds the run's story in order",
              kinds[:2] == ["started", "stepStarted"] and kinds[-1] == "finished" and kinds.count("stepPassed") == 2 and kinds.count("stepStarted") == 2
              and "report" in kinds and "question" in kinds, kinds)
    times = [e["at"] for e in events]
    ctx.check("event times never go backwards", times == sorted(times), times[:6])
    ctx.check("the run, its steps and its last sign of life are dated",
              run.get("startedAt") is not None and run.get("lastSignal") is not None
              and all(s.get("startedAt") is not None and s.get("endedAt") is not None for s in run["steps"]),
              (run.get("startedAt"), run.get("lastSignal"), [(s.get("startedAt"), s.get("endedAt")) for s in run["steps"]]))
    ctx.check("the saved plan keeps the step's model", run["plan"]["steps"][0].get("model") == "opus" and "model" not in run["plan"]["steps"][1], [s.get("model") for s in run["plan"]["steps"]])
    end = ctx.dump("dump-end.txt")
    ctx.check("the run screen shows the finished run and the question", "Finished" in end and "1 asked" in end,
              [l for l in end.splitlines() if "Finished" in l or "asked" in l][:4])


# S14 -----------------------------------------------------------------------------------------------------------------------------

S14_PLAN = plan(
    modelled("Investigate", [
        {"progress": {"passNumber": 1, "activity": "Reading the fixture", "latestChange": "none", "bugs": [], "fixes": [], "blockers": []}},
        ask("Should the greeting use a comma?", options=["comma", "dash"], proposed="comma"),
        {"sleep": 25},
        done("Investigation done.")], "opus"),
    step("Verify", [
        {"progress": {"passNumber": 2, "activity": "Verified", "latestChange": "none", "bugs": [], "fixes": [], "blockers": [],
                      "criteriaResults": [{"criterion": "Every step reported passed.", "met": True, "evidence": "both steps passed"}]}},
        done("Final verification passed.")]))


def s14_script(ctx):
    pictures = ["size 1280 900", "wait 1", "snap plan-empty"]
    plan_steps = ["press label:Propose plan", "waitfor 60 label:Review and approve", "wait 1", "snap plan-collapsed",
                  "press label:Edit step 1", "wait 1", "snap plan-step-editor"]
    approve = ["press label:Review and approve", "waitfor 10 label:Approve and start", "press label:Approve and start", "wait 12", "snap run-running"]
    tabs = ["snap run-finished"]
    for tab in ("Steps", "Questions", "Findings"):
        tabs += ["press label:%s" % tab, "wait 1", "snap run-%s" % tab.lower()]
    return script(opening(ctx, "Investigate the fixture and verify it.") + pictures + plan_steps + approve
                  + finish(ctx, "finished", 150) + tabs + quit_app())


def s14_verify(ctx):
    the_run(ctx)
    wanted = ["plan-empty", "plan-collapsed", "plan-step-editor", "run-running", "run-finished", "run-steps", "run-questions", "run-findings"]
    ctx.check("every picture was taken", all(os.path.exists(os.path.join(ctx.out, n + ".png")) for n in wanted),
              [n for n in wanted if not os.path.exists(os.path.join(ctx.out, n + ".png"))])


# S15 -----------------------------------------------------------------------------------------------------------------------------

S15_NOTE = "Prefer the dash, and keep the change small."
S15_QUESTION = "Comma or dash for the greeting?"
S15_PLAN = plan(
    step("Cruise", [
        {"progress": {"passNumber": 1, "activity": "Cruising", "latestChange": "none", "bugs": [], "fixes": [], "blockers": []}},
        {"sleep": 40},
        {"call": "markview_create_bug", "args": {"title": "A bug the lever should refuse", "description": "Filed after the lever was switched off."}},
        ask(S15_QUESTION, options=["comma", "dash"], proposed="comma"),
        done("Cruised.")]),
    step("Land", [done("Landed.")]))

def s15_script(ctx):
    cockpit = ["wait 6", "snap cp-running", "dump %s/dump-cp-running.txt" % ctx.out,
               "press label:File bugs", "wait 2", "snap cp-lever-cut", "dump %s/dump-cp-lever.txt" % ctx.out,
               "settext label:Note to the supervisor | " + S15_NOTE, "wait 1", "press label:Send note", "wait 2", "snap cp-note-sent",
               "dump %s/dump-cp-note.txt" % ctx.out]
    return script(opening(ctx, "Fly the scripted route.") + [BIG, "wait 1"] + propose_and_approve(ctx) + cockpit
                  + finish(ctx, "finished", 200) + ["snap cp-finished"] + quit_app())


def s15_verify(ctx):
    run = the_run(ctx)
    controls = (run or {}).get("plan", {}).get("controls", {})
    ctx.check("the approved plan still has filing bugs on (a lever never edits the plan)", controls.get("fileBugs") is True, controls)
    ctx.check("the run kept the lever as a cut", ((run or {}).get("switches") or {}).get("fileBugsCut") is True, (run or {}).get("switches"))
    events = (run or {}).get("events") or []
    ctx.check("the timeline says the lever was switched off", any(e["kind"] == "switched" and "Filing bugs" in e["text"] for e in events),
              [e["text"] for e in events if e["kind"] == "switched"])
    refused = ctx.result_of("markview_create_bug")
    ctx.check("the agent's next call was refused at the gate, in the middle of the step",
              bool(refused) and refused["exit"] != 0 and "Filing bugs is turned off" in refused["output"], refused)
    ctx.check("the refusal is in the run's timeline", any(e["kind"] == "refusal" for e in events), [e["kind"] for e in events][:12])
    notes = (run or {}).get("notes") or []
    ctx.check("the note is saved with its text", len(notes) == 1 and notes[0]["text"] == S15_NOTE, notes)
    ctx.check("the timeline says a note was sent", any(e["kind"] == "note" for e in events), [e["kind"] for e in events][:12])
    ctx.check("the note did not interrupt the agent (the step went on to pass)", all(x["status"] == "passed" for x in (run or {}).get("steps", [])), "")
    prompt = ctx.supervisor_prompt(1)
    ctx.check("the supervisor's prompt carries the note", "Notes from the person who supervises this run" in prompt and S15_NOTE in prompt, prompt[-400:])
    prompts = ctx.step_prompts()
    ctx.check("the next step's briefing carries the note, the first step's does not",
              len(prompts) >= 2 and S15_NOTE in prompts[1] and S15_NOTE not in prompts[0], [len(p) for p in prompts])
    for name in ("cp-running", "cp-lever-cut", "cp-note-sent", "cp-finished"):
        ctx.check("picture " + name, os.path.exists(os.path.join(ctx.out, name + ".png")), "")
    lever = ctx.dump("dump-cp-lever.txt")
    ctx.check("the lever panel shows File bugs off", "File bugs" in lever, [l for l in lever.splitlines() if "File bugs" in l][:3])
    end = ctx.dump("dump-end.txt")
    ctx.check("the radio panel counts the question", "1 asked" in end, [l for l in end.splitlines() if "asked" in l][:2])


# S16 -----------------------------------------------------------------------------------------------------------------------------

S16_PLAN = plan(
    step("Doomed", [
        {"progress": {"passNumber": 1, "activity": "About to fail", "latestChange": "none", "bugs": [], "fixes": [], "blockers": ["Nothing works"]}},
        {"complete": {"passed": False, "detail": "The check failed.", "build": ""}}]),
    step("Never reached", [done("Unreachable.")]))


def s16_script(ctx):
    return script(opening(ctx, "Fly into trouble.") + [BIG, "wait 1"] + propose_and_approve(ctx)
                  + ["waitfor 90 has:A step failed", "wait 3", "snap cp-failed", "dump %s/dump-cp-failed.txt" % ctx.out]
                  + quit_app())


def s16_verify(ctx):
    run = only_run(ctx)
    steps = [x["status"] for x in (run or {}).get("steps", [])]
    ctx.check("the first step failed and the second was never started", steps[:1] == ["failed"] and "passed" not in steps, steps)
    ctx.check("picture cp-failed", os.path.exists(os.path.join(ctx.out, "cp-failed.png")), "")
    dump = ctx.dump("dump-cp-failed.txt")
    lamp = [l for l in dump.splitlines() if "label=Step Failed" in l]
    ctx.check("the banner is shown and the STEP FAILED lamp reads 'on'", "A step failed" in dump and bool(lamp) and "Step Failed: on" in lamp[0], lamp[:2])
    ctx.check("the PAUSED lamp is on too (a failed step pauses the run) and LIMIT is off",
              any("Paused: on" in l for l in dump.splitlines()) and any("Limit: off" in l for l in dump.splitlines()), [l for l in dump.splitlines() if "label=Paused" in l or "label=Limit" in l])


# S17 -----------------------------------------------------------------------------------------------------------------------------

TOOLBAR = ("Git", "Build & Deployment (⌃⌘D)", "Workflow", "End-to-End QA (⌘8)", "UI Studio (⌘7)", "Copilot Cockpit", "Discussions (⌃⌘I)", "Tasks")


def s17_script(ctx):
    def look(name):
        return ["wait 2", "dump %s/dump-%s.txt" % (ctx.out, name), "snap %s" % name]
    lines = ["wait 2", "key", "openurl " + ctx.fx, "wait 4", "picktitle " + os.path.basename(ctx.fx), "size 1280 900"]
    lines += look("tb-none")
    lines += ["press label:Copilot Cockpit", "waitfor 20 label:Propose plan"] + look("tb-cockpit")
    lines += ["press label:Git"] + look("tb-git-cockpit")
    lines += ["press label:Tasks"] + look("tb-tasks")
    lines += ["press label:Git"] + look("tb-git-again")
    # The first "Close" button of the tab strip belongs to the first tab, the Cockpit.
    lines += ["press label:Close"] + look("tb-cockpit-closed")
    return script(lines + quit_app())


def toolbar_value(ctx, dump, label):
    for line in ctx.dump(dump).splitlines():
        if line.startswith("AXButton | label=%s |" % label):
            return line.rsplit("value=", 1)[1]
    return None


def s17_verify(ctx):
    steps = [
        ("dump-tb-none.txt", "nothing is open", {}),
        ("dump-tb-cockpit.txt", "the Cockpit tab is the current one", {"Copilot Cockpit": "current"}),
        ("dump-tb-git-cockpit.txt", "Git is current, the Cockpit tab stays open", {"Copilot Cockpit": "open", "Git": "current"}),
        ("dump-tb-tasks.txt", "the Tasks area hides both tabs: both are only open", {"Copilot Cockpit": "open", "Git": "open"}),
        ("dump-tb-git-again.txt", "choosing Git again shows its tab", {"Copilot Cockpit": "open", "Git": "current"}),
        ("dump-tb-cockpit-closed.txt", "closing the Cockpit tab clears its mark", {"Git": "current"}),
    ]
    for dump, title, want in steps:
        # "Tasks" is an area, not a tab: it has its own selected state and is not part of this mark.
        got = {label: toolbar_value(ctx, dump, label) for label in TOOLBAR if label != "Tasks"}
        ctx.check("%s (%s)" % (title, dump), all((got[label] or "") == want.get(label, "") for label in got), got)
    for name in ("tb-none", "tb-cockpit", "tb-git-cockpit", "tb-tasks", "tb-git-again", "tb-cockpit-closed"):
        ctx.check("picture " + name, os.path.exists(os.path.join(ctx.out, name + ".png")), "")


ALL.update({
    "S7": supervisor_scenario("S7", "an answered question is logged and shown", [S7_PLAN], verify=s7_verify),
    "S8": supervisor_scenario("S8", "a question about deploying is out of scope", [S8_PLAN], verify=s8_verify),
    "S9": supervisor_scenario("S9", "supervisor off", [S9_PLAN], controls=["press label:" + SUP_TOGGLE, "value label:" + SUP_TOGGLE], verify=s9_verify),
    "S10": supervisor_scenario("S10", "repeat, cap, a new step", [S10_PLAN], seconds=300, verify=s10_verify),
    "S11": supervisor_scenario("S11", "supervisor failures", [S11_PLAN], verify=s11_verify),
    "S12": supervisor_scenario("S12", "wrong tickets", [S12_PLAN], verify=s12_verify, during=s12_during),
    "S13": supervisor_scenario("S13", "a step's model and the run's timeline", [S13_PLAN], verify=s13_verify),
    "S14": {"name": "S14", "title": "pictures of both screens", "seconds": 220, "plans": [S14_PLAN], "script": s14_script, "verify": s14_verify, "during": None},
    "S15": {"name": "S15", "title": "levers and notes on the instrument panel", "seconds": 300, "plans": [S15_PLAN], "script": s15_script, "verify": s15_verify, "during": None},
    "S17": {"name": "S17", "title": "toolbar marks of the singleton tabs", "seconds": 120, "plans": [], "script": s17_script, "verify": s17_verify, "during": None},
    "S16": {"name": "S16", "title": "a failed step on the instrument panel", "seconds": 200, "plans": [S16_PLAN], "script": s16_script, "verify": s16_verify, "during": None},
})
