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

/// A mutable battery level the tests drop to hit the floor.
final class BatteryBox {
  var percent: Int
  init(_ percent: Int) { self.percent = percent }
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
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    #expect(runner.calls[0].contains("session is active"))
    #expect(runner.calls[1].contains("start new session with options {duration:8, interval:hours, displaySleepAllowed:false}"))
    #expect(runner.calls[2].contains("closed display mode enabled"))
    #expect(keeper.status == .active)
    keeper.setActive(false)
    #expect(await waitUntil { runner.calls.count >= 4 })
    #expect(runner.calls[3].contains("end session"))
    #expect(keeper.status == .idle)
  }

  @MainActor @Test func leavesAnInfiniteSessionTheUserStartedAlone() async {
    // zero seconds left means infinite: never downgraded to the capped hours
    let runner = RecordingRunner(replies: [("true", nil), ("0", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 2 })
    #expect(runner.calls[1].contains("session time remaining"))
    #expect(keeper.status == .foreignSession)
    keeper.setActive(false)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count == 2)
  }

  @MainActor @Test func aShorterForeignSessionIsReplaced() async {
    // 30 min left against the default 8 h: ours is at least as long, so the
    // start replaces it on the spot and jetlink owns the session from then on
    let runner = RecordingRunner(replies: [
      ("true", nil), ("1800", nil),
      ("", nil), ("true", nil),
    ])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 4 })
    #expect(runner.calls[2].contains("start new session"))
    #expect(keeper.status == .active)
  }

  @MainActor @Test func aLongerForeignSessionIsInheritedWhenItEnds() async {
    // 12 h left against 8 h: stand down, poll it on the tick, and the first
    // start after it ends takes over
    let runner = RecordingRunner(replies: [
      ("true", nil), ("43200", nil),
      ("true", nil), ("43190", nil),
      ("false", nil), ("", nil), ("true", nil),
    ])
    let clock = ClockBox(Date(timeIntervalSinceReferenceDate: 0))
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true },
                                   clock: { clock.date })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 2 })
    #expect(keeper.status == .foreignSession)
    clock.date = clock.date.addingTimeInterval(11)
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 4 })
    #expect(keeper.status == .foreignSession)
    clock.date = clock.date.addingTimeInterval(11)
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 7 })
    #expect(runner.calls[5].contains("start new session"))
    #expect(keeper.status == .active)
  }

  @MainActor @Test func aFailedStartIsNeverEnded() async {
    let runner = RecordingRunner(replies: [("false", nil), (nil, "osascript exited 1")])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 2 })
    #expect(keeper.status == .failed("osascript exited 1"))
    keeper.setActive(false)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count >= 2)
  }

  @MainActor @Test func aFailedEndRetriesOnTheNextTick() async {
    // the end fails once: the session is still up, the tick retries it after
    // the backoff, and nothing spins in between
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("true", nil),
      (nil, "osascript exited 1"),
      ("", nil),
    ])
    let clock = ClockBox(Date(timeIntervalSinceReferenceDate: 0))
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true },
                                   clock: { clock.date })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    keeper.setActive(false)
    #expect(await waitUntil { runner.calls.count >= 4 })
    #expect(keeper.status == .failed("osascript exited 1"))
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(runner.calls.count == 4)
    clock.date = clock.date.addingTimeInterval(11)
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 5 })
    #expect(runner.calls[4].contains("end session"))
    #expect(keeper.status == .idle)
  }

  @MainActor @Test func aDeniedStartReadsAsPermission() async {
    let runner = RecordingRunner(replies: [("false", nil), (nil, "execution error: Not authorized to send Apple events. (-1743)")])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 2 })
    #expect(keeper.status == .permissionDenied)
  }

  @MainActor @Test func aMachineWithoutABatteryNeverStarts() async {
    // desktops have no lid to close: the gate refuses before Amphetamine is
    // ever asked, whatever the toggle says
    let runner = RecordingRunner(replies: [])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true },
                                   hasBattery: false)
    keeper.setActive(true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.isEmpty)
    #expect(keeper.status == .idle)
  }

  @MainActor @Test func belowTheFloorAStartIsRefused() async {
    let runner = RecordingRunner(replies: [])
    let battery = BatteryBox(15)
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true },
                                  batteryLevel: { battery.percent }, floorPercent: { 20 })
    keeper.setActive(true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.isEmpty)
    #expect(keeper.status == .batteryFloor(20))
  }

  @MainActor @Test func aZeroFloorNeverEndsOrBlocksTheSession() async {
    // 0 means off: even a nearly empty battery neither refuses the start nor
    // ends a running session
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("true", nil),
      ("true", nil), ("600", nil),
    ])
    let battery = BatteryBox(5)
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true },
                                  batteryLevel: { battery.percent }, floorPercent: { nil })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 5 })
    #expect(keeper.status == .active)
  }

  @MainActor @Test func theFloorEndsAnActiveSessionAndHoldsItOff() async {
    let runner = RecordingRunner(replies: [("false", nil), ("", nil), ("true", nil), ("", nil)])
    let battery = BatteryBox(90)
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true },
                                  batteryLevel: { battery.percent }, floorPercent: { 20 })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    #expect(keeper.status == .active)
    battery.percent = 15
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 4 })
    #expect(runner.calls[3].contains("end session"))
    #expect(keeper.status == .batteryFloor(20))
    keeper.setActive(true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count >= 4)
  }

  @MainActor @Test func aMissingInstallIsReported() async {
    let runner = RecordingRunner(replies: [])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { false })
    keeper.setActive(true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.isEmpty)
    #expect(keeper.status == .notInstalled)
  }

  @MainActor @Test func theSessionCarriesTheConfiguredHours() async {
    let runner = RecordingRunner(replies: [("false", nil), ("", nil), ("true", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true }, sessionHours: { 24 })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    #expect(runner.calls[1].contains("start new session with options {duration:24, interval:hours, displaySleepAllowed:false}"))
  }

  @MainActor @Test func aKilledSessionIsRestartedByTheHealthCheck() async {
    // start: not active, started, closed-display ok; then the check finds it
    // gone, and the restart asks the same three questions again
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("true", nil),
      ("false", nil),
      ("false", nil), ("", nil), ("true", nil),
    ])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    #expect(keeper.status == .active)
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 7 })
    #expect(runner.calls[3].contains("session is active"))
    #expect(runner.calls[5].contains("start new session"))
    #expect(keeper.status == .active)
  }

  @MainActor @Test func aLiveSessionPassesTheHealthCheck() async {
    let runner = RecordingRunner(replies: [("false", nil), ("", nil), ("true", nil), ("true", nil), ("43200", nil)])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 5 })
    #expect(runner.calls[3].contains("session is active"))
    #expect(runner.calls[4].contains("session time remaining"))
    #expect(keeper.status == .active)
  }

  @MainActor @Test func aClosedDisplayWarningShowsAndSurvivesTheHealthCheck() async {
    // start: not active, started, then the closed-display preference reads
    // off: the session is up, but the lid close may sleep, and the health
    // check must not wash the warning away
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("false", nil),
      ("true", nil), ("600", nil),
    ])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    #expect(keeper.status == .maySleepWhenClosed)
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 5 })
    #expect(runner.calls[4].contains("session time remaining"))
    #expect(keeper.status == .maySleepWhenClosed)
  }

  @MainActor @Test func theTwelveHourBackstopIsNotRecreated() async {
    // start, then the check sees it alive with 45 s left, then gone: that
    // end was the backstop, and nothing may restart it for this serve — not
    // even the power-source churn that keeps calling setActive(true)
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("true", nil),
      ("true", nil), ("45", nil),
      ("false", nil),
      ("false", nil), ("", nil), ("true", nil),
    ])
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { true })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 5 })
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 6 })
    #expect(keeper.status == .expired(8))
    keeper.setActive(true)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count == 6)
    keeper.setActive(false)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(runner.calls.count == 6)
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 9 })
    #expect(runner.calls[7].contains("start new session"))
    #expect(keeper.status == .active)
  }

  @MainActor @Test func stoppingWithAmphetamineQuitNeverRelaunchesIt() async {
    let runner = RecordingRunner(replies: [("false", nil), ("", nil), ("true", nil)])
    let ampRunning = RunningBox(true)
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { ampRunning.value })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    ampRunning.value = false
    keeper.setActive(false)
    #expect(await waitUntil { keeper.status == .idle })
    #expect(runner.calls.count >= 3)
  }

  @MainActor @Test func aQuitAppFailsTheHealthCheckWithoutBeingAsked() async {
    // start: not active, started, closed-display ok; then the app quits: the
    // check must not ask it anything, and the restart is what relaunches it
    let runner = RecordingRunner(replies: [
      ("false", nil), ("", nil), ("true", nil),
      ("false", nil), ("", nil), ("true", nil),
    ])
    let ampRunning = RunningBox(true)
    let keeper = AmphetamineKeeper(runner: runner.run, installed: { true }, running: { ampRunning.value })
    keeper.setActive(true)
    #expect(await waitUntil { runner.calls.count >= 3 })
    ampRunning.value = false
    keeper.checkBattery()
    #expect(await waitUntil { runner.calls.count >= 6 })
    #expect(runner.calls[4].contains("start new session"))
    #expect(keeper.status == .active)
  }
}

/// A mutable "Amphetamine is running" flag the tests flip.
final class RunningBox {
  var value: Bool
  init(_ value: Bool) { self.value = value }
}

/// A mutable clock the tests advance past the end-retry backoff.
final class ClockBox {
  var date: Date
  init(_ date: Date) { self.date = date }
}
