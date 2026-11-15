import Foundation

// MARK: - Operation rules

/// A simulated GraphQL root field (REQ-015): which operation on the scenario state answers `query { posts }` or
/// `mutation { createPost(input: …) }` at an endpoint. Declarative, like `StudioRule`; never code an agent wrote.
struct StudioGraphQLOperation: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable { case query, mutation, subscription }
    enum Action: String, Codable, Sendable, CaseIterable { case list, get, create, update, delete, respond }

    var id: String
    /// The endpoint: `/graphql` on the application's origin, or a full URL (`https://api.example.com/graphql`).
    var path = "/graphql"
    var kind = Kind.query
    /// The root field the operation answers: `posts`, `post`, `createPost`, `onPostAdded`.
    var field: String
    var action = Action.respond
    var entity: String? = nil
    /// The argument holding the record id (default `id`, then `where.id`).
    var idArgument: String? = nil
    /// The argument holding a create's or an update's fields (default `input`, `data`, `object`, `_set`; else all arguments).
    var inputArgument: String? = nil
    /// A list answered as a Relay connection: `edges { node cursor }`, `nodes`, `pageInfo`, `totalCount`.
    var connection: Bool? = nil
    /// A list wrapped in an object: `{ items: [...], total }`.
    var envelope: String? = nil
    /// `__typename` of the records (default: the entity's name, singular and capitalised).
    var typeName: String? = nil
    /// The answer of a `respond` operation; `{{args.name}}` placeholders take the field's arguments.
    var response: StudioJSON? = nil
    /// A subscription's writes of `entity` that push an answer (default: all of them).
    var on: [StudioChannelWrite]? = nil
    var include: [StudioInclude]? = nil
    var evidence: [StudioEvidence] = []
    var origin = StudioRule.Origin.agent
}

/// Lenient, because one damaged operation must not make environment.json unreadable: unknown values fall back to their
/// defaults, and an operation without an id or a field is ignored where operations are used.
extension StudioGraphQLOperation {
    private enum Keys: String, CodingKey {
        case id, path, kind, field, action, entity, idArgument, inputArgument, connection, envelope, typeName, response, on, include,
             evidence, origin
    }

    init(from decoder: Decoder) throws {
        let read = StudioLenient<Keys>(decoder)
        id = read.value(.id) ?? ""
        path = read.value(.path) ?? "/graphql"
        kind = read.value(.kind) ?? .query
        field = read.value(.field) ?? ""
        action = read.value(.action) ?? .respond
        entity = read.value(.entity)
        idArgument = read.value(.idArgument)
        inputArgument = read.value(.inputArgument)
        connection = read.value(.connection)
        envelope = read.value(.envelope)
        typeName = read.value(.typeName)
        response = read.value(.response)
        on = read.list(.on)
        include = read.list(.include)
        evidence = read.list(.evidence)
        origin = read.value(.origin) ?? .agent
    }

    var isUsable: Bool { !id.isEmpty && !field.isEmpty }
}

/// Reads the fields of a lenient value: a missing or damaged field is nil, a damaged element of a list is left out.
struct StudioLenient<Key: CodingKey> {
    private let container: KeyedDecodingContainer<Key>?

    init(_ decoder: Decoder) { container = try? decoder.container(keyedBy: Key.self) }

    /// The value is a JSON object. Parts of a rule that are not are left out of their list instead of becoming empty
    /// (an empty reply would answer every message).
    var isObject: Bool { container != nil }

    func value<T: Decodable>(_ key: Key) -> T? { (try? container?.decodeIfPresent(T.self, forKey: key)) ?? nil }

    func list<T: Decodable>(_ key: Key) -> [T] {
        ((try? container?.decodeIfPresent([StudioLossy<T>].self, forKey: key)) ?? nil)?.compactMap(\.value) ?? []
    }
}

enum StudioLenientError: Error { case notAnObject }

/// An element of a list that decodes to nil instead of failing the whole list.
struct StudioLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

// MARK: - Documents

/// A value in a GraphQL document: a variable, a constant, or a list or object of values.
enum StudioGraphQLValue: Equatable, Sendable {
    case variable(String)
    case constant(StudioJSON)
    case list([StudioGraphQLValue])
    case object([String: StudioGraphQLValue])
}

struct StudioGraphQLDirective: Equatable, Sendable {
    var name: String
    var arguments: [String: StudioGraphQLValue]
}

struct StudioGraphQLField: Equatable, Sendable {
    var alias: String?
    var name: String
    var arguments: [String: StudioGraphQLValue] = [:]
    var directives: [StudioGraphQLDirective] = []
    var selections: [StudioGraphQLSelection] = []

    var responseKey: String { alias ?? name }
}

enum StudioGraphQLSelection: Equatable, Sendable {
    case field(StudioGraphQLField)
    /// `...name`
    case spread(String, [StudioGraphQLDirective])
    /// `... on Type { … }`
    case inline(String?, [StudioGraphQLDirective], [StudioGraphQLSelection])
}

struct StudioGraphQLDefinition: Equatable, Sendable {
    var kind: StudioGraphQLOperation.Kind
    var name: String?
    /// Declared variables and their default values.
    var defaults: [String: StudioGraphQLValue]
    var selections: [StudioGraphQLSelection]
}

struct StudioGraphQLDocument: Equatable, Sendable {
    var operations: [StudioGraphQLDefinition]
    var fragments: [String: [StudioGraphQLSelection]]
}

/// A GraphQL document reader: executable definitions only (operations and fragments), bounded in size and depth.
enum StudioGraphQLParser {
    static let maxLength = 100_000
    static let maxDepth = 40
    static let maxTokens = 50_000

    struct Failure: Error, Equatable {
        var message: String
        var code: String? = nil
    }

    enum Token: Equatable {
        case punctuator(Character)
        case spread
        case name(String)
        case number(Double)
        case string(String)
    }

    static func parse(_ text: String) throws -> StudioGraphQLDocument {
        var cursor = Cursor(tokens: try tokens(text))
        var operations: [StudioGraphQLDefinition] = []
        var fragments: [String: [StudioGraphQLSelection]] = [:]
        while let token = cursor.peek {
            switch token {
            case .punctuator("{"):
                operations.append(StudioGraphQLDefinition(kind: .query, name: nil, defaults: [:], selections: try selectionSet(&cursor)))
            case .name("query"), .name("mutation"), .name("subscription"):
                cursor.index += 1
                guard case .name(let word) = token, let kind = StudioGraphQLOperation.Kind(rawValue: word) else { throw Failure(message: "Unknown operation") }
                var name: String?
                if case .name(let given)? = cursor.peek { name = given; cursor.index += 1 }
                var defaults: [String: StudioGraphQLValue] = [:]
                if cursor.take("(") {
                    while !cursor.take(")") {
                        try cursor.expect("$")
                        let variable = try cursor.name()
                        try cursor.expect(":")
                        try skipType(&cursor)
                        if cursor.take("=") { defaults[variable] = try value(&cursor) }
                        _ = try directives(&cursor)
                    }
                }
                _ = try directives(&cursor)
                operations.append(StudioGraphQLDefinition(kind: kind, name: name, defaults: defaults, selections: try selectionSet(&cursor)))
            case .name("fragment"):
                cursor.index += 1
                let name = try cursor.name()
                guard name != "on", cursor.take(name: "on") else { throw Failure(message: "A fragment needs a name and a type condition") }
                _ = try cursor.name()
                _ = try directives(&cursor)
                fragments[name] = try selectionSet(&cursor)
            default:
                throw Failure(message: "Syntax Error: unexpected \(describe(token))")
            }
        }
        guard !operations.isEmpty else { throw Failure(message: "The document has no operation") }
        return StudioGraphQLDocument(operations: operations, fragments: fragments)
    }

    private struct Cursor {
        let tokens: [Token]
        var index = 0
        var depth = 0

        var peek: Token? { index < tokens.count ? tokens[index] : nil }

        mutating func next() throws -> Token {
            guard index < tokens.count else { throw Failure(message: "Syntax Error: unexpected end of the document") }
            index += 1
            return tokens[index - 1]
        }

        mutating func take(_ character: Character) -> Bool {
            guard peek == .punctuator(character) else { return false }
            index += 1
            return true
        }

        mutating func take(name: String) -> Bool {
            guard peek == .name(name) else { return false }
            index += 1
            return true
        }

        mutating func expect(_ character: Character) throws {
            guard take(character) else {
                throw Failure(message: "Syntax Error: expected \(character), found \(peek.map(StudioGraphQLParser.describe) ?? "the end")")
            }
        }

        mutating func name() throws -> String {
            guard case .name(let name) = try next() else { throw Failure(message: "Syntax Error: expected a name") }
            return name
        }

        mutating func enter() throws {
            depth += 1
            if depth > StudioGraphQLParser.maxDepth { throw Failure(message: "The document is nested too deeply") }
        }
    }

    private static func describe(_ token: Token) -> String {
        switch token {
        case .punctuator(let character): return "\"\(character)\""
        case .spread: return "\"...\""
        case .name(let name): return "\"\(name)\""
        case .number(let number): return "\(number)"
        case .string: return "a string"
        }
    }

    private static func skipType(_ cursor: inout Cursor) throws {
        if cursor.take("[") {
            try cursor.enter()
            try skipType(&cursor)
            try cursor.expect("]")
            cursor.depth -= 1
        } else {
            _ = try cursor.name()
        }
        _ = cursor.take("!")
    }

    private static func selectionSet(_ cursor: inout Cursor) throws -> [StudioGraphQLSelection] {
        try cursor.expect("{")
        try cursor.enter()
        var selections: [StudioGraphQLSelection] = []
        while !cursor.take("}") {
            if cursor.peek == .spread {
                cursor.index += 1
                if case .name(let name)? = cursor.peek, name != "on" {
                    cursor.index += 1
                    selections.append(.spread(name, try directives(&cursor)))
                } else {
                    var type: String?
                    if cursor.take(name: "on") { type = try cursor.name() }
                    let given = try directives(&cursor)
                    selections.append(.inline(type, given, try selectionSet(&cursor)))
                }
                continue
            }
            var name = try cursor.name()
            var alias: String?
            if cursor.take(":") {
                alias = name
                name = try cursor.name()
            }
            var field = StudioGraphQLField(alias: alias, name: name)
            if cursor.peek == .punctuator("(") { field.arguments = try arguments(&cursor) }
            field.directives = try directives(&cursor)
            if cursor.peek == .punctuator("{") { field.selections = try selectionSet(&cursor) }
            selections.append(.field(field))
        }
        cursor.depth -= 1
        guard !selections.isEmpty else { throw Failure(message: "Syntax Error: a selection set is empty") }
        return selections
    }

    private static func arguments(_ cursor: inout Cursor) throws -> [String: StudioGraphQLValue] {
        try cursor.expect("(")
        var result: [String: StudioGraphQLValue] = [:]
        while !cursor.take(")") {
            let name = try cursor.name()
            try cursor.expect(":")
            result[name] = try value(&cursor)
        }
        return result
    }

    private static func directives(_ cursor: inout Cursor) throws -> [StudioGraphQLDirective] {
        var result: [StudioGraphQLDirective] = []
        while cursor.take("@") {
            let name = try cursor.name()
            let given = cursor.peek == .punctuator("(") ? try arguments(&cursor) : [:]
            result.append(StudioGraphQLDirective(name: name, arguments: given))
        }
        return result
    }

    private static func value(_ cursor: inout Cursor) throws -> StudioGraphQLValue {
        switch try cursor.next() {
        case .punctuator("$"): return .variable(try cursor.name())
        case .number(let number): return .constant(.number(number))
        case .string(let text): return .constant(.string(text))
        case .name("true"): return .constant(.bool(true))
        case .name("false"): return .constant(.bool(false))
        case .name("null"): return .constant(.null)
        case .name(let name): return .constant(.string(name))
        case .punctuator("["):
            try cursor.enter()
            var items: [StudioGraphQLValue] = []
            while !cursor.take("]") { items.append(try value(&cursor)) }
            cursor.depth -= 1
            return .list(items)
        case .punctuator("{"):
            try cursor.enter()
            var fields: [String: StudioGraphQLValue] = [:]
            while !cursor.take("}") {
                let name = try cursor.name()
                try cursor.expect(":")
                fields[name] = try value(&cursor)
            }
            cursor.depth -= 1
            return .object(fields)
        case let token:
            throw Failure(message: "Syntax Error: unexpected \(describe(token))")
        }
    }

    // MARK: Lexer

    static func tokens(_ text: String) throws -> [Token] {
        guard text.utf8.count <= maxLength else { throw Failure(message: "The document is longer than \(maxLength) bytes") }
        let scalars = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var index = 0
        func at(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case " ", "\t", "\n", "\r", ",", "\u{FEFF}":
                index += 1
            case "#":
                while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" { index += 1 }
            case "!", "$", "&", "(", ")", ":", "=", "@", "[", "]", "{", "|", "}":
                tokens.append(.punctuator(Character(scalar)))
                index += 1
            case ".":
                guard at(1) == ".", at(2) == "." else { throw Failure(message: "Syntax Error: unexpected \".\"") }
                tokens.append(.spread)
                index += 3
            case "\"":
                if at(1) == "\"", at(2) == "\"" {
                    index += 3
                    var raw = ""
                    while true {
                        guard index < scalars.count else { throw Failure(message: "Syntax Error: an unterminated block string") }
                        if scalars[index] == "\"", at(1) == "\"", at(2) == "\"" { index += 3; break }
                        if scalars[index] == "\\", at(1) == "\"", at(2) == "\"", at(3) == "\"" {
                            raw += "\"\"\""
                            index += 4
                            continue
                        }
                        raw.unicodeScalars.append(scalars[index])
                        index += 1
                    }
                    tokens.append(.string(blockString(raw)))
                } else {
                    index += 1
                    var value = ""
                    while true {
                        guard index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" else {
                            throw Failure(message: "Syntax Error: an unterminated string")
                        }
                        let character = scalars[index]
                        index += 1
                        if character == "\"" { break }
                        guard character == "\\" else { value.unicodeScalars.append(character); continue }
                        guard index < scalars.count else { throw Failure(message: "Syntax Error: an unterminated string") }
                        let escaped = scalars[index]
                        index += 1
                        switch escaped {
                        case "\"", "\\", "/": value.unicodeScalars.append(escaped)
                        case "b": value += "\u{8}"
                        case "f": value += "\u{C}"
                        case "n": value += "\n"
                        case "r": value += "\r"
                        case "t": value += "\t"
                        case "u":
                            guard index + 4 <= scalars.count,
                                  let code = UInt32(String(String.UnicodeScalarView(scalars[index..<index + 4])), radix: 16) else {
                                throw Failure(message: "Syntax Error: a bad unicode escape")
                            }
                            index += 4
                            value.unicodeScalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                        default: throw Failure(message: "Syntax Error: a bad escape \\\(escaped)")
                        }
                    }
                    tokens.append(.string(value))
                }
            case "-", "0"..."9":
                var number = ""
                while index < scalars.count, "0123456789-+.eE".unicodeScalars.contains(scalars[index]) {
                    number.unicodeScalars.append(scalars[index])
                    index += 1
                }
                guard let value = Double(number) else { throw Failure(message: "Syntax Error: a bad number \(number)") }
                tokens.append(.number(value))
            case "_", "A"..."Z", "a"..."z":
                var name = ""
                while index < scalars.count, scalars[index] == "_" || ("A"..."Z").contains(scalars[index])
                        || ("a"..."z").contains(scalars[index]) || ("0"..."9").contains(scalars[index]) {
                    name.unicodeScalars.append(scalars[index])
                    index += 1
                }
                tokens.append(.name(name))
            default:
                throw Failure(message: "Syntax Error: unexpected character \"\(Character(scalar))\"")
            }
            if tokens.count > maxTokens { throw Failure(message: "The document has more than \(maxTokens) tokens") }
        }
        return tokens
    }

    /// A block string's value: common indentation removed, blank first and last lines dropped.
    private static func blockString(_ raw: String) -> String {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let indents = lines.dropFirst().compactMap { line -> Int? in
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            return indent < line.count ? indent : nil
        }
        if let common = indents.min(), common > 0 {
            lines = [lines[0]] + lines.dropFirst().map { String($0.dropFirst(min(common, $0.count))) }
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Requests

/// A GraphQL request over HTTP: the document, the chosen operation and its variables.
struct StudioGraphQLRequest: Equatable {
    var document: StudioGraphQLDocument
    var operation: StudioGraphQLDefinition
    var variables: [String: StudioJSON]

    /// nil: the request is not GraphQL. A failure: a GraphQL request that cannot be read, answered with `errors`.
    /// GraphQL is recognised by a document in `query` (POST JSON, `application/graphql`, or GET `?query=`) that starts like
    /// one, or by an endpoint whose path names GraphQL.
    static func read(_ request: StudioHTTPRequest) -> Result<StudioGraphQLRequest, StudioGraphQLParser.Failure>? {
        let endpoint = request.path.lowercased().contains("graphql")
        var query: String?
        var variables: StudioJSON?
        var name: String?
        var persisted = false
        if request.method == "GET" {
            let items = request.query
            query = items["query"]
            variables = items["variables"].flatMap { StudioJSON(text: $0) }
            name = items["operationName"]
            persisted = items["extensions"]?.contains("persistedQuery") == true
        } else if request.method == "POST" {
            if request.headers["content-type"]?.lowercased().hasPrefix("application/graphql") == true {
                query = request.body
            } else if let body = request.jsonBody?.objectValue {
                query = body["query"]?.stringValue
                variables = body["variables"]
                name = body["operationName"]?.stringValue
                persisted = body["extensions"]?["persistedQuery"] != nil
            }
        }
        guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Automatic persisted queries send a hash first; this answer makes the client send the whole document.
            if endpoint, persisted {
                return .failure(StudioGraphQLParser.Failure(message: "PersistedQueryNotFound", code: "PERSISTED_QUERY_NOT_FOUND"))
            }
            return nil
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeGraphQL = trimmed.range(of: #"^(query|mutation|subscription|fragment)\b|^\{"#, options: .regularExpression) != nil
        guard looksLikeGraphQL || endpoint else { return nil }
        return parse(query, variables: variables, operationName: name)
    }

    /// Reads a document with its variables (a JSON object, or JSON text of one) and picks the operation to run.
    static func parse(_ query: String, variables: StudioJSON?, operationName: String?) -> Result<StudioGraphQLRequest, StudioGraphQLParser.Failure> {
        let document: StudioGraphQLDocument
        do { document = try StudioGraphQLParser.parse(query) } catch let failure as StudioGraphQLParser.Failure {
            return .failure(failure)
        } catch {
            return .failure(StudioGraphQLParser.Failure(message: "The document could not be read"))
        }
        let name = operationName?.isEmpty == true ? nil : operationName
        let operation: StudioGraphQLDefinition
        if let name {
            guard let named = document.operations.first(where: { $0.name == name }) else {
                return .failure(StudioGraphQLParser.Failure(message: "Unknown operation named \"\(name)\""))
            }
            operation = named
        } else {
            guard document.operations.count == 1 else {
                return .failure(StudioGraphQLParser.Failure(message: "Must provide operation name if query contains multiple operations"))
            }
            operation = document.operations[0]
        }
        var given = variables ?? .null
        if case .string(let text) = given { given = StudioJSON(text: text) ?? .null }
        return .success(StudioGraphQLRequest(document: document, operation: operation, variables: given.objectValue ?? [:]))
    }

    /// The variables with the operation's defaults for those not given.
    var resolvedVariables: [String: StudioJSON] {
        var result = variables
        for (name, value) in operation.defaults where result[name] == nil {
            result[name] = StudioGraphQLExecutor.json(value, variables: [:])
        }
        return result
    }

    /// The root fields of the operation, fragments spread and `@skip`/`@include` applied.
    var rootFields: [StudioGraphQLField] {
        StudioGraphQLExecutor.fields(operation.selections, fragments: document.fragments, variables: resolvedVariables)
    }
}

// MARK: - Execution

/// Answers GraphQL fields from records: arguments, selection sets, `__typename`, related records and Relay connections.
enum StudioGraphQLExecutor {
    /// Argument names that page or order a list instead of filtering it.
    static let pagingArguments: Set<String> = ["first", "last", "limit", "take", "offset", "skip", "after", "before", "page", "perPage",
                                                "orderBy", "order_by", "order", "sort", "sortBy", "where", "filter", "distinct_on"]

    struct Context {
        var spec: StudioEnvironmentSpec
        var state: [String: [StudioJSON]]
        var fragments: [String: [StudioGraphQLSelection]]
        var variables: [String: StudioJSON]
    }

    /// The fields a selection set asks for, in order, with fragments spread, `@skip`/`@include` applied and fields with the
    /// same response key merged.
    static func fields(_ selections: [StudioGraphQLSelection], fragments: [String: [StudioGraphQLSelection]],
                       variables: [String: StudioJSON], depth: Int = 0) -> [StudioGraphQLField] {
        guard depth < StudioGraphQLParser.maxDepth else { return [] }
        var result: [StudioGraphQLField] = []
        func add(_ field: StudioGraphQLField) {
            if let index = result.firstIndex(where: { $0.responseKey == field.responseKey }) {
                result[index].selections += field.selections
            } else {
                result.append(field)
            }
        }
        for selection in selections {
            switch selection {
            case .field(let field):
                if included(field.directives, variables: variables) { add(field) }
            case .spread(let name, let directives):
                guard included(directives, variables: variables), let spread = fragments[name] else { continue }
                fields(spread, fragments: fragments, variables: variables, depth: depth + 1).forEach(add)
            case .inline(_, let directives, let nested):
                guard included(directives, variables: variables) else { continue }
                fields(nested, fragments: fragments, variables: variables, depth: depth + 1).forEach(add)
            }
        }
        return result
    }

    private static func included(_ directives: [StudioGraphQLDirective], variables: [String: StudioJSON]) -> Bool {
        for directive in directives {
            let condition = directive.arguments["if"].map { json($0, variables: variables).boolValue ?? false }
            if directive.name == "skip", condition == true { return false }
            if directive.name == "include", condition == false { return false }
        }
        return true
    }

    static func json(_ value: StudioGraphQLValue, variables: [String: StudioJSON]) -> StudioJSON {
        switch value {
        case .variable(let name): return variables[name] ?? .null
        case .constant(let json): return json
        case .list(let items): return .array(items.map { json($0, variables: variables) })
        case .object(let fields): return .object(fields.mapValues { json($0, variables: variables) })
        }
    }

    static func arguments(_ field: StudioGraphQLField, variables: [String: StudioJSON]) -> [String: StudioJSON] {
        field.arguments.mapValues { json($0, variables: variables) }
    }

    /// `__typename` of an entity's records: `posts` → `Post`, `categories` → `Category`.
    static func typeName(entity: String) -> String {
        var name = entity
        if name.hasSuffix("ies"), name.count > 3 { name = String(name.dropLast(3)) + "y" }
        else if name.hasSuffix("s"), !name.hasSuffix("ss"), name.count > 1 { name = String(name.dropLast()) }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Projection

    /// `value` shaped by a selection set: only the fields asked for, under their aliases, related records looked up when a
    /// record has only their id, `null` for what is missing.
    /// `wrapper`: an envelope object around a list (`{ items, total }`), whose children are records of `type` and `entity`.
    static func project(_ value: StudioJSON, _ selections: [StudioGraphQLSelection], type: String, entity: String?, context: Context,
                        depth: Int = 0, wrapper: Bool = false) -> StudioJSON {
        guard !selections.isEmpty, depth < StudioGraphQLParser.maxDepth else { return value }
        switch value {
        case .array(let items):
            return .array(items.map { project($0, selections, type: type, entity: entity, context: context, depth: depth + 1) })
        case .object(let object):
            var result: [String: StudioJSON] = [:]
            for field in fields(selections, fragments: context.fragments, variables: context.variables) {
                if field.name == "__typename" {
                    result[field.responseKey] = .string(wrapper ? type + "List" : type)
                    continue
                }
                if wrapper {
                    result[field.responseKey] = project(object[field.name] ?? .null, field.selections, type: type, entity: entity, context: context,
                                                        depth: depth + 1)
                    continue
                }
                var child = object[field.name]
                var childEntity: String?
                if child == nil, let related = relation(field.name, of: object, entity: entity, context: context) {
                    child = related.value
                    childEntity = related.entity
                }
                let (childType, nextEntity) = childShape(field.name, parentType: type, parentEntity: entity, related: childEntity)
                result[field.responseKey] = project(child ?? .null, field.selections, type: childType, entity: nextEntity, context: context,
                                                    depth: depth + 1)
            }
            return .object(result)
        default:
            return value
        }
    }

    private static func childShape(_ name: String, parentType: String, parentEntity: String?, related: String?) -> (String, String?) {
        if let related { return (typeName(entity: related), related) }
        if parentType.hasSuffix("Connection") {
            let base = String(parentType.dropLast("Connection".count))
            switch name {
            case "edges": return (base + "Edge", parentEntity)
            case "nodes": return (base, parentEntity)
            case "pageInfo": return ("PageInfo", nil)
            default: break
            }
        }
        if parentType.hasSuffix("Edge"), name == "node" { return (String(parentType.dropLast("Edge".count)), parentEntity) }
        return (typeName(entity: name), nil)
    }

    /// A related record a record names only by id (`authorId` → `author`), or the records of an entity that point at it
    /// (`comments` whose `postId` is the post's id).
    private static func relation(_ name: String, of record: [String: StudioJSON], entity: String?,
                                 context: Context) -> (value: StudioJSON, entity: String)? {
        let spec = context.spec
        for key in [name + "Id", name + "_id", name + "ID"] {
            guard let id = record[key]?.identityKey else { continue }
            let declared = entity.flatMap { spec.entity($0)?.fields.first { $0.name == key }?.references }
            let candidates = [declared, name, name + "s", name + "es"].compactMap { $0 }
            for target in candidates {
                guard let records = context.state[target] else { continue }
                let idField = spec.entity(target)?.idField ?? "id"
                return (records.first { $0[idField]?.identityKey == id } ?? .null, target)
            }
        }
        guard let entity, let records = context.state[name] else { return nil }
        let idField = spec.entity(entity)?.idField ?? "id"
        guard let id = record[idField]?.identityKey else { return nil }
        let singular = typeName(entity: entity)
        let lower = singular.prefix(1).lowercased() + singular.dropFirst()
        for key in [lower + "Id", lower + "_id", lower + "ID"] where records.contains(where: { $0[key] != nil }) {
            return (.array(records.filter { $0[key]?.identityKey == id }), name)
        }
        return nil
    }

    // MARK: Lists

    /// The records of a list field: equality filters from scalar arguments and `where`/`filter` objects, ordering, paging.
    static func list(_ records: [StudioJSON], arguments: [String: StudioJSON], entity: StudioEntity?) -> (page: [StudioJSON], total: Int, start: Int) {
        var list = records
        func filter(_ name: String, _ wanted: StudioJSON) {
            var expected = wanted
            if let object = wanted.objectValue {
                guard let equal = object["_eq"] ?? object["eq"] ?? object["equals"] else { return }
                expected = equal
            }
            guard let key = expected.identityKey, entity?.fields.contains(where: { $0.name == name }) == true
                    || records.contains(where: { $0[name] != nil }) else { return }
            list = list.filter { $0[name]?.identityKey == key }
        }
        for (name, value) in arguments where !pagingArguments.contains(name) && value.objectValue == nil && value.arrayValue == nil {
            filter(name, value)
        }
        for name in ["where", "filter"] {
            for (field, value) in arguments[name]?.objectValue ?? [:] { filter(field, value) }
        }
        if let order = arguments["orderBy"] ?? arguments["order_by"] ?? arguments["sort"] {
            let first = order.arrayValue?.first ?? order
            if let (field, direction) = first.objectValue?.first {
                let descending = direction.stringValue?.lowercased().hasPrefix("desc") == true
                list.sort { a, b in
                    let x = a[field], y = b[field]
                    let less: Bool
                    if let p = x?.numberValue, let q = y?.numberValue { less = p < q } else { less = (x?.identityKey ?? "") < (y?.identityKey ?? "") }
                    return descending ? !less && x != y : less
                }
            }
        }
        let total = list.count
        var start = 0
        if let offset = (arguments["offset"] ?? arguments["skip"])?.numberValue { start = max(0, Int(offset)) }
        if let after = arguments["after"]?.identityKey, let index = list.firstIndex(where: { cursor(of: $0, entity: entity) == after }) {
            start = index + 1
        }
        start = min(start, list.count)
        var end = list.count
        if let size = (arguments["first"] ?? arguments["limit"] ?? arguments["take"])?.numberValue { end = min(list.count, start + max(0, Int(size))) }
        if let last = arguments["last"]?.numberValue, arguments["first"] == nil { start = max(start, end - max(0, Int(last))) }
        return (Array(list[start..<end]), total, start)
    }

    /// A record's cursor in a connection: its id.
    static func cursor(of record: StudioJSON, entity: StudioEntity?) -> String {
        record[entity?.idField ?? "id"]?.identityKey ?? ""
    }

    /// A page of records as a Relay connection.
    static func connection(_ page: [StudioJSON], total: Int, start: Int, entity: StudioEntity?) -> StudioJSON {
        let cursors = page.map { cursor(of: $0, entity: entity) }
        return .object([
            "edges": .array(zip(page, cursors).map { .object(["node": $0, "cursor": .string($1)]) }),
            "nodes": .array(page),
            "totalCount": .number(Double(total)),
            "pageInfo": .object([
                "hasNextPage": .bool(start + page.count < total), "hasPreviousPage": .bool(start > 0),
                "startCursor": cursors.first.map { .string($0) } ?? .null, "endCursor": cursors.last.map { .string($0) } ?? .null,
            ]),
        ])
    }

    static func error(_ message: String, path: [String] = [], code: String? = nil) -> StudioJSON {
        var object: [String: StudioJSON] = ["message": .string(message)]
        if !path.isEmpty { object["path"] = .array(path.map { .string($0) }) }
        if let code { object["extensions"] = .object(["code": .string(code)]) }
        return .object(object)
    }
}

// MARK: - Simulation

extension StudioSimulator {
    /// The usable GraphQL operations of the endpoint `url` names.
    func graphQLOperations(at url: URL) -> [StudioGraphQLOperation] {
        let origin = StudioChannelRoute.origin(of: url)
        return (spec.graphQL ?? []).filter { operation in
            guard operation.isUsable else { return false }
            let (ruleOrigin, path) = StudioRoute.split(StudioChannelRoute.httpPattern(operation.path))
            if let ruleOrigin { guard ruleOrigin == origin else { return false } } else if appOrigin != nil, origin != appOrigin { return false }
            return StudioRoute.match(pattern: path, path: url.path.isEmpty ? "/" : url.path) != nil
        }
    }

    /// The contract of the GraphQL fields nobody answers yet: `GRAPHQL /graphql query posts,users`.
    static func graphQLContract(url: URL, kind: StudioGraphQLOperation.Kind, fields: [String], appOrigin: String?) -> String {
        StudioRoute.contractKey(method: "GRAPHQL", url: url, appOrigin: appOrigin) + " \(kind.rawValue) " + Set(fields).sorted().joined(separator: ",")
    }

    /// Answers a GraphQL request from the state (REQ-015): every root field by its operation rule, writes applied like a
    /// REST rule's, `{data}` and `{errors}` as a GraphQL server answers them. A field without a rule makes the request unknown.
    mutating func handleGraphQL(_ read: Result<StudioGraphQLRequest, StudioGraphQLParser.Failure>, request: StudioHTTPRequest) -> StudioSimOutcome {
        let graphQL: StudioGraphQLRequest
        switch read {
        case .failure(let failure):
            let status = failure.code == "PERSISTED_QUERY_NOT_FOUND" ? 200 : 400
            return .respond(.json(status, .object(["errors": .array([StudioGraphQLExecutor.error(failure.message, code: failure.code)])])),
                            rule: "graphql")
        case .success(let value):
            graphQL = value
        }
        let kind = graphQL.operation.kind
        let endpoint = StudioRoute.contractKey(method: "GRAPHQL", url: request.url, appOrigin: appOrigin)
        if kind == .subscription {
            return .unsupported(contract: endpoint + " subscription",
                                reason: "GraphQL subscriptions over HTTP (they are simulated over graphql-ws WebSockets)")
        }
        let fields = graphQL.rootFields
        let operations = graphQLOperations(at: request.url).filter { $0.kind == kind }
        let missing = fields.map(\.name).filter { name in !name.hasPrefix("__") && !operations.contains { $0.field == name } }
        if !missing.isEmpty { return .unknown(contract: Self.graphQLContract(url: request.url, kind: kind, fields: missing, appOrigin: appOrigin)) }
        let used = fields.compactMap { field in operations.first { $0.field == field.name } }
        let ruleID = used.map(\.id).joined(separator: ",")
        if let override = scenario.overrides.first(where: { override in used.contains { $0.id == override.ruleId } }) {
            if override.hang == true { return .respond(StudioSimResponse(status: 200, body: nil, hang: true), rule: ruleID) }
            if let status = override.status {
                var response = StudioSimResponse.json(status, override.body ?? .object([
                    "errors": .array([StudioGraphQLExecutor.error("Simulated error \(status)")]), "data": .null,
                ]))
                response.delayMs = max(0, override.delayMs ?? 0)
                return .respond(response, rule: ruleID)
            }
        }
        let empty = scenario.overrides.contains { override in override.empty == true && used.contains { $0.id == override.ruleId } }
        var data: [String: StudioJSON] = [:]
        var errors: [StudioJSON] = []
        let variables = graphQL.resolvedVariables
        for field in fields {
            if field.name == "__typename" {
                data[field.responseKey] = .string(kind == .mutation ? "Mutation" : "Query")
                continue
            }
            if field.name.hasPrefix("__") {
                data[field.responseKey] = .null
                errors.append(StudioGraphQLExecutor.error("Introspection (\(field.name)) is not simulated by MarkView UI Studio",
                                                          path: [field.responseKey]))
                continue
            }
            guard let operation = operations.first(where: { $0.field == field.name }) else { continue }
            data[field.responseKey] = resolve(field, operation, variables: variables, fragments: graphQL.document.fragments, empty: empty,
                                              errors: &errors)
        }
        var body: [String: StudioJSON] = ["data": .object(data)]
        if !errors.isEmpty { body["errors"] = .array(errors) }
        var response = StudioSimResponse.json(200, .object(body))
        if let delay = scenario.overrides.first(where: { override in used.contains { $0.id == override.ruleId } })?.delayMs {
            response.delayMs = max(0, delay)
        }
        return .respond(response, rule: ruleID)
    }

    /// One root field's value. Writes go through `perform`, so they validate and change the state exactly like REST writes.
    mutating func resolve(_ field: StudioGraphQLField, _ operation: StudioGraphQLOperation, variables: [String: StudioJSON],
                          fragments: [String: [StudioGraphQLSelection]], empty: Bool = false, errors: inout [StudioJSON]) -> StudioJSON {
        let arguments = StudioGraphQLExecutor.arguments(field, variables: variables)
        let entityName = operation.entity ?? ""
        let entity = spec.entity(entityName)
        let type = operation.typeName ?? StudioGraphQLExecutor.typeName(entity: entityName.isEmpty ? field.name : entityName)
        let idField = entity?.idField ?? "id"
        func context() -> StudioGraphQLExecutor.Context {
            StudioGraphQLExecutor.Context(spec: spec, state: state, fragments: fragments, variables: variables)
        }
        func shaped(_ value: StudioJSON, type: String) -> StudioJSON {
            StudioGraphQLExecutor.project(value, field.selections, type: type, entity: entityName.isEmpty ? nil : entityName, context: context())
        }
        func input() -> StudioJSON {
            for name in [operation.inputArgument, "input", "data", "object", "record", "values", "_set", "set", "patch", "changes"].compactMap({ $0 }) {
                if let value = arguments[name], value.objectValue != nil || value.arrayValue != nil { return value }
            }
            return .object(arguments)
        }
        func wantedID() -> String? {
            let name = operation.idArgument ?? "id"
            let found = arguments[name] ?? arguments["where"]?[idField] ?? arguments["pk_columns"]?[idField] ?? input()[idField] ?? arguments[idField]
            return found?.identityKey
        }
        func attached(_ record: StudioJSON) -> StudioJSON {
            guard let includes = operation.include, var fields = record.objectValue, let id = record[idField]?.identityKey else { return record }
            for include in includes {
                fields[include.field] = .array((state[include.entity] ?? []).filter { $0[include.foreignKey]?.identityKey == id })
            }
            return .object(fields)
        }
        func failed(_ response: StudioSimResponse) -> StudioJSON {
            let body = response.body.flatMap { StudioJSON(text: $0) }
            let message = body?["error"]?.stringValue ?? body?["errors"]?.arrayValue?.compactMap(\.stringValue).joined(separator: "; ")
            errors.append(StudioGraphQLExecutor.error(message ?? "The simulated write failed (\(response.status))", path: [field.responseKey],
                                                      code: response.status == 404 ? "NOT_FOUND" : "BAD_USER_INPUT"))
            return .null
        }

        switch operation.action {
        case .respond:
            let value = StudioChannelTemplate.fill(operation.response ?? .null, ["args": .object(arguments)])
            return shaped(value, type: type)
        case .list:
            let records = empty ? [] : (state[entityName] ?? []).map(attached)
            let (page, total, start) = StudioGraphQLExecutor.list(records, arguments: arguments, entity: entity)
            if operation.connection == true {
                return shaped(StudioGraphQLExecutor.connection(page, total: total, start: start, entity: entity), type: type + "Connection")
            }
            if let envelope = operation.envelope {
                let wrapped = StudioJSON.object([envelope: .array(page), "total": .number(Double(total)), "totalCount": .number(Double(total)),
                                                 "count": .number(Double(total))])
                return StudioGraphQLExecutor.project(wrapped, field.selections, type: type, entity: entityName, context: context(), wrapper: true)
            }
            return shaped(.array(page), type: type)
        case .get:
            guard !empty, let id = wantedID(), let record = (state[entityName] ?? []).first(where: { $0[idField]?.identityKey == id }) else { return .null }
            return shaped(attached(record), type: type)
        case .create:
            let given = input()
            let items = given.arrayValue ?? [given]
            var created: [StudioJSON] = []
            for item in items {
                let response = perform(.create, entity: entityName, id: nil, fields: item)
                guard (200..<300).contains(response.status), let record = response.body.flatMap({ StudioJSON(text: $0) }) else { return failed(response) }
                created.append(record)
            }
            if field.selections.isEmpty { return given.arrayValue == nil ? (created.first?[idField] ?? .null) : .bool(true) }
            return shaped(given.arrayValue == nil ? created[0] : .array(created), type: type)
        case .update:
            guard let id = wantedID() else { return failed(.json(404, .object(["error": .string("\(entityName): no id was given")]))) }
            var changes = input().objectValue ?? [:]
            changes[idField] = nil
            let response = perform(.update, entity: entityName, id: id, fields: .object(changes))
            guard (200..<300).contains(response.status), let record = response.body.flatMap({ StudioJSON(text: $0) }) else { return failed(response) }
            return field.selections.isEmpty ? (record[idField] ?? .null) : shaped(record, type: type)
        case .delete:
            guard let id = wantedID() else { return failed(.json(404, .object(["error": .string("\(entityName): no id was given")]))) }
            let before = (state[entityName] ?? []).first { $0[idField]?.identityKey == id }
            let response = perform(.delete, entity: entityName, id: id, fields: .object([:]))
            guard (200..<300).contains(response.status) else { return failed(response) }
            return field.selections.isEmpty ? .bool(true) : shaped(before ?? .null, type: type)
        }
    }
}
