import Foundation

/// Keep encrypted HTTP frames below serverless request limits without shrinking file/tool support.
/// Fragment IDs are independent delivery IDs; the original ID still correlates the tool result.
enum RemoteFraming {
    static let maxEncryptedBytes = 2 * 1024 * 1024
    static let partBytes = 1024 * 1024

    static func frames(for message: RemoteMessage) throws -> [RemoteMessage] {
        let data = try JSONEncoder().encode(message)
        guard data.count <= RemoteMessage.maxBytes else { throw RemoteFailure.invalid("Remote message is too large.") }
        let encryptedSize = ((data.count + 28 + 2) / 3) * 4
        if encryptedSize <= maxEncryptedBytes { return [message] }
        let count = (data.count + partBytes - 1) / partBytes
        return stride(from: 0, to: data.count, by: partBytes).enumerated().map { index, offset in
            RemoteMessage("fragment", .object([
                "message": .string(message.id.uuidString), "index": .int(index), "count": .int(count),
                "data": .string(data.subdata(in: offset..<min(offset + partBytes, data.count)).base64EncodedString())]))
        }
    }
}

struct RemoteReassembler {
    private struct Assembly {
        var parts: [Data?]
        var bytes = 0
        var completed: RemoteMessage?
    }
    private var assemblies: [UUID: Assembly] = [:]
    private var totalBytes = 0
    private var acknowledged: Set<UUID> = []

    mutating func accept(_ frame: RemoteMessage) throws -> RemoteMessage? {
        guard acknowledged.count < 100000 else { throw RemoteFailure.invalid("Reconnect to continue this remote session.") }
        guard frame.kind == "fragment" else { return acknowledged.contains(frame.id) ? nil : frame }
        guard let rawID = frame.payload["message"].string, let id = UUID(uuidString: rawID),
              let index = frame.payload["index"].integer, let count = frame.payload["count"].integer,
              (2...4).contains(count), index >= 0, index < count,
              let encoded = frame.payload["data"].string, encoded.utf8.count <= 1_500_000,
              let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= RemoteFraming.partBytes,
              index == count - 1 || data.count == RemoteFraming.partBytes else {
            throw RemoteFailure.invalid("Invalid remote message fragment.")
        }
        if acknowledged.contains(id) { return nil }
        if assemblies[id] == nil {
            guard index == 0, assemblies.count < 4 else { throw RemoteFailure.invalid("Incomplete remote message.") }
            assemblies[id] = Assembly(parts: Array(repeating: nil, count: count))
        }
        var assembly = assemblies[id]!
        var addedBytes = 0
        guard assembly.parts.count == count else { throw RemoteFailure.invalid("Fragment count changed.") }
        if let previous = assembly.parts[index] {
            guard previous == data else { throw RemoteFailure.invalid("Fragment contents changed.") }
        } else {
            guard totalBytes + data.count <= RemoteMessage.maxBytes * 4,
                  assembly.bytes + data.count <= RemoteMessage.maxBytes else { throw RemoteFailure.invalid("Remote assembly exceeds its size limit.") }
            assembly.parts[index] = data; assembly.bytes += data.count; addedBytes = data.count
        }
        if assembly.completed == nil, assembly.parts.allSatisfy({ $0 != nil }) {
            var joined = Data()
            for part in assembly.parts { joined.append(part!) }
            let message = try JSONDecoder().decode(RemoteMessage.self, from: joined)
            guard message.id == id, message.kind != "fragment" else { throw RemoteFailure.invalid("Invalid assembled message.") }
            assembly.completed = message
        }
        assemblies[id] = assembly
        totalBytes += addedBytes
        return assembly.completed
    }

    /// Keep the completed value until the application handler succeeds. Retrying the final frame
    /// after a failed handler then returns the same operation rather than losing its earlier parts.
    mutating func acknowledge(_ id: UUID) {
        if let assembly = assemblies.removeValue(forKey: id) { totalBytes -= assembly.bytes }
        acknowledged.insert(id)
    }
}
