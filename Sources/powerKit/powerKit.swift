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

