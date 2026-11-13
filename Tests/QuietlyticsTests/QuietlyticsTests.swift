import XCTest
@testable import Quietlytics

final class MockTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [DeliveryResult]
    private(set) var bodies: [[String: Any]] = []
    init(_ results: [DeliveryResult] = []) { self.results = results }
    func deliver(_ body: Data) async -> DeliveryResult {
        return record(body)
    }
    private func record(_ body: Data) -> DeliveryResult {
        lock.lock(); defer { lock.unlock() }
        bodies.append((try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:])
        return results.isEmpty ? .delivered : results.removeFirst()
    }
}

final class QuietlyticsTests: XCTestCase {
    let ctx = Context(key: "qla_test", platform: "ios", osVersion: "17.4", appVersion: "2.3.0")

    func event(_ name: String? = nil, screen: String? = nil, at t: TimeInterval = Date().timeIntervalSince1970, props: [String: PropertyValue]? = nil) -> QueuedEvent {
        QueuedEvent(name: name, screen: screen, props: props, queuedAt: t)
    }

    func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json") }

    func client(_ transport: Transport, file: URL? = nil, suite: String = UUID().uuidString) -> Client {
        let defaults = UserDefaults(suiteName: suite)!
        let c = Client(defaults: defaults, queue: EventQueue(fileURL: file))
        var s = Settings(); s.flushDelay = 3600; s.retryDelay = 3600; s.batchSize = 10_000 // tests flush by hand
        c.configure(context: ctx, transport: transport, settings: s)
        return c
    }

    // MARK: what is sent

    func testScreenViewBodyHasTheContextAndTheScreen() throws {
        let body = try XCTUnwrap(ctx.body(for: event(screen: "Home")))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["k"] as? String, "qla_test")
        XCTAssertEqual(o["s"] as? String, "Home")
        XCTAssertEqual(o["plat"] as? String, "ios")
        XCTAssertEqual(o["osv"] as? String, "17.4")
        XCTAssertEqual(o["appv"] as? String, "2.3.0")
        XCTAssertNil(o["n"]); XCTAssertNil(o["p"])
    }

    func testEventBodyHasNameAndProperties() throws {
        let body = try XCTUnwrap(ctx.body(for: event("export", props: ["format": .string("pdf"), "pages": .number(3), "pro": .bool(true)])))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(o["n"] as? String, "export")
        let p = try XCTUnwrap(o["p"] as? [String: Any])
        XCTAssertEqual(p["format"] as? String, "pdf"); XCTAssertEqual(p["pages"] as? Int, 3); XCTAssertEqual(p["pro"] as? Bool, true)
    }

    func testNothingIdentifyingIsInTheBody() throws {
        let body = try XCTUnwrap(ctx.body(for: event("x")))
        let keys = Set((try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])).keys)
        XCTAssertTrue(keys.isSubset(of: ["k", "n", "s", "p", "plat", "osv", "appv"]), "\(keys)")
    }

    // MARK: validation

    func testNamesAndScreensFollowTheServersRules() {
        XCTAssertTrue(Client.validName("app open")); XCTAssertTrue(Client.validName("a.b:c-d_e 1"))
        XCTAssertFalse(Client.validName("")); XCTAssertFalse(Client.validName("bad<name>")); XCTAssertFalse(Client.validName(String(repeating: "a", count: 65)))
        XCTAssertFalse(Client.validName("a/b")); XCTAssertFalse(Client.validName("café"))
        XCTAssertTrue(Client.validScreen("Settings/Profile")); XCTAssertFalse(Client.validScreen("Home?email=a@b.com"))
        XCTAssertFalse(Client.validScreen(String(repeating: "a", count: 101)))
    }

    func testPropertiesAreLimitedAndOddValuesDropped() throws {
        let p = try XCTUnwrap(Client.cleanProperties(["a": "1", "b": 2, "c": true, "d": 4.5, "e": "5", "f": "6", "bad": [1, 2], "long": String(repeating: "x", count: 65), "nan": Double.nan]))
        XCTAssertEqual(p.count, 5)
        XCTAssertNil(p["bad"]); XCTAssertNil(p["long"]); XCTAssertNil(p["nan"])
        XCTAssertNil(Client.cleanProperties(["bad": Date()]))
        XCTAssertNil(Client.cleanProperties(nil))
    }

    func testBadEventsAreNotQueued() {
        let c = client(MockTransport())
        c.record(name: "bad<name>", screen: nil, properties: nil)
        c.record(name: nil, screen: "Home?x=1", properties: nil)
        c.record(name: nil, screen: nil, properties: nil)
        XCTAssertEqual(c.queue.count, 0)
        c.record(name: nil, screen: "Home", properties: nil)
        c.record(name: "export", screen: nil, properties: ["format": "pdf"])
        XCTAssertEqual(c.queue.count, 2)
    }

    func testNothingIsQueuedBeforeConfigure() {
        let c = Client(defaults: UserDefaults(suiteName: UUID().uuidString)!, queue: EventQueue(fileURL: nil))
        c.record(name: nil, screen: "Home", properties: nil)
        XCTAssertEqual(c.queue.count, 0)
    }

    // MARK: sending and retrying

    func testEventsAreSentInOrderAndTheQueueEmpties() async {
        let t = MockTransport(); let c = client(t)
        c.record(name: nil, screen: "A", properties: nil); c.record(name: nil, screen: "B", properties: nil); c.record(name: "go", screen: nil, properties: nil)
        await c.flush()
        XCTAssertEqual(t.bodies.map { ($0["s"] as? String) ?? ($0["n"] as? String) ?? "" }, ["A", "B", "go"])
        XCTAssertEqual(c.queue.count, 0)
    }

    func testAFailedSendKeepsTheEventsAndStopsThere() async {
        let t = MockTransport([.delivered, .retryLater]); let c = client(t)
        for s in ["A", "B", "C"] { c.record(name: nil, screen: s, properties: nil) }
        await c.flush()
        XCTAssertEqual(t.bodies.count, 2)                       // A went, B failed, C was not tried
        XCTAssertEqual(c.queue.snapshot.compactMap { $0.screen }, ["B", "C"])
        await c.flush()                                          // back online
        XCTAssertEqual(c.queue.count, 0)
        XCTAssertEqual(t.bodies.compactMap { $0["s"] as? String }, ["A", "B", "B", "C"])
    }

    func testARejectedEventIsDroppedAndTheRestGoOn() async {
        let t = MockTransport([.rejected]); let c = client(t)
        c.record(name: nil, screen: "A", properties: nil); c.record(name: nil, screen: "B", properties: nil)
        await c.flush()
        XCTAssertEqual(c.queue.count, 0)
        XCTAssertEqual(t.bodies.count, 2)
    }

    func testEventsThatWaitedTooLongAreDroppedNotSentWithAWrongTime() async {
        let t = MockTransport()
        let q = EventQueue(fileURL: nil, maxAge: 3600)
        q.add(event(screen: "old", at: Date().timeIntervalSince1970 - 7200))
        q.add(event(screen: "fresh"))
        await q.flush(transport: t, context: ctx)
        XCTAssertEqual(t.bodies.compactMap { $0["s"] as? String }, ["fresh"])
    }

    func testTheQueueHasACapAndKeepsTheNewest() {
        let q = EventQueue(fileURL: nil, maxEvents: 3)
        for i in 0..<5 { q.add(event(screen: "S\(i)")) }
        XCTAssertEqual(q.snapshot.compactMap { $0.screen }, ["S2", "S3", "S4"])
    }

    func testTwoFlushesDoNotOverlap() async {
        final class Slow: Transport, @unchecked Sendable {
            var calls = 0
            func deliver(_ body: Data) async -> DeliveryResult { calls += 1; try? await Task.sleep(nanoseconds: 100_000_000); return .delivered }
        }
        let t = Slow(); let q = EventQueue(fileURL: nil); q.add(event(screen: "A"))
        async let a = q.flush(transport: t, context: ctx), b = q.flush(transport: t, context: ctx)
        _ = await (a, b)
        XCTAssertEqual(t.calls, 1)
    }

    // MARK: surviving a restart

    func testWaitingEventsSurviveTheAppBeingClosed() async throws {
        let file = tempFile()
        let first = client(MockTransport([.retryLater]), file: file)
        first.record(name: nil, screen: "A", properties: nil); first.record(name: "go", screen: nil, properties: ["k": "v"])
        await first.flush()
        XCTAssertEqual(first.queue.count, 2)

        let t = MockTransport(); let second = client(t, file: file)   // a new launch reads the file
        XCTAssertEqual(second.queue.count, 2)
        await second.flush()
        XCTAssertEqual(t.bodies.count, 2)
        XCTAssertEqual(EventQueue(fileURL: file).count, 0)
    }

    // MARK: opting out

    func testOptingOutStopsTrackingAndThrowsAwayWhatWasWaiting() async {
        let suite = UUID().uuidString; let t = MockTransport(); let c = client(t, suite: suite)
        c.record(name: nil, screen: "A", properties: nil)
        c.optOut()
        XCTAssertTrue(c.isOptedOut); XCTAssertEqual(c.queue.count, 0)
        c.record(name: nil, screen: "B", properties: nil)
        await c.flush()
        XCTAssertEqual(c.queue.count, 0); XCTAssertEqual(t.bodies.count, 0)
        c.optIn()
        c.record(name: nil, screen: "C", properties: nil)
        XCTAssertEqual(c.queue.count, 1)
    }

    func testTheOptOutIsRememberedBetweenLaunches() {
        let suite = UUID().uuidString
        client(MockTransport(), suite: suite).optOut()
        XCTAssertTrue(client(MockTransport(), suite: suite).isOptedOut)
    }

    // MARK: app opens

    func testAppOpenIsSentOnceThenOnlyAfterALongAbsence() {
        let c = client(MockTransport()); let t0 = Date()
        c.didBecomeActive(now: t0)                                    // first launch
        XCTAssertEqual(c.queue.snapshot.compactMap { $0.name }, ["app open"])
        c.didEnterBackground(now: t0.addingTimeInterval(60))
        c.didBecomeActive(now: t0.addingTimeInterval(120))            // back after a minute: same visit
        XCTAssertEqual(c.queue.count, 1)
        c.didEnterBackground(now: t0.addingTimeInterval(200))
        c.didBecomeActive(now: t0.addingTimeInterval(200 + 1800))     // back after half an hour
        XCTAssertEqual(c.queue.count, 2)
    }

    // MARK: against a real server (skipped unless QUIETLYTICS_TEST_ENDPOINT and QUIETLYTICS_TEST_KEY are set)

    func testEventsReachARealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["QUIETLYTICS_TEST_ENDPOINT"].flatMap(URL.init(string:)), let key = env["QUIETLYTICS_TEST_KEY"] else { throw XCTSkip("no test server given") }
        let c = Client(defaults: UserDefaults(suiteName: UUID().uuidString)!, queue: EventQueue(fileURL: nil))
        var s = Settings(); s.flushDelay = 3600; s.batchSize = 10_000
        c.configure(context: .current(key: key), transport: URLSessionTransport(endpoint: endpoint), settings: s)
        c.record(name: nil, screen: "Home", properties: nil)
        c.record(name: nil, screen: "Settings/Profile", properties: nil)
        c.record(name: "export", screen: "Editor", properties: ["format": "pdf", "pages": 3])
        await c.flush()
        XCTAssertEqual(c.queue.count, 0)
    }
}
