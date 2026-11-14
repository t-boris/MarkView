"""The Cockpit end-to-end scenarios: plan, probe script and checks. Run by e2e.py.

S5   happy path, the base run (no supervisor involved)
S7   an agent asks one question and gets the supervisor's answer; logged in the run, shown in the tab
S8   a question about deploying to production is answered "outside the plan"
S9   the supervisor control is off: nobody answers, the agent is told so
S10  a repeated question is answered once; the 25-question cap; a new step starts a new count
S11  the supervisor fails (exit, garbage, once): the agent gets the instruction to decide alone, the run goes on
S12  a wrong ticket, from inside a step and from a process outside any step
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
    return ["press label:Propose plan", "waitfor 60 label:Review and approve execution",
            "dump %s/dump-plan%s.txt" % (ctx.out, tag),
            "press label:Review and approve execution", "waitfor 10 label:Approve and start",
            "press label:Approve and start"]


def finish(ctx, status_label, seconds, tag=""):
    """Wait for `Execution: <status>` then take the picture of the tab and quit."""
    return ["waitfor %d has:Execution: %s" % (seconds, status_label), "wait 3", "dump %s/dump-end%s.txt" % (ctx.out, tag)]


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
    ctx.check("the tab shows the success outcome", "Outcome: success against the stated criteria" in end,
              [l for l in end.splitlines() if "Outcome" in l or "Execution:" in l])
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
        return script(opening(ctx, "Work the scripted step and ask the supervisor.", controls) + propose_and_approve(ctx)
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
    ctx.check("the tab shows the disclosure 'Supervisor: 1 question'", "Supervisor: 1 question" in end,
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
    ctx.check("the review text says 'Supervisor off'", "Supervisor off:" in ctx.dump("dump-plan.txt"), [l for l in ctx.dump("dump-plan.txt").splitlines() if "Supervisor" in l][:2])
    ctx.check("the tab shows no supervisor disclosure", "Supervisor: " not in ctx.dump("dump-end.txt").replace("Supervisor: off", ""), "")


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
    ctx.check("the tab shows '5 questions' and '3 unanswered'", "Supervisor: 5 questions" in ctx.dump("dump-end.txt") and "3 unanswered" in ctx.dump("dump-end.txt"),
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


ALL.update({
    "S7": supervisor_scenario("S7", "an answered question is logged and shown", [S7_PLAN], verify=s7_verify),
    "S8": supervisor_scenario("S8", "a question about deploying is out of scope", [S8_PLAN], verify=s8_verify),
    "S9": supervisor_scenario("S9", "supervisor off", [S9_PLAN], controls=["press label:" + SUP_TOGGLE, "value label:" + SUP_TOGGLE], verify=s9_verify),
    "S10": supervisor_scenario("S10", "repeat, cap, a new step", [S10_PLAN], seconds=300, verify=s10_verify),
    "S11": supervisor_scenario("S11", "supervisor failures", [S11_PLAN], verify=s11_verify),
    "S12": supervisor_scenario("S12", "wrong tickets", [S12_PLAN], verify=s12_verify, during=s12_during),
})
