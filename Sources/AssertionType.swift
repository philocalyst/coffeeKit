import Foundation
import IOKit.pwr_mgt

/// Defines the type of power assertion to create.
public enum AssertionType: CaseIterable, Sendable {
	case preventDisplaySleep
	case preventSystemIdleSleep
	case preventSystemSleep
	case declareUserActivity
	case preventUserIdleSleep
	case preventUserIdleSystemSleep

	/// The matching IOKit assertion type string, if any.
	internal var ioKitAssertionType: String? {
		switch self {
		case .preventDisplaySleep:
			return kIOPMAssertionTypeNoDisplaySleep as String
		case .preventSystemIdleSleep:
			return kIOPMAssertionTypeNoIdleSleep as String
		case .preventSystemSleep:
			return kIOPMAssertionTypePreventSystemSleep as String
		case .preventUserIdleSleep:
			return kIOPMAssertionTypePreventUserIdleDisplaySleep as String
		case .preventUserIdleSystemSleep:
			return kIOPMAssertionTypePreventUserIdleSystemSleep as String
		default:
			return nil
		}
	}

	public var description: String {
		switch self {
		case .preventDisplaySleep:
			return "preventDisplaySleep"
		case .preventSystemIdleSleep:
			return "preventSystemIdleSleep"
		case .preventSystemSleep:
			return "preventSystemSleep"
		case .preventUserIdleSleep:
			return "preventUserIdleSleep"
		case .preventUserIdleSystemSleep:
			return "preventUserIdleSystemSleep"
		case .declareUserActivity:
			return "declareUserActivity"
		}
	}
}
