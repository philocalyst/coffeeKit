import Foundation

/// Errors thrown by `CoffeeKit`.
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
