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

	/// Stops the power assertions and process watching.
	public func stop() async {
		guard isActive else {  // Check state within actor
			logger.debug("Caffeinator already stopped.")
			return
		}

		logger.debug("Stopping Caffeinator...")

		// Stop process watching first
		if isWatchingPID {
			stopWatchingPIDInternal()  // Stop the task and clean up resources
			self.isWatchingPID = false  // Update state
			logger.debug("Stopped watching PID.")
		}

		// Release all active assertions
		let assertionCount = activeAssertions.count
		if assertionCount > 0 {
			activeAssertions.values.forEach { releaseAssertion(id: $0) }  // Uses logger internally now
			activeAssertions.removeAll()
			logger.debug("Released \(assertionCount) assertion(s).")
		}

		logger.info("Caffeinator stopped.")

		// Call termination handler IF provided
		terminationHandler?(self)  // Passing actor instance
	}

	// MARK: - Private Helper Methods (For use within the acteur)

	private func applyTimeout(to assertionID: IOPMAssertionID, type: AssertionType) throws {
		guard let timeoutValue = timeout, timeoutValue > 0 else { return }

		// AHHH WHY THE PREFIXES WHY WHY WHY TS UGLY
		let timeoutKey = kIOPMAssertionTimeoutKey as CFString
		let timeoutActionKey = kIOPMAssertionTimeoutActionKey as CFString
		let timeoutActionValue = kIOPMAssertionTimeoutActionRelease as CFString

		var success =
			IOPMAssertionSetProperty(assertionID, timeoutKey, timeoutValue as CFNumber)
			== kIOReturnSuccess
		if !success {
			logger.warning("Failed to set timeout value for \(type.description)")
		}

		success =
			IOPMAssertionSetProperty(assertionID, timeoutActionKey, timeoutActionValue)
			== kIOReturnSuccess
		if !success {
			logger.warning("Failed to set timeout action for \(type.description)")
		} else {  // Only log success if action was set successfully
			logger.debug("Set timeout \(timeoutValue)s for \(type.description)")
		}
	}

	/// Releases a specific power assertion.
	private func releaseAssertion(id: IOPMAssertionID) {
		guard id != IOPMAssertionID(0) else { return }
		let status = IOPMAssertionRelease(id)
		if status != kIOReturnSuccess {
			logger.error(
				"Error releasing assertion ID \(id): \(kernelReturnStatusString(status)) (\(status))"
			)
		}
	}

	/// Checks if a process with the given PID is running.
	private func isProcessRunning(pid: pid_t) -> Bool {
		errno = 0  // Reset errno before calling kill
		return kill(pid, 0) == 0 || errno == EPERM
	}

	// MARK: - Kqueue Process Watching Implementation (Actor Internal)

	/// Sets up kqueue/pipes and starts the background monitoring Task.
	private func startWatchingPID(_ pid: pid_t) throws {
		// Ensure previous task is cleaned up if any (shouldn't happen if isActive is checked, but you never know!!)
		if processWatchingTask != nil {
			logger.debug("Stopping existing watcher task before starting new one.")
			stopWatchingPIDInternal()
		}

		// Shutdown pipe
		var pipeFileDescriptors = [Int32](repeating: -1, count: 2)
		let result = pipe(&pipeFileDescriptors)

		guard result == 0 else {
			let errorString = String(cString: strerror(errno))
			logger.error("Pipe creation failed: \(errorString)")
			throw CaffeinationError.pipeCreationFailed(error: errorString)
		}

		// Assign immediately to actor state
		self.kqueueShutdownPipe = (pipeFileDescriptors[0], pipeFileDescriptors[1])

		// Writing ending
		let flags = fcntl(self.kqueueShutdownPipe.write, F_GETFL)
		guard flags != -1 else {
			let errorStr = String(cString: strerror(errno))
			let fullErrorDesc = "F_GETFL: \(errorStr)"
			logger.error("fcntl failed: \(fullErrorDesc)")
			closePipeFDs()  // Clean up pipe
			throw CaffeinationError.fcntlFailed(error: fullErrorDesc)
		}
		let fcntlResult = fcntl(self.kqueueShutdownPipe.write, F_SETFL, flags | O_NONBLOCK)
		guard fcntlResult != -1 else {
			let errorStr = String(cString: strerror(errno))
			let fullErrorDesc = "F_SETFL O_NONBLOCK: \(errorStr)"
			logger.error("fcntl failed: \(fullErrorDesc)")
			closePipeFDs()  // Clean up pipe
			throw CaffeinationError.fcntlFailed(error: fullErrorDesc)
		}

		let kq = kqueue()
		guard kq != -1 else {
			let errorStr = String(cString: strerror(errno))
			logger.error("kqueue creation failed: \(errorStr)")
			closePipeFDs()  // Clean up pipe
			throw CaffeinationError.kqueueCreationFailed(error: errorStr)
		}
		self.kqueueDescriptor = kq

		// kevents configuration
		let processEvent = kevent(
			ident: UInt(pid), filter: Int16(EVFILT_PROC),
			flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT), fflags: UInt32(NOTE_EXIT), data: 0,
			udata: nil)
		let pipeEvent = kevent(
			ident: UInt(self.kqueueShutdownPipe.read), filter: Int16(EVFILT_READ),
			flags: UInt16(EV_ADD | EV_ENABLE), fflags: 0, data: 0, udata: nil)

		// Register possible events
		let eventsToRegister = [processEvent, pipeEvent]
		let registerResult = kevent(
			kq,
			eventsToRegister,
			Int32(eventsToRegister.count),
			nil,
			0,
			nil)

		guard registerResult != -1 else {
			let errorStr = String(cString: strerror(errno))
			logger.error("kqueue event registration failed: \(errorStr)")
			// Cleanup
			closeKQueueFD()
			closePipeFDs()
			throw CaffeinationError.kqueueEventRegistrationFailed(error: errorStr)
		}

		// Welcome to monitoring of kqs!
		let capturedKQ = self.kqueueDescriptor
		let capturedPipeReadFD = self.kqueueShutdownPipe.read
		let capturedPID = pid
		// Capture logger instance for the task
		let capturedLogger = self.logger

		self.processWatchingTask = Task.detached(priority: .utility) {
			[weak self, capturedLogger] in  // Capture logger
			guard let actorInstance = self else {
				// Use captured logger
				capturedLogger.info(
					"NativeCaffeinator actor deallocated before kqueue task could run.")
				// Best effort cleanup of captured FDs if actor is gone
				if capturedKQ != -1 { close(capturedKQ) }
				if capturedPipeReadFD != -1 { close(capturedPipeReadFD) }
				return
			}
			// Pass captured logger to the loop function
			await actorInstance.runKqueueMonitorLoop(
				kq: capturedKQ, pipeReadFD: capturedPipeReadFD, watchedPID: capturedPID,
				taskLogger: capturedLogger)
		}
		logger.debug("Kqueue monitoring task started.")  // Log using instance logger
	}

	/// Stops the kqueue monitoring task and cleans up related resources. (Synchronous internal helper)
	private func stopWatchingPIDInternal() {
		guard let task = processWatchingTask else {
			logger.debug("stopWatchingPIDInternal called but no task found.")
			return  // No task to stop
		}

		logger.debug("Stopping kqueue monitoring task...")

		// 1. Cancel the Task
		task.cancel()
		self.processWatchingTask = nil  // Remove reference to allow task cleanup

		// 2. Signal via Pipe (to potentially unblock kevent immediately)
		let pipeWriteFD = self.kqueueShutdownPipe.write
		if pipeWriteFD != -1 {
			let dummy: UInt8 = 0
			_ = write(pipeWriteFD, [dummy], 1)  // Best effort signal
			// Write end is closed below
		}

		// 3. Close File Descriptors (this will also cause kevent to fail in the task)
		closeKQueueFD()
		closePipeFDs()

		logger.debug("Kqueue monitoring resources cleaned up.")
	}

	/// Closes the kqueue descriptor if open.
	private func closeKQueueFD() {
		if kqueueDescriptor != -1 {
			close(kqueueDescriptor)
			kqueueDescriptor = -1
		}
	}

	/// Closes both pipe file descriptors if open.
	private func closePipeFDs() {
		if kqueueShutdownPipe.read != -1 {
			close(kqueueShutdownPipe.read)
			kqueueShutdownPipe.read = -1
		}
		if kqueueShutdownPipe.write != -1 {
			close(kqueueShutdownPipe.write)
			kqueueShutdownPipe.write = -1
		}
	}

	/// The actual kqueue monitoring loop, run by the detached Task.
	/// Accepts the logger instance to use.
	private func runKqueueMonitorLoop(
		kq: CInt, pipeReadFD: CInt, watchedPID: pid_t, taskLogger: Logger
	) async {
		// Use the passed-in logger for all logging within this task loop
		taskLogger.debug(
			"kqueue monitor loop started.",
			metadata: ["kq": .stringConvertible(kq), "pipe_read": .stringConvertible(pipeReadFD)])

		var triggeredEvent = kevent()
		var keepMonitoring = true

		while keepMonitoring && !Task.isCancelled {
			// Blocking call to wait for events (process exit OR pipe read)
			// Add a timeout (e.g., 1 second) to allow periodic Task.isCancelled checks
			var timeoutSpec = timespec(tv_sec: 1, tv_nsec: 0)
			let eventCount = kevent(kq, nil, 0, &triggeredEvent, 1, &timeoutSpec)

			if Task.isCancelled {
				taskLogger.debug("kqueue monitor loop detected cancellation.")
				keepMonitoring = false
				break  // Exit loop immediately on cancellation
			}

			if eventCount > 0 {
				// Event received
				if triggeredEvent.filter == Int16(EVFILT_PROC)
					&& (triggeredEvent.fflags & NOTE_EXIT) != 0
				{
					taskLogger.info(
						"Detected exit of watched process.",
						metadata: ["pid": .stringConvertible(triggeredEvent.ident)])
					// Call back into the actor to handle the stop logic
					await self.handleProcessExit()  // Let the actor handle state changes and cleanup
					keepMonitoring = false  // Stop monitoring after process exit
				} else if triggeredEvent.filter == Int16(EVFILT_READ)
					&& triggeredEvent.ident == UInt(pipeReadFD)
				{
					taskLogger.debug("kqueue monitor loop received shutdown signal via pipe.")
					keepMonitoring = false  // Stop monitoring on shutdown signal
				} else {
					// Unexpected event
					taskLogger.debug(
						"kqueue monitor loop woke up for unexpected event.",
						metadata: [
							"filter": .stringConvertible(triggeredEvent.filter),
							"flags": .stringConvertible(triggeredEvent.flags),
							"fflags": .stringConvertible(triggeredEvent.fflags),
							"ident": .stringConvertible(triggeredEvent.ident),
						])
					// Continue monitoring unless it's an error
				}
			} else if eventCount == 0 {
				// Timeout occurred, loop will check Task.isCancelled and continue
				continue
			} else {  // eventCount == -1 (Error)
				let errorNum = errno
				if errorNum == EBADF {
					// Expected when FDs are closed by stopWatchingPIDInternal
					taskLogger.debug(
						"kqueue monitor loop kevent failed (EBADF), likely intentional shutdown.")
				} else if errorNum == EINTR {
					// Interrupted by a signal, safe to continue
					taskLogger.debug("kqueue monitor loop kevent interrupted (EINTR), continuing.")
					continue
				} else {
					// Unexpected error
					taskLogger.error(
						"kqueue monitor loop kevent call failed.",
						metadata: [
							"errno": .stringConvertible(errorNum),
							"description": .string(String(cString: strerror(errorNum))),
						])
				}
				keepMonitoring = false  // Stop monitoring on unhandled error or EBADF
			}
		}

		taskLogger.debug(
			"kqueue monitor loop finished.",
			metadata: ["kq": .stringConvertible(kq), "watchedPID": .stringConvertible(watchedPID)])
	}

	/// Called by the monitoring task when the watched process exits. Runs on the actor.
	private func handleProcessExit() async {
		logger.debug("Handling process exit within actor.")
		// Needed check here in case stop was called manually
		if self.isWatchingPID {
			logger.info("Process exited, initiating stop.")
			// Call the main stop method to perform full cleanup
			await self.stop()
		} else {
			logger.debug("Process exited, but watching was already stopped. Ignoring.")
		}
	}
}

// MARK: - Helper Functions (Global or Static)

// Provides a "human-readable" (HEAVY QUOTES) string for annoying XNU kernel return codes (Mach errors).
private func kernelReturnStatusString(_ status: kern_return_t) -> String {
	// Use mach_error_string for Mach kernel errors
	if let cString = mach_error_string(status) {
		// Ensure the string is valid before returning
		let str = String(cString: cString)
		if !str.isEmpty {
			return str
		}
	}
	// Fallback for POSIX/BSD errors or if mach_error_string fails
	if let cString = strerror(status) {
		let str = String(cString: cString)
		if !str.isEmpty && str != "Unknown error: \(status)" {  // strerror might return this
			return str
		}
	}
	// Absolute fallback
	return "Unknown Error Code \(status)"
}
