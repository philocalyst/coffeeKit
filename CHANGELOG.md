# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] – 2025-05-12

### Changed
- Renamed actor type from `CoffeeKit` (and interim alias `SleepBlocker`) to `SleepManager`, updating all references.  
- Renamed initializer parameters:
  - `types` → `blocks`
  - `watchPID` → `watch`
- Updated `terminationHandler` signature to accept `SleepManager` instances.  
- Streamlined process-watching API and internal property names (`watchedPID`, `startWatchingPID`, `stopWatchingPIDInternal`).  
- Updated `Package.swift` (target and product names) to match `SleepManager`.  
- Switched documentation badges from Shields.io to Badgen.  
- Overhauled README:
  - Revised code examples, installation, configuration, and usage sections to reflect the new API.

### Fixed
- Enforced code-formatting consistency across `AssertionType`, `KernelHelpers`, and other modules.  
- Corrected minor typos and layout issues in README and source comments.  

## [0.1.0] – 2025‑04‑22

### Added

* Initial implementation of `CoffeeKit` actor for managing macOS power assertions.
* Support for creating multiple assertion types (`preventDisplaySleep`, `preventSystemIdleSleep`, `preventSystemSleep`, `preventUserIdleSleep`, `preventUserIdleSystemSleep`, `declareUserActivity`) with a custom reason string.
* Functionality to automatically release assertions after a specified timeout period.
* Functionality to monitor a given process ID (`pid_t`) using kqueue and automatically release assertions when that process exits.
* `isActive` computed property to check if assertions or process watching are currently active.
* `activeAssertionTypes` computed property returning a `Set<AssertionType>` of currently held assertions.
* Comprehensive error handling via the `CaffeinationError` enum.
* Logging integration using `swift-log`.
* Core lifecycle methods: `init`, `start()`, `stop()`, and `deinit` for cleanup.
* Helper function (`kernelReturnStatusString`) for converting `kern_return_t` status codes to human-readable strings.
* Basic Swift package structure (`Package.swift`, `.gitignore`) with `swift-log` dependency.
* Added `swift-testing` dependency for future test development.

### Changed

* Renamed the project and library target from `powerKit` to `coffeeKit`.
* Refactored the internal codebase by splitting the main `coffeeKit.swift` file into smaller, more focused source files: `AssertionType.swift`, `CaffinationError.swift`, `KernelHelpers.swift`, `coffeeKit.swift`, and `proccessWatching.swift`.

---

[Unreleased]: https://github.com/philocalyst/coffeeKit/compare/v0.2.0...HEAD  
[0.2.0]: https://github.com/philocalyst/coffeeKit/compare/v0.1.1...v0.2.0
[0.1.0]: https://github.com/philocalyst/coffeeKit/tree/b1e0672971ef9e0dd0d9ffb1c6ec9936ded3b5a7
