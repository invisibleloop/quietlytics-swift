import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Privacy-first analytics for your app, sent to Quietlytics.
///
/// ```swift
/// @main struct MyApp: App {
///     init() { Quietlytics.configure(key: "qla_…") }
///     var body: some Scene { WindowGroup { Home().quietlyticsScreen("Home") } }
/// }
/// ```
///
/// Nothing identifies the person or the device: no advertising ID, no vendor ID, no stored user ID. The server counts
/// visitors from a code that changes every day, so there is nothing to ask permission for.
public enum Quietlytics {
    public static let defaultEndpoint = URL(string: "https://quietlytics.app/api/app-event")!

    /// Call once, as early as you can (the `init` of your `App`, or `application(_:didFinishLaunchingWithOptions:)`).
    /// - Parameters:
    ///   - key: the app's key from your Quietlytics account (it starts with `qla_`).
    ///   - endpoint: only needed if you run Quietlytics yourself.
    ///   - trackAppOpens: sends an "app open" event when the app comes to the front after being away for 30 minutes or more,
    ///     which is what makes an app with no other events show up as visitors.
    public static func configure(key: String, endpoint: URL = defaultEndpoint, trackAppOpens: Bool = true) {
        var s = Settings(); s.trackAppOpens = trackAppOpens
        Client.shared.configure(key: key, endpoint: endpoint, settings: s)
    }

    /// Records that a screen was shown. Names use letters, digits, spaces and `_ . : - /`, up to 100 characters.
    public static func screen(_ name: String) {
        Client.shared.record(name: nil, screen: name, properties: nil)
    }

    /// Records something that happened, such as `track("export", properties: ["format": "pdf"])`.
    ///
    /// Properties are for categories, not people: at most five, with short text, number or boolean values. Anything that
    /// looks like an email address, a phone number, a link or an ID is dropped by the server.
    public static func track(_ name: String, screen: String? = nil, properties: [String: Any]? = nil) {
        Client.shared.record(name: name, screen: screen, properties: properties)
    }

    /// True once `optOut()` has been called. Kept on the device between launches.
    public static var isOptedOut: Bool { Client.shared.isOptedOut }

    /// Stops all tracking and throws away anything not yet sent. Connect this to a privacy switch in your settings.
    public static func optOut() { Client.shared.optOut() }

    /// Turns tracking back on after `optOut()`.
    public static func optIn() { Client.shared.optIn() }

    /// Sends what is waiting now. You rarely need this: events go out on their own after a few seconds and when the app
    /// goes to the background.
    public static func flush() async { await Client.shared.flush() }
}

#if canImport(SwiftUI)
public extension View {
    /// Records a screen view each time this view appears.
    func quietlyticsScreen(_ name: String) -> some View {
        onAppear { Quietlytics.screen(name) }
    }
}
#endif
