// Checks the pure modules of UI Studio (MarkView/Models/UIStudio*.swift): the simulation engine, rule validation,
// bounded preparation, redaction, bridge validation, the change manager with selective undo, code revision identity,
// scenarios and their compatibility, image comparison and feature packages. Run by tools/tests/ui-studio-tests.sh.
import CoreGraphics
import Combine
import Foundation
import os

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { print("ok  \(name)") } else {
        failures += 1
        let more = detail()
        print("FAIL \(name)" + (more.isEmpty ? "" : "\n     \(more)"))
    }
}

let fm = FileManager.default
let tmp = fm.temporaryDirectory.appendingPathComponent("markview-ui-studio-tests-\(UUID().uuidString)")
try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }

// MARK: - Reference environment (§13: projects with list, details, create, rename, delete)

let app = "http://localhost:5173"
var requestCounter = 0
func request(_ method: String, _ path: String, body: String? = nil, headers: [String: String] = [:], id: String? = nil) -> StudioHTTPRequest {
    requestCounter += 1
    return StudioHTTPRequest(method: method, url: URL(string: app + path)!, headers: headers, body: body, requestId: id ?? "r\(requestCounter)")
}
// MARK: - Bounded preparation (SIM-07…SIM-10, AC-05…AC-07)

// MARK: - Scenarios and compatibility (SCN-01…SCN-04)

// MARK: - Browser features and kept browser data (REQ-008)

// MARK: - Evidence (CAP-01…CAP-06)

// MARK: - One request box and context changes (DEC-010, REQ-013)

/// A context object as a strict-schema assistant returns it: every property present, empty when not given.
// MARK: - Selection (PRE-07…PRE-09)


// MARK: - Session processes and connection policy (REQ-006, AC-17, AC-18)


// MARK: - Conversation memory and page events

// MARK: - Server connections (REQ-007)



// MARK: - Session log (REQ-011)

// MARK: - Change tracking (REQ-012)



// MARK: - Application map (REQ-014)

/// Every object of a strict schema lists all its properties as required and allows no others (Codex's structured output).
// MARK: - Real-time channels and GraphQL (REQ-015)

func json(_ text: String) -> StudioJSON { StudioJSON(text: text) ?? .null }
func texts(_ frames: [StudioChannelFrame]) -> [String] { frames.compactMap { if case .text(let text) = $0 { return text }; return nil } }


extension StudioHTTPRequest {
    func withID(_ id: String?) -> StudioHTTPRequest {
        var copy = self
        if let id { copy.requestId = id }
        return copy
    }
}

final class SimulatorBox {
    var sim: StudioSimulator
    var changes: [StudioEntityChange] = []
    init(_ sim: StudioSimulator) { self.sim = sim }
}

@MainActor
func channelChecks() async {
    func message(_ data: String, event: String? = nil, topic: String? = nil) -> StudioChannelMessage {
        StudioChannelMessage(event: event, topic: topic, data: json(data))
    }
    var cspec = StudioEnvironmentSpec()
    cspec.entities = [StudioEntity(name: "messages", fields: [StudioField(name: "text", type: "string", required: true), StudioField(name: "room", type: "string")])]
    cspec.seed = ["messages": [json(#"{"id":1,"text":"Hello","room":"general"}"#)]]
    cspec.rules = [StudioRule(id: "messages-create", method: "POST", path: "/api/messages", operation: .create, entity: "messages")]
    cspec.channels = [
        StudioChannel(id: "chat", path: "/ws/chat", wire: .raw, onConnect: [message(#"{"type":"welcome"}"#)],
                      onMessage: [StudioChannelReply(match: ["type": .string("ping")], reply: [message(#"{"type":"pong"}"#)]),
                                  StudioChannelReply(match: ["type": .string("send")], reply: [message(#"{"type":"sent","message":"{{record}}"}"#)],
                                                     entity: "messages", operation: .create, recordPath: "message")],
                      events: [StudioChannelEvent(afterMs: 30, message: message(#"{"type":"tick","n":"{{count}}"}"#))],
                      links: [StudioChannelLink(entity: "messages", on: [.create], message: message(#"{"type":"new","message":"{{record}}"}"#))]),
        StudioChannel(id: "io", path: "/socket.io", wire: .socketio, onConnect: [message(#"{"user":"test"}"#, event: "hello")],
                      onMessage: [StudioChannelReply(match: ["event": .string("get-rooms")], reply: [message(#"["general","random"]"#)]),
                                  StudioChannelReply(match: ["event": .string("chat")], broadcast: [message(#""{{message.data}}""#, event: "chat")])]),
        StudioChannel(id: "realtime", path: "wss://abc.supabase.co/realtime/v1/websocket", wire: .phoenix),
        StudioChannel(id: "gql", path: "/graphql", wire: .graphqlWS),
        StudioChannel(id: "feed", path: "https://api.example.com/events/:room", wire: .raw, onConnect: [message(#"{"room":"{{params.room}}"}"#, event: "hello")]),
    ]
    cspec.graphQL = [StudioGraphQLOperation(id: "s-msg", kind: .subscription, field: "messageAdded", action: .get, entity: "messages", on: [.create]),
                     StudioGraphQLOperation(id: "q-msgs", kind: .query, field: "messages", action: .list, entity: "messages")]
    let box = SimulatorBox(StudioSimulator(spec: cspec, scenario: StudioScenario(id: "s", name: "S", kind: .populated), appOrigin: app))
    var logs: [String] = []
    var pushed: [String: [StudioChannelFrame]] = [:]
    let hub = StudioChannelHub(environment: StudioChannelHub.Environment(
        spec: { box.sim.spec }, state: { box.sim.state }, appOrigin: { app },
        perform: { operation, entity, id, fields in
            let before = box.sim.state
            let response = box.sim.perform(operation, entity: entity, id: id, fields: fields)
            box.changes += StudioEntityChange.diff(before: before, after: box.sim.state, spec: box.sim.spec)
            return response
        },
        graphQL: { url, payload in
            let http = StudioHTTPRequest(method: "POST", url: url, headers: ["content-type": "application/json"], body: payload.text, requestId: UUID().uuidString)
            if case .respond(let response, _) = box.sim.handle(http) { return StudioJSON(text: response.body ?? "") ?? .null }
            return .null
        },
        redact: { StudioRedactor().redact($0) }, log: { text, _ in logs.append(text) }))
    func open(_ id: String, _ url: String, protocols: [String] = [], transport: StudioChannelTransport = .webSocket) -> StudioChannelHub.Opening {
        hub.open(id: id, url: URL(string: url)!, protocols: protocols, transport: transport, source: "page", shown: url,
                 sink: { pushed[id, default: []] += $0 })
    }
    func flushChanges() {
        hub.entitiesChanged(box.changes)
        box.changes = []
    }

    // Matching and templates.
    check("channels: a ws URL matches a channel of the app's origin", StudioChannelRoute.channel(for: URL(string: "ws://localhost:5173/ws/chat")!,
          in: cspec.channels ?? [], appOrigin: app)?.0.id == "chat")
    check("channels: a full-URL channel matches wss and https alike, with parameters",
          StudioChannelRoute.channel(for: URL(string: "https://api.example.com/events/general")!, in: cspec.channels ?? [], appOrigin: app)?.1 == ["room": "general"]
          && StudioChannelRoute.channel(for: URL(string: "wss://abc.supabase.co/realtime/v1/websocket?vsn=1.0.0")!, in: cspec.channels ?? [], appOrigin: app)?.0.id == "realtime")
    check("channels: another origin does not match a path channel", StudioChannelRoute.channel(for: URL(string: "wss://other.example.com/ws/chat")!,
          in: cspec.channels ?? [], appOrigin: app) == nil)
    check("channels: a whole placeholder keeps its JSON value, an embedded one becomes text",
          StudioChannelTemplate.fill(json(#"{"a":"{{record}}","b":"id {{record.id}}!"}"#), ["record": json(#"{"id":7}"#)]) == json(#"{"a":{"id":7},"b":"id 7!"}"#))
    check("channels: match by dotted field and any value", StudioChannelTemplate.matches(["payload.type": .string("*"), "event": .string("x")],
          json(#"{"event":"x","payload":{"type":1}}"#)) && !StudioChannelTemplate.matches(["event": .string("y")], json(#"{"event":"x"}"#)))
    if case .unknown(let contract) = open("u1", "ws://localhost:5173/other/7") {
        check("channels: an address no channel answers is prepared by its contract", contract == "WS /other/:id", contract)
    } else { check("channels: unknown address", false) }
    if case .unknown(let contract) = open("u2", "https://api.example.com/stream", transport: .eventSource) {
        check("channels: an unknown event stream keeps its origin in the contract", contract == "SSE https://api.example.com/stream", contract)
    } else { check("channels: unknown event stream", false) }

    // Raw JSON: connect message, reply, a write that the link pushes to every connection, a REST write pushed too.
    if case .accepted(_, let welcome) = open("a", "ws://localhost:5173/ws/chat") {
        check("raw: the connect message arrives with the open", texts(welcome) == [#"{"type":"welcome"}"#], "\(welcome)")
    } else { check("raw: open", false) }
    _ = open("b", "ws://localhost:5173/ws/chat")
    check("raw: a matched message gets its reply", texts(hub.receive(id: "a", text: #"{"type":"ping"}"#)) == [#"{"type":"pong"}"#])
    let sent = texts(hub.receive(id: "a", text: #"{"type":"send","message":{"text":"Hi","room":"general"}}"#))
    check("raw: a message that creates a record answers with it", sent.count == 1 && json(sent[0])["message"]?["id"] == .number(2)
          && box.sim.state["messages"]?.count == 2, "\(sent)")
    flushChanges()
    check("raw: the link pushes the new record to the other connection",
          texts(pushed["b"] ?? []).contains { json($0)["type"] == .string("new") && json($0)["message"]?["text"] == .string("Hi") }, "\(pushed["b"] ?? [])")
    let before = box.sim.state
    _ = box.sim.handle(request("POST", "/api/messages", body: #"{"text":"From REST"}"#))
    hub.entitiesChanged(StudioEntityChange.diff(before: before, after: box.sim.state, spec: box.sim.spec))
    check("raw: a REST create reaches the subscriber through the link",
          texts(pushed["b"] ?? []).contains { json($0)["message"]?["text"] == .string("From REST") })
    check("raw: an unmatched message is logged, not answered", hub.receive(id: "a", text: "plain words").isEmpty
          && logs.contains { $0.contains("no channel rule answers") })
    try? await Task.sleep(nanoseconds: 200_000_000)
    check("raw: a timed event is pushed", texts(pushed["a"] ?? []).contains(#"{"n":1,"type":"tick"}"#), "\(pushed["a"] ?? [])")
    check("raw: an oversized message closes the connection with 1009",
          hub.receive(id: "b", text: String(repeating: "x", count: StudioChannelHub.maxMessage + 1)) == [.close(code: 1009, reason: "The message is larger than 1000000 bytes.")]
          && hub.connections["b"] == nil)
    if case .accepted(_, let hello) = open("f", "wss://api.example.com/events/sales", transport: .eventSource) {
        check("raw: an event stream sends named events with path parameters", hello == [.event(name: "hello", data: #"{"room":"sales"}"#, id: nil)], "\(hello)")
    } else { check("raw: event stream", false) }

    // Socket.IO over a WebSocket: open packet, namespace connect, greeting, acknowledgements, broadcast.
    if case .accepted(_, let opened) = open("io1", "ws://localhost:5173/socket.io/?EIO=4&transport=websocket") {
        let packet = texts(opened).first ?? ""
        check("socket.io: the Engine.IO open packet stays on this transport", packet.hasPrefix("0{") && packet.contains(#""upgrades":[]"#)
              && packet.contains(#""pingInterval":25000"#), packet)
    } else { check("socket.io: open", false) }
    let connected = texts(hub.receive(id: "io1", text: "40"))
    check("socket.io: connect answers with a sid and the greeting", connected.count == 2 && connected[0].hasPrefix(#"40{"sid":"#)
          && connected[1] == #"42["hello",{"user":"test"}]"#, "\(connected)")
    check("socket.io: an emit with a callback gets the reply as its acknowledgement",
          texts(hub.receive(id: "io1", text: #"421["get-rooms"]"#)) == [#"431[["general","random"]]"#])
    check("socket.io: an unanswered callback still gets an empty acknowledgement", texts(hub.receive(id: "io1", text: #"422["nobody"]"#)) == ["432[]"])
    check("socket.io: a ping is answered with a pong", texts(hub.receive(id: "io1", text: "2")) == ["3"])
    _ = open("io2", "ws://localhost:5173/socket.io/?EIO=4&transport=websocket")
    _ = hub.receive(id: "io2", text: "40")
    _ = hub.receive(id: "io1", text: #"42["chat",{"text":"yo"}]"#)
    check("socket.io: a broadcast reaches the other socket", texts(pushed["io2"] ?? []).contains(#"42["chat",{"text":"yo"}]"#), "\(pushed["io2"] ?? [])")

    // Socket.IO over HTTP long-polling.
    var polls: [StudioSimResponse] = []
    func poll(_ method: String, _ query: String, body: String? = nil) -> Bool {
        hub.poll(StudioHTTPRequest(method: method, url: URL(string: app + "/socket.io/?EIO=4&transport=polling" + query)!, body: body, requestId: UUID().uuidString),
                 source: "page", shown: "polling", reply: { polls.append($0) })
    }
    check("polling: a request without EIO is not a poll", !hub.poll(request("GET", "/socket.io/"), source: "page", shown: "", reply: { _ in }))
    _ = poll("GET", "&t=1")
    let sid = (polls.first?.body).flatMap { StudioJSON(text: String($0.dropFirst())) }?["sid"]?.stringValue ?? ""
    check("polling: the handshake opens a session", polls.first?.body?.hasPrefix("0{") == true && !sid.isEmpty, polls.first?.body ?? "nil")
    _ = poll("POST", "&sid=\(sid)", body: "40")
    check("polling: a POST of packets answers ok", polls.last?.body == "ok")
    _ = poll("GET", "&sid=\(sid)")
    let batch = polls.last?.body?.split(separator: "\u{1e}").map(String.init) ?? []
    check("polling: the next GET carries the connect answer and the greeting", batch.count == 2 && batch[0].hasPrefix("40{") && batch[1].hasPrefix(#"42["hello""#),
          polls.last?.body ?? "nil")
    let waitingCount = polls.count
    _ = poll("GET", "&sid=\(sid)")
    check("polling: a GET with nothing to send waits", polls.count == waitingCount)
    _ = poll("POST", "&sid=\(sid)", body: #"421["get-rooms"]"#)
    check("polling: the waiting GET gets the acknowledgement", polls.contains { $0.body == #"431[["general","random"]]"# }, "\(polls.map { $0.body ?? "" })")
    _ = poll("GET", "&sid=unknown")
    check("polling: an unknown sid is refused", polls.last?.status == 400)

    // Supabase Realtime (Phoenix): join with postgres_changes, heartbeat, a change pushed to the matching binding.
    if case .accepted(_, let none) = open("ph1", "wss://abc.supabase.co/realtime/v1/websocket?apikey=test-key&vsn=1.0.0") {
        check("phoenix: nothing is sent before a join", none.isEmpty)
    } else { check("phoenix: open", false) }
    let join = texts(hub.receive(id: "ph1", text: #"{"topic":"realtime:public:messages","event":"phx_join","payload":{"config":{"broadcast":{"self":false},"presence":{"key":""},"postgres_changes":[{"event":"INSERT","schema":"public","table":"messages"}]},"access_token":"test-token"},"ref":"1","join_ref":"1"}"#))
    let joinReply = join.first.map(json) ?? .null
    let binding = joinReply["payload"]?["response"]?["postgres_changes"]?.arrayValue?.first
    check("phoenix: the join reply echoes the bindings with ids and no invented filter",
          joinReply["event"] == .string("phx_reply") && joinReply["payload"]?["status"] == .string("ok") && joinReply["ref"] == .string("1")
          && binding?["table"] == .string("messages") && binding?["event"] == .string("INSERT") && binding?["id"]?.numberValue != nil
          && binding?["filter"] == nil, join.first ?? "nil")
    check("phoenix: presence is announced on join", join.contains { json($0)["event"] == .string("presence_state") })
    check("phoenix: a heartbeat is answered", texts(hub.receive(id: "ph1", text: #"{"topic":"phoenix","event":"heartbeat","payload":{},"ref":"2"}"#)).first.map(json)?["payload"]?["status"] == .string("ok"))
    pushed["ph1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":9,"text":"Live"}"#), old: nil)])
    let change = texts(pushed["ph1"] ?? []).first.map(json) ?? .null
    check("phoenix: an insert is pushed as postgres_changes to the binding",
          change["event"] == .string("postgres_changes") && change["payload"]?["ids"] == .array([binding?["id"] ?? .null])
          && change["payload"]?["data"]?["type"] == .string("INSERT") && change["payload"]?["data"]?["record"]?["text"] == .string("Live")
          && change["payload"]?["data"]?["table"] == .string("messages"), change.text)
    pushed["ph1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .update, record: json(#"{"id":9,"text":"Edited"}"#), old: json(#"{"id":9,"text":"Live"}"#))])
    check("phoenix: an update does not reach an INSERT binding", (pushed["ph1"] ?? []).isEmpty)
    _ = open("ph2", "wss://abc.supabase.co/realtime/v1/websocket?vsn=2.0.0")
    let arrayJoin = texts(hub.receive(id: "ph2", text: #"["1","1","realtime:room","phx_join",{"config":{"broadcast":{"self":true}}}]"#))
    check("phoenix: vsn 2.0.0 answers in arrays", arrayJoin.first.map(json)?.arrayValue?[3] == .string("phx_reply"), "\(arrayJoin)")
    let echo = texts(hub.receive(id: "ph2", text: #"[null,"2","realtime:room","broadcast",{"type":"broadcast","event":"typing","payload":{"u":1}}]"#))
    check("phoenix: broadcast with self comes back", echo.first.map(json)?.arrayValue?[3] == .string("broadcast")
          && echo.first.map(json)?.arrayValue?[4]["event"] == .string("typing"), "\(echo)")

    // GraphQL over WebSocket (graphql-transport-ws): ack, a query answered at once, a subscription pushed by a write.
    if case .accepted(let chosen, _) = open("g1", "ws://localhost:5173/graphql", protocols: ["graphql-transport-ws"]) {
        check("graphql-ws: the subprotocol is chosen", chosen == "graphql-transport-ws")
    } else { check("graphql-ws: open", false) }
    check("graphql-ws: connection_init is acknowledged", texts(hub.receive(id: "g1", text: #"{"type":"connection_init","payload":{}}"#)) == [#"{"type":"connection_ack"}"#])
    check("graphql-ws: a subscription waits for writes", hub.receive(id: "g1", text: #"{"id":"1","type":"subscribe","payload":{"query":"subscription { messageAdded { id text __typename } }"}}"#).isEmpty)
    let queried = texts(hub.receive(id: "g1", text: #"{"id":"2","type":"subscribe","payload":{"query":"{ messages { text } }"}}"#))
    check("graphql-ws: a query is answered with next and complete", queried.count == 2 && json(queried[0])["type"] == .string("next")
          && json(queried[0])["payload"]?["data"]?["messages"]?.arrayValue?.isEmpty == false && json(queried[1])["type"] == .string("complete"), "\(queried)")
    pushed["g1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":10,"text":"Sub"}"#), old: nil)])
    check("graphql-ws: a create is pushed to the subscription", texts(pushed["g1"] ?? []).first.map(json) == json(#"{"id":"1","type":"next","payload":{"data":{"messageAdded":{"id":10,"text":"Sub","__typename":"Message"}}}}"#),
          "\(pushed["g1"] ?? [])")
    _ = hub.receive(id: "g1", text: #"{"id":"1","type":"complete"}"#)
    pushed["g1"] = []
    hub.entitiesChanged([StudioEntityChange(entity: "messages", kind: .create, record: json(#"{"id":11,"text":"After"}"#), old: nil)])
    check("graphql-ws: complete ends the subscription", (pushed["g1"] ?? []).isEmpty)
    let missing = texts(hub.receive(id: "g1", text: #"{"id":"3","type":"subscribe","payload":{"query":"subscription { nothing { id } }"}}"#))
    check("graphql-ws: a subscription without a rule is a named error", missing.first.map(json)?["type"] == .string("error"), "\(missing)")

    // Changes between states; closing.
    let diff = StudioEntityChange.diff(before: ["messages": [json(#"{"id":1,"text":"a"}"#), json(#"{"id":2,"text":"b"}"#)]],
                                       after: ["messages": [json(#"{"id":1,"text":"A"}"#), json(#"{"id":3,"text":"c"}"#)]], spec: cspec)
    check("changes: update, create and delete by id", diff.map(\.kind) == [.update, .create, .delete], "\(diff.map(\.kind))")
    pushed["a"] = []
    hub.closeAll(source: "page", code: 1012, reason: "reset")
    check("channels: the session closes connections with a close frame", pushed["a"]?.last == .close(code: 1012, reason: "reset") && hub.connections.isEmpty)
    check("channels: opens and closes are logged", logs.contains { $0.contains("open · raw channel chat") } && logs.contains { $0.contains("closed 1012") })
}


// MARK: - Electron preload bridge (REQ-016)

@MainActor
func ipcChecks() async {
    // The verb convention, the same as the page runtime's (the web harness compares both).
    let verbs = ["getDocument": "GET", "listBrokers": "GET", "loadState": "GET", "fetchAiModels": "GET", "readFile": "GET", "findOrder": "GET",
                 "queryBars": "GET", "isConnected": "GET", "hasKey": "GET", "canTrade": "GET", "deleteBroker": "DELETE", "removeItem": "DELETE",
                 "clearCache": "DELETE", "updateBroker": "PATCH", "patchOrder": "PATCH", "saveBroker": "PUT", "setTheme": "PUT", "put": "PUT",
                 "resetDocument": "PUT", "importSettings": "PUT", "testConnection": "POST", "issue": "POST", "getter": "POST",
                 "settings:get-document": "GET", "order:submit": "POST", "settings:delete_broker": "DELETE", "GetAll": "GET",
                 "constructor": "POST", "toString": "POST", "": "POST", "settings:": "POST", "_internal.save": "PUT"]
    let wrong = verbs.filter { StudioIPC.verb(of: $0.key) != $0.value }.map { "\($0.key) → \(StudioIPC.verb(of: $0.key))" }
    check("REQ-016 a bridge method's verb follows its name's first word, a channel's its last part", wrong.isEmpty, wrong.joined(separator: ", "))
    check("REQ-016 an endpoint path's verb is its method's, or its channel's after invoke",
          StudioIPC.verb(ofPath: "/desk/settings/getBroker/:id") == "GET"
          && StudioIPC.verb(ofPath: "/electron/ipcRenderer/invoke/settings:get-document") == "GET"
          && StudioIPC.verb(ofPath: "/electron/ipcRenderer/invoke/order%3Asubmit/:id") == "POST"
          && StudioIPC.verb(ofPath: "/desk/brokers/deleteBroker/:id") == "DELETE" && StudioIPC.verb(ofPath: "/:only") == nil)
    check("REQ-016 only http://electron.ipc is the bridge's address",
          StudioIPC.isIPC(URL(string: "http://electron.ipc/desk/settings/getDocument")!) && !StudioIPC.isIPC(URL(string: "https://electron.ipc/x")!)
          && !StudioIPC.isIPC(URL(string: "http://electron.ipc:8080/x")!) && !StudioIPC.isIPC(URL(string: "http://evil.electron.ipc/x")!)
          && StudioIPC.isIPC(path: "http://electron.ipc/desk/x") && !StudioIPC.isIPC(path: "/api/x"))

    // The bridge's messages: a call is a request with the ipc transport, a callback a channel with it; both only at the bridge.
    let ipcOrigin = StudioBridge.Origin(url: URL(string: app)!)!
    let expected = StudioBridge.Expectation(session: "s-1", generation: 3, origin: ipcOrigin)
    func message(_ fields: [String: Any]) -> [String: Any] { ["session": "s-1", "generation": 3].merging(fields) { _, new in new } }
    let call = message(["kind": "request", "requestId": "g3-1-x", "method": "PUT", "url": "http://electron.ipc/desk/settings/saveBroker",
                        "headers": ["content-type": "application/json", StudioIPC.argumentsHeader: #"[{"id":"b1"}]"#], "body": #"{"id":"b1"}"#,
                        "transport": "ipc"])
    var parsedCall: StudioBridge.Request?
    if case .success(.request(let parsed)) = StudioBridge.validate(call, isMainFrame: true, origin: ipcOrigin, expecting: expected) { parsedCall = parsed }
    check("REQ-016 a bridge call is a request with the ipc transport", parsedCall?.transport == "ipc" && parsedCall?.method == "PUT")
    var elsewhere = call
    elsewhere["url"] = app + "/api/brokers"
    let elsewhereResult = StudioBridge.validate(elsewhere, isMainFrame: true, origin: ipcOrigin, expecting: expected)
    check("REQ-016 the ipc transport is refused for another address", elsewhereResult == .failure(.malformed("ipc url")), "\(elsewhereResult)")
    let listen = message(["kind": "channel", "action": "open", "id": "c3-1-x", "url": "http://electron.ipc/desk/settings/onDocumentApplied",
                          "protocols": [String](), "transport": "ipc"])
    var parsedListen: StudioBridge.Channel?
    if case .success(.channel(let parsed)) = StudioBridge.validate(listen, isMainFrame: true, origin: ipcOrigin, expecting: expected) { parsedListen = parsed }
    var wrongListen = listen
    wrongListen["url"] = "ws://localhost:5173/ws"
    check("REQ-016 a bridge callback is a channel with the ipc transport, only at the bridge's address", parsedListen?.transport == .ipc
          && StudioBridge.validate(wrongListen, isMainFrame: true, origin: ipcOrigin, expecting: expected) == .failure(.malformed("ipc url")))

    // The arguments header is redacted field by field before it reaches a prompt or the log.
    let fakeKey = "sk-" + String(repeating: "q7", count: 12)
    let header = StudioRedactor().redact(headers: [StudioIPC.argumentsHeader: #"[{"name":"Paper","apiKey":"plain-value"},"\#(fakeKey)",3]"#])
    let redactedArgs = header[StudioIPC.argumentsHeader] ?? ""
    check("REQ-016 the arguments header is redacted field by field and for credential shapes",
          !redactedArgs.contains("plain-value") && !redactedArgs.contains(fakeKey) && redactedArgs.contains("Paper") && redactedArgs.contains("[redacted]"),
          redactedArgs)

    // The map: its version, lenient decoding, and an older map of an Electron renderer extended with the preload bridge.
    check("REQ-016 a new map has the current version; a completed older map of an Electron renderer is outdated, of a web app not",
          StudioEnvironmentMap().version == StudioEnvironmentMap.currentVersion
          && StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, version: 1).isOutdated(electron: true)
          && !StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, version: 1).isOutdated(electron: false)
          && !StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true).isOutdated(electron: true))
    let oldMap = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, inventoryAttempts: 3, version: 1)
    check("REQ-016 a session maps again only an outdated completed map of an Electron renderer",
          StudioEnvironmentMapper.needsMapping(oldMap, appFolder: "web", electron: true)
          && !StudioEnvironmentMapper.needsMapping(oldMap, appFolder: "web", electron: false)
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true), appFolder: "web", electron: true)
          && !StudioEnvironmentMapper.needsMapping(StudioEnvironmentMap(status: .cancelled, appFolder: "web", inventoried: true, version: 1),
                                                   appFolder: "web", electron: true))
    let ipcRoot = tmp.appendingPathComponent("ipc-environment")
    var stored = StudioEnvironmentSpec()
    stored.rules = [StudioRule(id: "list-orders", method: "GET", path: "https://api.example.test/orders", operation: .list, entity: "orders")]
    stored.entities = [StudioEntity(name: "orders")]
    stored.map = StudioEnvironmentMap(status: .complete, appFolder: "web", inventoried: true, inventoryAttempts: 1,
                                      services: [StudioMapService(name: "api", baseURL: "https://api.example.test", address: "https://api.example.test")],
                                      groups: [StudioMapGroup(id: "api/orders", service: "api", resource: "orders",
                                                              endpoints: [StudioMapEndpoint(method: "GET", path: "/orders", resource: "orders")],
                                                              status: .done, rules: ["list-orders"])])
    try? StudioStore.saveEnvironment(stored, root: ipcRoot)
    let environmentFile = StudioStore.environmentURL(ipcRoot)
    var written = (try? String(contentsOf: environmentFile, encoding: .utf8)) ?? ""
    check("REQ-016 the map is saved with its version", written.contains("\"version\" : 2") || written.contains("\"version\":2"), String(written.prefix(200)))
    // The map's version is its last key (sorted); a rule's own version is 1.
    written = written.replacingOccurrences(of: #",\s*"version"\s*:\s*2"#, with: "", options: .regularExpression)
    try? written.write(to: environmentFile, atomically: true, encoding: .utf8)
    let reloaded = StudioStore.loadEnvironment(ipcRoot)
    check("REQ-016 an environment saved before map versions loads, its map as version 1 with its groups and rules",
          !written.contains("\"version\" : 2") && reloaded?.map?.version == 1 && reloaded?.map?.groups.first?.status == .done
          && reloaded?.rules.first?.id == "list-orders" && reloaded?.map?.isOutdated(electron: true) == true,
          "\(String(describing: reloaded?.map))")

    let answer: [String: Any] = [
        "services": [["name": "api", "baseURL": "https://api.example.test", "variable": "", "side": "browser"],
                     ["name": "electron-ipc", "baseURL": "", "variable": "WRONG", "side": "server"]],
        "endpoints": [
            ["service": "api", "resource": "orders", "method": "GET", "path": "/orders", "callSite": "src/api.ts:3", "side": "browser"],
            ["service": "electron-ipc", "resource": "settings", "method": "POST", "path": "/desk/settings/getDocument", "callSite": "src/preload.ts:60", "side": "browser"],
            ["service": "electron-ipc", "resource": "settings", "method": "GET", "path": "http://electron.ipc/desk/settings/saveDocument/:expectedRevision",
             "callSite": "src/preload.ts:62", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/getBrokers", "callSite": "src/preload.ts:70", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/saveBroker", "callSite": "src/preload.ts:71", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/deleteBroker/:id", "callSite": "src/preload.ts:72", "side": "browser"],
            ["service": "electron-ipc", "resource": "brokers", "method": "GET", "path": "/desk/settings/testConnection/:id", "callSite": "src/preload.ts:73", "side": "browser"],
        ],
        "notes": ["onDocumentApplied(cb) is a subscription"], "userRoles": ["names": [], "ordinary": ""]]
    let inventory = StudioMapParsing.inventory(from: answer)
    let methods = inventory?.entries.filter { $0.service == StudioIPC.service }.map { "\($0.endpoint.method) \($0.endpoint.path)" } ?? []
    check("REQ-016 the inventory gives the bridge its logical address and each method the verb the page calls it with",
          inventory?.services.first { $0.name == StudioIPC.service }?.baseURL == StudioIPC.origin
          && inventory?.services.first { $0.name == StudioIPC.service }?.variable == ""
          && methods == ["GET /desk/settings/getDocument", "PUT /desk/settings/saveDocument/:expectedRevision", "GET /desk/settings/getBrokers",
                         "PUT /desk/settings/saveBroker", "DELETE /desk/settings/deleteBroker/:id", "POST /desk/settings/testConnection/:id"],
          "\(methods)")
    let unlisted = StudioMapParsing.inventory(from: ["services": [], "endpoints": [
        ["service": "electron-ipc", "resource": "x", "method": "GET", "path": "/desk/clearAll", "callSite": "", "side": "browser"]]])
    check("REQ-016 a bridge endpoint whose service the answer did not list still gets the bridge's address",
          unlisted?.services.first?.baseURL == StudioIPC.origin && unlisted?.entries.first?.endpoint.method == "DELETE")

    // A page call prepared the document's getter before the map was extended: only what has no rule gets a group.
    var rules = stored.rules
    rules.append(StudioRule(id: "get-document", method: "GET", path: "http://electron.ipc/desk/settings/getDocument", operation: .respond,
                            response: StudioFixedResponse(status: 200, body: .object([:]))))
    var withIPCGroup = oldMap
    withIPCGroup.services = stored.map?.services ?? []
    withIPCGroup.groups = (stored.map?.groups ?? []) + [StudioMapGroup(id: "electron-ipc/settings+brokers", service: "other", resource: "x", endpoints: [])]
    if let inventory {
        let (extended, added) = StudioMapPlanner.extended(withIPCGroup, with: inventory, rules: rules, connections: [], limits: StudioMapLimits())
        let addedEndpoints = added.flatMap { $0.endpoints.map { "\($0.method) \($0.path)" } }
        check("REQ-016 an extended map keeps its groups and adds groups only for endpoints with no rule and no group",
              extended.groups.prefix(2).map(\.id) == ["api/orders", "electron-ipc/settings+brokers"] && extended.groups.first?.status == .done
              && extended.groups.first?.rules == ["list-orders"]
              && addedEndpoints == ["PUT /desk/settings/saveDocument/:expectedRevision", "GET /desk/settings/getBrokers", "PUT /desk/settings/saveBroker",
                                    "DELETE /desk/settings/deleteBroker/:id", "POST /desk/settings/testConnection/:id"]
              && added.allSatisfy { $0.status == .pending && $0.service == StudioIPC.service }, "\(addedEndpoints) \(extended.groups.map(\.id))")
        check("REQ-016 new group ids do not clash with the old ones; the map has the bridge's service and the current version",
              Set(extended.groups.map(\.id)).count == extended.groups.count && added.map(\.id) == ["electron-ipc/settings+brokers-2"]
              && extended.service(StudioIPC.service)?.address == StudioIPC.origin && extended.version == StudioEnvironmentMap.currentVersion
              && extended.notes == ["onDocumentApplied(cb) is a subscription"], "\(added.map(\.id))")
        let again = StudioMapPlanner.extended(extended, with: inventory, rules: rules, connections: [], limits: StudioMapLimits())
        check("REQ-016 extending twice adds nothing more", again.added.isEmpty && again.map.groups.count == extended.groups.count)
        check("REQ-016 every new endpoint is covered by a rule at the bridge's address once prepared",
              StudioMapPlanner.rulePath(added[0].endpoints[0], service: extended.service(StudioIPC.service))
                == "http://electron.ipc/desk/settings/saveDocument/:expectedRevision")
    } else {
        check("REQ-016 the inventory with the bridge is readable", false)
    }

    // What the prompts say about the bridge (DEC-007 included), and what the Environment panel shows.
    let electronContext = StudioMapContext(appFolder: "app", appOrigin: nil, connections: [], electron: true)
    let ipcContext = StudioPreparationContext(contract: "GET http://electron.ipc/desk/settings/getDocument", method: "GET",
                                              url: "http://electron.ipc/desk/settings/getDocument", headers: [StudioIPC.argumentsHeader: "[]"],
                                              body: nil, attempt: 1, problems: [])
    let preparation = StudioPrompts.preparationPrompt(ipcContext, spec: StudioEnvironmentSpec(), appFolder: "app")
    check("REQ-016 the prompts explain the bridge's address, where its answers are found, entities and DEC-007",
          StudioPrompts.preparationSystem.contains("http://electron.ipc/<global>/<path>/<method>")
          && StudioPrompts.preparationSystem.contains("ipcMain.handle") && StudioPrompts.preparationSystem.contains("testConnection")
          && StudioPrompts.preparationSystem.contains("saves and deletes change") && StudioPrompts.preparationSystem.contains(StudioIPC.argumentsHeader)
          && StudioMapPrompts.inventorySystem.contains("`electron-ipc`") && StudioMapPrompts.inventorySystem.contains("/desk/settings/getBroker/:id")
          && StudioMapPrompts.inventoryPrompt(electronContext).contains("This is an Electron renderer")
          && !StudioMapPrompts.inventoryPrompt(StudioMapContext(appFolder: "app", appOrigin: nil, connections: [])).contains("Electron renderer")
          && preparation.contains("A call of the Electron preload bridge") && preparation.contains(StudioIPC.argumentsHeader))
    var bridgeSpec = StudioEnvironmentSpec()
    bridgeSpec.rules = rules
    bridgeSpec.channels = [StudioChannel(id: "applied", path: "http://electron.ipc/desk/settings/onDocumentApplied")]
    check("REQ-016 the Environment panel counts the bridge's simulated methods",
          StudioIPC.summary(bridgeSpec, globals: ["desk"]) == "simulated (2 methods) · window.desk"
          && StudioIPC.summary(StudioEnvironmentSpec(), globals: []) == "simulated (0 methods)", StudioIPC.summary(bridgeSpec, globals: ["desk"]))

    // A callback waits for its channel and gets what the channel pushes once one is registered.
    var ispec = StudioEnvironmentSpec()
    ispec.entities = [StudioEntity(name: "documents")]
    ispec.seed = ["documents": [json(#"{"id":"current","theme":"dark"}"#)]]
    let box = SimulatorBox(StudioSimulator(spec: ispec, scenario: StudioScenario(id: "s", name: "S", kind: .populated), appOrigin: app))
    var logs: [String] = []
    var pushed: [String: [StudioChannelFrame]] = [:]
    let hub = StudioChannelHub(environment: StudioChannelHub.Environment(
        spec: { box.sim.spec }, state: { box.sim.state }, appOrigin: { app },
        perform: { _, _, _, _ in .json(501, nil) }, graphQL: { _, _ in .null }, redact: { $0 }, log: { text, _ in logs.append(text) }))
    let address = URL(string: "http://electron.ipc/desk/settings/onDocumentApplied")!
    let listening = hub.listen(id: "page-c1", url: address, transport: .ipc, source: "page", shown: address.absoluteString,
                               sink: { pushed["page-c1", default: []] += $0 })
    check("REQ-016 a callback no channel answers yet is accepted and waits, without a preparation",
          listening == .accepted(protocol: nil, frames: []) && hub.connections.isEmpty
          && logs.contains { $0.contains("IPC callback http://electron.ipc/desk/settings/onDocumentApplied · page · listening") }, logs.joined(separator: "\n"))
    var registered = box.sim.spec
    registered.channels = [StudioChannel(id: "applied", path: "http://electron.ipc/desk/settings/onDocumentApplied", wire: .raw,
                                         onConnect: [StudioChannelMessage(data: json(#"{"ready":true}"#))],
                                         links: [StudioChannelLink(entity: "documents", on: [.update], message: StudioChannelMessage(data: .string("{{record}}")))])]
    box.sim.replaceSpec(registered)
    hub.openListeners()
    check("REQ-016 a waiting callback opens when its channel is registered and gets its first message", hub.connections["page-c1"] != nil
          && texts(pushed["page-c1"] ?? []) == [#"{"ready":true}"#], "\(pushed)")
    hub.entitiesChanged([StudioEntityChange(entity: "documents", kind: .update, record: json(#"{"id":"current","theme":"light"}"#),
                                            old: json(#"{"id":"current","theme":"dark"}"#))])
    check("REQ-016 a write of the linked entity reaches the callback", texts(pushed["page-c1"] ?? []).last == #"{"id":"current","theme":"light"}"#,
          "\(texts(pushed["page-c1"] ?? []))")
    _ = hub.listen(id: "page-c2", url: URL(string: "http://electron.ipc/desk/orders/onOrderUpdate")!, transport: .ipc, source: "page",
                   shown: "onOrderUpdate", sink: { _ in })
    hub.close(id: "page-c2", code: nil)
    var more = box.sim.spec
    more.channels = (more.channels ?? []) + [StudioChannel(id: "orders", path: "http://electron.ipc/desk/orders/onOrderUpdate")]
    box.sim.replaceSpec(more)
    hub.openListeners()
    check("REQ-016 an unsubscribed callback does not open later", hub.connections["page-c2"] == nil)
    _ = hub.listen(id: "page-c3", url: URL(string: "http://electron.ipc/desk/x/onLater")!, transport: .ipc, source: "page", shown: "onLater", sink: { _ in })
    hub.closeAll(source: "page")
    more.channels = (more.channels ?? []) + [StudioChannel(id: "later", path: "http://electron.ipc/desk/x/onLater")]
    box.sim.replaceSpec(more)
    hub.openListeners()
    check("REQ-016 a new page drops the callbacks of the old one", hub.connections.isEmpty)
}

// MARK: - Fix data (REQ-017)



// MARK: - Run

let done = DispatchSemaphore(value: 0)
Task { @MainActor in
    await channelChecks()
    await ipcChecks()
    done.signal()
}
while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
print(failures == 0 ? "All UI Studio checks passed." : "\(failures) UI Studio check(s) failed.")
exit(failures == 0 ? 0 : 1)
