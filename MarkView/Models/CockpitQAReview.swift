import Foundation

enum CockpitQAReviewBuilder {
    enum Failure: LocalizedError {
        case unapprovable([String])
        var errorDescription: String? {
            switch self { case .unapprovable(let problems): return problems.joined(separator: " ") }
        }
    }

    static func make(scenario: QAScenario, targetID: String, savedLogins: Set<QALoginReference>) throws -> CockpitQAReview {
        let plan = QAPlanner.make(scenario, targetID: targetID, savedLogins: savedLogins)
        guard plan.canBeApproved else { throw Failure.unapprovable(plan.blockingProblems.map(\.message)) }
        let presented = CockpitQAPresented(scenario: scenario, targetID: targetID, selectedBranches: plan.branches.map(\.id),
            preparation: plan.preparation.map { .init(id: $0.id, kind: $0.kind.rawValue, title: $0.title, detail: $0.detail, changesData: $0.changesData.rawValue, manual: $0.manual) },
            confirmations: plan.confirmations.map { .init(id: $0.id, title: $0.title, reason: $0.reason, manual: $0.manual) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let exact = String(decoding: try encoder.encode(presented), as: UTF8.self)
        let changing = plan.isProduction ? plan.confirmations.filter { confirmation in
            guard confirmation.manual else { return true }
            return plan.preparation.first(where: { $0.id == confirmation.id })?.changesData != .no
        }.map { "\($0.id): \($0.title) — \($0.reason)" } : []
        return CockpitQAReview(scenarioID: scenario.id, targetID: targetID, fingerprint: plan.fingerprint,
                               production: plan.isProduction, exactPlan: exact, dataChangingActions: changing,
                               productionConfirmationRequired: plan.isProduction && !plan.confirmations.isEmpty)
    }
}

/// What the person approves for one QA scenario, as the exact JSON `CockpitQAReview.exactPlan` holds. The review builder encodes it and
/// the plan screen decodes the same text, so what is drawn is what was approved.
struct CockpitQAPresented: Codable, Equatable {
    struct Preparation: Codable, Equatable {
        var id: String; var kind: String; var title: String; var detail: String
        var changesData: String; var manual: Bool
    }
    struct Confirmation: Codable, Equatable { var id: String; var title: String; var reason: String; var manual: Bool }
    var scenario: QAScenario
    var targetID: String
    var selectedBranches: [String]
    var preparation: [Preparation]
    var confirmations: [Confirmation]

    /// nil when the text is not in this shape; the screen then shows the exact text only.
    init?(exactPlan: String) {
        guard let value = try? JSONDecoder().decode(CockpitQAPresented.self, from: Data(exactPlan.utf8)) else { return nil }
        self = value
    }

    init(scenario: QAScenario, targetID: String, selectedBranches: [String], preparation: [Preparation], confirmations: [Confirmation]) {
        self.scenario = scenario; self.targetID = targetID; self.selectedBranches = selectedBranches
        self.preparation = preparation; self.confirmations = confirmations
    }
}
