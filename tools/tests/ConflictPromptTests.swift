import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let merge = ConflictPrompt.make(files: ["a.swift", "docs/b.md"], operation: "merge", branch: "feat/x")
check(merge.contains("- a.swift\n- docs/b.md"), "every conflicted file is listed")
check(merge.contains("middle of a merge on branch feat/x"), "the operation and branch are named")
check(merge.contains("`git merge --continue`"), "it names the command that continues a merge")
check(merge.contains("Do not commit, push or abort"), "it forbids committing, pushing and aborting")
check(ConflictPrompt.make(files: ["a"], operation: "rebase", branch: "b").contains("`git rebase --continue`"), "rebase continues with rebase")
let plain = ConflictPrompt.make(files: ["a"], operation: nil, branch: "main")
check(plain.contains("The work tree is on branch main.") && plain.contains("the matching `git … --continue`"), "no operation known: generic wording")
let many = ConflictPrompt.make(files: (1...75).map { "f\($0).txt" }, operation: "merge", branch: "m")
check(many.contains("- f60.txt") && !many.contains("- f61.txt") && many.contains("and 15 more"), "a long list is cut and says how many are left")
print(failures == 0 ? "All conflict prompt checks passed." : "\(failures) conflict prompt check(s) failed.")
exit(failures == 0 ? 0 : 1)
