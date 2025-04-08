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

