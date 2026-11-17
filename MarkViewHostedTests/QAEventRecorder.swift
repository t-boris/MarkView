import Foundation
@testable import MarkView

// unchecked Sendable: the runner owns the recorder during a run; the waiting test reads it only after completion.
final class QAEventRecorder: QARunObserver, @unchecked Sendable {
    var events: [QARunEvent] = []
    var onEvent: ((QARunEvent) -> Void)?
    func handle(_ event: QARunEvent) { events.append(event); onEvent?(event) }
    var narrations: [QATimelineEntry] { events.compactMap { if case .narration(let entry) = $0 { return entry } else { return nil } } }
    var shown: [QAScreenEvent] { events.compactMap { if case .screen(let screen) = $0 { return screen } else { return nil } } }
    var screens: [(isNew: Bool, png: Data?)] { shown.map { ($0.isNew, $0.png) } }
}
