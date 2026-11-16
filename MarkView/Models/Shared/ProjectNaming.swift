import Foundation

/// Names of the new folder and of its GitHub repository.
enum ProjectNaming {
    /// "Recipe Planner for Families" → "recipe-planner-for-families"; Cyrillic and accents are
    /// transliterated; "new-project" when nothing usable is left.
    static func suggestedFolderName(_ title: String) -> String {
        let latin = title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title
        let base = latin.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var name = String(base).split(separator: "-").prefix(6).joined(separator: "-")
        if name.count > 60 { name = String(name.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        return name.isEmpty ? "new-project" : name
    }

    /// Why `name` cannot be the new folder's name, or nil when it can.
    static func folderNameProblem(_ name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a folder name." }
        if name != name.trimmingCharacters(in: .whitespaces) { return "The name cannot start or end with a space." }
        if name == "." || name == ".." { return "Choose another name." }
        if name.hasPrefix(".") { return "A name starting with a dot would be hidden in Finder." }
        if name.contains("/") || name.contains(":") { return "The name cannot contain / or :." }
        if name.utf8.count > 255 { return "The name is too long." }
        return nil
    }

    /// Why `name` cannot be a GitHub repository name, or nil when it can.
    static func repoNameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Enter a repository name." }
        if name.count > 100 { return "At most 100 characters." }
        if name == "." || name == ".." { return "Choose another name." }
        if name.lowercased().hasSuffix(".git") { return "The name cannot end with .git." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "Use letters, digits, '.', '-' and '_' only."
        }
        return nil
    }

    /// The folder name as a valid repository name.
    static func suggestedRepoName(_ folderName: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var name = String(folderName.map { allowed.contains($0) ? $0 : "-" })
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        return name.isEmpty ? "new-project" : String(name.prefix(100))
    }
}
