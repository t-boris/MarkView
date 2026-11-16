import Foundation

/// The structured answers the prototype assistant is asked for: one JSON schema per kind of run, so a strict provider sees the same contract
/// the parsers read (`PrototypePlan`, `PrototypeFiles.change(from:)`).
enum PrototypeSchemas {

    private static var fileSchema: [String: Any] { [
        "type": "object",
        "properties": ["path": ["type": "string"], "content": ["type": "string"]],
        "required": ["path", "content"], "additionalProperties": false,
    ] }

    private static func strings(_ description: String? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "array", "items": ["type": "string"]]
        if let description { schema["description"] = description }
        return schema
    }

    /// The plan of both modes: one schema, so a strict provider sees the same contract. The code-mode fields
    /// (`gaps`, `evidence`, `components`) are required but described as empty in requirements mode, and
    /// `Plan` drops whatever the planner put there in that mode.
    static var planSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "assumptions": strings(),
            "gaps": strings("Behaviour of the original that the prototype cannot reproduce; empty unless reconstructing existing code."),
            "roles": strings(),
            "entities": ["type": "array", "items": [
                "type": "object",
                "properties": ["name": ["type": "string"], "fields": strings(), "notes": ["type": "string"]],
                "required": ["name", "fields", "notes"], "additionalProperties": false,
            ]],
            "screens": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"], "name": ["type": "string"], "route": ["type": "string"],
                    "purpose": ["type": "string"], "data": strings(), "actions": strings(),
                    "states": strings(), "rules": strings(), "requirements": strings(),
                    "evidence": strings("Source files read for the screen; empty unless reconstructing existing code."),
                    "components": strings("Component files among the evidence that the screen reproduces; empty unless reconstructing existing code."),
                    "embedded": ["type": "boolean",
                                 "description": "True for a widget of a docked window or a modal that a host screen lays out; false otherwise and in requirements mode."],
                    "hosts": strings("Ids of the widget and modal screens this screen lays out or opens, in layout order; empty unless it is a host."),
                ],
                "required": ["id", "name", "route", "purpose", "data", "actions", "states", "rules", "requirements", "evidence",
                             "components", "embedded", "hosts"],
                "additionalProperties": false,
            ]],
            "styles": strings("The original stylesheet files the interface loads, in import order; empty unless reconstructing existing code."),
            "themes": strings("Ids of the themes the original interface can switch between, in its own order; empty unless reconstructing existing code."),
            "defaultTheme": ["type": "string",
                             "description": "The id of the theme the original starts with; empty unless reconstructing existing code with themes."],
        ],
        "required": ["title", "summary", "assumptions", "gaps", "roles", "entities", "screens", "styles", "themes", "defaultTheme"],
        "additionalProperties": false,
    ] }

    /// The answer of the foundation and screen runs: a summary and whole files.
    static var filesSchema: [String: Any] { [
        "type": "object",
        "properties": ["summary": ["type": "string"], "files": ["type": "array", "items": fileSchema]],
        "required": ["summary", "files"], "additionalProperties": false,
    ] }

    static var reviseSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "summary": ["type": "string"],
            "screens": ["type": "array", "items": ["type": "string"]],
            "files": ["type": "array", "items": fileSchema],
            "edits": ["type": "array", "items": [
                "type": "object",
                "properties": ["path": ["type": "string"], "find": ["type": "string"], "replace": ["type": "string"]],
                "required": ["path", "find", "replace"], "additionalProperties": false,
            ]],
            "delete": ["type": "array", "items": ["type": "string"]],
            "remaining": ["type": "array", "items": ["type": "string"],
                          "description": "Paths of the files a request for many files needs, left for runs of their own; empty otherwise."],
        ],
        "required": ["summary", "screens", "files", "edits", "delete", "remaining"], "additionalProperties": false,
    ] }
}
