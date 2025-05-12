import Darwin

/// Human‑readable string for Mach/POSIX error codes.
internal func kernelReturnStatusString(_ status: kern_return_t) -> String {
  // Try Mach error string first
  if let cString = mach_error_string(status) {
    let str = String(cString: cString)
    if !str.isEmpty { return str }
  }
  // Fallback to POSIX strerror
  if let cString = strerror(status) {
    let str = String(cString: cString)
    if !str.isEmpty && str != "Unknown error: \(status)" {
      return str
    }
  }
  return "Unknown Error Code \(status)"
}
