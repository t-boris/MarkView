import Foundation

// Checks for BUG-059: the labels of a source file, the source set of a screen, the share of the labels a screen shows,
// and the repair request for a thin one. The fixtures are small widgets shaped like the OptionDesk widget of the StrikeDesk app.

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print((ok ? "ok   " : "FAIL ") + name)
    if !ok { failures += 1 }
}

let root = "apps/desk/src/widgets/chain"

let deskSource = """
import React from 'react';
import { ChainTable } from './components/ChainTable';
import { ConfirmDialog } from './components/ConfirmDialog';
import { Helper } from '../shared/Helper';
import { Other } from '../other/Other';
import './Desk.css';
// A comment that says Not a label at all
export function Desk() {
  const options = [{ label: 'Custom (Manual)', value: 'manual' }, { label: 'Live', value: 'live' }];
  const key = 'ArrowUp';
  const route = '/api/v1/chains';
  const css = 'flex items-center';
  return (
    <div className="desk-toolbar big-title" data-testid="Toolbar Root" aria-label="Hidden accessibility text">
      <span title="Tooltip text here">Underlying</span>
      <button onClick={go}>Refresh</button>
      <button onClick={cfg}>CONFIG</button>
      <input placeholder="Search strikes" name="searchField" />
      <span>{count} legs</span>
      <b>P/L Open</b>
      <i>Total:</i>
    </div>
  );
}
"""

let tableSource = """
import React from 'react';
const COLUMNS = [
  { header: 'Delta' }, { header: 'Bid (Sell)' }, { header: 'Ask (Buy)' }, { header: 'Strike' },
  { header: 'Open interest' }, { header: 'Gamma' }, { header: 'Theta' }, { header: 'Vega' },
];
export function ChainTable() {
  return (<table><thead><tr><th>Calls</th><th>Puts</th></tr></thead><tfoot><tr><td>Max profit</td><td>BP Eff</td></tr></tfoot></table>);
}
"""

let dialogSource = "export const ConfirmDialog = () => (<div><h1>Confirm replacement</h1><p>Are you sure about this change?</p></div>);"
let helperSource = "export const Helper = () => (<p>Shared helper text</p>);"
let otherSource = "export const Other = () => (<p>Another screen's own text</p>);"
let testSource = "it('shows labels', () => { expect(screen.getByText('Test only label')).toBeTruthy(); });"

let files: [String: String] = [
    root + "/Desk.tsx": deskSource,
    root + "/components/ChainTable.tsx": tableSource,
    root + "/components/ConfirmDialog.tsx": dialogSource,
    "apps/desk/src/widgets/shared/Helper.tsx": helperSource,
    "apps/desk/src/widgets/other/Other.tsx": otherSource,
    root + "/__tests__/Desk.test.tsx": testSource,
]
func read(_ path: String) -> String? { files[path] }

// MARK: - Labels of one file

do {
    let labels = PrototypeFidelity.labels(in: deskSource)
    for wanted in ["Custom (Manual)", "Underlying", "Refresh", "CONFIG", "Search strikes", "P/L Open", "Total:", "Live"] {
        check(labels.contains(wanted), "a visible label is found: \(wanted)")
    }
    for unwanted in ["Not a label at all", "Hidden accessibility text", "Tooltip text here", "ArrowUp", "/api/v1/chains", "flex items-center",
                     "desk-toolbar big-title", "Toolbar Root", "searchField", "manual", "React", "./components/ChainTable"] {
        check(!labels.contains(unwanted), "not a label: \(unwanted)")
    }
    check(!labels.contains { $0.contains("{") || $0.contains("legs") && $0.contains("count") }, "an expression is not taken as text")
    check(labels.count == Set(labels).count, "each label is listed once")
    check(PrototypeFidelity.labels(in: tableSource).prefix(3) == ["Delta", "Bid (Sell)", "Ask (Buy)"], "labels keep the order of the source")
    check(PrototypeFidelity.looksLikeLabel("Bid (Sell)") && PrototypeFidelity.looksLikeLabel("MAX PROFIT") && PrototypeFidelity.looksLikeLabel("Swap"),
          "titles, upper case and one capitalized word are labels")
    check(!PrototypeFidelity.looksLikeLabel("useState") && !PrototypeFidelity.looksLikeLabel("order") && !PrototypeFidelity.looksLikeLabel("on-click")
          && !PrototypeFidelity.looksLikeLabel("a_b_c") && !PrototypeFidelity.looksLikeLabel("BracketLeft"),
          "identifiers, lower case words, kebab case and key names are not labels")
    check(!PrototypeFidelity.looksLikeLabel("0 && loadedStrikeCount") && !PrototypeFidelity.looksLikeLabel("count > 0 || ready"),
          "a condition between two comparisons is not a label")
    check(PrototypeFidelity.labels(in: "<div>{rows.length > 0 && diff < max}</div><span>R&D budget</span><b>P&L Open</b>") == ["R&D budget", "P&L Open"],
          "an ampersand inside a label is kept, a logical and is not")
    check(PrototypeFidelity.normalized("  Bid\u{00A0}(Sell)  ") == "bid (sell)", "normalizing ignores case and spacing")
}

// MARK: - Imports and the source set

do {
    check(PrototypeFidelity.relativeImports(in: deskSource) == ["./components/ChainTable", "./components/ConfirmDialog", "../shared/Helper", "../other/Other", "./Desk.css"],
          "relative imports are found, packages are not")
    check(PrototypeFidelity.resolve("./components/ChainTable", from: root + "/Desk.tsx", exists: { read($0) != nil }) == root + "/components/ChainTable.tsx",
          "an import resolves to the file with its extension")
    // The widget folder has five levels: five `..` reach the root itself, the sixth leaves it.
    check(PrototypeFidelity.resolve("../../../../../escape", from: root + "/Desk.tsx", exists: { _ in true }) == "escape.tsx", "a path up to the root is resolved")
    check(PrototypeFidelity.resolve("../../../../../../escape", from: root + "/Desk.tsx", exists: { _ in true }) == nil, "a path above the root is not resolved")
    check(!PrototypeFidelity.isSource(root + "/__tests__/Desk.test.tsx") && !PrototypeFidelity.isSource("a/b.d.ts") && !PrototypeFidelity.isSource("a/b.css")
          && PrototypeFidelity.isSource("a/b.tsx"), "tests, declarations and styles are not label sources")
    check(PrototypeFidelity.isSecondary("a/ExitBracketPopup.tsx") && PrototypeFidelity.isSecondary("a/OrderAmendmentEditor.tsx")
          && PrototypeFidelity.isSecondary("a/RollPreview.tsx") && !PrototypeFidelity.isSecondary("a/ChainTable.tsx") && !PrototypeFidelity.isSecondary("a/OrderTicket.tsx"),
          "dialogs, editors and previews are secondary; tables and tickets are not")

    let set = PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx"], otherEvidence: ["apps/desk/src/widgets/other/Other.tsx"], read: read).map(\.path)
    check(set == [root + "/Desk.tsx", root + "/components/ChainTable.tsx"],
          "the set is the entry and what it imports inside its folder: no dialog, no file outside the folder (\(set))")
    let withOthers = PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx", "apps/desk/src/widgets/other/Other.tsx"], otherEvidence: [], read: read).map(\.path)
    check(withOthers.contains("apps/desk/src/widgets/other/Other.tsx"), "an evidence file is always part of its own set")
    check(PrototypeFidelity.sourceSet(evidence: [root + "/Missing.tsx"], otherEvidence: [], read: read).isEmpty, "a file that cannot be read gives an empty set")
    check(PrototypeFidelity.sourceSet(evidence: [root + "/Desk.tsx", root + "/Desk.tsx"], otherEvidence: [], read: read).count == 2, "a file is not read twice")
}

// MARK: - The report

let faithfulScreen = """
App.register({ id: 'desk', render(ctx) {
  const labels = ['Custom (Manual)', 'Live', 'Underlying', 'Refresh', 'CONFIG', 'Search strikes', 'P/L Open', 'Total:',
    'Delta', 'Bid (Sell)', 'Ask (Buy)', 'Strike', 'Open interest', 'Gamma', 'Theta', 'Vega', 'Calls', 'Puts', 'MAX PROFIT', 'BP EFF'];
} });
"""
let thinScreen = "App.register({ id: 'desk', render(ctx) { return ['Underlying', 'Refresh', 'Delta', 'Bid', 'Ask', 'Strike', 'Volume'].join(' '); } });"

do {
    let faithful = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: faithfulScreen, read: read)
    check(faithful != nil && faithful!.total >= 20, "the report counts the labels of the whole set (\(faithful?.total ?? -1))")
    check(faithful?.present == faithful?.total && faithful?.missing.isEmpty == true && faithful?.isThin == false,
          "a screen that shows every label is complete (\(faithful?.present ?? -1) of \(faithful?.total ?? -1))")

    let thin = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen, read: read)
    check(thin?.isThin == true, "a screen that shows a few labels is thin (\(thin?.percent ?? -1)%)")
    check(thin?.missing.contains(PrototypeFidelity.Missing(label: "Bid (Sell)", file: root + "/components/ChainTable.tsx")) == true,
          "a missing label names the file that defines it")
    check(thin?.missing.contains { $0.label == "Underlying" } == false, "a label the screen shows is not missing")
    check(thin?.files == [root + "/Desk.tsx", root + "/components/ChainTable.tsx"], "the report lists the files it read")

    // The shared sample data holds the labels of every screen: a screen is not complete because data.js has its words.
    let alsoInData = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [],
                                              screen: thinScreen + "\n/* data.js */ const DB = { cols: ['Open interest', 'Gamma', 'Theta', 'Calls', 'Puts'] };", read: read)
    check(alsoInData?.missing.contains { $0.label == "Gamma" } == false, "a label written in the screen's own script counts, in any case")
    check(PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen.lowercased(), read: read)?.present ?? 0 > 0,
          "the same label in another case is the same label")

    let small = PrototypeFidelity.report(id: "tiny", name: "Tiny", evidence: [root + "/components/ConfirmDialog.tsx"], otherEvidence: [], screen: "", read: read)
    check(small != nil && small!.total < PrototypeFidelity.minLabels && small!.present == 0 && small!.isThin == false,
          "a source with few labels is never thin, even when none is shown")
    check(PrototypeFidelity.report(id: "x", name: "X", evidence: [root + "/Nope.tsx"], otherEvidence: [], screen: "", read: read) == nil,
          "no readable source gives no report")
    check(PrototypeFidelity.summary(thin!).hasPrefix("\"Desk\" shows ") && PrototypeFidelity.summary(thin!).contains("labels of its source files ("),
          "the summary names the screen and the share")
}

// MARK: - The repair request

do {
    let thin = PrototypeFidelity.report(id: "desk", name: "Desk", evidence: [root + "/Desk.tsx"], otherEvidence: [], screen: thinScreen, read: read)!
    let text = PrototypeFidelity.repairInstruction(thin)
    check(text.contains("`screens/desk.js`") && text.contains("`\(root)/components/ChainTable.tsx`: "), "the request names the screen file and the source file")
    check(text.contains("\"Bid (Sell)\"") && text.contains("\"Calls\"") && !text.contains("\"Underlying\""), "it lists the missing labels, not the present ones")
    check(text.contains("copying every label exactly") && text.contains("skip them otherwise") && text.contains("Do not invent") && text.contains("this screen's script only"),
          "it says to copy the labels, skip dialogs, not to invent and to stay in the screen")
    check(text.range(of: "ChainTable.tsx`: ")!.lowerBound < text.range(of: "Desk.tsx`: ")!.lowerBound, "the file with more missing labels comes first")

    var many = thin
    many.missing = (0..<100).map { PrototypeFidelity.Missing(label: "Label number \($0)", file: root + "/Big.tsx") }
    many.total = 100
    many.present = 0
    let long = PrototypeFidelity.repairInstruction(many)
    check(long.components(separatedBy: "\"Label number ").count - 1 == PrototypeFidelity.listLimit, "the list is capped at \(PrototypeFidelity.listLimit) labels")
    check(long.contains("and 60 more"), "the rest is counted")
}

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
