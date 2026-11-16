import Foundation
#if canImport(MarkViewCore)
import MarkViewCore
#endif

/// Every request of the page and of the development server, and every simulated connection (REQ-007, REQ-015, BUG-074, BUG-089): the
/// decision for a request (pass it, answer it from the simulation, prepare rules for it), the WebSocket, EventSource and Socket.IO
/// channels, the answers the simulation gave (for Fix data), and the rules that arrive after their page rendered.
@MainActor
final class StudioRequestPath: ObservableObject {
    /// Unowned: the session owns this part. A task of this part starts through `session.startPartTask`, which holds the session until it ends.
    unowned let session: StudioSession

    @Published private(set) var requests: [StudioSession.RequestRecord] = []

    /// The simulated WebSocket, EventSource and Socket.IO connections of the page and of the server (REQ-015).
    private(set) lazy var channels = makeChannelHub()

    /// Frames pushed to the page, one after the other.
    private var channelDeliveries: Task<Void, Never>?

    /// The generation that already reloaded for rules that arrived late (at most once per generation).
    private var reloadedForRules: Int?

    /// Rules arrived for a server request after its page had rendered, and the page was not reloaded by itself because the
    /// person had typed into it: the banner offers Reload (BUG-074).
    @Published var rulesArrivedLate = false

    /// A request of the page. One that goes to a gateway port (a public variable inlined in the page's code) is the
    /// service's request and keeps the service's address (REQ-007).
    func handle(_ request: StudioBridge.Request, reply: @escaping (Any?, String?) -> Void) {
        let http = StudioHTTPRequest(method: request.method, url: logicalURL(for: request.url) ?? request.url, headers: request.headers,
                                     body: request.body, requestId: request.requestId)
        route(http, source: .page) { answer in
            switch answer {
            case .respond(let response): reply(StudioBridge.reply(response), nil)
            case .pass(let headers): reply(headers.isEmpty ? StudioBridge.passThrough : StudioBridge.passThrough(adding: headers), nil)
            case .dropped(let reason): reply(nil, reason)
            }
        }
    }

    /// A request the development server made through a simulated connection (REQ-007): answered by the same simulation as
    /// the page's requests, under the service's own address.
    func handleServerRequest(_ request: StudioGatewayRequest, reply: @escaping @Sendable (StudioGatewayResponse) -> Void) {
        func plain(_ status: Int, _ text: String) -> StudioGatewayResponse {
            StudioGatewayResponse(status: status, headers: ["content-type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }
        guard !session.closed, let connection = session.serverConnections.first(where: { $0.variable == request.variable && $0.mode == .simulated }),
              let url = URL(string: connection.origin + request.target) else {
            return reply(plain(503, "MarkView UI Studio has no simulated connection for this address."))
        }
        let http = StudioHTTPRequest(method: request.method, url: url, headers: request.headers,
                                     body: request.body.map { String(decoding: $0, as: UTF8.self) }, requestId: UUID().uuidString)
        route(http, source: .server(variable: request.variable)) { answer in
            switch answer {
            case .respond(let response):
                reply(StudioGatewayResponse(status: response.status, headers: response.headers, body: response.body.map { Data($0.utf8) },
                                            delayMs: response.delayMs, hang: response.hang))
            case .pass:
                reply(plain(502, "MarkView UI Studio answers simulated connections only; switch \(request.variable) to Real to reach the service."))
            case .dropped(let reason):
                reply(plain(503, "The simulated answer was dropped (\(reason))."))
            }
        }
    }

    /// The service address behind a gateway port.
    func logicalURL(for url: URL) -> URL? {
        guard let host = url.host, ["127.0.0.1", "localhost"].contains(host), let port = url.port,
              let variable = session.gatewayPorts.first(where: { Int($0.value) == port })?.key,
              let connection = session.serverConnections.first(where: { $0.variable == variable }),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let target = (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
            + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        return URL(string: connection.origin + target)
    }

    /// The simulation's answer to `http`; a write that changed the state is pushed to the channels and GraphQL
    /// subscriptions (REQ-015).
    private func simulate(_ http: StudioHTTPRequest) -> StudioSimOutcome {
        let before = http.isWrite ? session.simulator.state : nil
        let outcome = session.simulator.handle(http)
        if let before { channels.entitiesChanged(StudioEntityChange.diff(before: before, after: session.simulator.state, spec: session.simulator.spec)) }
        if case .respond(let response, let rule) = outcome {
            noteServed(rule)
            noteAnswer(response, rule: rule)
        }
        return outcome
    }

    /// The latest answers the simulation gave the page since it was loaded, the most recent first, for Fix data (REQ-017):
    /// the rule, the entities it reads and the body as sent, redacted and cut.
    private(set) var servedAnswers: [StudioDataFix.Served] = []

    /// A Reset starts a new page: the answers the old one was given are not for Fix data any more.
    func forgetServedAnswers() { servedAnswers = [] }

    private func noteAnswer(_ response: StudioSimResponse, rule id: String) {
        guard let rule = session.simulator.spec.rules.first(where: { $0.id == id }) else { return }
        // Cut first, so a large list costs nothing; redact a longer piece than is kept, so a secret cut at the edge is gone.
        let piece = String((response.body ?? "").prefix(StudioDataFix.answerChars * 3))
        let body = String(StudioLogFormat.redact(piece, redactor: session.redactor, hashes: session.secretHashes).prefix(StudioDataFix.answerChars))
        let entities = [rule.entity].compactMap { $0 } + (rule.include ?? []).map(\.entity)
        servedAnswers.insert(StudioDataFix.Served(ruleId: rule.id, method: rule.method.uppercased(), path: rule.path,
                                                  operation: rule.operation.rawValue, entities: entities, status: response.status,
                                                  body: body), at: 0)
        if servedAnswers.count > StudioDataFix.servedKept { servedAnswers.removeLast() }
    }

    /// The rules that answered the page, the most recent first (BUG-084): a context change sees them, and the shape of
    /// their fixed answers, before the environment's other rules.
    private(set) var servedRules: [String] = []

    private func noteServed(_ rule: String) {
        guard servedRules.first != rule else { return }
        servedRules.removeAll { $0 == rule }
        servedRules.insert(rule, at: 0)
        if servedRules.count > Self.servedRulesKept { servedRules.removeLast() }
    }

    static let servedRulesKept = 100

    private func makeChannelHub() -> StudioChannelHub {
        StudioChannelHub(environment: StudioChannelHub.Environment(
            spec: { [weak self] in self?.session.simulator.spec ?? StudioEnvironmentSpec() },
            state: { [weak self] in self?.session.simulator.state ?? [:] },
            appOrigin: { [weak self] in self?.session.appOrigin?.text },
            perform: { [weak self] operation, entity, id, fields in
                guard let self else { return .json(503, nil) }
                let before = self.session.simulator.state
                let response = self.session.simulator.perform(operation, entity: entity, id: id, fields: fields)
                self.pushChanges(since: before)
                return response
            },
            graphQL: { [weak self] url, payload in
                guard let self else { return .null }
                let http = StudioHTTPRequest(method: "POST", url: url, headers: ["content-type": "application/json"], body: payload.text,
                                             requestId: UUID().uuidString)
                let before = self.session.simulator.state
                let outcome = self.session.simulator.handle(http)
                self.pushChanges(since: before)
                func errors(_ message: String) -> StudioJSON { .object(["errors": .array([StudioGraphQLExecutor.error(message)])]) }
                switch outcome {
                case .respond(let response, _):
                    return response.body.flatMap { StudioJSON(text: $0) } ?? .null
                case .unknown(let contract):
                    // Prepared now, so the client's next try is answered.
                    self.prepare(http, contract: contract, source: .page) { _ in }
                    return errors("MarkView UI Studio is preparing a simulation rule for \(contract); try again in a moment.")
                case .unsupported(_, let reason):
                    return errors("MarkView UI Studio does not simulate \(reason).")
                }
            },
            redact: { [weak self] json in self?.session.redactor.redact(json) ?? json },
            log: { [weak self] text, problem in self?.session.sessionLog.add(.request, problem: problem, text) }
        ))
    }

    /// Writes made while a channel message is answered reach the subscribers after that answer.
    private func pushChanges(since before: [String: [StudioJSON]]) {
        let changes = StudioEntityChange.diff(before: before, after: session.simulator.state, spec: session.simulator.spec)
        guard !changes.isEmpty else { return }
        session.startPartTask { _ in self.channels.entitiesChanged(changes) }
    }

    /// A page WebSocket or EventSource on a simulated channel. One to a gateway port (a public variable inlined in the
    /// page's code) keeps the service's address, like a request.
    func handleChannel(_ message: StudioBridge.Channel, reply: @escaping (Any?, String?) -> Void) {
        let id = "page-" + message.id
        switch message.action {
        case .open:
            guard let asked = message.url else { return reply(nil, "No URL.") }
            let answer: (StudioChannelHub.Opening) -> Void = { opening in
                switch opening {
                case .accepted(let chosen, let frames):
                    reply(["ok": true, "protocol": chosen ?? "", "frames": frames.map(\.bridgeValue)], nil)
                case .refused(let reason), .unknown(let reason):
                    reply(["ok": false, "code": 1006, "reason": String(reason.prefix(120))], nil)
                }
            }
            if message.transport == .ipc {
                // A callback of the Electron preload bridge (REQ-016): it listens until a channel answers its address, and
                // is never prepared on its own; the bridge's methods are.
                let shown = session.redactor.redact(text: StudioConnections.redact(asked.absoluteString, hashes: session.secretHashes))
                return answer(channels.listen(id: id, url: asked, transport: .ipc, source: "page", shown: shown, sink: pageSink(message.id)))
            }
            let http = StudioChannelRoute.httpURL(asked)
            let transport: StudioChannelTransport = message.transport == .eventSource ? .eventSource : .webSocket
            openChannel(id: id, url: logicalURL(for: http) ?? http, protocols: message.protocols, transport: transport, source: .page,
                        sink: pageSink(message.id), done: answer)
        case .send:
            var frames: [StudioChannelFrame] = []
            if let text = message.text { frames = channels.receive(id: id, text: text) }
            else if let data = message.binary { frames = channels.receive(id: id, binary: data) }
            reply(["frames": frames.map(\.bridgeValue)], nil)
        case .close:
            channels.close(id: id, code: message.code)
            reply(["ok": true], nil)
        }
    }

    /// Tell the person about a page-initiated protocol that cannot be simulated without disturbing a pending turn.
    private func noteUnsupportedChannel(contract: String, reason: String) {
        let request = session.redactor.redact(text: "Unsupported connection: " + contract)
        let answer = session.redactor.redact(text: "MarkView UI Studio does not simulate \(contract): \(reason)")
        guard !session.conversation.contains(where: { $0.request == request && $0.answer == answer }) else { return }
        var operation = StudioOperation(id: session.historyStore.newOperationID(), kind: .question, request: request, status: .answered)
        operation.answer = answer
        session.historyStore.append(operation, endsPendingTurn: false)
    }

    /// Frames for page connection `pageID`, delivered in order to the page of the current generation.
    private func pageSink(_ pageID: String) -> StudioChannelHub.Sink {
        { [weak self] frames in
            guard let self, !frames.isEmpty else { return }
            let generation = self.session.simulator.generation
            let values = frames.map(\.bridgeValue)
            let previous = self.channelDeliveries
            self.channelDeliveries = self.session.startPartTask { session in
                await previous?.value
                guard !session.closed, session.simulator.generation == generation else { return }
                _ = try? await session.call("return window.__markviewStudio ? window.__markviewStudio.deliver(id, frames) : false;",
                                            ["id": pageID, "frames": values])
            }
        }
    }

    /// Opens a channel connection; an address no channel answers yet is prepared first (the connection waits), like an
    /// unknown request. It never reaches a real service.
    private func openChannel(id: String, url: URL, protocols: [String], transport: StudioChannelTransport, source: StudioRequestSource,
                             sink: @escaping StudioChannelHub.Sink, done: @escaping (StudioChannelHub.Opening) -> Void) {
        let shown = session.redactor.redact(text: StudioConnections.redact(url.absoluteString, hashes: session.secretHashes))
        let opening = channels.open(id: id, url: url, protocols: protocols, transport: transport, source: source.transport, shown: shown, sink: sink)
        guard case .unknown(let contract) = opening else { return done(opening) }
        let kind = transport.label
        session.sessionLog.add(.request, "\(kind) \(shown) · \(source.transport) · preparing")
        var headers = transport == .eventSource ? ["accept": "text/event-stream"] : ["upgrade": "websocket"]
        if !protocols.isEmpty { headers["sec-websocket-protocol"] = protocols.joined(separator: ", ") }
        let context = StudioPreparationContext(contract: contract, method: "GET", url: shown, headers: headers, body: nil, attempt: 1, problems: [],
                                               serverVariable: source.variable, group: StudioBridge.Origin(url: url)?.text)
        let generation = session.simulator.generation
        let preparer = makePreparer()
        session.updateReadiness()
        session.startPartTask { session in
            let outcome = await session.preparation.resolve(context, generation: generation, preparer: preparer,
                                                            currentGeneration: { session.simulator.generation },
                                                            commit: { session.commit($0) })
            guard !session.closed else { return done(.refused("The session is closed.")) }
            var reason: String?
            switch outcome {
            case .registered:
                let again = self.channels.open(id: id, url: url, protocols: protocols, transport: transport, source: source.transport,
                                               shown: shown, sink: sink)
                if case .unknown = again { reason = "the rules registered for it do not answer this connection." } else { done(again) }
            case .unsupported(let why):
                session.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: why))
                self.noteUnsupportedChannel(contract: contract, reason: why)
                session.sessionLog.add(.request, problem: true, "\(kind) \(shown) · \(source.transport) · unsupported: \(why)")
                done(.refused("MarkView UI Studio does not simulate \(contract): \(why)"))
            case .stale:
                done(.refused("The simulation was reset."))
            default:
                reason = session.preparation.records[contract]?.message ?? "it could not be prepared."
            }
            if let reason {
                session.noteDependency(StudioDependency(id: contract, mode: .unresolved, note: reason))
                session.sessionLog.add(.request, problem: true, "\(kind) \(shown) · \(source.transport) · unresolved: \(reason)")
                done(.refused("MarkView UI Studio has no simulation rule for \(contract): \(reason)"))
            }
            session.updateReadiness()
        }
    }

    /// A WebSocket or event stream the development server opened to a simulated connection's gateway port.
    func handleServerStream(_ event: StudioGatewayStreamEvent, on gateway: StudioGateway) {
        switch event {
        case .open(let stream, let kind, let request):
            guard !session.closed, let connection = session.serverConnections.first(where: { $0.variable == request.variable && $0.mode == .simulated }),
                  let url = URL(string: connection.origin + request.target) else {
                return gateway.refuseStream(stream, status: 503, "MarkView UI Studio has no simulated connection for this address.")
            }
            var protocols: [String] = []
            var transport = StudioChannelTransport.eventSource
            if case .webSocket(let asked) = kind {
                protocols = asked
                transport = .webSocket
            }
            openChannel(id: "server-\(stream)", url: url, protocols: protocols, transport: transport, source: .server(variable: request.variable),
                        sink: { [weak gateway] frames in frames.forEach { gateway?.sendStream(stream, $0) } }) { [weak gateway] opening in
                switch opening {
                case .accepted(let chosen, let frames):
                    gateway?.acceptStream(stream, protocol: chosen)
                    frames.forEach { gateway?.sendStream(stream, $0) }
                case .refused(let reason), .unknown(let reason):
                    gateway?.refuseStream(stream, status: 404, reason)
                }
            }
        case .text(let stream, let text):
            channels.receive(id: "server-\(stream)", text: text).forEach { gateway.sendStream(stream, $0) }
        case .binary(let stream, let data):
            channels.receive(id: "server-\(stream)", binary: data).forEach { gateway.sendStream(stream, $0) }
        case .closed(let stream, let code):
            channels.close(id: "server-\(stream)", code: code)
        }
    }

    /// The session's decision for any request, from the page or from the server: pass it to its address, answer it from
    /// the simulation, or prepare rules for it.
    func route(_ http: StudioHTTPRequest, source: StudioRequestSource, reply: @escaping (StudioReply) -> Void) {
        let shown = session.redactor.redact(text: StudioConnections.redact(http.url.absoluteString, hashes: session.secretHashes))
        let contract = StudioRoute.contractKey(method: http.method, url: http.url, appOrigin: session.appOrigin?.text)
        let transport = source.transport
        let sameServer = source == .page && (StudioBridge.Origin(url: http.url).map { session.appOrigin?.sameServer($0) == true } ?? false)
        // The Electron preload bridge (REQ-016) is a logical address: always simulated, never passed through.
        let ipc = StudioIPC.isIPC(http.url)
        if sameServer && StudioConnectionPolicy.isFrameworkRequest(http.url, headers: http.headers) {
            log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil, transport: transport))
            return reply(.pass(adding: StudioConnectionPolicy.frameworkRequestHeaders))
        }
        // The server's connections are switched by the person (Simulated or Real), not by the page's allowed addresses.
        if (sameServer && session.ownsServer && session.target?.usesIsolatedBackend == true)
            || (sameServer && StudioConnectionPolicy.isDevelopmentResource(http.url, appFolder: session.appFolder))
            || (source == .page && !ipc && session.spec.allowedRequests.contains(where: { StudioRoute.allows($0, url: http.url, appOrigin: session.appOrigin?.text) })) {
            if !sameServer { session.noteDependency(StudioDependency(id: contract, mode: .allowed, note: "Allowed by the connection policy.")) }
            log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "allowed", status: nil, transport: transport))
            return reply(.pass(adding: [:]))
        }
        if !ipc, channels.poll(http, source: transport, shown: shown, reply: { reply(.respond($0)) }) { return }
        switch simulate(http) {
        case .respond(let response, _):
            log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status, transport: transport))
            reply(.respond(response))
        case .unsupported(let contract, let reason):
            session.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason + " are not simulated."))
            log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "unsupported", status: 501, transport: transport))
            reply(.respond(.unsupported(contract, reason: reason)))
            session.updateReadiness()
        case .unknown(let contract):
            log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "preparing", status: nil, transport: transport))
            prepare(http, contract: contract, source: source, reply: reply)
        }
    }

    /// An unknown request (SIM-07): the assistant prepares rules for it within the session's limits; the request waits for
    /// them or ends in a controlled error. It never goes to a real service.
    private func prepare(_ http: StudioHTTPRequest, contract: String, source: StudioRequestSource, reply: @escaping (StudioReply) -> Void) {
        let generation = session.simulator.generation
        let hashes = session.secretHashes
        var body = http.body.map { session.redactor.redact(body: StudioConnections.redact($0, hashes: hashes)) }
        if let text = body, text.count > 4_000 { body = String(text.prefix(4_000)) }
        let headers = session.redactor.redact(headers: http.headers).mapValues { StudioConnections.redact($0, hashes: hashes) }
        let shown = session.redactor.redact(text: StudioConnections.redact(http.url.absoluteString, hashes: hashes))
        let group = StudioBridge.Origin(url: http.url)?.text
        let baseContext = StudioPreparationContext(contract: contract, method: http.method, url: shown, headers: headers, body: body,
                                                   attempt: 1, problems: [], serverVariable: source.variable, group: group)
        let preparer = makePreparer()
        let asked = Date()
        session.updateReadiness()
        session.startPartTask { session in
            var context = baseContext
            // A page's request answers within `provisionalAfter` seconds, whatever the preparation needs (BUG-089); the rule that
            // arrives later loads the page again once. Requests of the development server keep waiting: it renders from them.
            let answer = StudioReplyOnce(reply)
            let provisionalTimer: Task<Void, Never>? = source.variable == nil ? session.startPartTask { session in
                try? await Task.sleep(nanoseconds: UInt64(Self.provisionalAfter * 1_000_000_000))
                guard !Task.isCancelled, !session.closed, session.simulator.generation == generation, answer.reply(.respond(.preparing(contract))) else { return }
                self.provisional[generation, default: []].insert(contract)
                self.log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "preparing", status: 503, transport: source.transport))
                session.sessionLog.add(.notice, "\(contract) has no rule yet: the page got a 503 \"preparing\" after \(Int(Self.provisionalAfter)) s and is loaded again when the rule is ready")
            } : nil
            defer { provisionalTimer?.cancel() }
            if source.variable == nil, let hint = await self.handlerHint(for: http) {
                context.handlerFile = hint.file
                context.handlerText = hint.text
            }
            // A request whose endpoint a group of the application's map is preparing waits for that group (REQ-014).
            await session.mapping.waitForEndpoint(http.method, url: http.url)
            // A request to a service that is being prepared waits for it: that preparation often registers this rule too.
            if let group {
                await session.preparation.waitForGroup(group)
                guard !session.closed else { return answer(.dropped("closed")) }
                if session.simulator.generation == generation, case .respond(let response, _) = self.simulate(http) {
                    self.log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status,
                                           transport: source.transport))
                    answer(.respond(response))
                    self.noteLateRules(source: source, asked: asked)
                    return session.updateReadiness()
                }
            }
            // A rule belongs to the environment: it is registered even when the scenario changed while it was prepared (BUG-089).
            let outcome = await session.preparation.resolve(context, generation: generation, preparer: preparer,
                                                            currentGeneration: { generation },
                                                            commit: { session.commit($0) })
            guard !session.closed else { return answer(.dropped("closed")) }
            var registered = false
            switch outcome {
            case .registered:
                registered = true
                if answer.delivered {
                    // The page was answered "preparing": it is loaded again below and then served from this rule.
                } else if session.simulator.generation != generation {
                    answer(.dropped("stale"))
                } else if case .respond(let response, _) = self.simulate(http) {
                    self.log(StudioSession.RequestRecord(method: http.method, url: shown, contract: contract, outcome: "simulated", status: response.status,
                                           transport: source.transport))
                    answer(.respond(response))
                } else {
                    answer(.respond(.unresolved(contract, reason: "the rules registered for it do not answer this request.")))
                }
                self.noteLateRules(source: source, asked: asked)
            case .unsupported(let reason):
                session.noteDependency(StudioDependency(id: contract, mode: .unsupported, note: reason))
                answer(.respond(.unsupported(contract, reason: reason)))
            case .stale:
                answer(.dropped("stale"))
            default:
                let reason = session.preparation.records[contract]?.message ?? "it could not be prepared."
                session.noteDependency(StudioDependency(id: contract, mode: .unresolved, note: reason))
                answer(.respond(.unresolved(contract, reason: reason)))
            }
            if self.provisional[generation]?.contains(contract) == true {
                self.provisionalEnded(contract, generation: generation, registered: registered)
            }
            session.updateReadiness()
        }
    }

    /// Prepares the rule for a request a scenario names although no rule serves it (a context change). It waits for the preparation,
    /// which has its own deadlines, and returns whether a rule now serves the request. There is no real request to show the assistant,
    /// only its method and address; the rule is prepared from the application's code like any other.
    func prepareNamedRequest(method: String, path: String) async -> Bool {
        let text = path.hasPrefix("/") ? (session.appOrigin?.text ?? "") + path : path
        guard let url = URL(string: text), url.host != nil else { return false }
        let generation = session.simulator.generation
        let contract = StudioRoute.contractKey(method: method, url: url, appOrigin: session.appOrigin?.text)
        let shown = session.redactor.redact(text: StudioConnections.redact(url.absoluteString, hashes: session.secretHashes))
        let context = StudioPreparationContext(contract: contract, method: method.uppercased(), url: shown, headers: [:], body: nil, attempt: 1,
                                               problems: [], group: StudioBridge.Origin(url: url)?.text)
        session.showBusyDetail("Preparing the rule for \(contract)")
        if let group = context.group { await session.preparation.waitForGroup(group) }
        let outcome = await session.preparation.resolve(context, generation: generation, preparer: makePreparer(), currentGeneration: { generation },
                                                commit: { [weak self] proposal in self?.session.commit(proposal) ?? ["The session is closed."] })
        guard !session.closed else { return false }
        if case .registered = outcome { session.updateReadiness(); return session.spec.rules.contains { $0.method.uppercased() == method.uppercased() && $0.path == path } }
        let reason = session.preparation.records[contract]?.message ?? "it could not be prepared."
        session.sessionLog.add(.preparation, problem: true, "The rule for \(contract) could not be prepared for the scenario: \(reason)")
        return false
    }

    /// A request that was answered "preparing" has its rule (or has none): once every such request of the generation has ended and
    /// one of them has a rule, the page is loaded again so that it renders with the real answers (BUG-089). Text typed into the
    /// page since its route is never thrown away: the banner offers the reload instead.
    private func provisionalEnded(_ contract: String, generation: Int, registered: Bool) {
        provisional[generation]?.remove(contract)
        if registered { provisionalReady.insert(generation) }
        guard provisional[generation]?.isEmpty ?? true, provisionalReady.contains(generation), session.simulator.generation == generation,
              !session.closed, session.appURL != nil else { return }
        provisionalReady.remove(generation)
        session.startPartTask { session in
            let typed = (try? await session.call("return !!(window.__markviewStudio && window.__markviewStudio.typedSinceRoute && window.__markviewStudio.typedSinceRoute());")) as? Bool ?? false
            guard !session.closed, session.simulator.generation == generation else { return }
            if typed {
                session.sessionLog.add(.notice, "Rules arrived for requests the page was answered \"preparing\"; text was typed into the page, so it is not reloaded by itself (Reload in the banner)")
                self.rulesArrivedLate = true
            } else {
                session.sessionLog.add(.notice, "Rules arrived for requests the page was answered \"preparing\"; the page is loaded again once to render with them")
                session.reloadPage()
            }
        }
    }

    /// The route handlers of the application's own server, read from its folders once per session (BUG-089, BUG-090).
    private var routeIndex: [StudioRouteHandler]?

    func routeHandlers() async -> [StudioRouteHandler] {
        if let routeIndex { return routeIndex }
        let root = session.root, folder = session.appFolder
        let found = await Task.detached(priority: .utility) { StudioRouteScanner.scan(project: root, appFolder: folder) }.value
        routeIndex = found
        return found
    }

    /// The handler that serves a page request to the application's own origin, with the start of its text (redacted): the
    /// agent is told where to look instead of searching the project, which took it a minute or more (BUG-089).
    private func handlerHint(for http: StudioHTTPRequest) async -> (file: String, text: String)? {
        guard let app = session.appURL, let host = http.url.host, host == app.host, http.url.port == app.port else { return nil }
        let handlers = await routeHandlers()
        guard let handler = StudioRouteScanner.handler(for: http.method, path: http.url.path, in: handlers) else { return nil }
        let file = session.root.appendingPathComponent(handler.file)
        let text = await Task.detached(priority: .utility) { () -> String in
            guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
            defer { try? handle.close() }
            return String(decoding: (try? handle.read(upToCount: 6_000)) ?? Data(), as: UTF8.self)
        }.value
        return (handler.file, session.redactor.redact(text: text))
    }

    /// The project's assistant, read-only, preparing rules against the environment as it is now.
    func makePreparer() -> StudioCLIPreparer {
        let relative = session.appFolder.standardizedFileURL.path.dropFirst(session.root.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let usage = session.recordUsage
        return StudioCLIPreparer(project: session.root, appFolder: relative, spec: session.simulator.spec) { input, output, cost in
            // task: a hop onto the main actor from the preparer's callback; it never suspends and touches only the usage closure it holds
            Task { @MainActor in usage(input, output, cost) }
        }
    }

    /// How long a server request may wait for its rules before its page has most likely rendered without them: an
    /// application gives its own calls a deadline of a few seconds (vivaa: 5 s).
    static let lateRules: TimeInterval = 3

    /// How long a page's request waits for its rule to be prepared before it gets the "preparing" answer (BUG-089); a variable
    /// so that a test can shorten it.
    static var provisionalAfter: TimeInterval = 8

    /// Contracts a page's request was answered "preparing" for, by generation, and whether one of them has a rule by now.
    private var provisional: [Int: Set<String>] = [:]

    private var provisionalReady: Set<Int> = []

    /// A server request whose rules arrived after its page rendered without them (BUG-074): the page reloads once so it
    /// renders with the simulation, unless the person typed into it; then the banner offers Reload.
    private func noteLateRules(source: StudioRequestSource, asked: Date) {
        guard source.variable != nil, Date().timeIntervalSince(asked) > Self.lateRules, !session.closed, session.appURL != nil else { return }
        let generation = session.simulator.generation
        guard reloadedForRules != generation else { return }
        reloadedForRules = generation
        session.startPartTask { session in
            let typed = (try? await session.call("return !!(window.__markviewStudio && window.__markviewStudio.typedSinceRoute && window.__markviewStudio.typedSinceRoute());")) as? Bool ?? false
            guard !session.closed, session.simulator.generation == generation else { return }
            let late = "Rules for a request of the server arrived after its page had rendered without them"
            if typed {
                session.sessionLog.add(.notice, late + "; text was typed into the page, so it is not reloaded by itself (Reload in the banner)")
                self.rulesArrivedLate = true
            } else {
                session.sessionLog.add(.notice, late + "; the page is loaded again once to render with them")
                session.reloadPage()
            }
        }
    }

    private func log(_ record: StudioSession.RequestRecord) {
        requests.append(record)
        if requests.count > 400 { requests.removeFirst(requests.count - 400) }
        let answer = record.outcome + (record.status.map { " \($0)" } ?? "")
        session.sessionLog.add(.request, problem: record.outcome == "unsupported" || (record.status ?? 0) >= 500,
                       "\(record.method) \(record.url) · \(record.transport) · \(answer)")
    }

    init(session: StudioSession) {
        self.session = session
    }
}
