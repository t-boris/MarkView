import Foundation

// The Swift side of `Editor/js/bridge-contract.json`: the payload type of every message a first-party page posts. A handler
// registers the type of the message it takes (`TypedWebBridge.on`) and receives the payload decoded into it, after the contract has
// checked the message. Each type's `messageType` and fields are what the contract declares for that message; tools/tests/
// bridge-contract-tests.sh sends a contract-valid sample of every message through these types.

/// The payload of each message of the editor page (channel "bridge" of `Editor/js/bridge-contract.json`). `messageType` is the
/// message's name in the contract; the fields are what the contract declares for it. The contract is checked before a payload is
/// decoded, so a field the contract marks required is never missing here.
enum EditorMessage {
    struct Ready: BridgePayload { static let messageType = "ready" }
    struct SaveRequested: BridgePayload { static let messageType = "saveRequested" }
    struct RefreshRequested: BridgePayload { static let messageType = "refreshRequested" }

    struct ContentChanged: BridgePayload {
        static let messageType = "contentChanged"
        let markdown: String
        let html: String?
    }

    /// The payload is the list of headings itself.
    struct HeadingsUpdated: BridgePayload {
        static let messageType = "headingsUpdated"
        struct Heading: Decodable {
            let id: String
            let level: Int
            let text: String
        }
        let headings: [Heading]
        init(from decoder: Decoder) throws {
            headings = try decoder.singleValueContainer().decode([Heading].self)
        }
    }

    struct ScrollPosition: BridgePayload {
        static let messageType = "scrollPosition"
        let activeHeadingId: String
    }

    struct LinkClicked: BridgePayload {
        static let messageType = "linkClicked"
        let href: String
    }

    struct EditorFontSize: BridgePayload {
        static let messageType = "editorFontSize"
        let size: Double
    }

    struct EditorWindowPref: BridgePayload {
        static let messageType = "editorWindowPref"
        let key: String
        let value: String
    }

    struct CanvasOpenFile: BridgePayload {
        static let messageType = "canvasOpenFile"
        let path: String
    }

    struct TranslateRequested: BridgePayload {
        static let messageType = "translateRequested"
        let markdown: String
        let targetLang: String
    }

    struct SelectionAction: BridgePayload {
        static let messageType = "selectionAction"
        let action: String
        let text: String
    }

    struct FeatureAction: BridgePayload {
        static let messageType = "featureAction"
        let action: String
        let text: String
        let question: String?
    }

    struct GenerateGraph: BridgePayload {
        static let messageType = "generateGraph"
        let type: String?
        let editInstruction: String?
        let currentMermaid: String?
    }

    /// The code viewer's actions; the other fields of each action are read from `BridgeMessage.raw` by the handler's owner.
    struct CodeAction: BridgePayload {
        static let messageType = "code"
        let action: String
    }

    /// The X-Ray tab's actions (see `CodeAction`).
    struct ArchitectureAction: BridgePayload {
        static let messageType = "arch"
        let action: String
    }

    /// The research map's actions (see `CodeAction`).
    struct ResearchMapAction: BridgePayload {
        static let messageType = "researchMap"
        let action: String
    }

    struct JSError: BridgePayload {
        static let messageType = "jsError"
        let `where`: String?
        let message: String?
        let source: String?
        let lineno: Double?
        let colno: Double?
        let stack: String?
    }

    struct InsightIframeReady: BridgePayload {
        static let messageType = "insightIframeReady"
        let sessionId: String
        let nodeId: String
    }

    struct InsightDeepDiveClicked: BridgePayload {
        static let messageType = "insightDeepDiveClicked"
        let sessionId: String
        let sectionId: String
        let topicIndex: Int
    }

    struct InsightBreadcrumbClicked: BridgePayload {
        static let messageType = "insightBreadcrumbClicked"
        let sessionId: String
        let nodeId: String
    }

    struct InsightRequestSave: BridgePayload { static let messageType = "insightRequestSave" }
    struct InsightRequestUp: BridgePayload { static let messageType = "insightRequestUp" }
    struct InsightRequestRegenerate: BridgePayload { static let messageType = "insightRequestRegenerate" }

    struct InsightRequestCustomDeepDive: BridgePayload {
        static let messageType = "insightRequestCustomDeepDive"
        let topic: String
    }

    struct InsightRequestExploreAll: BridgePayload {
        static let messageType = "insightRequestExploreAll"
        let depth: Int?
    }

    struct InsightRequestRetrySection: BridgePayload {
        static let messageType = "insightRequestRetrySection"
        let sectionId: String
    }
}


/// The payload of each message of the terminal page (channel "terminal" of `Editor/js/bridge-contract.json`).
enum TerminalMessage {
    struct Ready: BridgePayload {
        static let messageType = "ready"
        let cols: Int
        let rows: Int
    }
    struct Input: BridgePayload {
        static let messageType = "input"
        let data: String
    }
    struct Resize: BridgePayload {
        static let messageType = "resize"
        let cols: Int
        let rows: Int
    }
    struct PasteFiles: BridgePayload { static let messageType = "pasteFiles" }
    struct Link: BridgePayload {
        static let messageType = "link"
        let url: String
    }
    struct ResolveLinks: BridgePayload {
        static let messageType = "resolveLinks"
        let request: Int
        let paths: [String]
    }
}

/// The payload of each message of the discussion page (channel "discussion" of `Editor/js/bridge-contract.json`).
enum DiscussionMessage {
    struct Ready: BridgePayload { static let messageType = "ready" }
    struct Copy: BridgePayload {
        static let messageType = "copy"
        let text: String
    }
    struct Save: BridgePayload {
        static let messageType = "save"
        let name: String
        let data: String
        let base64: Bool?
    }
}
