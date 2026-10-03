import AppKit
import CoreServices
import Foundation
import IOKit.ps
import os

/// One round of AppleScript, away from the main actor. `runner` executes a
/// script and returns its trimmed output, or an error string.
private enum Amph {
  static let bundleID = "com.if.Amphetamine"

  /// A crash must not keep the Mac awake forever: the session dies after this
  /// many hours even if jetlink never ends it. A serve that outlasts it loses
  /// lid-close protection until the next state change re-arms the keeper.
  static let sessionHours = 12

  static let log = Logger(subsystem: "io.zoompilot.jetlink", category: "amphetamine")

  enum Outcome {
    case started
    case foreign
    case notInstalled
    case denied
    case failed(String)
    case ended
    case endFailed(String)
  }

  static func performStart(runner: (String) -> (String?, String?), installed: Bool) -> Outcome {
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

  static func performEnd(runner: (String) -> (String?, String?)) -> Outcome {
    let (_, error) = script(runner: runner, "tell application id \"\(bundleID)\"\nend session\nend tell")
    if let error { return denied(error) ? .denied : .endFailed(error) }
    log.info("ended the Amphetamine session")
    return .ended
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
  }

  private(set) var status: Status = .idle
  private var desiredActive = false
  private var startedSession = false
  private var executing = false
  private var blocked = false
  private var floorTimer: Timer?
  private let queue = DispatchQueue(label: "io.zoompilot.jetlink.amphetamine", qos: .utility)
  private let runner: (String) -> (String?, String?)
  private let installed: () -> Bool
  private let batteryLevel: () -> Int?
  private let floorEnabled: () -> Bool
  private let floorPercent: () -> Int

  init(runner: ((String) -> (String?, String?))? = nil,
       installed: (() -> Bool)? = nil,
       batteryLevel: (() -> Int?)? = nil,
       floorEnabled: (() -> Bool)? = nil,
       floorPercent: (() -> Int)? = nil) {
    self.runner = runner ?? Amph.osascript
    self.installed = installed ?? {
      let urls = LSCopyApplicationURLsForBundleIdentifier(Amph.bundleID as CFString, nil)?.takeRetainedValue()
      return (urls as? [URL])?.isEmpty == false
    }
    self.batteryLevel = batteryLevel ?? Amph.batteryPercent
    self.floorEnabled = floorEnabled ?? { false }
    self.floorPercent = floorPercent ?? { 20 }
  }

  func setActive(_ active: Bool) {
    desiredActive = active
    // every explicit transition re-arms attempts; nothing retries on its own
    blocked = false
    pump()
  }

  /// The floor timer's tick; tests call it directly.
  func checkBattery() {
    pump()
  }

  private func pump() {
    guard !executing, !blocked else { return }
    let floor = floorEnabled() ? floorPercent() : nil
    let belowFloor = floor.flatMap { percent in batteryLevel().map { $0 < percent } } ?? false
    let endForFloor = startedSession && belowFloor
    let start = desiredActive && !startedSession && !belowFloor
    let end = (!desiredActive && startedSession) || endForFloor
    guard start || end else {
      if desiredActive, !startedSession, belowFloor, let floor {
        status = .batteryFloor(floor)
      }
      return
    }
    executing = true
    let runner = runner
    let installing = installed()
    let floorNow = endForFloor ? floor : nil
    queue.async { [weak self] in
      let outcome = start
        ? Amph.performStart(runner: runner, installed: installing)
        : Amph.performEnd(runner: runner)
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
      status = .active
      startFloorTimer()
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
      stopFloorTimer()
      status = floor.map(Status.batteryFloor) ?? .idle
    case .endFailed(let message):
      blocked = true
      status = .failed(message)
    }
  }

  private func startFloorTimer() {
    guard floorTimer == nil else { return }
    floorTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.checkBattery() }
    }
  }

  private func stopFloorTimer() {
    floorTimer?.invalidate()
    floorTimer = nil
  }
}
