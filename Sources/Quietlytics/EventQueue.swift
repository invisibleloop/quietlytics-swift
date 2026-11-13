import Foundation

/// Events waiting to be sent, kept on disk so they survive the app being closed. Oldest first, and sent in that order.
/// The server stamps an event with the time it arrives, so an event that waited too long is dropped rather than sent
/// with a time that is wrong by hours.
final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [QueuedEvent]
    private var flushing = false
    private let fileURL: URL?
    private let maxEvents: Int
    private let maxAge: TimeInterval

    init(fileURL: URL?, maxEvents: Int = 500, maxAge: TimeInterval = 3600) {
        self.fileURL = fileURL
        self.maxEvents = maxEvents
        self.maxAge = maxAge
        if let fileURL, let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([QueuedEvent].self, from: data) {
            events = Array(saved.suffix(maxEvents))
        } else {
            events = []
        }
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return events.count }
    var snapshot: [QueuedEvent] { lock.lock(); defer { lock.unlock() }; return events }

    func add(_ event: QueuedEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        persist()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        events.removeAll()
        persist()
    }

    /// Sends what is waiting, one event at a time, stopping at the first one that cannot be delivered yet.
    /// Returns true when the queue is empty afterwards. Two flushes never overlap.
    @discardableResult
    func flush(transport: Transport, context: Context, now: Date = Date()) async -> Bool {
        guard beginFlush() else { return false }
        defer { endFlush() }

        while true {
            guard let event = nextEvent(droppingOlderThan: now.timeIntervalSince1970 - maxAge) else { save(); return true }
            guard let body = context.body(for: event) else { remove(event); continue }
            switch await transport.deliver(body) {
            case .delivered, .rejected: remove(event)
            case .retryLater: save(); return false
            }
        }
    }

    // The locking is kept in these plain functions: a lock must not be held, or taken, across an `await`.
    private func beginFlush() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flushing { return false }
        flushing = true
        return true
    }

    private func endFlush() { lock.lock(); flushing = false; lock.unlock() }

    private func nextEvent(droppingOlderThan cutoff: TimeInterval) -> QueuedEvent? {
        lock.lock(); defer { lock.unlock() }
        events.removeAll { $0.queuedAt < cutoff }
        return events.first
    }

    private func remove(_ event: QueuedEvent) {
        lock.lock(); defer { lock.unlock() }
        if let i = events.firstIndex(where: { $0.id == event.id }) { events.remove(at: i) }
        persist()
    }

    private func save() { lock.lock(); defer { lock.unlock() }; persist() }

    // Call with the lock held.
    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: fileURL, options: [.atomic])
        } catch { /* the queue still works in memory */ }
    }
}
