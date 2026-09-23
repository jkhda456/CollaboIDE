import Foundation

/// iOS 16 / macOS 13 에서도 쓸 수 있는 간단한 락 (Synchronization.Mutex 는 iOS 18 / macOS 15+).
public final class Locked<Value>: @unchecked Sendable {
  private var value: Value
  private let lock = NSLock()

  public init(_ value: Value) {
    self.value = value
  }

  @discardableResult
  public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
