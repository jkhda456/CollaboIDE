/// 동시 생성 수 제한. 한 세션은 한 번에 한 요청만 처리할 수 있고,
/// 여러 세션을 동시에 돌려도 온디바이스 모델은 사실상 순차 처리하므로 큐잉한다.
actor AsyncLimiter {
  private let limit: Int
  private var running = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async {
    if running < limit {
      running += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      running -= 1
    } else {
      waiters.removeFirst().resume()
    }
  }

  func withPermit<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await body()
  }
}
