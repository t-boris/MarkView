import Foundation
import MarkViewCore

/// A running or failed AI tool run (diagram, code map, review, audit) that works inside a headless
/// agent. Shown by `AIToolJobsBanner`; a successful run disappears and opens its result.
struct AIToolJob: Identifiable, Equatable {
    enum Phase: Equatable { case running, failed(String) }
    let id = UUID()
    var title: String
    var stage = "Starting"
    var phase = Phase.running
    let started = Date()
}

@MainActor
final class AIToolJobs: ObservableObject {
    @Published private(set) var jobs: [AIToolJob] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Handed to the work closure to report progress.
    struct Handle {
        let id: UUID
        let jobs: AIToolJobs
        func stage(_ text: String) { Task { @MainActor in jobs.setStage(id, text) } }
    }

    /// Runs `work`; its returned file is opened by `onDone`. A failure keeps the job listed with its error.
    func start(title: String, work: @escaping @MainActor (Handle) async throws -> URL?,
               onDone: @escaping @MainActor (URL?) -> Void) {
        let job = AIToolJob(title: title)
        jobs.append(job)
        let handle = Handle(id: job.id, jobs: self)
        tasks[job.id] = Task { @MainActor in
            do {
                let url = try await work(handle)
                finish(job.id)
                onDone(url)
            } catch is CancellationError {
                finish(job.id)
            } catch {
                if let i = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[i].phase = .failed(error.localizedDescription)
                }
                tasks[job.id] = nil
            }
        }
    }

    func isRunning(title: String) -> Bool {
        jobs.contains { $0.title == title && $0.phase == .running }
    }

    func cancel(_ id: UUID) { tasks[id]?.cancel() }

    func dismiss(_ id: UUID) {
        tasks[id]?.cancel()
        finish(id)
    }

    private func setStage(_ id: UUID, _ text: String) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].phase == .running else { return }
        jobs[i].stage = text
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        jobs.removeAll { $0.id == id }
    }
}
