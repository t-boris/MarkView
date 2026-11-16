import Foundation

/// Shared by the connection list and its terminal tab; online means a recent peer response.
struct RemoteConnectionState {
    enum Phase { case connecting, online, waiting, reconnecting, offline, revoking, revoked }
    var phase: Phase
    var detail: String
    var lastSeen: Date?
}
