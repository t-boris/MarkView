import Foundation
import CryptoKit
import Darwin

struct CockpitTLSFiles: Codable { var ca: String; var cert: String; var key: String }
struct CockpitEndpoint: Codable { var address: String; var tls: CockpitTLSFiles }
struct CockpitTemporalStep: Codable { var id: String; var title: String; var agent: String; var assignment: String; var completionCondition: String; var prerequisite: Bool; var qaScenarioID: String? }
struct CockpitTemporalPlan: Codable {
    var fingerprint: String
    var goal: String
    var controls: String
    var successCriteria: [String]
    var steps: [CockpitTemporalStep]

    init(_ plan: CockpitPlan) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(plan)
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        goal = plan.goal
        controls = String(decoding: try encoder.encode(plan.controls), as: UTF8.self)
        successCriteria = plan.successCriteria
        steps = plan.steps.map { CockpitTemporalStep(id: $0.id.uuidString, title: $0.title, agent: $0.agent, assignment: $0.assignment, completionCondition: $0.completionCondition, prerequisite: $0.isPrerequisite, qaScenarioID: $0.qaScenarioID) }
    }
}
struct CockpitTemporalApproval: Codable { var fingerprint: String; var step: Int }
struct CockpitTemporalRequest: Codable {
    var address: String
    var queue: String
    var workflowID: String
    var action: String
    var plan: CockpitTemporalPlan?
    var approval: CockpitTemporalApproval?
    var command: String?
    var tls: CockpitTLSFiles
}

/// One service per project within this app process. Windows use their own workers and private host sockets.
@MainActor
final class CockpitService {
    enum Failure: LocalizedError {
        case missingRuntime, invalidResponse, command
        var errorDescription: String? {
            switch self {
            case .missingRuntime: return "The local cockpit runtime is not included in this build."
            case .invalidResponse: return "The local cockpit runtime returned an invalid response."
            case .command: return "The local cockpit runtime could not perform the request."
            }
        }
    }
    private static var services: [String: CockpitService] = [:]
    static func forProject(_ root: URL) -> CockpitService {
        let root = root.standardizedFileURL
        if let existing = services[root.path] { return existing }
        let service = CockpitService(root: root); services[root.path] = service; return service
    }

    private let root: URL
    private let bundledOverride: URL?
    private var startup: Task<CockpitEndpoint, Error>?
    private var server: CockpitChild?
    init(root: URL, bundled: URL? = nil) { self.root = root; self.bundledOverride = bundled }

    private var bundled: URL? {
        if let bundledOverride { return bundledOverride }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        return Bundle.main.resourceURL?.appendingPathComponent("Cockpit/" + arch, isDirectory: true)
    }

    func start() async throws -> CockpitEndpoint {
        if let startup {
            let endpoint = try await startup.value
            if server?.isRunning == true { return endpoint }
            self.startup = nil
            server = nil
        }
        guard let bundled else { throw Failure.missingRuntime }
        let state = root.appendingPathComponent(".dde/cockpit/temporal", isDirectory: true)
        let runtime = URL(fileURLWithPath: "/tmp/mvt-" + UUID().uuidString.lowercased(), isDirectory: true)
        let startup = Task { [weak self] () throws -> CockpitEndpoint in
            let serverURL = bundled.appendingPathComponent("bin/server")
            let postgres = bundled.appendingPathComponent("postgres")
            let supervisor = bundled.appendingPathComponent("bin/postgres-supervisor")
            let available = await Task.detached { () -> Bool in
                guard FileManager.default.isExecutableFile(atPath: serverURL.path),
                      FileManager.default.isExecutableFile(atPath: supervisor.path),
                      FileManager.default.fileExists(atPath: postgres.path) else { return false }
                return mkdir(runtime.path, 0o700) == 0
            }.value
            guard available else { throw Failure.missingRuntime }
            let (child, data) = try await CockpitChild.launch(executable: serverURL, arguments: ["--runtime", runtime.path, "--state", state.path,
                                                                                              "--postgres", postgres.path, "--supervisor", supervisor.path], onExit: {
                // Only remove the app-created per-launch directory, after its server has exited.
                try? FileManager.default.removeItem(at: runtime)
            })
            guard let endpoint = try? JSONDecoder().decode(CockpitEndpoint.self, from: data) else { child.stop(); throw Failure.invalidResponse }
            self?.server = child
            return endpoint
        }
        self.startup = startup
        do { return try await startup.value } catch { self.startup = nil; throw error }
    }

    func worker(socket: String, queue: String) async throws -> CockpitChild {
        let endpoint = try await start()
        guard let bundled else { throw Failure.missingRuntime }
        let (child, data) = try await CockpitChild.launch(executable: bundled.appendingPathComponent("bin/worker"), arguments: [
            "--address", endpoint.address, "--queue", queue, "--socket", socket,
            "--ca", endpoint.tls.ca, "--cert", endpoint.tls.cert, "--key", endpoint.tls.key
        ])
        guard let ready = try? JSONDecoder().decode([String: Bool].self, from: data), ready["ready"] == true else { child.stop(); throw Failure.invalidResponse }
        return child
    }

    func request(_ request: CockpitTemporalRequest) async throws -> Data {
        guard let bundled else { throw Failure.missingRuntime }
        let data = try JSONEncoder().encode(request)
        let result = await ProcessRunner.run(executable: bundled.appendingPathComponent("bin/control").path, arguments: [], stdin: String(decoding: data, as: UTF8.self), timeout: 30)
        guard result.succeeded, !result.truncated, let output = result.stdout.data(using: .utf8) else { throw Failure.command }
        return output
    }

    func stop() {
        startup?.cancel()
        startup = nil
        server?.stop()
        server = nil
    }
}
