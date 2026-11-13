import Foundation

/// A property value attached to an event. The server keeps short text, so numbers and booleans are sent as they are
/// and stored as text there.
enum PropertyValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        }
    }

    /// Only strings, booleans and finite numbers are accepted. Anything else is dropped.
    static func from(_ any: Any) -> PropertyValue? {
        switch any {
        case let b as Bool: return .bool(b)
        case let s as String: return .string(s)
        case let i as Int: return .number(Double(i))
        case let d as Double: return d.isFinite ? .number(d) : nil
        case let f as Float: return f.isFinite ? .number(Double(f)) : nil
        default: return nil
        }
    }
}

/// An event waiting to be sent. A screen view has a `screen` and no `name`.
struct QueuedEvent: Codable, Equatable {
    var id = UUID()
    var name: String?
    var screen: String?
    var props: [String: PropertyValue]?
    var queuedAt: TimeInterval   // seconds since 1970; used only to drop events that waited too long
}

/// What is the same for every event from this install of the app.
struct Context: Equatable {
    var key: String
    var platform: String
    var osVersion: String
    var appVersion: String?

    /// The JSON the server expects at /api/app-event.
    func body(for e: QueuedEvent) -> Data? {
        var o: [String: Any] = ["k": key, "plat": platform, "osv": osVersion]
        if let appVersion { o["appv"] = appVersion }
        if let n = e.name { o["n"] = n }
        if let s = e.screen { o["s"] = s }
        if let p = e.props, !p.isEmpty {
            o["p"] = p.mapValues { v -> Any in
                switch v { case .string(let s): return s; case .number(let n): return n; case .bool(let b): return b }
            }
        }
        return try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    }

    /// The platform name the server knows, the OS's major.minor version, and the app's own version.
    static func current(key: String) -> Context {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return Context(key: key, platform: Device.platform(), osVersion: "\(v.majorVersion).\(v.minorVersion)",
                       appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }
}

enum Device {
    static func platform() -> String {
        #if os(iOS)
        return onMain { UIDevice.current.userInterfaceIdiom == .pad } ? "ipados" : "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #else
        return "other"
        #endif
    }

    #if os(iOS)
    private static func onMain<T>(_ work: @escaping () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
    #endif
}

#if os(iOS)
import UIKit
#endif
