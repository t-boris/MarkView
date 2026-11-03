import Foundation

// BUG-062: what the fix round of a prototype can know without an assistant. Compiled with MarkView/Models/PrototypeAudit.swift alone.
//   tools/tests/prototype-fixround-tests.sh
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}

// 1. The files a problem names.
let blank = PrototypeAudit.message(for: .init(id: "trade", name: "Trade", route: "/widgets/trade", kind: .blank, sample: ""))
check(PrototypeAudit.files(in: blank) == ["screens/trade.js"], "a screen finding names its script: \(PrototypeAudit.files(in: blank))")
check(PrototypeAudit.files(in: "TypeError: Attempted to assign to readonly property. (app.js:93)") == ["app.js"], "a runtime error names its file")
check(PrototypeAudit.files(in: "boom (screens/trade.js:12) after screens/home.js ran") == ["screens/trade.js", "screens/home.js"], "order of appearance, no repeats")
check(PrototypeAudit.files(in: "ResizeObserver loop completed with undelivered notifications.").isEmpty, "an error without a file names none")
check(PrototypeAudit.files(in: "x (original/theme.css:3)") == ["original/theme.css"], "the pattern itself does not judge the folder")
let existing: Set<String> = ["app.js", "screens/trade.js", "screens/home.js", "data.js"]
let problems = [blank, "TypeError: x (app.js:93)", "y (original/theme.css:3)", "z (screens/ghost.js:1)", blank,
                "Screen \"Home\" (#/, screens/home.js) is a placeholder"]
check(PrototypeAudit.fixFiles(problems: problems, existing: existing) == ["screens/trade.js", "app.js", "screens/home.js"],
      "only files of the prototype, once each, in order: \(PrototypeAudit.fixFiles(problems: problems, existing: existing))")
check(PrototypeAudit.directFixLimit == 3, "up to three files go to one run")

// 2. The loader defect, as strikedesk's trade.js wrote it.
let trade = """
App.register({
  id: 'trade',
  render: function (ctx) {
    var root = h('div', { className: 'sd-widget' });
    function draw() {
      var layout = h('div', { className: 'layout' });
      root.replaceChildren(toolbar(), layout);
    }
    function drawLoading() { root.replaceChildren(h('div', 'Chain Loading…')); setTimeout(draw, 350); }
    root.append(App.load(function () { var content = h('div'); draw(); content.append.apply(content, Array.from(root.childNodes)); return content; }));
    return root;
  }
});
"""
let hit = PrototypeAudit.loadProblem(id: "trade", content: trade)
check(hit != nil, "the strikedesk trade.js pattern is found")
check(hit?.hasPrefix("screens/trade.js:") == true && hit?.contains("root.replaceChildren(") == true && hit?.contains("through draw()") == true,
      "the message names the file, the call and the function: \(hit ?? "nil")")
check(PrototypeAudit.files(in: hit ?? "") == ["screens/trade.js"], "the lint message points to the screen file for the fix round")

// Directly in the callback, with innerHTML, with an arrow function, and through two levels of calls.
check(PrototypeAudit.loadProblem(id: "a", content: "host.append(App.load(() => { host.innerHTML = ''; return build(); }));") != nil, "innerHTML in the callback")
check(PrototypeAudit.loadProblem(id: "a", content: "const el = h('div'); el.appendChild(App.load(function () { el.textContent = ''; return x; }));") != nil, "textContent in the callback")
let deep = """
const draw = () => { paint(); };
function paint() { box.replaceChildren(a, b); }
box.append(App.load(() => { draw(); return box; }));
"""
check(PrototypeAudit.loadProblem(id: "a", content: deep) != nil, "a call two levels down")

// What is fine: the shapes the other screens of that prototype use.
let activity = """
function draw() { root.replaceChildren(toolbar, rows); }
return App.load(function () { draw(); return root; });
"""
check(PrototypeAudit.loadProblem(id: "activity", content: activity) == nil, "the loader is returned, not appended to the cleared element")
let roll = """
host.append(App.load(() => {
  const content = h('div');
  content.replaceChildren(a, b);
  return content;
}));
"""
check(PrototypeAudit.loadProblem(id: "roll", content: roll) == nil, "the callback clears its own content, not the host")
check(PrototypeAudit.loadProblem(id: "x", content: "root.append(App.load(() => build()));\nfunction later() { root.replaceChildren(); }") == nil,
      "a function the callback never calls may clear the host")
check(PrototypeAudit.loadProblem(id: "x", content: "// root.append(App.load(() => { root.innerHTML = ''; }))\nconst a = 1;") == nil, "a comment is not code")
check(PrototypeAudit.loadProblem(id: "x", content: "root.append(App.load(() => build()));\nroot.innerHTML == '';") == nil, "a comparison is not an assignment")
check(PrototypeAudit.loadProblem(id: "x", content: "App.register({id: 'x', render() { return h('div'); }});") == nil, "no loader, no finding")

if failures > 0 { print("\(failures) check(s) failed"); exit(1) }
print("Prototype fix round: problems name their files, the loader pattern of BUG-062 is found and the neighbouring shapes are not.")
