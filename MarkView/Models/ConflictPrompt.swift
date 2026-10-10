import Foundation

/// The prompt that hands Git merge conflicts to the assistant (Git tab → Conflicts → Resolve with AI).
/// The assistant resolves and stages; it never commits, pushes or aborts, so the person reviews first.
enum ConflictPrompt {
    /// `operation` is what Git is in the middle of ("merge", "rebase", "cherry-pick", "revert"), if known.
    static func make(files: [String], operation: String?, branch: String) -> String {
        let list = files.prefix(60).map { "- \($0)" }.joined(separator: "\n")
        let more = files.count > 60 ? "\n- … and \(files.count - 60) more (run `git diff --name-only --diff-filter=U`)" : ""
        let state = operation.map { "Git is in the middle of a \($0) on branch \(branch)." } ?? "The work tree is on branch \(branch)."
        let cont: String
        switch operation {
        case "merge": cont = "`git merge --continue`"
        case "rebase": cont = "`git rebase --continue`"
        case "cherry-pick": cont = "`git cherry-pick --continue`"
        case "revert": cont = "`git revert --continue`"
        default: cont = "the matching `git … --continue`"
        }
        return """
        Resolve the Git conflicts in this repository. \(state)

        Conflicted files:
        \(list)\(more)

        How to do it:
        1. Open each file and read both sides of every conflict (<<<<<<<, =======, >>>>>>>). Use `git log` and `git diff` on both sides to understand what each change is for.
        2. Keep the intent of both sides. Take one side whole only when the other is clearly obsolete, and say why. Remove every conflict marker.
        3. For generated files and lock files, regenerate them with the project's own command instead of merging text.
        4. If the project has a build or tests, run them and fix what the merge broke.
        5. Stage each resolved file with `git add <file>`.

        Do not commit, push or abort (`git merge --abort`, `git reset --hard`, `git checkout --ours/--theirs` on a whole file without reading it). I review first.

        When you are done, list for each file what you decided and why, and anything you are unsure about. Then tell me to run \(cont) when I am happy.
        """
    }
}
