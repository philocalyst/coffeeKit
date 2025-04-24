# Welcome to CoffeeKit

[![Swift Version](https://badgen.net/static/Swift/6.0/orange)](https://swift.org)
[![Platform](https://badgen.net/static/platform/macOS%2010.15+)](https://developer.apple.com/macOS)

A Swift library designed for robust management of macOS power assertions.

## Summary

`CoffeeKit` provides a modern, safe, and easy-to-use Swift actor (`CoffeeKit`) for interacting with the macOS IOKit Power Management APIs. It allows your application to prevent display sleep, system sleep, or idle sleep with a specific reason.

Key features include:
* Creating various power assertion types (e.g., `preventDisplaySleep`, `preventSystemIdleSleep`).
* Automatically releasing assertions after a specified timeout.
* Monitoring a specific process ID (`pid_t`) and automatically releasing assertions when that process exits, using efficient `kqueue` notifications.
* Built with Swift concurrency (`actor`) for thread safety.
* Integrated logging using `swift-log`.
* Clear error handling via the `CaffeinationError` enum.

## Get Started

Coffee's no killer, head to the [Installation](#installation) section to add `CoffeeKit` to your project.

## Tutorial

Here's a basic example of how to use `CoffeeKit` to prevent idle sleep while your task runs:

```swift
import CoffeeKit

// ▰▰▰ Basic Usage ▰▰▰ //
func runImportantTask() async {
    let coffee = CoffeeKit(reason: "Running important background task")

    do {
        print("Starting task, preventing idle sleep...")
        try await coffee.start() // Activate assertions

        print("Task is running. Assertions active: \(await coffee.isActive)")
        print("Active assertion types: \(await coffee.activeAssertionTypes)")

        // Simulate your long-running work
        try await Task.sleep(for: .seconds(30))

        print("Task finished.")

    } catch let error as CaffeinationError {
        print("Failed to manage power assertion: \(error)")
    } catch {
        print("An unexpected error occurred: \(error)")
    }

    // Assertions are released automatically when `coffee` goes out of scope (deinit)
    // or you can explicitly stop them:
    // await coffee.stop()
    // print("Assertions stopped manually. Active: \(await coffee.isActive)")
}

// ▰▰▰ Usage with Timeout ▰▰▰ //
func runTaskWithTimeout() async {
    // Prevent display sleep for 60 seconds max
    let coffee = CoffeeKit(
        reason: "Quick display activity",
        types: [.preventDisplaySleep],
        timeout: 60.0 // Release assertion after 60 seconds
    )

    do {
        try await coffee.start()
        print("Display sleep prevented for up to 60 seconds...")
        // No need to call stop() if timeout is set, unless you finish early
        // await coffee.stop()
    } catch {
        print("Error: \(error)")
    }
}

// ▰▰▰ Usage with Process Watching ▰▰▰ //
func watchProcess(pid: pid_t) async {
    // Keep system awake only while process 'pid' is running
    let coffee = CoffeeKit(
        reason: "Keeping system awake for process \(pid)",
        types: [.preventSystemIdleSleep],
        watchPID: pid
    )

    // Optional: Get notified when CoffeeKit stops (e.g., because process ended)
    await coffee.terminationHandler = { kit in
        // Note: This runs *after* stop() completes.
        // Accessing 'kit' properties requires 'await'.
        Task { // Launch new task if needed from non-async context
             print("CoffeeKit stopped. Watched PID likely exited.")
        }
    }


    do {
        try await coffee.start()
        print("Watching PID \(pid). System idle sleep prevented.")
        // CoffeeKit will automatically call stop() when the process exits.
        // You can also call stop() manually if needed.
        // await coffee.stop()
    } catch CaffeinationError.processNotFound(let pid) {
        print("Error: Process \(pid) was not found or already exited.")
    } catch {
        print("Error: \(error)")
    }
}

// ▰▰▰ Example Execution ▰▰▰ //
Task {
    await runImportantTask()
    await runTaskWithTimeout()

    // Example: Launch TextEdit and watch its PID
    let textEditPID: pid_t = 12345 // Just a stand-in number
    await watchProcess(pid: textEditPID)
    // Keep the script running to allow watching
    try? await Task.sleep(for: .seconds(300))
}
````

### Configuration

When initializing `CoffeeKit`, you can specify:

  * `reason`: (String) A human-readable reason for the assertion, visible in tools like Activity Monitor.
  * `types`: (Set\<`AssertionType`\>) The types of power assertions to create. Defaults to `[.preventSystemIdleSleep, .preventDisplaySleep]`. Available types:
      * `.preventDisplaySleep`
      * `.preventSystemIdleSleep`
      * `.preventSystemSleep` 
      * `.declareUserActivity`
      * `.preventUserIdleSleep`
      * `.preventUserIdleSystemSleep`
  * `timeout`: (TimeInterval?) Optional duration in seconds after which the assertion(s) should be automatically released. `nil` means no timeout.
  * `watchPID`: (pid\_t?) Optional process ID to monitor. If provided, `CoffeeKit` will automatically stop assertions when this process terminates. Invalid PIDs (\<= 0) are ignored.

## Design Philosophy

`CoffeeKit` aims to be:

  * **Safe:** Leverages Swift actors to ensure thread-safe access to internal state and IOKit calls.
  * **Robust:** Implements reliable process monitoring using `kqueue` and provides specific error types (`CaffeinationError`) for better diagnostics.
  * **Modern:** Built with modern Swift concurrency (`async`/`await`).
  * **Clear:** Uses `swift-log` for detailed operational logging.
  * **Resourceful:** Ensures power assertions and system resources (like file descriptors for `kqueue`) are properly released via `deinit` or explicit `stop()`.

## Building and Debugging

This project uses the Swift Package Manager.

  * **Build:** Open the `Package.swift` file in Xcode or run `swift build` in the terminal.
  * **Test:** Run `swift test`
  * **Debugging:** Use Xcode's debugger or add `swift-log` handlers to view detailed logs.

## Installation

`CoffeeKit` is distributed using the Swift Package Manager. To install it into a project, add it as a dependency in your `Package.swift` file:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YourProjectName",
    platforms: [.macOS(.v10_15)], // CoffeeKit requires macOS 10.15+
    dependencies: [
        .package(url: "[https://github.com/philocalyst/coffeeKit.git](https://github.com/philocalyst/coffeeKit.git)", from: "0.1.0") // Replace with desired version or branch
        // Other dependencies...
    ],
    targets: [
        .target(
            name: "YourTargetName",
            dependencies: [
                .product(name: "CoffeeKit", package: "coffeeKit"), // Corrected product name
                // Other dependencies...
            ]
        )
        // Other targets...
    ]
)
```

Then, run `swift package update` or `swift package resolve` to fetch the package. Import `CoffeeKit` in your Swift files where needed.

## Changelog

Notable changes are documented in the [CHANGELOG.md](CHANGELOG.md) file.

## Libraries Used

  * [swift-log](https://github.com/apple/swift-log): A Logging API package for Swift.
  * [swift-testing](https://www.google.com/search?q=https://github.com/apple/swift-testing): (For testing) Modern testing library for Swift.

## Acknowledgements

  * Inspired by the classic `caffeinate` command-line tool on macOS.
  * Thanks to the Swift community :)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
