import Foundation
import Testing
@testable import Jetlink

/// Answers AppleScript calls in order, recording what was asked. Thread-safe:
/// the keeper runs scripts on its own queue.
final class RecordingRunner: @unchecked Sendable {
  private let lock = NSLock()
  private var replies: [(String?, String?)]
  private var index = 0
  private var sources: [String] = []

  init(replies: [(String?, String?)]) {
    self.replies = replies
  }

  func run(_ source: String) -> (String?, String?) {
    lock.lock()
    defer { lock.unlock() }
    sources.append(source)
    let reply = index < replies.count ? replies[index] : ("", nil)
    index += 1
    return reply
  }

  var calls: [String] {
    lock.lock()
    defer { lock.unlock() }
    return sources
  }
}

@MainActor
private func waitUntil(_ condition: @escaping () -> Bool) async -> Bool {
  for _ in 0..<150 {
    if condition() { return true }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return condition()
}

@Suite struct AmphetamineKeeperTests {

  @MainActor @Test func startsASessionAndEndsOnlyWhatItStarted() async {
    let runner = RecordingRunner(replies: [("false", nil), ("", nil), ("true", nil), ("", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count == 3 })
    #expect(runner.calls[0].contains("session is active"))
    #expect(runner.calls[1].contains("start new session with options {duration:0, interval:0, displaySleepAllowed:false}"))
    #expect(runner.calls[2].contains("closed display mode enabled"))
    keeper.setActive(false)
    #expect(await waitUntil { runner.calls.count == 4 })
    #expect(runner.calls[3].contains("end session"))
  }

  @MainActor @Test func leavesASessionTheUserStartedAlone() async {
    let runner = RecordingRunner(replies: [("true", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count == 1 })
    keeper.setActive(false)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count == 1)
  }

  @MainActor @Test func aFailedStartIsNeverEnded() async {
    let runner = RecordingRunner(replies: [("false", nil), (nil, "not authorized")])
    let keeper = AmphetamineKeeper(runner: runner.run)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count == 2 })
    keeper.setActive(false)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count == 2)
  }

  @MainActor @Test func startingAgainAfterAFailureTriesOnceMore() async {
    let runner = RecordingRunner(replies: [("false", nil), (nil, "not authorized"), ("false", nil), ("", nil), ("true", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count == 2 })
    keeper.setActive(false)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count == 5 })
    #expect(runner.calls[3].contains("start new session"))
  }
}
