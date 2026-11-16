import Foundation

/// Owns block-based NotificationCenter registrations and removes them when their owner ends.
// unchecked Sendable: the lock protects registrations; NotificationCenter supports removal from any thread.
public final class NotificationObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [(NotificationCenter, NSObjectProtocol)] = []

    public init() {}

    public func observe(_ name: Notification.Name, object: Any? = nil, center: NotificationCenter = .default,
                        handler: @escaping @Sendable (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main, using: handler)
        lock.lock()
        registrations.append((center, token))
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        let old = registrations
        registrations.removeAll()
        lock.unlock()
        for (center, token) in old { center.removeObserver(token) }
    }

    deinit { removeAll() }
}
