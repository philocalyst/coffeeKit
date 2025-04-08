//////////
// This module is meant to manage power assertions related to the prevention of desktop sleep and idiling
//////////

import Darwin  // For kqueue, kevent, pid_t, signal constants, pipe, fcntl, strerror, EPERM, EBADF, NOTE_EXIT, EVFILT_PROC, EVFILT_READ, EV_ADD, EV_ENABLE, EV_ONESHOT, O_NONBLOCK, F_GETFL, F_SETFL, EINTR
import Foundation
import IOKit.pwr_mgt  // For the vital Power Management headers
import Logging

// MARK: - coffeeKit Actor

let libName = "coffeeKit"
let maintainer = "philocalyst"

public actor CoffeeKit {
	// MARK: - Public Enums

	// This enum defines the type of power assertion to create. Conforms to Sendable.
	public enum AssertionType: CaseIterable, Sendable {
		case preventDisplaySleep
		case preventSystemIdleSleep
		case preventSystemSleep
		case declareUserActivity
		case preventUserIdleSleep
		case preventUserIdleSystemSleep

		// Get the readable IOKit constant string for match
		internal var ioKitAssertionType: String? {
			switch self {
			case .preventDisplaySleep: return kIOPMAssertionTypeNoDisplaySleep as String
			case .preventSystemIdleSleep: return kIOPMAssertionTypeNoIdleSleep as String
			case .preventSystemSleep: return kIOPMAssertionTypePreventSystemSleep as String
			case .preventUserIdleSleep:
				return kIOPMAssertionTypePreventUserIdleDisplaySleep as String
			case .preventUserIdleSystemSleep:
				return kIOPMAssertionTypePreventUserIdleSystemSleep as String
			default: return nil
			}
		}

		var description: String {
			switch self {
			case .preventDisplaySleep: return "preventDisplaySleep"
			case .preventSystemIdleSleep: return "preventSystemIdleSleep"
			case .preventSystemSleep: return "preventSystemSleep"
			case .preventUserIdleSleep: return "preventUserIdleSleep"
			case .preventUserIdleSystemSleep: return "preventUserIdleSystemSleep"
			case .declareUserActivity: return "declareUserActivity"
			}
		}
	}

	public enum CaffeinationError: Error, Sendable {
		case assertionCreationFailed(type: AssertionType, status: kern_return_t)
		case userActivityDeclarationFailed(status: kern_return_t)
		case kqueueCreationFailed(error: String)
		case kqueueEventRegistrationFailed(error: String)
		case kqueueMonitorStartFailed
		case pipeCreationFailed(error: String)
		case fcntlFailed(error: String)
		case processWatchNotSupported
		case alreadyActive
		case processNotFound(pid: pid_t)
		case invalidPID(pid: pid_t)
	}

	// MARK: - Actor State (Protected)

	// Class state
	private var activeAssertions: [AssertionType: IOPMAssertionID] = [:]
	private let assertionReason: String
	private let assertionTypes: Set<AssertionType>
	private let timeout: TimeInterval?
	private var watchedPID: pid_t?

	// kqueue related properties
	private var kqueueDescriptor: CInt = -1
	private var kqueueShutdownPipe: (read: CInt, write: CInt) = (-1, -1)
	private var isWatchingPID: Bool = false
	private var processWatchingTask: Task<Void, Never>?  // Task handle for kqueue monitoring

	// Logger instance - initialized in init
	private let logger: Logger

	public var isActive: Bool {
		return !activeAssertions.isEmpty || isWatchingPID
	}

	public var terminationHandler: (@Sendable (CoffeeKit) -> Void)?

	public init(
		reason: String,
		types: Set<AssertionType> = [.preventSystemIdleSleep, .preventDisplaySleep],
		timeout: TimeInterval? = nil,
		watchPID: pid_t? = nil
	) {
		self.assertionReason = reason
		self.assertionTypes = types
		self.timeout = timeout

		// Set up the instance logger
		var baseLogger = Logger(
			label: (Bundle.main.bundleIdentifier ?? "com." + maintainer + "." + libName))

		// Spice some metadata on!
		baseLogger[metadataKey: "reason"] = .string(reason)
		if let pid = watchPID {
			baseLogger[metadataKey: "watchedPIDOnInit"] = .stringConvertible(pid)
		}
		self.logger = baseLogger

		// Validate PID during init
		if let pid = watchPID, pid <= 0 {
			// Must use the init logger
			self.logger.error("Invalid PID provided: \(pid). Process watching will be disabled.")
			self.watchedPID = nil
		} else {
			self.watchedPID = watchPID
		}
	}

	deinit {
		logger.debug("NativeCaffeinator deinit: Scheduling async stop task.")

		// Capture the logger instance along with weak self for the detached task
		let capturedLogger = self.logger
		Task.detached { [weak self, capturedLogger] in  // Capture logger by value
			// Check if the actor instance still exists when the task actually executes.
			if let strongSelf = self {
				// If the actor still exists, call its stop method.
				await strongSelf.stop()
				// Use the logger captured by the task
				capturedLogger.debug("NativeCaffeinator deinit task completed stop().")
			} else {
				// The actor was deallocated before this task could call stop.
				// Log using the captured logger.
				capturedLogger.warning(
					"NativeCaffeinator deallocated before deinit task could run stop(). Explicit stop() call is recommended for guaranteed cleanup."
				)
			}
		}
	}

	// MARK: - Public Actor Methods (Require await)

	/// Starts the power assertions and process watching if configured.
	public func start() async throws {
		// Check state within the actor's isolated context
		guard !isActive else {
			logger.info("Attempted to start an already active Caffeinator.")
			// throw CaffeinationError.alreadyActive
			return
		}

		// Spicy metadata for effective debugging
		logger.debug(
			"Starting Caffeinator...",
			metadata: [
				"reason": .string(assertionReason),
				"types": .string(assertionTypes.map { $0.description }.joined(separator: ", ")),
				"timeout": .stringConvertible(timeout ?? -1),
				"watchedPID": .stringConvertible(watchedPID ?? -1),
			])

		var createdIDs: [AssertionType: IOPMAssertionID] = [:]

		do {
			// Assertion time!! Create based on config ;)
			for type in assertionTypes {
				var assertionID: IOPMAssertionID = IOPMAssertionID(0)
				let status: kern_return_t

				if let ioKitType = type.ioKitAssertionType {
					status = IOPMAssertionCreateWithName(
						ioKitType as CFString,  // bruh
						IOPMAssertionLevel(kIOPMAssertionLevelOn),
						assertionReason as CFString,
						&assertionID
					)
					guard status == kIOReturnSuccess else {
						logger.error(
							"Failed to create assertion \(type.description): \(kernelReturnStatusString(status)) (\(status))"
						)
						throw CaffeinationError.assertionCreationFailed(type: type, status: status)
					}
					createdIDs[type] = assertionID
					logger.debug("Created assertion: \(type.description) (ID: \(assertionID))")

					// Apply Timeout if needed
					try applyTimeout(to: assertionID, type: type)

				} else if type == .declareUserActivity {
					status = IOPMAssertionDeclareUserActivity(
						assertionReason as CFString, kIOPMUserActiveLocal, &assertionID)
					guard status == kIOReturnSuccess else {
						logger.error(
							"Failed to declare user activity: \(kernelReturnStatusString(status)) (\(status))"
						)
						throw CaffeinationError.userActivityDeclarationFailed(status: status)
					}
					createdIDs[type] = assertionID
					logger.debug("Declared user activity (ID: \(assertionID))")
				}
			}

			// Update actor state to reflected new IDs
			self.activeAssertions = createdIDs

			// Welcome to process watching (if PID provided)
			if let pid = watchedPID {
				guard isProcessRunning(pid: pid) else {
					logger.error("Process with PID \(pid) not found. Cannot start watching.")
					// Drop assertions before throwing
					createdIDs.values.forEach { releaseAssertion(id: $0) }
					self.activeAssertions.removeAll()
					throw CaffeinationError.processNotFound(pid: pid)
				}
				try startWatchingPID(pid)
				self.isWatchingPID = true
				logger.debug("Started watching PID \(pid).")
			}

			logger.info("Caffeinator started successfully.")

		} catch {
			// If failure, rollback
			logger.error(
				"Rolling back Caffeinator start due to error: \(error.localizedDescription)",
				metadata: ["error_details": .string("\(error)")])
			// Assertion drop
			createdIDs.values.forEach { releaseAssertion(id: $0) }  // Uses logger internally now
			self.activeAssertions.removeAll()  // Ensure state is clean

			// Stop watching if it somehow partially started from the CLI or elsewhere
			if isWatchingPID {
				stopWatchingPIDInternal()
				self.isWatchingPID = false
			}
			throw error
		}
	}

