import Foundation
import os

/// Drives an Amphetamine session while the server serves on battery: only
/// Amphetamine's sessions survive a lid close on this OS (measured
/// 2026-10-03: assertions identical to its own, held by this app, did not), so
/// the battery keep-awake borrows the one holder powerd honors. A session the
/// user started is left alone, and only a session this keeper started is
/// ended. The first script asks macOS for permission to control Amphetamine.
@MainActor
final class AmphetamineKeeper {
  private var desiredActive = false
  private var startedSession = false
  private var executing = false
  private var blocked = false
  private let queue = DispatchQueue(label: "io.zoompilot.jetlink.amphetamine", qos: .utility)
  private nonisolated(unsafe) let runner: (String) -> (String?, String?)
  private nonisolated(unsafe) let log = Logger(subsystem: "io.zoompilot.jetlink", category: "amphetamine")

  /// `runner` executes one AppleScript and returns its trimmed output, or an
  /// error string. The default shells out to osascript; tests inject a fake.
  init(runner: ((String) -> (String?, String?))? = nil) {
    self.runner = runner ?? AmphetamineKeeper.osascript
  }

  func setActive(_ active: Bool) {
    desiredActive = active
    // every explicit transition re-arms attempts; nothing retries on its own
    blocked = false
    pump()
  }

  private func pump() {
    guard !executing, !blocked else { return }
    let start = desiredActive && !startedSession
    let end = !desiredActive && startedSession
    guard start || end else { return }
    executing = true
    queue.async { [weak self] in
      guard let self else { return }
      let (ok, ours) = start ? self.performStart() : (self.performEnd(), false)
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.executing = false
        if start {
          if ok, ours {
            self.startedSession = true
          } else {
            // a failed script, or a session the user owns: hold off until the
            // next transition instead of retrying in a loop
            self.blocked = true
          }
        } else if ok {
          self.startedSession = false
        } else {
          self.blocked = true
        }
        self.pump()
      }
    }
  }

  /// Starts a session unless one already runs. Returns whether a session now
  /// runs, and whether it is ours to end later.
  nonisolated private func performStart() -> (Bool, Bool) {
    if let active = script("tell application id \"com.if.Amphetamine\"\nsession is active\nend tell"), active == "true" {
      log.info("an Amphetamine session is already active; leaving it alone")
      return (true, false)
    }
    guard script("tell application id \"com.if.Amphetamine\"\nstart new session with options {duration:0, interval:0, displaySleepAllowed:false}\nend tell") != nil else {
      return (false, false)
    }
    log.info("started an Amphetamine session")
    if let enabled = script("tell application id \"com.if.Amphetamine\"\nclosed display mode enabled\nend tell"), enabled == "false" {
      log.warning("Amphetamine may sleep with the lid closed: turn off 'Allow System to Sleep When Display is Closed' in its Sessions preferences")
    }
    return (true, true)
  }

  nonisolated private func performEnd() -> Bool {
    guard script("tell application id \"com.if.Amphetamine\"\nend session\nend tell") != nil else { return false }
    log.info("ended the Amphetamine session")
    return true
  }

  nonisolated private func script(_ source: String) -> String? {
    let (output, error) = runner(source)
    if let error {
      log.error("Amphetamine script failed: \(error, privacy: .public)")
      return nil
    }
    return output
  }

  private static func osascript(_ source: String) -> (String?, String?) {
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
