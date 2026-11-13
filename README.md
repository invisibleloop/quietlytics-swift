# Quietlytics for Apple apps

A small Swift package that sends screen views and events from an iOS, iPadOS, macOS, tvOS, watchOS or visionOS app to
Quietlytics. No dependencies, no advertising ID, no vendor ID and no stored user ID, so there is nothing to ask permission for.

## Install

In Xcode: **File → Add Package Dependencies**, then enter `https://github.com/invisibleloop/quietlytics-swift`. Or in `Package.swift`:

```swift
.package(url: "https://github.com/invisibleloop/quietlytics-swift", from: "1.0.0")
```

## Use

Add the app in your Quietlytics account (**Websites → Your apps**) to get its key, then:

```swift
import Quietlytics

@main struct MyApp: App {
    init() { Quietlytics.configure(key: "qla_…") }   // as early as you can
    var body: some Scene {
        WindowGroup { Home().quietlyticsScreen("Home") }
    }
}

Quietlytics.screen("Settings/Profile")                                   // UIKit, or anywhere else
Quietlytics.track("export", properties: ["format": "pdf", "pages": 3])  // something happened
```

If you run Quietlytics yourself, pass `endpoint: URL(string: "https://your.host/api/app-event")!` to `configure`.

## Opt out

```swift
Quietlytics.optOut()   // stops tracking and discards anything not yet sent; remembered between launches
Quietlytics.optIn()
```

Connect these to a privacy switch in your app's settings.

## What is sent

`key`, the platform (`ios`, `ipados`, `macos`…), the OS version as major.minor, the app's version, and the screen or event
(with up to five short properties). Visitors are counted by the server from a code that changes every day, so a returning
person on another day is a new visitor. Retention is not measured.

Properties are for categories, not people. The server drops names and values that look like email addresses, phone numbers,
links or IDs.

## How it behaves

- Events are queued on disk and sent after a few seconds, in order, one request each, and when the app goes to the background.
- With no connection they wait and are retried. The server stamps an event with the time it arrives, so an event that has
  waited more than an hour is dropped rather than recorded at the wrong time. At most 500 are kept.
- An "app open" event is sent when the app comes to the front after 30 minutes or more away (turn off with
  `configure(key:trackAppOpens: false)`). It is what makes an app that sends no other events still show visitors. Call
  `configure` early enough to see the first launch.
- Requests use a session with no cookies, no cache and no credentials.

## Tests

```sh
swift test
# against a local server, with an app key from your account:
QUIETLYTICS_TEST_ENDPOINT=http://localhost:3100/api/app-event QUIETLYTICS_TEST_KEY=qla_… swift test
```
