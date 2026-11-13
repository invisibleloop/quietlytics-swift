import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct Settings {
    var trackAppOpens = true
    var flushDelay: TimeInterval = 5      // how long events gather before they are sent
    var retryDelay: TimeInterval = 60     // how long to wait after a failed attempt
    var batchSize = 10                    // send at once when this many are waiting
    var openGap: TimeInterval = 1800      // coming back after less than this is the same visit, not a new app open
}

/// The one object behind the public functions. It is separate from `Quietlytics` so tests can build their own.
final class Client: @unchecked Sendable {
    static let shared = Client()
    static let optOutKey = "app.quietlytics.optedOut"

    private let lock = NSLock()
    private let defaults: UserDefaults
    let queue: EventQueue
    private var context: Context?
    private var transport: Transport?
    private var settings = Settings()
    private var flushScheduled = false
    private var lastBackground: Date?
    private var observing = false

    init(defaults: UserDefaults = .standard, queue: EventQueue = EventQueue(fileURL: Client.defaultQueueFile())) {
        self.defaults = defaults
        self.queue = queue
    }

    static func defaultQueueFile() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Quietlytics", isDirectory: true).appendingPathComponent("queue.json")
    }

    // MARK: setup

    func configure(key: String, endpoint: URL, settings: Settings) {
        configure(context: .current(key: key), transport: URLSessionTransport(endpoint: endpoint), settings: settings)
        observeLifecycle()
    }

    func configure(context: Context, transport: Transport, settings: Settings) {
        lock.lock()
        self.context = context; self.transport = transport; self.settings = settings
        lock.unlock()
        if queue.count > 0 { scheduleFlush() } // events left over from an earlier run
    }

    // MARK: opting out

    var isOptedOut: Bool { defaults.bool(forKey: Client.optOutKey) }

    func optOut() { defaults.set(true, forKey: Client.optOutKey); queue.removeAll() }
    func optIn() { defaults.set(false, forKey: Client.optOutKey) }

    // MARK: recording

    func record(name: String?, screen: String?, properties: [String: Any]?, now: Date = Date()) {
        guard !isOptedOut else { return }
        lock.lock(); let ready = context != nil; lock.unlock()
        guard ready else { return }
        if let name, !Client.validName(name) { return }
        if let screen, !Client.validScreen(screen) { return }
        if name == nil && screen == nil { return }
        queue.add(QueuedEvent(name: name, screen: screen, props: Client.cleanProperties(properties), queuedAt: now.timeIntervalSince1970))
        scheduleFlush()
    }

    // Letters, digits, space and _ . : - (the server's rule for names), plus / for screens.
    private static func allowed(_ s: String, extra: String, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_ .:-\(extra)".contains($0)) }
    }
    static func validName(_ s: String) -> Bool { allowed(s, extra: "", max: 64) }
    static func validScreen(_ s: String) -> Bool { allowed(s, extra: "/", max: 100) }

    /// At most five properties with short values. The server applies its own privacy rules on top of this.
    static func cleanProperties(_ p: [String: Any]?) -> [String: PropertyValue]? {
        guard let p else { return nil }
        var out: [String: PropertyValue] = [:]
        for key in p.keys.sorted() {
            guard out.count < 5, !key.isEmpty, key.count <= 32, let v = PropertyValue.from(p[key]!) else { continue }
            if case .string(let s) = v, s.count > 64 { continue }
            out[key] = v
        }
        return out.isEmpty ? nil : out
    }

    // MARK: sending

    func flush() async {
        guard let (ctx, tr, retry) = sendingSetup(), !isOptedOut else { return }
        let emptied = await queue.flush(transport: tr, context: ctx)
        if !emptied && queue.count > 0 { schedule(after: retry) }
    }

    private func sendingSetup() -> (Context, Transport, TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard let context, let transport else { return nil }
        return (context, transport, settings.retryDelay)
    }

    private func clearScheduled() { lock.lock(); flushScheduled = false; lock.unlock() }

    private func scheduleFlush() {
        lock.lock(); let delay = settings.flushDelay, batch = settings.batchSize; lock.unlock()
        if queue.count >= batch { Task { await self.flush() } } else { schedule(after: delay) }
    }

    private func schedule(after delay: TimeInterval) {
        lock.lock()
        if flushScheduled { lock.unlock(); return }
        flushScheduled = true
        lock.unlock()
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.clearScheduled()
            await self.flush()
        }
    }

    // MARK: app lifecycle

    /// Called when the app comes to the front. Coming back after a long time away counts as opening the app again.
    func didBecomeActive(now: Date = Date()) {
        lock.lock(); let track = settings.trackAppOpens, gap = settings.openGap, last = lastBackground; lock.unlock()
        guard track else { return }
        if let last, now.timeIntervalSince(last) < gap { return }
        record(name: "app open", screen: nil, properties: nil, now: now)
    }

    func didEnterBackground(now: Date = Date()) {
        lock.lock(); lastBackground = now; lock.unlock()
        #if !os(macOS)
        // Ask for a little time to send what is waiting before the app is suspended. (A Mac app is not suspended.)
        ProcessInfo.processInfo.performExpiringActivity(withReason: "Quietlytics sending events") { expired in
            if expired { return }
            let done = DispatchSemaphore(value: 0)
            Task { await self.flush(); done.signal() }
            done.wait()
        }
        #else
        Task { await self.flush() }
        #endif
    }

    private func observeLifecycle() {
        lock.lock(); if observing { lock.unlock(); return }; observing = true; lock.unlock()
        let nc = NotificationCenter.default
        #if canImport(UIKit) && !os(watchOS)
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.didBecomeActive() }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.didEnterBackground() }
        #elseif canImport(AppKit)
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.didBecomeActive() }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.didEnterBackground() }
        #endif
    }
}
