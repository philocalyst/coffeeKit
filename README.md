# Welcome to CoffeeKit

[![Swift Version](https://badgen.net/static/Swift/6.0/orange)](https://swift.org)  
[![Platform](https://badgen.net/static/platform/macOS%2010.15+)](https://developer.apple.com/macOS)

A Swift library for robust, thread-safe management of macOS power assertions using a Swift actor.

## Summary

`CoffeeKit` provides a modern, safe, and easy-to-use Swift actor for interacting with the macOS IOKit Power Management APIs. It allows your application to prevent display sleep, system sleep, or idle sleep—with optional automatic timeout or process-lifetime monitoring.

Key features:
* Create any combination of power assertions (e.g. `.preventDisplaySleep`, `.preventSystemIdleSleep`).
* Automatically release assertions after a specified timeout.
* Watch a `pid_t` and automatically release assertions when that process exits (using efficient `kqueue` notifications).
* Built with Swift concurrency (`actor`) for thread safety.
* Integrated logging via `swift-log`.
* Clear error handling via the `CaffeinationError` enum.

## Get Started

Ready to keep the system awake? Head to [Installation](#installation) to add `CoffeeKit` to your project.

---

## Tutorial

Below are common usage patterns for `CoffeeKit`.

```swift
import coffeeKit
import Logging

// ▰▰▰ Basic Usage ▰▰▰ //
func runImportantTask() async {
    let blocker = sleepManager(
        reason: "Running important background task"
    )

    do {
        print("Starting task, preventing idle sleep…")
        try await blocker.start()

        print("Assertions active: \(await blocker.isActive)")
        print("Types: \(await blocker.activeAssertionTypes)")

        // Simulate long-running work
        try await Task.sleep(for: .seconds(30))

        print("Task finished.")
    }
    catch let error as CaffeinationError {
        print("Power assertion error: \(error)")
    }
    catch {
        print("Unexpected error: \(error)")
    }

    // When `blocker` deinitializes or you call `stop()`, 
    // assertions are released automatically.
    // await blocker.stop()
}
```

```swift
// ▰▰▰ Usage with Timeout ▰▰▰ //
func runTaskWithTimeout() async {
    // Prevent display sleep for up to 60 seconds
    let blocker = sleepManager(
        blocks: [.preventDisplaySleep],
        reason: "Quick display activity",
        timeout: 60.0  // seconds
    )

    do {
        try await blocker.start()
        print("Display sleep prevented for 60s.")
        // No need to call stop() unless you finish early
    }
    catch {
        print("Error: \(error)")
    }
}
```

```swift
// ▰▰▰ Usage with Process Watching ▰▰▰ //
func watchProcess(pid: pid_t) async {
    // Keep system awake only while `pid` runs
    let blocker = sleepManager(
        blocks: [.preventSystemIdleSleep],
        reason: "Keeping system awake for PID \(pid)",
        watch: pid
    )

    // Optional: get notified when blocker stops
    await blocker.terminationHandler = { kit in
        Task {
            print("sleepManager stopped; watched PID likely exited.")
        }
    }

    do {
        try await blocker.start()
        print("Watching PID \(pid); system idle sleep prevented.")
        // blocker.stop() will be called automatically on process exit
    }
    catch CaffeinationError.processNotFound(let pid) {
        print("Process \(pid) not found or already exited.")
    }
    catch {
        print("Error: \(error)")
    }
}
```

```swift
// ▰▰▰ Example Execution ▰▰▰ //
Task {
    await runImportantTask()
    await runTaskWithTimeout()

    let somePID: pid_t = 12345
    await watchProcess(pid: somePID)

    // Keep the Task alive to allow watching
    try? await Task.sleep(for: .seconds(300))
}
```

---

## Configuration

Initialize `sleepManager` with:

* `blocks`: Set<AssertionType>  
  The types of assertions to create.  
  Default: `[.preventSystemIdleSleep, .preventDisplaySleep]`  
  Available types:
  - `.preventDisplaySleep`
  - `.preventSystemIdleSleep`
  - `.preventSystemSleep`
  - `.declareUserActivity`
  - `.preventUserIdleSleep`
  - `.preventUserIdleSystemSleep`
* `reason`: String  
  A human-readable reason for the assertion (visible in Activity Monitor).
* `timeout`: TimeInterval?  
  Optional duration in seconds after which assertions are released.  
  `nil` means no timeout.
* `watch`: pid_t?  
  Optional process ID to monitor. If provided and > 0, `sleepManager` will
  automatically stop assertions when that process terminates.

---

## Design Philosophy

* **Safe**: Swift actor guarantees thread-safe access to internal state and IOKit calls.  
* **Robust**: Reliable process monitoring with `kqueue` + clear `CaffeinationError` cases.  
* **Modern**: Leverages Swift concurrency (`async`/`await`).  
* **Clear**: Integrated with `swift-log` for structured logging.  
* **Resourceful**: Ensures assertions and system resources are always released (via `deinit` or explicit `stop()`).

---

## Building and Debugging

This library uses Swift Package Manager.

* **Build**: `swift build` or open in Xcode.  
* **Test**: `swift test`  
* **Debug**: Use Xcode’s debugger or add `swift-log` handlers to inspect logs.

---

## Installation

Add `CoffeeKit` to your `Package.swift`:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "YourProject",
  platforms: [.macOS(.v10_15)],
  dependencies: [
    .package(
      url: "https://github.com/philocalyst/CoffeeKit.git",
      from: "0.1.0"
    )
  ],
  targets: [
    .target(
      name: "YourTarget",
      dependencies: [
        .product(name: "CoffeeKit", package: "CoffeeKit")
      ]
    )
  ]
)
```

Run `swift package update` to fetch the package, then `import CoffeeKit` in your code.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for notable changes.

## Libraries Used

* [swift-log](https://github.com/apple/swift-log)  
* [swift-testing](https://github.com/apple/swift-testing) (for tests)

## Acknowledgements

Inspired by Apple’s `caffeinate` tool. Thanks to the Swift community!

## License

MIT License – see [LICENSE](LICENSE) for details.
