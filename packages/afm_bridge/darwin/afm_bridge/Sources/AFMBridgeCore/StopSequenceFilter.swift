/// 스트리밍 텍스트에 `stop` 시퀀스를 적용한다.
///
/// 모델은 stop 을 지원하지 않으므로 출력 후처리로 자른다. stop 문자열이 청크 경계에 걸칠 수 있어
/// `최장 stop 길이 - 1` 글자는 내보내지 않고 보류한다.
public struct StopSequenceFilter: Sendable {
  public let stops: [String]
  private var pending = ""
  public private(set) var isStopped = false
  private let holdBack: Int

  public init(stops: [String]) {
    self.stops = stops.filter { !$0.isEmpty }
    self.holdBack = max(0, (self.stops.map(\.count).max() ?? 0) - 1)
  }

  /// 새 텍스트를 넣고, 지금 안전하게 내보낼 수 있는 텍스트를 돌려준다.
  public mutating func feed(_ text: String) -> String {
    guard !isStopped else { return "" }
    guard !stops.isEmpty else { return text }
    pending += text
    if let range = earliestStop(in: pending) {
      isStopped = true
      let output = String(pending[..<range.lowerBound])
      pending = ""
      return output
    }
    let emitCount = pending.count - holdBack
    guard emitCount > 0 else { return "" }
    let splitIndex = pending.index(pending.startIndex, offsetBy: emitCount)
    let output = String(pending[..<splitIndex])
    pending = String(pending[splitIndex...])
    return output
  }

  /// 스트림 종료 시 보류 중인 텍스트를 내보낸다.
  public mutating func flush() -> String {
    defer { pending = "" }
    return isStopped ? "" : pending
  }

  /// 완성된 텍스트에 stop 을 적용한다. (잘렸는지 여부 포함)
  public static func apply(_ stops: [String], to text: String) -> (text: String, stopped: Bool) {
    var filter = StopSequenceFilter(stops: stops)
    let output = filter.feed(text) + filter.flush()
    return (output, filter.isStopped)
  }

  private func earliestStop(in text: String) -> Range<String.Index>? {
    stops.compactMap { text.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
  }
}

/// 누적 스냅샷 → delta 변환 (Foundation Models 스트림은 매번 전체 텍스트를 준다)
public struct SnapshotDiffer: Sendable {
  public private(set) var emitted = ""

  public init() {}

  /// 새 스냅샷에서 아직 내보내지 않은 부분. 이전 출력과 prefix 가 어긋나면 빈 문자열.
  public mutating func delta(for snapshot: String) -> String {
    guard snapshot.count > emitted.count, snapshot.hasPrefix(emitted) else { return "" }
    let delta = String(snapshot.dropFirst(emitted.count))
    emitted = snapshot
    return delta
  }
}
