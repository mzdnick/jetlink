import AppKit
import CoreServices
import Foundation
import IOKit.ps
import os

/// One round of AppleScript, away from the main actor. `runner` executes a
/// script and returns its trimmed output, or an error string.
private enum Amph {
  static let bundleID = "com.if.Amphetamine"

  /// A crash must not keep the Mac awake forever: every session dies on its
  /// own after this many hours even if jetlink never ends it. The setting
  /// offers 4/8/12/24 — never unlimited, so the crash backstop always holds.
  static let defaultSessionHours = 12

  /// A session last seen alive with at most this many seconds left and then
  /// found dead ran out on purpose; anything more was a death.
  static let expiryWindowSeconds = 120

  static let log = Logger(subsystem: "io.zoompilot.jetlink", category: "amphetamine")

  enum Outcome {
    case started
    case foreign
    case notInstalled
    case denied
    case failed(String)
    case ended
    case endFailed(String)
    case alive(Int?)
    case gone
  }

  static func performStart(runner: (String) -> (String?, String?), installed: Bool, sessionHours: Int) -> Outcome {
    guard installed else { return .notInstalled }
    let (active, _) = script(runner: runner, "tell application id \"\(bundleID)\"\nsession is active\nend tell")
    if active == "true" {
      log.info("an Amphetamine session is already active; leaving it alone")
      return .foreign
    }
    let (_, startError) = script(runner: runner, "tell application id \"\(bundleID)\"\nstart new session with options {duration:\(sessionHours), interval:hours, displaySleepAllowed:false}\nend tell")
    if let startError { return denied(startError) ? .denied : .failed(startError) }
    log.info("started an Amphetamine session")
    let (closedDisplay, _) = script(runner: runner, "tell application id \"\(bundleID)\"\nclosed display mode enabled\nend tell")
    if closedDisplay == "false" {
      log.warning("Amphetamine may sleep with the lid closed: turn off 'Allow System to Sleep When Display is Closed' in its Sessions preferences")
    }
    return .started
  }

  /// Ending must never relaunch a quit Amphetamine just to hear "nothing to
  /// end", so the caller says whether the app is running at all.
  static func performEnd(runner: (String) -> (String?, String?), running: Bool) -> Outcome {
    guard running else {
      log.info("Amphetamine is not running; the session went with it")
      return .ended
    }
    let (_, error) = script(runner: runner, "tell application id \"\(bundleID)\"\nend session\nend tell")
    if let error { return denied(error) ? .denied : .endFailed(error) }
    log.info("ended the Amphetamine session")
    return .ended
  }

  /// A session we started can vanish without us: Amphetamine killed, or the
  /// finite duration ran out mid-serve. One look, so the health timer can
  /// restart what died. A quit app answers without being launched. While a
  /// session lives, the seconds it has left come along, so a natural end can
  /// be told from a death.
  static func performVerify(runner: (String) -> (String?, String?), installed: Bool, running: Bool) -> Outcome {
    guard installed else { return .notInstalled }
    guard running else { return .gone }
    let (active, error) = script(runner: runner, "tell application id \"\(bundleID)\"\nsession is active\nend tell")
    if let error { return denied(error) ? .denied : .failed(error) }
    guard active == "true" else { return .gone }
    let (remaining, _) = script(runner: runner, "tell application id \"\(bundleID)\"\nsession time remaining\nend tell")
    return .alive(remaining.flatMap(Int.init))
  }

  static func script(runner: (String) -> (String?, String?), _ source: String) -> (String?, String?) {
    let (output, error) = runner(source)
    if let error {
      log.error("Amphetamine script failed: \(error, privacy: .public)")
    }
    return (output, error)
  }

  /// errAEEventNotPermitted: macOS refused the Apple event, most likely the
  /// Automation permission was declined.
  static func denied(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return lowered.contains("not authorized") || lowered.contains("-1743")
  }

  static func batteryPercent() -> Int? {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in list {
      if let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
         let capacity = description[kIOPSCurrentCapacityKey as String] as? Int {
        return capacity
      }
    }
    return nil
  }

  static func osascript(_ source: String) -> (String?, String?) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      return (nil, "could not run osascript: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return (output, detail?.isEmpty == false ? detail! : "osascript exited \(process.terminationStatus)")
    }
    return (output, nil)
  }
}

/// Drives an Amphetamine session while the server serves on battery: only
/// Amphetamine's sessions survive a lid close on this OS (measured
/// 2026-10-03: assertions identical to its own, held by this app, did not), so
/// the battery keep-awake borrows the one holder powerd honors. A session the
/// user started is left alone, and only a session this keeper started is
/// ended — when serving stops, or when the battery reaches its floor so a
/// closed-lid Mac cannot run itself flat. The first script asks macOS for
/// permission to control Amphetamine.
@MainActor
@Observable
final class AmphetamineKeeper {
  enum Status: Equatable {
    case idle
    case active
    case foreignSession
    case notInstalled
    case permissionDenied
    case failed(String)
    case batteryFloor(Int)
    case expired
  }

  private(set) var status: Status = .idle
  private var desiredActive = false
  private var startedSession = false
  private var executing = false
  private var blocked = false
  /// The seconds the session had left when last seen alive; a session found
  /// dead with almost none was the 12-hour backstop running out, not a death.
  private var lastKnownRemaining: Int?
  /// The backstop fired for this serve; nothing restarts it until serving
  /// actually stops. Power-source churn re-calls setActive(true) constantly,
  /// so only a real stop clears this.
  private var expired = false
  private var floorTimer: Timer?
  private let queue = DispatchQueue(label: "io.zoompilot.jetlink.amphetamine", qos: .utility)
  private let runner: (String) -> (String?, String?)
  private let installed: () -> Bool
  private let running: () -> Bool
  private let batteryLevel: () -> Int?
  private let floorEnabled: () -> Bool
  private let floorPercent: () -> Int
  private let sessionHours: () -> Int

  init(runner: ((String) -> (String?, String?))? = nil,
       installed: (() -> Bool)? = nil,
       running: (() -> Bool)? = nil,
       batteryLevel: (() -> Int?)? = nil,
       floorEnabled: (() -> Bool)? = nil,
       floorPercent: (() -> Int)? = nil,
       sessionHours: (() -> Int)? = nil) {
    self.runner = runner ?? Amph.osascript
    self.installed = installed ?? {
      let urls = LSCopyApplicationURLsForBundleIdentifier(Amph.bundleID as CFString, nil)?.takeRetainedValue()
      return (urls as? [URL])?.isEmpty == false
    }
    self.running = running ?? {
      !NSRunningApplication.runningApplications(withBundleIdentifier: Amph.bundleID).isEmpty
    }
    self.batteryLevel = batteryLevel ?? Amph.batteryPercent
    self.floorEnabled = floorEnabled ?? { false }
    self.floorPercent = floorPercent ?? { 20 }
    self.sessionHours = sessionHours ?? { Amph.defaultSessionHours }
  }

  func setActive(_ active: Bool) {
    desiredActive = active
    // every explicit transition re-arms attempts; nothing retries on its own
    blocked = false
    // only a real stop ends the serve: it alone grants a fresh 12 hours
    if !active { expired = false }
    pump()
  }

  /// The health timer's tick; tests call it directly. Only this entry may
  /// verify a live session — a transition-driven pump that verified would
  /// loop start → verify → gone → start on a slow Apple event.
  func checkBattery() {
    pump(true)
  }

  private func pump(_ verify: Bool = false) {
    guard !executing, !blocked else { return }
    let floor = floorEnabled() ? floorPercent() : nil
    let belowFloor = floor.flatMap { percent in batteryLevel().map { $0 < percent } } ?? false
    let endForFloor = startedSession && belowFloor
    let verifyLive = verify && startedSession && desiredActive && !belowFloor
    let start = desiredActive && !startedSession && !belowFloor && !expired
    let end = (!desiredActive && startedSession) || endForFloor
    guard start || end || verifyLive else {
      if desiredActive, !startedSession, belowFloor, !expired, let floor {
        status = .batteryFloor(floor)
      }
      return
    }
    executing = true
    let runner = runner
    let installing = installed()
    let ampRunning = running()
    let hours = sessionHours()
    let floorNow = endForFloor ? floor : nil
    queue.async { [weak self] in
      let outcome = start
        ? Amph.performStart(runner: runner, installed: installing, sessionHours: hours)
        : verifyLive
          ? Amph.performVerify(runner: runner, installed: installing, running: ampRunning)
          : Amph.performEnd(runner: runner, running: ampRunning)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.executing = false
        self.apply(outcome, floor: floorNow)
        self.pump()
      }
    }
  }

  private func apply(_ outcome: Amph.Outcome, floor: Int?) {
    switch outcome {
    case .started:
      startedSession = true
      lastKnownRemaining = nil
      status = .active
      startHealthTimer()
    case .foreign:
      blocked = true
      status = .foreignSession
    case .notInstalled:
      blocked = true
      status = .notInstalled
    case .denied:
      blocked = true
      status = .permissionDenied
    case .failed(let message):
      blocked = true
      status = .failed(message)
    case .ended:
      startedSession = false
      stopHealthTimer()
      status = floor.map(Status.batteryFloor) ?? .idle
    case .endFailed(let message):
      blocked = true
      status = .failed(message)
    case .alive(let remaining):
      lastKnownRemaining = remaining
      status = .active
    case .gone:
      if let remaining = lastKnownRemaining, remaining <= Amph.expiryWindowSeconds {
        // the 12-hour backstop ran out on purpose: the Mac may sleep, and
        // nothing restarts the session until this serve stops
        expired = true
        startedSession = false
        stopHealthTimer()
        status = .expired
      } else {
        // our session died without us — Amphetamine killed, or ended by
        // hand. Drop the claim; pump starts a fresh session, which
        // relaunches Amphetamine if it was quit.
        startedSession = false
        stopHealthTimer()
        status = .idle
      }
    }
  }

  private func startHealthTimer() {
    guard floorTimer == nil else { return }
    // Amphetamine broadcasts no session events, so the only way to notice a
    // session that ended — by hand, a kill, or the finite duration — is to
    // ask. One Apple event per tick on a utility queue is cheap enough for
    // ten seconds, which bounds how long the status line can lie.
    floorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.checkBattery() }
    }
  }

  private func stopHealthTimer() {
    floorTimer?.invalidate()
    floorTimer = nil
  }
}
