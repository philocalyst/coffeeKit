import Darwin
import Foundation
import IOKit.pwr_mgt
import Logging

public actor SleepManager {
  // MARK: - Private State

  private var activeAssertions: [AssertionType: IOPMAssertionID] = [:]
  private let assertionReason: String
  private let assertionTypes: Set<AssertionType>
  private let timeout: TimeInterval?
  private var watchedPID: pid_t?

  // kqueue/watch state
  internal var kqueueDescriptor: CInt = -1
  internal var kqueueShutdownPipe: (read: CInt, write: CInt) = (-1, -1)
  internal var isWatchingPID: Bool = false
  internal var processWatchingTask: Task<Void, Never>?

  internal let logger: Logger

  public var terminationHandler: (@Sendable (SleepManager) -> Void)?

  public var isActive: Bool {
    !activeAssertions.isEmpty || isWatchingPID
  }

  public var activeAssertionTypes: Set<AssertionType> {
    Set(activeAssertions.keys)
  }

  // MARK: - Init / Deinit

  public init(
    blocks: Set<AssertionType> = [.preventSystemIdleSleep, .preventDisplaySleep],
    reason: String = "Blocking system sleeping and shutdown",
    timeout: TimeInterval? = nil,
    watch PID: pid_t? = nil
  ) {
    self.assertionReason = reason
    self.assertionTypes = blocks
    self.timeout = timeout

    var baseLogger = Logger(
      label: Bundle.main.bundleIdentifier
        ?? "com.philocalyst.coffeeKit"
    )
    baseLogger[metadataKey: "reason"] = .string(reason)
    if let pid = PID {
      baseLogger[metadataKey: "watchedPIDOnInit"] = .stringConvertible(pid)
    }
    self.logger = baseLogger

    if let pid = PID, pid > 0 {
      self.watchedPID = pid
    } else if PID != nil {
      self.logger.error("Invalid PID provided: \(PID!). Disabling watch.")
      self.watchedPID = nil
    }
  }

  deinit {
    logger.debug("CoffeeKit deinit: scheduling async stop()")
    let capturedLogger = logger
    Task.detached { [weak self, capturedLogger] in
      if let strong = self {
        await strong.stop()
        capturedLogger.debug("Cleanup stop() completed in deinit task.")
      } else {
        capturedLogger.warning(
          "Actor deallocated before stop(); explicit stop() recommended."
        )
      }
    }
  }

  // MARK: - Public API

  public func start() async throws {
    guard !isActive else {
      logger.info("start() called but already active.")
      return
    }

    logger.debug(
      "Starting...",
      metadata: [
        "reason": .string(assertionReason),
        "types": .string(
          assertionTypes.map { $0.description }
            .joined(separator: ", ")),
        "timeout": .stringConvertible(timeout ?? -1),
        "watchedPID": .stringConvertible(watchedPID ?? -1),
      ])

    var created: [AssertionType: IOPMAssertionID] = [:]

    do {
      for type in assertionTypes {
        var assertionID = IOPMAssertionID(0)
        let status: kern_return_t

        if let ioKitType = type.ioKitAssertionType {
          status = IOPMAssertionCreateWithName(
            ioKitType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            assertionReason as CFString,
            &assertionID
          )
          guard status == kIOReturnSuccess else {
            logger.error(
              "Create failed \(type): \(kernelReturnStatusString(status))"
            )
            throw CaffeinationError.assertionCreationFailed(
              type: type, status: status
            )
          }
          created[type] = assertionID
          logger.debug("Created assertion \(type) (ID \(assertionID))")
          try applyTimeout(to: assertionID, type: type)

        } else if type == .declareUserActivity {
          status = IOPMAssertionDeclareUserActivity(
            assertionReason as CFString,
            kIOPMUserActiveLocal,
            &assertionID
          )
          guard status == kIOReturnSuccess else {
            logger.error(
              "Declare user activity failed: \(kernelReturnStatusString(status))"
            )
            throw CaffeinationError.userActivityDeclarationFailed(
              status: status
            )
          }
          created[type] = assertionID
          logger.debug("Declared user activity (ID \(assertionID))")
        }
      }

      activeAssertions = created

      if let pid = watchedPID {
        guard isProcessRunning(pid: pid) else {
          logger.error("PID \(pid) not running.")
          rollbackAssertions(created)
          throw CaffeinationError.processNotFound(pid: pid)
        }
        try startWatchingPID(pid)
        isWatchingPID = true
        logger.debug("Watching PID \(pid).")
      }

      logger.info("Started successfully.")
    } catch {
      logger.error("Start failed—rolling back: \(error)")
      rollbackAssertions(created)
      if isWatchingPID {
        stopWatchingPIDInternal()
        isWatchingPID = false
      }
      throw error
    }
  }

  public func stop() async {
    guard isActive else {
      logger.debug("stop() called but already stopped.")
      return
    }

    logger.debug("Stopping...")

    if isWatchingPID {
      stopWatchingPIDInternal()
      isWatchingPID = false
      logger.debug("Stopped watching PID.")
    }

    let count = activeAssertions.count
    if count > 0 {
      activeAssertions.values.forEach(releaseAssertion(id:))
      activeAssertions.removeAll()
      logger.debug("Released \(count) assertion(s).")
    }

    logger.info("Stopped.")
    terminationHandler?(self)
  }

  // MARK: - Internal Helpers

  private func applyTimeout(
    to assertionID: IOPMAssertionID, type: AssertionType
  ) throws {
    guard let t = timeout, t > 0 else { return }
    let timeoutKey = kIOPMAssertionTimeoutKey as CFString
    let actionKey = kIOPMAssertionTimeoutActionKey as CFString
    let actionValue = kIOPMAssertionTimeoutActionRelease as CFString

    if IOPMAssertionSetProperty(
      assertionID, timeoutKey, t as CFNumber
    ) != kIOReturnSuccess {
      logger.warning("Failed to set timeout for \(type).")
    }
    if IOPMAssertionSetProperty(
      assertionID, actionKey, actionValue
    ) == kIOReturnSuccess {
      logger.debug("Set timeout \(t)s for \(type).")
    } else {
      logger.warning("Failed to set timeout action for \(type).")
    }
  }

  private func releaseAssertion(id: IOPMAssertionID) {
    guard id != 0 else { return }
    let status = IOPMAssertionRelease(id)
    if status != kIOReturnSuccess {
      logger.error(
        "Release \(id) failed: \(kernelReturnStatusString(status))"
      )
    }
  }

  private func isProcessRunning(pid: pid_t) -> Bool {
    errno = 0
    return kill(pid, 0) == 0 || errno == EPERM
  }

  private func rollbackAssertions(_ dict: [AssertionType: IOPMAssertionID]) {
    dict.values.forEach(releaseAssertion(id:))
    activeAssertions.removeAll()
  }
}
