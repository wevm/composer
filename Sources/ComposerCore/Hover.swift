import Foundation
import Observation

/// What the pointer is over: a token or a link, and where it is drawn, in
/// the view's coordinates.
public struct HoverTarget: Sendable, Equatable {
  public enum Kind: Sendable, Hashable {
    case node(AtomicNode)
    /// A link's destination.
    case link(String)
  }

  public var kind: Kind
  /// The target's document range, which tells two equal tokens apart.
  public var range: DocumentRange
  /// The rect to anchor a card or tooltip to.
  public var anchor: CGRect

  public init(kind: Kind, range: DocumentRange, anchor: CGRect) {
    self.kind = kind
    self.range = range
    self.anchor = anchor
  }

  /// The same target, wherever it is drawn: anchors move as text lays out.
  func isSame(as other: HoverTarget) -> Bool { kind == other.kind && range == other.range }
}

/// Hover intent, as a pure state machine over time (in seconds): a target
/// shows after the pointer rests on it for `openDelay`, and stays for
/// `gracePeriod` after the pointer leaves, so the pointer can travel from the
/// text to the card; while the card itself is hovered, it stays.
public struct HoverIntent: Sendable, Equatable {
  public static let openDelay: TimeInterval = 0.5
  public static let gracePeriod: TimeInterval = 0.15

  /// The target to show, if any.
  public private(set) var shown: HoverTarget?
  private var pending: HoverTarget?
  private var pendingSince: TimeInterval = 0
  private var leftAt: TimeInterval?
  private var isOverCard = false

  public init() {}

  /// The pointer moved over `target` (`nil`: over nothing hoverable).
  public mutating func pointer(over target: HoverTarget?, at now: TimeInterval) {
    if let shown, let target, target.isSame(as: shown) {
      // Back on the shown target: it stays, at its new anchor.
      self.shown = target
      leftAt = nil
      pending = nil
      return
    }
    if shown != nil, leftAt == nil, !isOverCard { leftAt = now }
    if let target {
      if pending.map({ !$0.isSame(as: target) }) ?? true { pendingSince = now }
      pending = target
    } else {
      pending = nil
    }
    advance(to: now)
  }

  /// The pointer entered or left the card showing the target.
  public mutating func card(isHovered: Bool, at now: TimeInterval) {
    isOverCard = isHovered
    if isHovered {
      leftAt = nil
    } else if shown != nil {
      leftAt = now
    }
    advance(to: now)
  }

  /// Dismisses the target at once, as a click or scroll does.
  public mutating func dismiss() {
    shown = nil
    pending = nil
    leftAt = nil
    isOverCard = false
  }

  /// Applies the delays that have run out by `now`. Returns when the next
  /// one runs out, if one is pending, to schedule a call then.
  @discardableResult
  public mutating func advance(to now: TimeInterval) -> TimeInterval? {
    // A tolerance, so a call scheduled for a deadline meets it.
    let now = now + 1e-9
    if let left = leftAt, now - left >= Self.gracePeriod {
      shown = nil
      leftAt = nil
      isOverCard = false
    }
    if let pending, shown == nil, now - pendingSince >= Self.openDelay {
      shown = pending
      self.pending = nil
    }
    var next: TimeInterval?
    if let left = leftAt { next = left + Self.gracePeriod }
    if pending != nil {
      let open = max(pendingSince + Self.openDelay, next ?? 0)
      next = next.map { min($0, open) } ?? open
    }
    return next
  }
}

/// Hover for a text view: feeds pointer moves into a `HoverIntent` and runs
/// its delays, publishing the target to show. The input's is
/// `ComposerController.hover`; read-only content views have their own.
@MainActor @Observable
public final class HoverTracker {
  /// The hovered token or link to show a card or tooltip for.
  public private(set) var target: HoverTarget?
  @ObservationIgnored private var intent = HoverIntent()
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private let start = ContinuousClock.now

  public init() {}

  private var now: TimeInterval {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
  }

  public func pointer(over target: HoverTarget?) {
    intent.pointer(over: target, at: now)
    publish()
  }

  /// Report the card's hover, so it stays open while the pointer is on it.
  public func card(isHovered: Bool) {
    intent.card(isHovered: isHovered, at: now)
    publish()
  }

  public func dismiss() {
    intent.dismiss()
    publish()
  }

  private func publish() {
    let next = intent.advance(to: now)
    if intent.shown != target { target = intent.shown }
    timer?.cancel()
    guard let next else { return }
    let delay = max(next - now, 0) + 0.001
    timer = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.publish()
    }
  }
}

extension Document {
  /// The token or link at a document position, for hover, taps, and context
  /// menus: a token whose unit starts at `position`, or the text with one
  /// link around the unit after it.
  public func hoverKind(at position: Int) -> (kind: HoverTarget.Kind, range: DocumentRange)? {
    guard let block = textBlock(containing: Position(position)),
      case .paragraph(let inlines) = block.content
    else { return nil }
    var runs: [(inline: Inline, start: Int)] = []
    var offset = block.range.lowerBound.offset
    for inline in inlines {
      runs.append((inline, offset))
      offset += inline.length
    }
    guard
      let index = runs.firstIndex(where: {
        $0.start <= position && position < $0.start + $0.inline.length
      })
    else { return nil }
    let (inline, start) = runs[index]
    switch inline {
    case .node(let node):
      return (.node(node), Position(start)..<Position(start + 1))
    case .text(_, let marks):
      guard let url = marks.link else { return nil }
      func linked(_ run: Inline) -> Bool {
        if case .text(_, let marks) = run { return marks.link == url }
        return false
      }
      var (lower, upper) = (index, index)
      while lower > 0, linked(runs[lower - 1].inline) { lower -= 1 }
      while upper + 1 < runs.count, linked(runs[upper + 1].inline) { upper += 1 }
      let end = runs[upper].start + runs[upper].inline.length
      return (.link(url), Position(runs[lower].start)..<Position(end))
    case .unknown:
      return nil
    }
  }
}
