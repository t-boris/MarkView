import AppKit
import MarkViewCore
import CryptoKit
import os
import Darwin
import WebKit
import XCTest
@testable import MarkView

// Model checks use the same app-hosted XCTest class as the session lifetime suite.
extension UIStudioLifetimeHostTests {
    @MainActor func testGraphQLModel() {
        let app = "http://localhost:5173"
        var requestCounter = 0
        func request(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:]) -> StudioHTTPRequest {
            requestCounter += 1
            return StudioHTTPRequest(method: method, url: URL(string: app + path)!, headers: headers, body: body, requestId: "r\(requestCounter)")
        }
        func json(_ text: String) -> StudioJSON { StudioJSON(text: text) ?? .null }
        func answer(_ outcome: StudioSimOutcome) -> (Int, StudioJSON?) {
            guard case .respond(let response, _) = outcome else { return (-1, nil) }
            return (response.status, response.body.flatMap { StudioJSON(text: $0) })
        }
        // Documents: operations, variables with defaults, aliases, arguments, fragments, directives, block strings, comments.
        let source = """
            # The feed
            query Feed($first: Int = 2, $skipAuthor: Boolean!) {
              latest: posts(first: $first, where: {status: {_eq: "published"}}) { ...postFields author @skip(if: $skipAuthor) { name } }
              ... on Query { me { id } }
            }
            fragment postFields on Post { id title __typename body: text(format: \"\"\"
                block
                \"\"\") }
            """
        let document = try? StudioGraphQLParser.parse(source)
        check("GraphQL: a document with a fragment and a named operation is read", document?.operations.count == 1
              && document?.operations.first?.name == "Feed" && document?.fragments["postFields"] != nil
              && document?.operations.first?.defaults["first"] == .constant(.number(2)))
        if let document, let operation = document.operations.first {
            let roots = StudioGraphQLExecutor.fields(operation.selections, fragments: document.fragments, variables: ["skipAuthor": .bool(true)])
            check("GraphQL: inline fragments are spread into the root fields", roots.map(\.responseKey) == ["latest", "me"], "\(roots.map(\.responseKey))")
            let nested = roots.first.map { StudioGraphQLExecutor.fields($0.selections, fragments: document.fragments, variables: ["skipAuthor": .bool(true)]) } ?? []
            check("GraphQL: fragment spreads, aliases and @skip apply", nested.map(\.responseKey) == ["id", "title", "__typename", "body"],
                  "\(nested.map(\.responseKey))")
            if case .constant(.string(let block))? = nested.last?.arguments["format"] {
                check("GraphQL: a block string loses its indentation", block == "block", block)
            } else { check("GraphQL: block string argument", false) }
        }
        check("GraphQL: an unterminated selection set is a syntax error", (try? StudioGraphQLParser.parse("{ posts { id }")) == nil)
        check("GraphQL: an empty selection set is a syntax error", (try? StudioGraphQLParser.parse("query { }")) == nil)

        // Which requests are GraphQL.
        func post(_ path: String, _ body: String, headers: [String: String] = ["content-type": "application/json"]) -> StudioHTTPRequest {
            request("POST", path, body: body, headers: headers)
        }
        check("GraphQL: POST JSON with a document is GraphQL", (try? StudioGraphQLRequest.read(post("/graphql", #"{"query":"{ me { id } }"}"#))?.get()) != nil)
        check("GraphQL: GET ?query= is GraphQL", (try? StudioGraphQLRequest.read(request("GET", "/graphql?query=%7B%20me%20%7B%20id%20%7D%20%7D"))?.get()) != nil)
        check("GraphQL: application/graphql is GraphQL",
              (try? StudioGraphQLRequest.read(post("/api/gql", "query { me { id } }", headers: ["content-type": "application/graphql"]))?.get()) != nil)
        check("GraphQL: a REST search with a query field is not GraphQL", StudioGraphQLRequest.read(post("/api/search", #"{"query":"red shoes"}"#)) == nil
              && StudioGraphQLRequest.read(request("GET", "/api/search?query=hello")) == nil)
        if case .failure(let failure)? = StudioGraphQLRequest.read(post("/graphql", #"{"extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc"}}}"#)) {
            check("GraphQL: a persisted query hash asks for the document", failure.code == "PERSISTED_QUERY_NOT_FOUND")
        } else { check("GraphQL: persisted query", false) }
        if case .failure(let failure)? = StudioGraphQLRequest.read(post("/graphql", #"{"query":"query A { me { id } } query B { me { id } }"}"#)) {
            check("GraphQL: several operations need an operationName", failure.message.contains("operation name"))
        } else { check("GraphQL: several operations", false) }

        // Answers from the state.
        var gspec = StudioEnvironmentSpec()
        gspec.entities = [StudioEntity(name: "users", fields: [StudioField(name: "name", type: "string", required: true)]),
                          StudioEntity(name: "posts", fields: [StudioField(name: "title", type: "string", required: true),
                                                               StudioField(name: "authorId", type: "integer", references: "users"),
                                                               StudioField(name: "status", type: "string")])]
        gspec.seed = ["users": [json(#"{"id":1,"name":"Ada"}"#), json(#"{"id":2,"name":"Lin"}"#)],
                      "posts": [json(#"{"id":1,"title":"One","authorId":1,"status":"published"}"#), json(#"{"id":2,"title":"Two","authorId":2,"status":"draft"}"#),
                                json(#"{"id":3,"title":"Three","authorId":1,"status":"published"}"#)]]
        gspec.graphQL = [
            StudioGraphQLOperation(id: "q-posts", kind: .query, field: "posts", action: .list, entity: "posts"),
            StudioGraphQLOperation(id: "q-post", kind: .query, field: "post", action: .get, entity: "posts"),
            StudioGraphQLOperation(id: "q-feed", kind: .query, field: "feed", action: .list, entity: "posts", connection: true),
            StudioGraphQLOperation(id: "q-page", kind: .query, field: "postPage", action: .list, entity: "posts", envelope: "items"),
            StudioGraphQLOperation(id: "q-me", kind: .query, field: "me", action: .respond, response: json(#"{"id":"u-1","name":"Test {{args.x}}"}"#)),
            StudioGraphQLOperation(id: "m-create", kind: .mutation, field: "createPost", action: .create, entity: "posts"),
            StudioGraphQLOperation(id: "m-update", kind: .mutation, field: "updatePost", action: .update, entity: "posts"),
            StudioGraphQLOperation(id: "m-delete", kind: .mutation, field: "deletePost", action: .delete, entity: "posts"),
        ]
        var gsim = StudioSimulator(spec: gspec, scenario: StudioScenario(id: "g", name: "G", kind: .populated), appOrigin: app)
        func graph(_ query: String, variables: String = "{}", id: String? = nil) -> (Int, StudioJSON?) {
            var input = post("/graphql", StudioJSON.object(["query": .string(query), "variables": json(variables)]).text, headers: [:])
            if let id { input.requestId = id }
            return answer(gsim.handle(input))
        }
        let (listStatus, list) = graph(#"{ posts(where: {status: {_eq: "published"}}) { id title author { name } __typename } }"#)
        check("GraphQL: a list filters by where, resolves author from authorId and names the type",
              listStatus == 200 && list?["data"]?["posts"] == json(#"[{"id":1,"title":"One","author":{"name":"Ada"},"__typename":"Post"},{"id":3,"title":"Three","author":{"name":"Ada"},"__typename":"Post"}]"#),
              list?.text ?? "nil")
        let (_, detail) = graph("query($id: ID!) { a: post(id: $id) { title } b: post(id: 1) { title } }", variables: #"{"id":"2"}"#)
        check("GraphQL: a detail by variable and aliases", detail?["data"] == json(#"{"a":{"title":"Two"},"b":{"title":"One"}}"#), detail?.text ?? "nil")
        let (_, feed) = graph("{ feed(first: 2) { totalCount edges { cursor node { id } } pageInfo { hasNextPage endCursor } } }")
        check("GraphQL: a Relay connection pages with cursors",
              feed?["data"]?["feed"] == json(#"{"totalCount":3,"edges":[{"cursor":"1","node":{"id":1}},{"cursor":"2","node":{"id":2}}],"pageInfo":{"hasNextPage":true,"endCursor":"2"}}"#),
              feed?.text ?? "nil")
        let (_, after) = graph(#"{ feed(first: 2, after: "2") { edges { node { id } } } }"#)
        check("GraphQL: after continues from the cursor", after?["data"]?["feed"]?["edges"] == json(#"[{"node":{"id":3}}]"#), after?.text ?? "nil")
        let (_, page) = graph("{ postPage(limit: 1) { total items { title } } }")
        check("GraphQL: an envelope wraps the list", page?["data"]?["postPage"] == json(#"{"total":3,"items":[{"title":"One"}]}"#), page?.text ?? "nil")
        let (_, me) = graph(#"{ me(x: "A") { name } __typename }"#)
        check("GraphQL: a respond operation fills its arguments", me?["data"] == json(#"{"me":{"name":"Test A"},"__typename":"Query"}"#), me?.text ?? "nil")
        if case .unknown(let contract) = gsim.handle(post("/graphql", #"{"query":"{ comments { id } posts { id } }"}"#)) {
            check("GraphQL: a field without an operation is prepared, by its contract", contract == "GRAPHQL /graphql query comments", contract)
        } else { check("GraphQL: an unknown field is unknown", false) }
        let create = #"mutation { createPost(input: {title: "New", authorId: 2}) { id title author { name } } }"#
        let (_, created) = graph(create, id: "gm-1")
        _ = graph(create, id: "gm-1")
        check("GraphQL: a mutation creates the record once per request id",
              created?["data"]?["createPost"] == json(#"{"id":4,"title":"New","author":{"name":"Lin"}}"#) && gsim.state["posts"]?.count == 4,
              "\(created?.text ?? "nil") \(gsim.state["posts"]?.count ?? 0)")
        let (_, restList) = graph("{ posts { title } }")
        check("GraphQL: the list shows the new record", restList?["data"]?["posts"]?.arrayValue?.count == 4)
        let (_, updated) = graph(#"mutation { updatePost(id: 1, input: {title: "Uno"}) { id title } }"#)
        check("GraphQL: an update changes the record", updated?["data"]?["updatePost"] == json(#"{"id":1,"title":"Uno"}"#), updated?.text ?? "nil")
        let (_, deleted) = graph("mutation { deletePost(id: 3) { id title } }")
        check("GraphQL: a delete answers the record it removed", deleted?["data"]?["deletePost"] == json(#"{"id":3,"title":"Three"}"#)
              && gsim.state["posts"]?.count == 3, deleted?.text ?? "nil")
        let (_, invalid) = graph("mutation { createPost(input: {authorId: 1}) { id } }")
        check("GraphQL: a write the schema refuses is an error with a null field",
              invalid?["data"]?["createPost"] == .null && invalid?["errors"]?.arrayValue?.first?["message"]?.stringValue?.contains("title is required") == true,
              invalid?.text ?? "nil")
        if case .unsupported(_, let reason) = gsim.handle(post("/graphql", #"{"query":"subscription { postAdded { id } }"}"#)) {
            check("GraphQL: a subscription over HTTP is named as not simulated", reason.contains("subscriptions over HTTP"), reason)
        } else { check("GraphQL: subscription over HTTP", false) }
        var failing = StudioScenario(id: "f", name: "F", kind: .error)
        failing.overrides = [StudioOverride(ruleId: "q-posts", status: 500)]
        gsim.activate(failing)
        check("GraphQL: a scenario override fails the operation", graph("{ posts { id } }").0 == 500)
    }

    @MainActor func testRealtimeProposalModel() {
        let app = "http://localhost:5173"
        let origin = StudioBridge.Origin(url: URL(string: app)!)!
        let expectation = StudioBridge.Expectation(session: "s-1", generation: 3, origin: origin)
        func context(_ contract: String) -> StudioPreparationContext {
            StudioPreparationContext(contract: contract, method: "GET", url: app + "/api/labels", headers: [:], body: nil, attempt: 1, problems: [])
        }
        // Older environment files load; damaged channel parts are left out instead of failing the file.
        let old = #"{"schemaVersion":1,"entities":[],"rules":[],"seed":{},"allowedRequests":[],"confidentialFields":[],"dependencies":[]}"#
        let oldSpec = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: Data(old.utf8))
        check("REQ-015 an environment file without channels or GraphQL loads", oldSpec != nil && oldSpec?.channels == nil && oldSpec?.graphQL == nil)
        let damaged = String(old.dropLast()) + #","channels":[{"id":"x","path":"/ws","protocol":"carrier-pigeon","onMessage":[5,{"match":{"type":"a"}}]},"oops",{"id":7}],"graphQL":[{"id":"g","field":"posts","kind":"nope"},{}]}"#
        let damagedSpec = try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: Data(damaged.utf8))
        let usable = (damagedSpec?.channels ?? []).filter(\.isUsable)
        check("REQ-015 damaged channels and operations decode leniently", damagedSpec != nil && usable.count == 1 && usable.first?.wire == .raw
              && usable.first?.onMessage.count == 1 && (damagedSpec?.graphQL ?? []).filter(\.isUsable).first?.kind == .query,
              "\(damagedSpec.map { "\($0.channels ?? [])" } ?? "nil")")
        var roundTrip = StudioEnvironmentSpec()
        roundTrip.channels = [StudioChannel(id: "io", path: "/socket.io", wire: .socketio)]
        let encoded = (try? JSONEncoder().encode(roundTrip)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check("REQ-015 a channel's wire is saved as protocol", encoded.contains(#""protocol":"socketio""#)
              && (try? JSONDecoder().decode(StudioEnvironmentSpec.self, from: Data(encoded.utf8)))?.channels == roundTrip.channels)

        // Validation and registration of proposals with channels and operations only.
        var vspec = StudioEnvironmentSpec()
        vspec.entities = [StudioEntity(name: "messages", fields: [])]
        var proposal = StudioProposal()
        proposal.channels = [StudioChannel(id: "chat", path: "/ws/chat", links: [StudioChannelLink(entity: "messages", message: StudioChannelMessage(data: .string("x")))])]
        proposal.graphQL = [StudioGraphQLOperation(id: "q", kind: .query, field: "messages", action: .list, entity: "messages")]
        check("REQ-015 a proposal with only a channel and an operation is valid", StudioValidator.problems(proposal: proposal, spec: vspec, state: [:]).isEmpty,
              "\(StudioValidator.problems(proposal: proposal, spec: vspec, state: [:]))")
        var vsim = StudioSimulator(spec: vspec, scenario: StudioScenario(id: "v", name: "V", kind: .populated), appOrigin: app)
        check("REQ-015 registration adds channels and operations", vsim.register(proposal).isEmpty && vsim.spec.channels?.first?.id == "chat"
              && vsim.spec.graphQL?.first?.id == "q")
        check("REQ-015 the same channel and operation are not registered twice", !vsim.register(proposal).isEmpty)
        var bad = StudioProposal()
        bad.channels = [StudioChannel(id: "c", path: "chat", wire: .raw, events: [StudioChannelEvent(everyMs: 10)],
                                      links: [StudioChannelLink(entity: "ghosts")])]
        bad.graphQL = [StudioGraphQLOperation(id: "g", field: "bad-name", action: .respond)]
        let problems = StudioValidator.problems(proposal: bad, spec: vspec, state: [:]).joined(separator: "\n")
        check("REQ-015 bad channels and operations are named", problems.contains("must start with /") && problems.contains("entity ghosts is not defined")
              && problems.contains("needs a message") && problems.contains("at least 250") && problems.contains("not a GraphQL name")
              && problems.contains("needs a response"), problems)

        // The preparation schema and prompts.
        let schema = StudioRealtimePrompts.schema(StudioPrompts.preparationSchema)
        check("REQ-015 the preparation schema requires channels and graphql", (schema["required"] as? [String] ?? []).contains("channels")
              && (schema["required"] as? [String] ?? []).contains("graphql") && (schema["properties"] as? [String: Any])?["graphql"] != nil)
        let structured: [String: Any] = ["unsupported": false, "reason": "", "assumptions": [], "entities": [], "records": [], "rules": [],
                                         "channels": #"[{"id":"chat","path":"/ws","protocol":"socketio","onConnect":[{"event":"hello","data":{"a":1}}]}]"#,
                                         "graphql": #"[{"id":"q","field":"posts","action":"list","entity":"posts"},{"bad":true}]"#]
        let parsed = StudioRealtimePrompts.proposal(StudioPrompts.proposal(from: structured), from: structured)
        check("REQ-015 channels and operations are read from the answer", parsed?.channels?.first?.wire == .socketio
              && parsed?.channels?.first?.onConnect.first?.event == "hello" && parsed?.graphQL?.count == 1)
        let withoutThem = StudioRealtimePrompts.proposal(StudioPrompts.proposal(from: ["rules": []]), from: ["rules": []])
        check("REQ-015 an answer without channels still reads", withoutThem != nil && withoutThem?.channels == nil)
        let system = StudioRealtimePrompts.system(StudioPrompts.preparationSystem)
        check("REQ-015 the preparation prompt no longer refuses GraphQL and WebSockets",
              !system.contains("cannot answer over HTTP: GraphQL") && system.contains("Supabase Realtime") && system.contains("graphql-ws"))
        let channelPrompt = StudioRealtimePrompts.prompt("base", context: context("WS /socket"), spec: vspec)
        check("REQ-015 a channel contract asks for a channel", channelPrompt.contains("real-time connection") && channelPrompt.hasPrefix("base"))

        // The bridge's channel messages.
        func message(_ fields: [String: Any]) -> [String: Any] {
            fields.merging(["session": "s-1", "generation": 3, "kind": "channel"]) { first, _ in first }
        }
        if case .success(.channel(let open)) = StudioBridge.validate(message(["action": "open", "id": "c3-1-ab", "url": "wss://abc.supabase.co/realtime/v1/websocket",
                                                                            "protocols": ["graphql-transport-ws"], "transport": "websocket"]),
                                                                   isMainFrame: true, origin: origin, expecting: expectation) {
            check("bridge: a channel open is accepted", open.url?.host == "abc.supabase.co" && open.protocols == ["graphql-transport-ws"])
        } else { check("bridge: a channel open is accepted", false) }
        let refusedOpen = StudioBridge.validate(message(["action": "open", "id": "c1", "url": "file:///etc/passwd", "transport": "websocket"]),
                                                isMainFrame: true, origin: origin, expecting: expectation)
        let badCode = StudioBridge.validate(message(["action": "close", "id": "c1", "code": 1006]), isMainFrame: true, origin: origin, expecting: expectation)
        let badProtocol = StudioBridge.validate(message(["action": "open", "id": "c1", "url": "ws://localhost:5173/x", "transport": "websocket", "protocols": ["a b"]]),
                                                isMainFrame: true, origin: origin, expecting: expectation)
        check("bridge: a channel to a non-web URL, a reserved close code and a bad subprotocol are refused",
              refusedOpen == .failure(.malformed("channel url")) && badCode == .failure(.malformed("channel close code"))
              && badProtocol == .failure(.malformed("channel protocols")), "\(refusedOpen) \(badCode) \(badProtocol)")
        if case .success(.channel(let binary)) = StudioBridge.validate(message(["action": "send", "id": "c1", "binary": Data([1, 2, 3]).base64EncodedString()]),
                                                                     isMainFrame: true, origin: origin, expecting: expectation) {
            check("bridge: a binary message arrives as bytes", binary.binary == Data([1, 2, 3]))
        } else { check("bridge: binary message", false) }

        // WebSocket framing and server-sent events.
        check("websocket: the accept key of RFC 6455", StudioWebSocketCodec.acceptKey("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        var decoder = StudioWebSocketCodec.Decoder()
        let hello = StudioWebSocketCodec.frame(.text, Data("Hello".utf8), masked: true)
        let firstPart = (try? decoder.feed(hello.prefix(3))) ?? [.close(nil, "error")]
        let secondPart = (try? decoder.feed(hello.dropFirst(3))) ?? []
        check("websocket: a masked frame in two pieces", firstPart.isEmpty && secondPart == [.text("Hello")])
        let fragmented = StudioWebSocketCodec.frame(.text, Data("Hel".utf8), masked: true, fin: false) + StudioWebSocketCodec.frame(.ping, Data("p".utf8), masked: true)
            + StudioWebSocketCodec.frame(.continuation, Data("lo".utf8), masked: true)
        check("websocket: fragments with a ping between them", (try? decoder.feed(fragmented)) == [.ping(Data("p".utf8)), .text("Hello")])
        let long = String(repeating: "a", count: 70_000)
        check("websocket: a 64-bit length frame", (try? decoder.feed(StudioWebSocketCodec.frame(.text, Data(long.utf8), masked: true))) == [.text(long)])
        check("websocket: a close frame carries its code", (try? decoder.feed(StudioWebSocketCodec.frame(.close, Data([0x03, 0xE8]) + Data("bye".utf8), masked: true)))
              == [.close(1000, "bye")])
        var strict = StudioWebSocketCodec.Decoder()
        do { _ = try strict.feed(StudioWebSocketCodec.frame(.text, Data("x".utf8))); check("websocket: an unmasked client frame is refused", false) } catch let failure as StudioWebSocketCodec.Decoder.Failure {
            check("websocket: an unmasked client frame is refused", failure.code == 1002)
        } catch { check("websocket: unmasked", false) }
        var big = StudioWebSocketCodec.Decoder()
        do { _ = try big.feed(StudioWebSocketCodec.frame(.binary, Data(count: StudioWebSocketCodec.maxMessage + 1), masked: true)); check("websocket: too large", false) } catch let failure as StudioWebSocketCodec.Decoder.Failure {
            check("websocket: a frame over the limit closes with 1009", failure.code == 1009)
        } catch { check("websocket: too large", false) }
        check("sse: an event with lines and an id", String(decoding: StudioWebSocketCodec.event(name: "update", data: "a\nb", id: "7"), as: UTF8.self)
              == "event: update\ndata: a\ndata: b\nid: 7\n\n")
        check("streams: an Upgrade and an event-stream request are recognised",
              StudioWebSocketCodec.kind(method: "GET", headers: ["upgrade": "websocket", "connection": "keep-alive, Upgrade", "sec-websocket-key": "k",
                                                                 "sec-websocket-protocol": "graphql-transport-ws, graphql-ws"])
                  == .webSocket(protocols: ["graphql-transport-ws", "graphql-ws"])
              && StudioWebSocketCodec.kind(method: "GET", headers: ["accept": "text/event-stream"]) == .eventSource
              && StudioWebSocketCodec.kind(method: "POST", headers: ["accept": "text/event-stream"]) == nil)
    }

    @MainActor func testDataFixModel() {
        func pageError(_ detail: String) -> StudioDataFix.PageError {
            StudioDataFix.PageError(key: StudioDataFix.key(of: detail), kind: .runtimeError, detail: detail, date: Date())
        }
        func js(_ text: String) -> StudioJSON { StudioJSON(text: text)! }
        // The vivaa case (BUG-080): `status` is not declared with its values, so only the code knows them.
        var env = StudioEnvironmentSpec()
        env.entities = [
            StudioEntity(name: "bundles", fields: [StudioField(name: "name", type: "string", required: true), StudioField(name: "status", type: "string")]),
            StudioEntity(name: "orders", fields: [StudioField(name: "bundleId", type: "integer", required: true, references: "bundles"),
                                                  StudioField(name: "state", type: "string", enumValues: ["open", "paid"]),
                                                  StudioField(name: "total", type: "number")]),
            StudioEntity(name: "users", fields: [StudioField(name: "name", type: "string")]),
        ]
        env.seed = [
            "bundles": (1...6).map { js(#"{"id":\#($0),"name":"Bundle \#($0)","status":"draft"}"#) },
            "orders": [js(#"{"id":10,"bundleId":1,"state":"open","total":12.5}"#), js(#"{"id":11,"bundleId":2,"state":"paid","total":3}"#)],
            "users": [js(#"{"id":"u1","name":"Ann","token":"secret-token-value"}"#)],
        ]
        let redactor = StudioRedactor()

        // AC1: which page errors are offered.
        let thrown = "Uncaught TypeError: Cannot read properties of undefined (reading 'label') (http://localhost:3000/_next/static/chunks/app.js:12:34)\n    at Bundle (app.js:12:34)"
        let logged = "console.error: TypeError: Cannot read properties of undefined (reading 'label')\n    at Bundle (webpack-internal:///./app/bundle.tsx:9:5)"
        check("REQ-017 an uncaught error is offered", StudioDataFix.isFixable(kind: .runtimeError, detail: thrown))
        check("REQ-017 an Error the application logged is offered", StudioDataFix.isFixable(kind: .logged, detail: logged))
        check("REQ-017 a build error is not data, so it is not offered", !StudioDataFix.isFixable(kind: .buildError, detail: "Failed to compile"))
        check("REQ-017 routes, idle, blocked resources, browser notes and stand-ins are not offered",
              [StudioBridge.Event.Kind.route, .idle, .blocked, .browser, .standIn, .unsupported, .electron, .recorded].allSatisfy { !StudioDataFix.isFixable(kind: $0, detail: "x") })
        check("REQ-017 an empty error is not offered", !StudioDataFix.isFixable(kind: .runtimeError, detail: "  \n"))
        check("REQ-017 a module that failed to load is not data, so it is not offered",
              ["TypeError: Importing a module script failed.\nimportUpdatedModule@http://localhost:5173/@vite/client:1015:30",
               "TypeError: Failed to fetch dynamically imported module: http://localhost:3000/assets/Page-1a2b.js",
               "ChunkLoadError: Loading chunk 42 failed.", "Error: Loading chunk app failed. (error: /static/js/app.js)",
               "console.error: [vite] Failed to reload /src/pages/Settings.tsx. This could be due to syntax errors"]
                  .allSatisfy { !StudioDataFix.isFixable(kind: .runtimeError, detail: $0) && !StudioDataFix.isFixable(kind: .logged, detail: $0) })
        check("REQ-017 an error that only mentions loading is still offered",
              StudioDataFix.isFixable(kind: .runtimeError, detail: "TypeError: Cannot read properties of undefined (reading 'name') while loading the page"))
        let hidden = "Script error. WebKit hides the message and stack of this error: it was thrown by a script of another origin or one without an address."
        check("REQ-017 a crash WebKit hid with nothing logged beside it is not offered",
              !StudioDataFix.isFixable(kind: .runtimeError, detail: hidden + " The application logged no Error object with it."))
        check("REQ-017 a hidden crash with the application's logged Error is offered",
              StudioDataFix.isFixable(kind: .runtimeError, detail: hidden + "\nThe application logged just then:\nTypeError: x is not a function\n    at a (b.js:1:1)"))

        // The identity of an error does not depend on how it was reported or where it was thrown.
        check("REQ-017 the same crash reported as uncaught and as logged is one error", StudioDataFix.key(of: thrown) == StudioDataFix.key(of: logged),
              "\(StudioDataFix.key(of: thrown)) | \(StudioDataFix.key(of: logged))")
        check("REQ-017 the key keeps the message and drops the throw site", StudioDataFix.key(of: thrown) == "TypeError: Cannot read properties of undefined (reading 'label')",
              StudioDataFix.key(of: thrown))
        check("REQ-017 another message is another error", StudioDataFix.key(of: "Uncaught RangeError: x") != StudioDataFix.key(of: thrown))
        check("REQ-017 a hidden crash is identified by the Error the application logged",
              StudioDataFix.key(of: hidden + "\nThe application logged just then:\nTypeError: x is not a function\n    at a (b.js:1:1)") == "TypeError: x is not a function")
        check("REQ-017 an unhandled rejection is identified by its message", StudioDataFix.key(of: "Unhandled rejection: Error: boom\n    at f") == "Error: boom")

        // AC5: offered again only when the fix did not remove the error.
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first: [StudioDataFix.Seen] = [
            .init(kind: .runtimeError, detail: thrown, generation: 3, date: t0),
            .init(kind: .logged, detail: logged, generation: 3, date: t0.addingTimeInterval(1)),
            .init(kind: .buildError, detail: "Failed to compile", generation: 3, date: t0.addingTimeInterval(2)),
            .init(kind: .runtimeError, detail: "Uncaught RangeError: other", generation: 3, date: t0.addingTimeInterval(3)),
            .init(kind: .runtimeError, detail: "Uncaught Error: from an older page", generation: 2, date: t0.addingTimeInterval(-5)),
        ]
        let offered = StudioDataFix.fixable(first, generation: 3)
        check("REQ-017 the current page's errors are listed once each, the latest first",
              offered.map(\.key) == ["RangeError: other", "TypeError: Cannot read properties of undefined (reading 'label')"], "\(offered.map(\.key))")
        check("REQ-017 an error of an earlier page is not offered", !offered.contains { $0.key.contains("older page") })
        check("REQ-017 after a fix the new page has no error, so nothing is offered", StudioDataFix.fixable(first, generation: 4).isEmpty)
        let again = first + [.init(kind: .runtimeError, detail: thrown, generation: 4, date: t0.addingTimeInterval(60))]
        check("REQ-017 an error that comes back after the fix is offered again",
              StudioDataFix.fixable(again, generation: 4).map(\.key) == [StudioDataFix.key(of: thrown)])

        // AC3: the answer.
        let schema = StudioDataFix.schema
        func strictProblems(_ node: Any, at path: String) -> [String] {
            guard let object = node as? [String: Any] else { return [] }
            var found: [String] = []
            if let properties = object["properties"] as? [String: Any] {
                if Set(object["required"] as? [String] ?? []) != Set(properties.keys) { found.append(path + ": not every property is required") }
                if object["additionalProperties"] as? Bool != false { found.append(path + ": additionalProperties is not false") }
                for (key, value) in properties { found += strictProblems(value, at: path + "." + key) }
            }
            if let items = object["items"] { found += strictProblems(items, at: path + "[]") }
            return found
        }
        check("REQ-017 the answer schema is strict: every property is required, also in a correction", strictProblems(schema, at: "fix").isEmpty,
              strictProblems(schema, at: "fix").joined(separator: "; "))
        func answer(kind: String = "data", summary: String = "The code switches on the status.", pointer: String = "", changes: [[String: Any]]) -> [String: Any] {
            ["kind": kind, "summary": summary, "codePointer": pointer, "changes": changes]
        }
        func entry(_ entity: String, _ id: String, _ field: String, _ value: String, _ reason: String = "app/bundle.tsx:9 reads STATUS[status]") -> [String: Any] {
            ["entity": entity, "id": id, "field": field, "valueJSON": value, "reason": reason]
        }
        let plan = StudioDataFix.plan(from: answer(changes: [entry("bundles", "1", "status", #""editable""#), entry("orders", "10", "total", "12")]))
        check("REQ-017 a data answer is read with its corrections", plan?.kind == .data && plan?.changes.count == 2
              && plan?.changes.first?.value == .string("editable") && plan?.changes.last?.value == .number(12) && plan?.changes.first?.reason.isEmpty == false)
        let notData = StudioDataFix.plan(from: answer(kind: "not_data", summary: "A missing import.", pointer: "app/page.tsx:4", changes: []))
        check("REQ-017 a not-data answer points at the code", notData?.kind == .notData && notData?.codePointer == "app/page.tsx:4" && notData?.changes.isEmpty == true)
        let empty = StudioDataFix.plan(from: answer(summary: "", changes: []))
        check("REQ-017 a data answer without a correction is a not-data answer", empty?.kind == .notData && empty?.summary.isEmpty == false)
        let broken = StudioDataFix.plan(from: answer(changes: [entry("bundles", "1", "status", "not json {")]))
        check("REQ-017 a correction whose value is not JSON is reported, not dropped silently", broken?.kind == .data && broken?.unreadable.count == 1 && broken?.changes.isEmpty == true,
              "\(String(describing: broken))")
        check("REQ-017 an answer of another shape is not read", StudioDataFix.plan(from: ["kind": "maybe"]) == nil && StudioDataFix.plan(from: nil) == nil
              && StudioDataFix.plan(from: "text") == nil)

        // AC4: corrections are applied to a copy and checked like a prepared record.
        func change(_ entity: String, _ id: String, _ field: String, _ value: StudioJSON, _ reason: String = "reads STATUS[status]") -> StudioDataFix.Change {
            .init(entity: entity, id: id, field: field, value: value, reason: reason)
        }
        let sixFixes = (1...6).map { change("bundles", "\($0)", "status", .string("editable")) }
        let fixed = StudioDataFix.apply(sixFixes, spec: env, scenarioData: nil, redactor: redactor)
        check("REQ-017 six records of the seed are corrected", fixed.ok && fixed.applied.count == 6 && fixed.seed["bundles"]?.allSatisfy { $0["status"] == .string("editable") } == true,
              fixed.problems.joined(separator: "; "))
        check("REQ-017 the environment given is not changed by a check", env.seed["bundles"]?.first?["status"] == .string("draft"))
        check("REQ-017 the other records and fields stay as they were", fixed.seed["orders"] == env.seed["orders"] && fixed.seed["users"] == env.seed["users"]
              && fixed.seed["bundles"]?.first?["name"] == .string("Bundle 1"))
        check("REQ-017 the log line says what changed and how many records", StudioDataFix.summary(fixed.applied) == "Fixed data: bundles.status draft → editable in 6 records",
              StudioDataFix.summary(fixed.applied))
        check("REQ-017 one record is singular", StudioDataFix.summary(Array(fixed.applied.prefix(1))) == "Fixed data: bundles.status draft → editable in 1 record")
        let mixed = StudioDataFix.apply([change("bundles", "1", "status", .string("editable")), change("orders", "10", "total", .number(12), "total is an integer there")],
                                        spec: env, scenarioData: nil, redactor: redactor)
        check("REQ-017 two kinds of correction make two groups in the log line", StudioDataFix.summary(mixed.applied) == "Fixed data: bundles.status draft → editable in 1 record; orders.total 12.5 → 12 in 1 record",
              StudioDataFix.summary(mixed.applied))
        check("REQ-017 reasons are logged once each", StudioDataFix.reasons(fixed.applied) == ["Reason: reads STATUS[status]"] && StudioDataFix.reasons(mixed.applied).count == 2)

        // A scenario with its own records is corrected too, and the seed where the record is in both.
        var own = env.seed
        own["bundles"] = [js(#"{"id":1,"name":"Mine","status":"draft"}"#), js(#"{"id":99,"name":"Only mine","status":"draft"}"#)]
        let both = StudioDataFix.apply([change("bundles", "1", "status", .string("editable")), change("bundles", "99", "status", .string("editable"))],
                                       spec: env, scenarioData: own, redactor: redactor)
        check("REQ-017 a record of the scenario and of the seed is corrected in both", both.ok && both.scenarioData?["bundles"]?.first?["status"] == .string("editable")
              && both.seed["bundles"]?.first?["status"] == .string("editable") && both.applied.first?.inSeed == true && both.applied.first?.inScenario == true,
              both.problems.joined(separator: "; "))
        check("REQ-017 a record only the scenario has is corrected there alone", both.scenarioData?["bundles"]?.last?["status"] == .string("editable")
              && both.applied.last?.inSeed == false && both.applied.last?.inScenario == true && both.seed["bundles"]?.count == 6)
        check("REQ-017 the seed's other records are untouched when the scenario has its own", both.seed["bundles"]?.dropFirst().allSatisfy { $0["status"] == .string("draft") } == true)

        // The guards: each refused correction stops the whole fix.
        func refused(_ name: String, _ changes: [StudioDataFix.Change], _ expected: String, scenarioData: [String: [StudioJSON]]? = nil) {
            let outcome = StudioDataFix.apply(changes, spec: env, scenarioData: scenarioData, redactor: redactor)
            check("REQ-017 refused: " + name, !outcome.ok && outcome.problems.contains { $0.contains(expected) }, outcome.problems.joined(separator: "; "))
        }
        refused("an unknown entity", [change("invoices", "1", "status", .string("x"))], "not an entity of the environment")
        refused("an unknown record", [change("bundles", "404", "status", .string("x"))], "no bundles record with the id 404")
        refused("an id change", [change("bundles", "1", "id", .number(7))], "the id of a record cannot change")
        refused("a confidential field", [change("users", "u1", "token", .string("x"))], "confidential")
        refused("a change that changes nothing", [change("bundles", "1", "status", .string("draft"))], "changes nothing")
        refused("a value outside a declared enumeration", [change("orders", "10", "state", .string("refunded"))], "must be one of open, paid")
        refused("a value of the wrong type", [change("orders", "10", "total", .string("12"))], "must be number")
        refused("a reference to a record that does not exist", [change("orders", "10", "bundleId", .number(77))], "points at bundles 77")
        refused("a field name that is a path", [change("bundles", "1", "a.b", .string("x"))], "not a plain field name")
        refused("two values for one field", [change("bundles", "1", "status", .string("a")), change("bundles", "1", "status", .string("b"))], "corrected twice")
        refused("a copied shortened list", [change("bundles", "1", "tags", js(#"["a","… 4 more like these"]"#))], "shortened list")
        refused("nothing to apply", [], "no correction to apply")
        refused("too many corrections", (0...StudioDataFix.maxChanges).map { _ in change("bundles", "1", "status", .string("x")) }, "Too many corrections")
        refused("a value that is too large", [change("bundles", "1", "status", .string(String(repeating: "x", count: StudioDataFix.maxValueSize + 10)))], "too large")
        check("REQ-017 a refused fix still leaves the copies unchanged for the caller to drop",
              StudioDataFix.apply([change("bundles", "1", "status", .string("editable")), change("bundles", "404", "status", .string("x"))],
                                  spec: env, scenarioData: nil, redactor: redactor).ok == false && env.seed["bundles"]?.first?["status"] == .string("draft"))
        // A record that already had a problem is not blamed for it: only what the correction adds counts.
        var withOld = env
        withOld.seed["orders"] = [js(#"{"id":10,"bundleId":1,"state":"legacy","total":12.5}"#)]
        let neighbour = StudioDataFix.apply([change("orders", "10", "total", .number(13))], spec: withOld, scenarioData: nil, redactor: redactor)
        check("REQ-017 a problem the record already had does not stop a correction of another field", neighbour.ok, neighbour.problems.joined(separator: "; "))
        check("REQ-017 a field the entity does not declare can be corrected", StudioDataFix.apply([change("bundles", "1", "badge", js(#"{"label":"New"}"#))],
                                                                                                  spec: env, scenarioData: nil, redactor: redactor).ok)
        check("REQ-017 a number written as a string id is found", StudioDataFix.apply([change("bundles", "3", "status", .string("editable"))], spec: env,
                                                                                      scenarioData: nil, redactor: redactor).ok)

        // AC2: what the assistant is given.
        var scenario = StudioScenario(id: "custom-many", name: "Many bundles", kind: .custom)
        let served = [
            StudioDataFix.Served(ruleId: "list-bundles", method: "GET", path: "/api/bundles", operation: "list", entities: ["bundles"], status: 200,
                                 body: #"{"items":[{"id":1,"status":"draft"}]}"#),
            StudioDataFix.Served(ruleId: "list-orders", method: "GET", path: "/api/orders", operation: "list", entities: ["orders"], status: 200, body: ""),
        ]
        let secretError = "Uncaught TypeError: bad\n    at f (a.js:1:1)\nAuthorization: Bearer abcdefghijklmnop1234567890"
        let page = pageError(secretError)
        var request = StudioDataFix.prompt(error: page, route: "/bundles/1", served: served, spec: env, records: env.seed, scenario: scenario,
                                           redactor: redactor, hashes: [:])
        check("REQ-017 the prompt has the error with its stack and the route", request.contains("TypeError: bad") && request.contains("at f (a.js:1:1)") && request.contains("Route: /bundles/1"))
        check("REQ-017 the prompt has what the page was answered with", request.contains("GET /api/bundles (rule list-bundles, list) → 200") && request.contains(#"{"items":[{"id":1,"status":"draft"}]}"#))
        check("REQ-017 the prompt has the entities and their records", request.contains("- bundles (id field id, 6 records): name:string!, status:string")
              && request.contains(#""name":"Bundle 6""#) && request.contains("orders (id field id, 2 records)") && request.contains("bundleId:integer!→bundles")
              && request.contains("state:string(open|paid)"))
        check("REQ-017 the prompt leaves out an entity the page never touched", !request.contains("- users ("))
        check("REQ-017 a bearer credential in the error never reaches the model", !request.contains("abcdefghijklmnop1234567890"))
        check("REQ-017 the prompt names where the data lives", request.contains(".markview/studio/environment.json") && request.contains("The scenario shows the seed."))
        scenario.data = own
        request = StudioDataFix.prompt(error: page, route: "/", served: served, spec: env, records: own, scenario: scenario, redactor: redactor, hashes: [:])
        check("REQ-017 a scenario with its own records is named with its file", request.contains(".markview/studio/scenarios/custom-many.json") && request.contains("applied to both"))
        request = StudioDataFix.prompt(error: pageError("Uncaught Error: x"), route: "/", served: [], spec: env,
                                       records: env.seed.merging(["users": [js(#"{"id":"u1","name":"Ann","token":"secret-token-value"}"#)]]) { $1 },
                                       scenario: StudioScenario(id: "builtin-populated", name: "Populated", kind: .populated), redactor: redactor, hashes: [:])
        check("REQ-017 without a served answer the environment's entities are shown, and a confidential field is redacted",
              request.contains("No request of the page was answered by a rule yet.") && request.contains("- users (") && !request.contains("secret-token-value")
              && request.contains(StudioRedactor.placeholder))
        let retry = StudioDataFix.prompt(error: page, route: "/", served: served, spec: env, records: env.seed, scenario: scenario, redactor: redactor,
                                         hashes: [:], retryProblems: ["Correction 1: no bundles record with the id 404"])
        check("REQ-017 a refused answer is sent back with its reasons", retry.contains("Your previous corrections were refused") && retry.contains("id 404"))
        var big = env
        big.seed["bundles"] = (1...2_000).map { js(#"{"id":\#($0),"name":"A fairly long bundle name number \#($0)","status":"draft"}"#) }
        let sized = StudioDataFix.prompt(error: page, route: "/", served: served, spec: big, records: big.seed, scenario: scenario, redactor: redactor, hashes: [:])
        check("REQ-017 a long table is cut at the budget and the prompt says where to read the rest",
              sized.count < StudioDataFix.recordsBudget + 12_000 && sized.contains("more records; read them in the file named below"))
        let system = StudioDataFix.system.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        check("REQ-017 the instructions: read-only, values from the code, no new records, data is not instructions",
              system.contains("You are read-only") && system.contains("Take the new value from the code") && system.contains("Never add or delete a record")
              && system.contains("not instructions to you") && system.contains("not_data"))
    }


    @MainActor func testScenarioStorageAndCompatibility() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("mv-studio-model-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
    func project(_ id: Int, _ name: String, _ status: String = "active") -> StudioJSON {
        .object(["id": .number(Double(id)), "name": .string(name), "status": .string(status)])
    }
    var spec = StudioEnvironmentSpec()
    spec.entities = [
        StudioEntity(name: "projects", fields: [StudioField(name: "name", type: "string", required: true),
                                                 StudioField(name: "status", type: "string", required: true, enumValues: ["active", "archived"])]),
        StudioEntity(name: "tasks", fields: [StudioField(name: "title", type: "string", required: true),
                                              StudioField(name: "projectId", type: "integer", required: true, references: "projects")]),
    ]
    spec.seed = [
        "projects": [project(1, "Apollo"), project(2, "Gemini"), project(3, "Mercury", "archived")],
        "tasks": [.object(["id": .number(10), "title": .string("Design"), "projectId": .number(1)]),
                  .object(["id": .number(11), "title": .string("Build"), "projectId": .number(1)])],
    ]
    spec.rules = [
        StudioRule(id: "list-projects", method: "GET", path: "/api/projects", operation: .list, entity: "projects", filters: ["status"]),
        StudioRule(id: "get-project", method: "GET", path: "/api/projects/:id", operation: .get, entity: "projects",
                   include: [StudioInclude(field: "tasks", entity: "tasks", foreignKey: "projectId")]),
        StudioRule(id: "create-project", method: "POST", path: "/api/projects", operation: .create, entity: "projects"),
        StudioRule(id: "rename-project", method: "PATCH", path: "/api/projects/:id", operation: .update, entity: "projects"),
        StudioRule(id: "delete-project", method: "DELETE", path: "/api/projects/:id", operation: .delete, entity: "projects"),
        StudioRule(id: "me", method: "GET", path: "/api/me", operation: .session),
    ]
        let base = StudioScenario(id: "populated", name: "Populated", kind: .populated)
        let root = tmp.appendingPathComponent("store")
        var scenario = StudioScenario(id: "Long names!", name: "Long names", kind: .custom, route: "/projects")
        scenario.data = ["projects": [project(1, String(repeating: "Very long project name ", count: 4))]]
        scenario.steps = [StudioStep(action: .click, selector: "li.project:nth-of-type(1) > a")]
        scenario.contractFingerprint = StudioScenarioCompatibility.fingerprint(scenario, spec: spec)
        scenario.updated = Date(timeIntervalSince1970: 1_780_000_000) // ISO 8601 in the file keeps whole seconds
        try! StudioStore.saveScenario(scenario, root: root)
        let loaded = StudioStore.loadScenarios(root)
        check("scenarios are saved as reusable configuration", loaded.count == 1 && loaded[0] == scenario
              && fm.fileExists(atPath: root.appendingPathComponent(".markview/studio/scenarios/long-names.json").path))
        check("a saved scenario is compatible with its contracts", StudioScenarioCompatibility.problems(scenario, spec: spec).isEmpty)
        var changed = spec
        changed.entities[0].fields.append(StudioField(name: "owner", type: "string", required: true))
        let problems = StudioScenarioCompatibility.problems(scenario, spec: changed)
        check("SCN-04 a changed contract marks the scenario incompatible", problems.contains { $0.contains("contracts") } && problems.contains { $0.contains("owner is required") }, problems.joined(separator: "; "))
        let (updated, notes) = StudioScenarioCompatibility.updated(scenario, spec: changed)
        check("SCN-04 an explicit update fills the new field and bumps the revision", updated.revision == 2 && notes.contains { $0.contains("owner") }
              && StudioScenarioCompatibility.problems(updated, spec: changed).isEmpty)
        check("the baseline is not changed by the check itself", scenario.revision == 1 && scenario.data?["projects"]?.first?["owner"] == nil)
        let presets = StudioScenarioCompatibility.presets(spec: spec, base: base)
        check("built-in populated, empty, loading and error states", presets.map(\.kind) == [.populated, .empty, .loading, .error])
        StudioStore.prepareLocalFolder(root)
        check("session data folder ignores itself in Git", (try? String(contentsOf: root.appendingPathComponent(".dde/studio/.gitignore"), encoding: .utf8))?.contains("*") == true)
        try! StudioStore.saveEnvironment(spec, root: root)
        check("environment round trip", StudioStore.loadEnvironment(root)?.rules == spec.rules && StudioStore.loadEnvironment(root)?.seed == spec.seed)

        // Team-owned files that cannot be read, or that a newer MarkView wrote, are never replaced unseen (AR-36).
        let scenarioFile = root.appendingPathComponent(".markview/studio/scenarios/long-names.json")
        let cut = Data("{ \"id\": \"Long names!\", ".utf8)
        try! cut.write(to: scenarioFile)
        check("damaged scenario: it is left out of the list and left as it is",
              StudioStore.loadScenarios(root).isEmpty && StoreFixture.bytes(scenarioFile) == cut)
        try! StudioStore.saveScenario(scenario, root: root)
        check("damaged scenario: a save keeps the old bytes in a dated backup",
              StoreFixture.backups(of: scenarioFile).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: scenarioFile)[0]) == cut
              && StudioStore.loadScenarios(root) == [scenario])
        try! StudioStore.saveScenario(scenario, root: root)
        check("a scenario that reads makes no further backup", StoreFixture.backups(of: scenarioFile).count == 1)

        let environmentFile = StudioStore.environmentURL(root)
        var future = spec
        future.schemaVersion = StudioEnvironmentSpec.currentSchemaVersion + 1
        try! StudioStore.save(future, to: environmentFile)
        let futureBytes = StoreFixture.bytes(environmentFile)
        var refused = false
        do { try StudioStore.saveEnvironment(spec, root: root) } catch is PlainJSONFile.NewerVersion { refused = true } catch {}
        check("newer environment: it is not read as the current one", StudioStore.loadEnvironment(root) == nil)
        check("newer environment: a save is refused and the file stays as it is",
              refused && StoreFixture.bytes(environmentFile) == futureBytes && StoreFixture.backups(of: environmentFile).isEmpty)
        let halfEnvironment = Data(#"{"schemaVersion":1,"entities":["#.utf8)
        try! halfEnvironment.write(to: environmentFile)
        check("damaged environment: it reads as none and is left as it is",
              StudioStore.loadEnvironment(root) == nil && StoreFixture.bytes(environmentFile) == halfEnvironment)
        try! StudioStore.saveEnvironment(spec, root: root)
        check("damaged environment: a save keeps the old bytes in a dated backup and replaces it",
              StoreFixture.backups(of: environmentFile).count == 1 && StoreFixture.bytes(StoreFixture.backups(of: environmentFile)[0]) == halfEnvironment
              && StudioStore.loadEnvironment(root)?.rules == spec.rules)

        var book = StudioScreenBook()
        book.version = StudioScreenBook.currentVersion + 1
        let bookFile = StudioStore.screensURL(root, appFolder: "")
        try! StudioStore.save(book, to: bookFile, version: nil)
        let bookBytes = StoreFixture.bytes(bookFile)
        refused = false
        do { try StudioStore.saveScreenBook(StudioScreenBook(), root: root) } catch is PlainJSONFile.NewerVersion { refused = true } catch {}
        check("newer screen book: it is not read, a save is refused and the file stays as it is",
              StudioStore.loadScreenBook(root, appFolder: "") == nil && refused && StoreFixture.bytes(bookFile) == bookBytes)
    }

    @MainActor func testContextPlanningModel() {
    func project(_ id: Int, _ name: String, _ status: String = "active") -> StudioJSON {
        .object(["id": .number(Double(id)), "name": .string(name), "status": .string(status)])
    }
    var spec = StudioEnvironmentSpec()
    spec.entities = [
        StudioEntity(name: "projects", fields: [StudioField(name: "name", type: "string", required: true),
                                                 StudioField(name: "status", type: "string", required: true, enumValues: ["active", "archived"])]),
        StudioEntity(name: "tasks", fields: [StudioField(name: "title", type: "string", required: true),
                                              StudioField(name: "projectId", type: "integer", required: true, references: "projects")]),
    ]
    spec.seed = [
        "projects": [project(1, "Apollo"), project(2, "Gemini"), project(3, "Mercury", "archived")],
        "tasks": [.object(["id": .number(10), "title": .string("Design"), "projectId": .number(1)]),
                  .object(["id": .number(11), "title": .string("Build"), "projectId": .number(1)])],
    ]
    spec.rules = [
        StudioRule(id: "list-projects", method: "GET", path: "/api/projects", operation: .list, entity: "projects", filters: ["status"]),
        StudioRule(id: "get-project", method: "GET", path: "/api/projects/:id", operation: .get, entity: "projects",
                   include: [StudioInclude(field: "tasks", entity: "tasks", foreignKey: "projectId")]),
        StudioRule(id: "create-project", method: "POST", path: "/api/projects", operation: .create, entity: "projects"),
        StudioRule(id: "rename-project", method: "PATCH", path: "/api/projects/:id", operation: .update, entity: "projects"),
        StudioRule(id: "delete-project", method: "DELETE", path: "/api/projects/:id", operation: .delete, entity: "projects"),
        StudioRule(id: "me", method: "GET", path: "/api/me", operation: .session),
    ]
        let redactor = StudioRedactor()
    func contextObject(name: String = "", data: String = "", addData: String = "", userJSON: String = "", route: String = "",
                       overrides: [[String: Any]] = [], steps: [[String: Any]] = [], testTime: String = "", locale: String = "",
                       timeZone: String = "", theme: String = "", unsupported: [String] = []) -> [String: Any] {
        ["name": name, "description": "", "route": route, "data": data, "addData": addData, "userJSON": userJSON, "overrides": overrides,
         "steps": steps, "testTime": testTime, "locale": locale, "timeZone": timeZone, "theme": theme, "unsupported": unsupported]
    }

    func overrideObject(ruleId: String = "", method: String = "", path: String = "", status: Int = 0, body: String = "",
                        empty: Bool = false, hang: Bool = false, delayMs: Int = 0) -> [String: Any] {
        ["ruleId": ruleId, "method": method, "path": path, "status": status, "body": body, "empty": empty, "hang": hang, "delayMs": delayMs]
    }

    func stepObject(_ action: String, _ selector: String = "", text: String = "", ms: Int = 0) -> [String: Any] {
        ["action": action, "selector": selector, "text": text, "ms": ms]
    }

    /// The whole answer of the request call, as the schema requires it.
    func planObject(kind: String, answer: String = "", context: [String: Any]? = nil, edits: [[String: Any]] = []) -> [String: Any] {
        ["kind": kind, "answer": answer, "scope": "unknown", "scopeNote": "", "needsClarification": false, "question": "", "options": [],
         "summary": "", "edits": edits, "context": context ?? contextObject()]
    }
        // The populated scenario, in whole seconds as the stored files keep dates.
        var base = StudioScenario(id: "populated", name: "Populated", kind: .populated)
        base.updated = Date(timeIntervalSince1970: 1_790_000_000)
        // DEC-010: the kind is in the same structured answer; an older answer without one is read from what it has.
        let answered = StudioPrompts.editPlan(from: planObject(kind: "answer", answer: " It posts to /api/projects. "))
        check("DEC-010 an answer is read as an answer, with no context", answered?.kind == .answer
              && answered?.answer == "It posts to /api/projects." && answered?.context == nil && answered?.edits.isEmpty == true)
        let older = StudioPrompts.editPlan(from: ["scope": "instance", "summary": "x", "edits": [["path": "a.css", "search": "a", "replace": "b"]]])
        check("DEC-010 an answer without a kind and with edits is a code change", older?.kind == .code && older?.edits.count == 1)
        check("DEC-010 an answer without a kind and with only an answer text is an answer", StudioPrompts.editPlan(from: ["answer": "Because."])?.kind == .answer)
        check("DEC-010 the schema's kinds are answer, context and code",
              ((StudioPrompts.editSchema["properties"] as? [String: Any])?["kind"] as? [String: Any])?["enum"] as? [String] == ["answer", "context", "code"])
        let system = StudioPrompts.editSystem.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        check("DEC-010 a data request is always a context change, never a pointer to another button",
              system.contains("Every request to see, add, fill or show data is a context change") && system.contains("never send the person to another button")
              && system.contains("never say that data cannot be changed"))
        check("DEC-010 the clarification stays for ambiguous code changes", system.contains("`needsClarification`"))

        // Strict structured output (Codex): every object lists all of its properties as required.
        func strictProblems(_ schema: Any, at path: String) -> [String] {
            guard let object = schema as? [String: Any] else { return [] }
            var problems: [String] = []
            if let properties = object["properties"] as? [String: Any] {
                let required = Set(object["required"] as? [String] ?? [])
                if required != Set(properties.keys) { problems.append(path + ": required " + required.sorted().joined(separator: ",")) }
                for (key, value) in properties { problems += strictProblems(value, at: path + "." + key) }
            }
            if let items = object["items"] { problems += strictProblems(items, at: path + "[]") }
            return problems
        }
        let strict = strictProblems(StudioPrompts.editSchema, at: "plan")
        check("REQ-013 the request schema is strict: every property is required, also in context, overrides and steps", strict.isEmpty, strict.joined(separator: "; "))
        let contextProperties = ((StudioPrompts.editSchema["properties"] as? [String: Any])?["context"] as? [String: Any])?["properties"] as? [String: Any]
        check("REQ-013 records, the user and bodies travel as JSON text", (contextProperties?["data"] as? [String: Any])?["type"] as? String == "string"
              && (contextProperties?["addData"] as? [String: Any])?["type"] as? String == "string"
              && (contextProperties?["userJSON"] as? [String: Any])?["type"] as? String == "string")

        // Reading a context plan.
        let raw = contextObject(name: "Many projects",
                                data: #"{"projects":[{"id":1,"name":"Apollo","status":"active"},{"id":4,"name":"Vega","status":"archived"}]}"#,
                                overrides: [overrideObject(ruleId: "list-projects", delayMs: 1500)],
                                steps: [stepObject("click", "#add"), stepObject("type", "input[name=title]", text: " New task ")],
                                testTime: "2026-03-01T09:30:00Z", locale: "de-DE", timeZone: "Europe/Berlin", theme: "dark",
                                unsupported: ["A chart nothing serves", ""])
        let contextPlan = StudioPrompts.editPlan(from: planObject(kind: "context", context: raw))
        let plan = contextPlan?.context ?? StudioContextPlan()
        check("REQ-013 a context answer is read as a context plan", contextPlan?.kind == .context && plan.parseProblems.isEmpty
              && plan.data?["projects"]?.count == 2 && plan.addedData == nil && plan.user == nil, "\(plan.parseProblems)")
        check("REQ-013 overrides and steps are read; zero and empty mean not given", plan.overrides.count == 1 && plan.overrides[0].ruleId == "list-projects"
              && plan.overrides[0].delayMs == 1500 && plan.overrides[0].status == nil && plan.overrides[0].empty == nil && plan.overrides[0].method == nil
              && plan.steps.count == 2 && plan.steps[0].selector == "#add" && plan.steps[0].text == nil && plan.steps[1].text == " New task ")
        check("REQ-013 clock, locale, time zone, theme and notes are read", plan.testTime == ISO8601DateFormatter().date(from: "2026-03-01T09:30:00Z")
              && plan.locale == "de-DE" && plan.timeZone == "Europe/Berlin" && plan.theme == .dark && plan.unsupported == ["A chart nothing serves"])
        let broken = StudioContextPlan(structured: contextObject(data: "not json", userJSON: "[1]", overrides: [overrideObject(ruleId: "me", status: 200, body: "{oops")],
                                                                 steps: [stepObject("hover", "#a")], testTime: "next tuesday", theme: "sepia"))
        let brokenText = broken.parseProblems.joined(separator: " | ")
        check("REQ-013 what cannot be read is a problem, not a guess", broken.parseProblems.count == 6 && brokenText.contains("`data`")
              && brokenText.contains("`userJSON`") && brokenText.contains("`body`") && brokenText.contains("hover") && brokenText.contains("`testTime`")
              && brokenText.contains("`theme`"), brokenText)
        check("REQ-013 an answer without a context object is a problem", StudioContextPlan(structured: nil).parseProblems.count == 1)

        // Checks against the environment and the current scenario.
        func problems(_ object: [String: Any]) -> [String] {
            StudioContextValidator.problems(StudioContextPlan(structured: object), current: base, spec: spec)
        }
        check("REQ-013 a valid plan passes", StudioContextValidator.problems(plan, current: base, spec: spec).isEmpty,
              StudioContextValidator.problems(plan, current: base, spec: spec).joined(separator: " | "))
        let unknown = problems(contextObject(data: #"{"users":[{"id":1}]}"#))
        check("REQ-013 records of an unknown entity are refused, naming the known ones", unknown.count == 1 && unknown[0].contains("unknown entity users")
              && unknown[0].contains("projects, tasks"), unknown.joined(separator: " | "))
        let invalid = problems(contextObject(data: #"{"projects":[{"id":5,"name":"X","status":"paused"},{"id":6,"name":7,"status":"active"},{"name":"No id","status":"active"}]}"#))
        check("REQ-013 records are checked like any record: enumerations, types and ids", invalid.count >= 3
              && invalid.contains { $0.contains("must be one of") } && invalid.contains { $0.contains("must be string") }
              && invalid.contains { $0.contains("needs a string or integer id") }, invalid.joined(separator: " | "))
        let twice = problems(contextObject(addData: #"{"projects":[{"id":1,"name":"Again","status":"active"}]}"#))
        check("REQ-013 an added record cannot reuse an id", twice.contains { $0.contains("id 1 is used twice") }, twice.joined(separator: " | "))
        let dangling = problems(contextObject(data: #"{"projects":[{"id":9,"name":"Only","status":"active"}]}"#))
        check("REQ-013 kept records may not be left pointing at replaced ones", dangling.count == 2
              && dangling.allSatisfy { $0.contains("points at projects 1") }, dangling.joined(separator: " | "))
        let addedTask = problems(contextObject(addData: #"{"tasks":[{"id":12,"title":"Ship","projectId":2},{"id":13,"title":"Lost","projectId":99}]}"#))
        check("REQ-013 an added record's references are checked", addedTask.count == 1 && addedTask[0].contains("projects 99"), addedTask.joined(separator: " | "))
        let rules = problems(contextObject(overrides: [overrideObject(ruleId: "nope", status: 500), overrideObject(method: "get", path: "/api/projects", status: 500),
                                                       overrideObject(ruleId: "list-projects", empty: true), overrideObject(ruleId: "me"),
                                                       overrideObject(ruleId: "get-project", body: #"{"error":"x"}"#), overrideObject(ruleId: "delete-project", status: 999)]))
        check("REQ-013 overrides name rules that exist, once, and change something", rules.count == 5
              && rules[0].contains("nope, which does not exist") && rules[0].contains("list-projects")
              && rules.contains { $0.contains("list-projects has two overrides") } && rules.contains { $0.contains("changes nothing") }
              && rules.contains { $0.contains("a body needs a status") } && rules.contains { $0.contains("999 is not an HTTP status") }, rules.joined(separator: " | "))
        let steps = problems(contextObject(steps: [stepObject("click"), stepObject("wait", ms: 0), stepObject("navigate", text: "https://evil.example/"),
                                                   stepObject("press", "input", text: "Enter"), stepObject("wait", ms: 500), stepObject("navigate", text: "/projects/2")]))
        check("REQ-013 steps are checked before they are replayed", steps.count == 3 && steps[0].contains("Step 1 (click)")
              && steps[1].contains("Step 2 (wait)") && steps[2].contains("Step 3 (navigate)"), steps.joined(separator: " | "))
        var invalidDestination = contextObject()
        invalidDestination["expectedPath"] = "https://example.invalid/"
        invalidDestination["expectedSelector"] = "main\nheader"
        let destinationProblems = problems(invalidDestination)
        check("destination expectations reject external paths and multiline selectors", destinationProblems.count == 2,
              destinationProblems.joined(separator: " | "))
        var validDestination = contextObject()
        validDestination["expectedPath"] = "/account"
        validDestination["expectedSelector"] = "main h1"
        let destinationPlan = StudioContextPlan(structured: validDestination)
        let destinationScenario = StudioContextValidator.scenario(destinationPlan, from: base, spec: spec, request: "Open account", taken: [])
        check("destination expectations are saved in the scenario", destinationScenario.expectedPath == "/account"
              && destinationScenario.expectedSelector == "main h1")
        check("the assistant is told how to use the simulated sign-in", system.contains("Setting `userJSON` alone does not create a browser session")
              && system.contains("actually sign in with restoration steps") && system.contains("do not override its auth requests"))
        let place = problems(contextObject(route: "projects list", locale: "??", timeZone: "Mars/Olympus"))
        check("REQ-013 the route, locale and time zone are checked", place.count == 3, place.joined(separator: " | "))

        // The new scenario derived from the current one.
        let taken = [base, StudioScenario(id: "many-projects", name: "Many projects")]
        let request = "Show many projects, with a slow list"
        let next = StudioContextValidator.scenario(plan, from: base, spec: spec, request: request, taken: taken, now: Date(timeIntervalSince1970: 1_800_000_000))
        check("REQ-013 the new scenario has a name and id of its own, the request as description, and kind custom",
              next.name == "Many projects 2" && next.id == StudioStore.safeID("Many projects 2") && next.id != base.id && next.kind == .custom
              && next.description == request && next.revision == 1, "\(next.name) \(next.id)")
        check("REQ-013 only the named entities' records are replaced", next.data?["projects"]?.count == 2 && next.data?["tasks"] == spec.seed["tasks"])
        check("REQ-013 the overrides, steps, clock, locale, time zone and theme come from the plan", next.overrides == plan.overrides
              && next.steps == plan.steps && next.testTime == plan.testTime && next.locale == "de-DE" && next.timeZone == "Europe/Berlin" && next.theme == .dark
              && next.route == base.route && next.viewport == base.viewport)
        check("REQ-013 the new scenario is compatible with the environment", StudioScenarioCompatibility.problems(next, spec: spec).isEmpty
              && !next.contractFingerprint.isEmpty, StudioScenarioCompatibility.problems(next, spec: spec).joined(separator: " | "))
        let change = StudioContextValidator.change(from: base, to: next, spec: spec, unsupported: plan.unsupported)
        check("REQ-013 the change says what changed", change.previous == base && change.previousScenarioName == "Populated"
              && change.scenarioName == "Many projects 2" && change.records == ["projects": 2] && change.recordsBefore == ["projects": 3]
              && change.lines.contains("Records: projects 3 → 2") && change.overrides == ["list-projects: after 1500 ms"]
              && change.steps == ["click #add", "type \" New task \" into input[name=title]"] && change.route == nil
              && change.other.contains("Locale: de-DE") && change.other.contains("Time zone: Europe/Berlin") && change.other.contains("Theme: dark")
              && change.other.contains { $0.hasPrefix("Clock: 2026-03-01") } && change.unsupported == ["A chart nothing serves"], change.lines.joined(separator: " | "))
        let added = StudioContextPlan(structured: contextObject(addData: #"{"projects":[{"id":7,"name":"Orion","status":"active"}]}"#))
        let addedScenario = StudioContextValidator.scenario(added, from: base, spec: spec, request: "Add a project", taken: taken)
        check("REQ-013 added records join the current ones", addedScenario.data?["projects"]?.count == 4
              && addedScenario.data?["projects"]?.last?["name"]?.stringValue == "Orion" && addedScenario.name == "Add a project")
        let nothing = StudioContextValidator.scenario(StudioContextPlan(structured: contextObject()), from: base, spec: spec, request: "Leave it", taken: taken)
        check("REQ-013 a plan that changes nothing makes no change", !StudioContextValidator.change(from: base, to: nothing, spec: spec, unsupported: []).changesAnything)
        // BUG-087: the current scenario's overrides stay in the derived one; the assistant never has to copy a long body.
        var chain = base
        chain.overrides = [StudioOverride(ruleId: "list-projects", status: 200, body: .array([.object(["id": .number(1)])])),
                           StudioOverride(method: "GET", path: "/api/me", status: 200, body: .object(["name": .string("Ann")]))]
        let slow = StudioContextPlan(structured: contextObject(overrides: [overrideObject(ruleId: "list-projects", delayMs: 900)]))
        let afterSlow = StudioContextValidator.scenario(slow, from: chain, spec: spec, request: "Slow list", taken: taken)
        check("BUG-087 an override the plan does not name stays, one it names is replaced whole",
              afterSlow.overrides.count == 2 && afterSlow.overrides.first?.path == "/api/me"
              && afterSlow.overrides.last == StudioOverride(ruleId: "list-projects", delayMs: 900), "\(afterSlow.overrides)")
        let unrelated = StudioContextPlan(structured: contextObject(addData: #"{"projects":[{"id":7,"name":"Orion","status":"active"}]}"#))
        let afterUnrelated = StudioContextValidator.scenario(unrelated, from: chain, spec: spec, request: "Add a project", taken: taken)
        check("BUG-087 a plan with no overrides keeps every current one", afterUnrelated.overrides == chain.overrides)
        let sameRule = StudioContextPlan(structured: contextObject(overrides: [overrideObject(ruleId: "me", status: 200, body: #"{"name":"Bob"}"#)]))
        check("BUG-087 a method and path override and a rule id override of one rule are one override",
              StudioContextValidator.scenario(sameRule, from: chain, spec: spec, request: "Bob", taken: taken).overrides.count == 2)
        var dropPlan = StudioContextPlan(structured: contextObject())
        dropPlan.dropOverrides = ["list-projects", "me"]
        let withoutOverrides = StudioContextValidator.scenario(dropPlan, from: chain, spec: spec, request: "Back to normal", taken: taken)
        check("BUG-087 an override named in dropOverrides is removed, by rule id or by method and path", withoutOverrides.overrides.isEmpty,
              "\(withoutOverrides.overrides)")
        let droppedChange = StudioContextValidator.change(from: chain, to: afterSlow, spec: spec, unsupported: [])
        check("BUG-087 the change lists what was added or replaced, not what stayed", droppedChange.overrides == ["list-projects: after 900 ms"]
              && droppedChange.other.isEmpty, "\(String(describing: droppedChange.overrides)) \(droppedChange.other)")
        check("BUG-087 the change says which overrides were removed", StudioContextValidator.change(from: chain, to: withoutOverrides, spec: spec, unsupported: [])
              .other == ["Override removed: list-projects", "Override removed: me"])
        let parsedDrop = StudioContextPlan(structured: contextObject().merging(["dropOverrides": ["list-projects", ""]]) { $1 })
        check("BUG-087 dropOverrides is read, and is optional", parsedDrop.dropOverrides == ["list-projects"]
              && StudioContextPlan(structured: contextObject()).dropOverrides.isEmpty && parsedDrop.parseProblems.isEmpty)
        check("REQ-013 a new scenario never takes a built-in id", StudioContextValidator.uniqueName("builtin-populated", taken: []).id.hasPrefix("scenario-")
              && StudioContextValidator.uniqueName("", taken: []).name == "Scenario")
        var unserved = spec
        unserved.entities.append(StudioEntity(name: "notes", fields: []))
        let notes = StudioContextValidator.notes(StudioContextPlan(structured: contextObject(data: #"{"notes":[{"id":1}]}"#)), spec: unserved)
        check("REQ-013 records no rule serves are reported as not shown", notes.count == 1 && notes[0].contains("no simulation rule serves"), notes.joined())

        // BUG-084: data a rule answers with a fixed body. The page's chain comes from a rule registered late, after many others.
        let chainBody: StudioJSON = .object([
            "underlying": .string("SPX"), "strikes": .array([5890, 5895, 5900, 5905, 5910].map { .number($0) }),
            "contracts": .array([5890, 5895, 5900].map { .object(["strike": .number($0), "type": .string("call"), "bid": .number(1), "apiKey": .string("k-123")]) })])
        var chainSpec = spec
        chainSpec.rules += (1...65).map { StudioRule(id: "filler-\($0)", method: "GET", path: "/api/filler/\($0)", operation: .respond,
                                                     response: StudioFixedResponse(status: 200, body: .object([:]))) }
        chainSpec.rules.append(StudioRule(id: "fetch-chain", method: "GET", path: "/api/chain", operation: .respond,
                                          response: StudioFixedResponse(status: 200, body: chainBody)))
        let chainBlock = StudioPrompts.contextBlock(spec: chainSpec, scenario: base, redactor: StudioRedactor(), reached: ["fetch-chain", "list-projects", "gone"])
        let chainLines = chainBlock.components(separatedBy: "\n")
        let firstRule = chainLines.firstIndex { $0.hasPrefix("- ") && $0.contains(": GET /api/") }
        check("BUG-084 the rules that answered the page come first, also beyond the listed limit",
              firstRule.map { chainLines[$0].hasPrefix("- fetch-chain: GET /api/chain → respond (answered the page)") } == true
              && firstRule.map { chainLines[$0 + 2].hasPrefix("- list-projects:") } == true && !chainBlock.contains("- gone"), chainBlock)
        check("BUG-084 a fixed answer that answered the page is shown in full, with its secrets redacted",
              chainBlock.contains("Current answer 200, in full: {") && chainBlock.contains("5910") && chainBlock.contains(#""strike":5900"#)
              && !chainBlock.contains(StudioJSON.shortenedNote) && chainBlock.contains("SPX") && !chainBlock.contains("k-123")
              && !chainBlock.contains("filler-1: GET /api/filler/1 → respond (answered"), chainBlock)
        let crowded = StudioPrompts.contextBlock(spec: chainSpec, scenario: base, redactor: StudioRedactor(),
                                                 reached: (1...40).map { "filler-\($0)" } + ["fetch-chain"])
        check("BUG-084 many small answers before it do not crowd out the page's data", crowded.contains("SPX") && crowded.contains("5910"))
        // Only an answer longer than the limit is shortened, and its line says where the whole answer is.
        var hugeSpec = chainSpec
        hugeSpec.rules.append(StudioRule(id: "fetch-huge", method: "GET", path: "/api/huge", operation: .respond,
                                         response: StudioFixedResponse(status: 200, body: .object(["rows": .array((1...2_000).map { .object(["n": .number(Double($0))]) })]))))
        let huge = StudioPrompts.contextBlock(spec: hugeSpec, scenario: base, redactor: StudioRedactor(), reached: ["fetch-huge"])
        check("BUG-084 a very long answer is shortened and says where the whole one is",
              huge.contains("Current answer 200, lists shortened; the whole answer is in .markview/studio/environment.json (rules, id fetch-huge)")
              && huge.contains("… 1997 more like these") && huge.count < 20_000, String(huge.prefix(1_500)))
        var chainScenario = base
        chainScenario.overrides = [StudioOverride(ruleId: "fetch-chain", status: 200, body: .object(["underlying": .string("NDX")]))]
        check("BUG-084 the shown answer is the scenario's current one",
              StudioPrompts.contextBlock(spec: chainSpec, scenario: chainScenario, redactor: StudioRedactor(), reached: ["fetch-chain"]).contains("NDX"))
        let system084 = StudioPrompts.editSystem.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        check("BUG-084 the prompt says how fixed-answer data is filled", system084.contains("Data that a rule answers with a fixed body")
              && system084.contains("`status` 200 and the whole new `body`, in the same shape") && system084.contains("not a fake"))
        func chainProblems(_ body: String, status: Int = 200) -> [String] {
            StudioContextValidator.problems(StudioContextPlan(structured: contextObject(overrides: [overrideObject(ruleId: "fetch-chain", status: status, body: body)])),
                                            current: base, spec: chainSpec)
        }
        let fuller = #"{"underlying":"SPX","strikes":[5800,5805],"contracts":[{"strike":5800,"type":"put","bid":2}],"extra":true}"#
        check("BUG-084 a new body of the same shape passes, with other values and list lengths", chainProblems(fuller).isEmpty,
              chainProblems(fuller).joined(separator: " | "))
        let dropped = chainProblems(#"{"contracts":[]}"#)
        check("BUG-084 a new body that leaves out keys of the current answer is refused, naming them",
              dropped.count == 1 && dropped[0].contains("fetch-chain") && dropped[0].contains("strikes, underlying"), dropped.joined(separator: " | "))
        check("BUG-084 a new body of another kind is refused", chainProblems("[1,2]").first?.contains("must be a JSON object") == true)
        check("BUG-084 an error override keeps any body", chainProblems(#"{"error":"down"}"#, status: 503).isEmpty)
        let copied = chainProblems(#"{"underlying":"SPX","strikes":[5890,"… 3 more like these"],"contracts":[]}"#)
        check("BUG-084 a body that copies a shortened list is refused", copied.count == 1 && copied[0].contains("shortened list"), copied.joined(separator: " | "))
        // Giving up on data the application can change is asked about once.
        func givenUp(_ unsupported: [String], overrides: [[String: Any]] = []) -> [String] {
            StudioContextValidator.givenUpProblems(StudioContextPlan(structured: contextObject(overrides: overrides, unsupported: unsupported)),
                                                   current: base, spec: chainSpec)
        }
        let gaveUp = givenUp(["Could not build the full answer of fetch-chain: its lists are shortened."])
        check("BUG-084 an unsupported note that gives up on a fixed-answer rule is sent back, naming the override to write",
              gaveUp.count == 1 && gaveUp[0].contains("override of fetch-chain") && gaveUp[0].contains("Do not leave it in `unsupported`"), gaveUp.joined(separator: " | "))
        check("BUG-084 the same note given up by its path is sent back too", givenUp(["GET /api/chain cannot return more strikes"]).count == 1)
        check("BUG-084 an honest note about something no rule answers stays", givenUp(["A live tick stream is not simulated."]).isEmpty
              && givenUp(["list-projects has no field for colours"]).isEmpty)
        check("BUG-084 a note next to an override of that rule stays",
              givenUp(["fetch-chain: the second expiry is unchanged"], overrides: [overrideObject(ruleId: "fetch-chain", status: 200, body: "{}")]).isEmpty)
        check("BUG-084 the change names a new answer",
              StudioContextValidator.describe(StudioOverride(ruleId: "fetch-chain", status: 200, body: .object([:]))) == "fetch-chain: status 200, a new answer")
        check("BUG-084 lists are shortened to their first items, nested too",
              StudioJSON.array([.number(1), .array([.number(1), .number(2), .number(3)]), .number(3)]).abbreviated(items: 2)
              == .array([.number(1), .array([.number(1), .number(2), .string("… 1 more like these")]), .string("… 1 more like these")]))

        // Stored history and scenarios: new fields are optional, old files load, an unknown kind does not lose the history.
        func reencode<T: Codable>(_ value: T, _ edit: (inout [String: Any]) -> Void) -> T? {
            guard let data = try? StudioStore.encoder.encode(value),
                  var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            edit(&object)
            guard let edited = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? StudioStore.decoder.decode(T.self, from: edited)
        }
        let plain = StudioOperation(id: "e0", kind: .edit, request: "Bigger", created: Date(timeIntervalSince1970: 1_800_000_000), status: .applied)
        check("REQ-013 a history entry from before context changes loads", reencode(plain) { $0["context"] = nil } == plain)
        var contextOperation = StudioOperation(id: "c1", kind: .context, request: request, created: Date(timeIntervalSince1970: 1_800_000_000), status: .applied)
        contextOperation.context = change
        contextOperation.selection = StudioPrompts.pageElement("/projects")
        check("REQ-013 a context change round-trips", reencode(contextOperation) { _ in } == contextOperation)
        check("REQ-013 an unknown kind of a later version loads as a question", reencode(contextOperation) { $0["kind"] = "future" }?.kind == .question)
        let damaged = reencode(contextOperation) { $0["context"] = 42 }
        check("REQ-013 a damaged context entry does not lose the history", damaged?.id == "c1" && damaged?.context?.scenarioId == "")
        let partial = reencode(contextOperation) { object in
            var context = object["context"] as? [String: Any] ?? [:]
            context["records"] = "many"
            context["previous"] = nil
            object["context"] = context
        }
        check("REQ-013 a context entry with a wrong field keeps the rest", partial?.context?.scenarioName == "Many projects 2"
              && partial?.context?.records.isEmpty == true && partial?.context?.previous == nil)
        check("REQ-013 a scenario from before descriptions loads", reencode(base) { $0["description"] = nil } == base
              && reencode(next) { _ in }?.description == request)

        // The prompt: the page when nothing is selected, the environment for a context change, the refused change once.
        var shown = base
        shown.route = "/projects"
        shown.overrides = [StudioOverride(ruleId: "list-projects", empty: true)]
        shown.steps = [StudioStep(action: .click, selector: "#add")]
        shown.role.user = .object(["name": .string("Test User"), "email": .string("test@example.com"), "apiKey": .string("sk-ant-abcdefghijklmnopqrstuvwxyz")])
        var secretSpec = spec
        secretSpec.seed["projects"]?[0] = .object(["id": .number(1), "name": .string("Apollo"), "status": .string("active"), "password": .string("hunter2secret")])
        let page = StudioPrompts.editPrompt("Fill it with random numbers", selection: nil, scenario: shown, revision: nil, history: [],
                                            redactor: redactor, clarification: nil, retryProblem: nil, route: "/projects",
                                            pageImage: "/tmp/page.png", spec: secretSpec, refusedContext: ["projects 5: status must be one of active, archived"])
        check("DEC-010 a request without a selection is about the page", page.hasPrefix("No element is selected") && page.contains("Page route: /projects")
              && page.contains("A picture of the page: /tmp/page.png") && !page.contains("Selected element"), String(page.prefix(300)))
        check("REQ-013 the prompt lists entities with fields, ids and rules", page.contains("- projects (id field id, 3 records): name:string!, status:string!(active|archived)")
              && page.contains("projectId:integer!→projects") && page.contains("Ids: 1, 2, 3") && page.contains("- list-projects: GET /api/projects → list projects")
              && page.contains("- me: GET /api/me → session"), page)
        check("REQ-013 the prompt shows the current overrides and steps in the plan's form",
              page.contains(#"{"body":"","delayMs":0,"empty":true,"hang":false,"method":"","path":"","ruleId":"list-projects","status":0}"#)
              && page.contains(##"{"action":"click","ms":0,"selector":"#add","text":""}"##), page)
        check("REQ-013 the prompt never shows the test token or confidential values", !page.contains("markview-test-token") && !page.contains("hunter2secret")
              && !page.contains("sk-ant-") && page.contains("test@example.com"), page)
        check("REQ-013 a refused change comes back with its problems", page.contains("Your previous context change was not saved")
              && page.contains("- projects 5: status must be one of active, archived") && page.hasSuffix("return the whole corrected change."))
        let realAuthPrompt = StudioPrompts.editPrompt("Sign in", selection: nil, scenario: shown, revision: nil, history: [],
                                                     redactor: redactor, clarification: nil, retryProblem: nil, supabaseAuthReal: true)
        check("a real Supabase connection is not described as a mock", realAuthPrompt.contains("Supabase connection is set to Real")
              && !realAuthPrompt.contains("Built-in Supabase Auth is active"))
        let elementPrompt = StudioPrompts.editPrompt("Why?", selection: StudioSelectionContext(["rect": ["x": 0, "y": 0, "width": 1, "height": 1], "tag": "h1", "selector": "h1"])!,
                                                     scenario: nil, revision: nil, history: [], redactor: redactor, clarification: nil, retryProblem: nil)
        check("DEC-010 a request with a selection is about the element, without an environment block when none is known",
              elementPrompt.hasPrefix("Selected element: h1") && !elementPrompt.contains("No element is selected") && !elementPrompt.contains("Simulated environment"))

        // The conversation remembers what a context change made.
        let remembered = StudioPrompts.conversationBlock([contextOperation], redactor: redactor)
        check("REQ-013 a remembered context change names its scenario and what changed", remembered.contains("(context change · page /projects)")
              && remembered.contains("New scenario: Many projects 2 (made from Populated)") && remembered.contains("Records: projects 3 → 2")
              && remembered.contains("Not done: A chart nothing serves") && !remembered.contains("· element page"), remembered)
    }
}
