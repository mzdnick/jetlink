import AppKit
import JetlinkUI
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem { Label("General", systemImage: "gear") }
      ServerSettingsView()
        .tabItem { Label("Server", systemImage: "cpu") }
    }
    .frame(width: 540)
  }
}

// MARK: - General

struct GeneralSettingsView: View {
  @Environment(AppSettings.self) private var settings
  @Environment(ServerStore.self) private var server
  @State private var loginItem = LoginItem()

  var body: some View {
    @Bindable var settings = settings
    Form {
      Section {
        Toggle("Start server when Jetlink opens", isOn: $settings.startServerOnLaunch)
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Open Jetlink at login", isOn: $loginItem.isEnabled)
          if loginItem.requiresApproval {
            Text("Approve Jetlink in System Settings > General > Login Items.")
              .font(.callout)
              .foregroundStyle(.secondary)
            Button("Open Login Items") { loginItem.openSystemSettings() }
          }
        }
        VStack(alignment: .leading, spacing: 4) {
          Toggle("Prevent sleep while server is running", isOn: $settings.keepAwakeWhileServing)
            .onChange(of: settings.keepAwakeWhileServing) { server.keepAwakeSettingChanged() }
          Toggle("Prevent sleep on battery", isOn: $settings.keepAwakeOnBattery)
            .disabled(!settings.keepAwakeWhileServing)
            .onChange(of: settings.keepAwakeOnBattery) { server.keepAwakeSettingChanged() }
          Toggle("End the session on low battery", isOn: $settings.keepAwakeBatteryFloorEnabled)
            .disabled(!settings.keepAwakeOnBattery)
            .onChange(of: settings.keepAwakeBatteryFloorEnabled) { server.keepAwakeSettingChanged() }
          TextField("End the session below (%)", value: $settings.keepAwakeBatteryFloorPercent, format: .number.grouping(.never))
            .disabled(!settings.keepAwakeBatteryFloorEnabled || !settings.keepAwakeOnBattery)
            .onChange(of: settings.keepAwakeBatteryFloorPercent) { server.keepAwakeSettingChanged() }
          TextField("Keep-awake limit (hours)", value: $settings.keepAwakeSessionHours, format: .number.grouping(.never))
            .disabled(!settings.keepAwakeOnBattery)
            .onChange(of: settings.keepAwakeSessionHours) { server.keepAwakeSettingChanged() }
          Text("By default, sleep prevention applies only on power. On battery, Jetlink starts an Amphetamine session so the Mac stays awake with the lid closed. Without Amphetamine, closing the lid may still put the Mac to sleep.")
            .font(.callout)
            .foregroundStyle(.secondary)
          if settings.keepAwakeWhileServing && settings.keepAwakeOnBattery {
            amphetamineStatusLine
              .font(.callout)
              .foregroundStyle(amphetamineStatusTone)
          }
        }
      }

      Section("Cache folder") {
        VStack(alignment: .leading, spacing: 8) {
          Text(settings.cacheDirectory.path(percentEncoded: false))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          HStack {
            Button("Choose…") { chooseCacheDirectory() }
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([settings.cacheDirectory])
            }
            if needsRestart {
              Button("Restart Now") { server.restart() }
            }
          }
          Text("Models and prepared engines. A CoreML engine is about 2 GB. Takes effect when the server restarts.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var needsRestart: Bool {
    guard server.runState == .serving, let running = server.info?.cache else { return false }
    return running != settings.cacheDirectory.path(percentEncoded: false)
  }

  @ViewBuilder private var amphetamineStatusLine: some View {
    switch server.amphetamineStatus {
    case .idle:
      Text("Amphetamine session starts when the server serves on battery.")
    case .active:
      Text("Amphetamine session is keeping the Mac awake.")
    case .foreignSession:
      Text("An Amphetamine session you started is keeping the Mac awake.")
    case .notInstalled:
      VStack(alignment: .leading, spacing: 2) {
        Text("Amphetamine is not installed. Get it from the App Store to keep the Mac awake with the lid closed.")
        Link("Open Amphetamine in the App Store",
             destination: URL(string: "macappstore://apps.apple.com/us/app/amphetamine/id937984704?mt=12")!)
      }
    case .permissionDenied:
      Text("Jetlink may not control Amphetamine. Allow it in System Settings > Privacy & Security > Automation.")
    case .failed(let message):
      Text("Amphetamine session failed: \(message)")
    case .batteryFloor(let percent):
      Text("The session ended at the battery floor (\(percent)%).")
    case .expired:
      Text("The \(settings.effectiveKeepAwakeSessionHours)-hour keep-awake ran out; the Mac may sleep. Restart the server for another.")
    }
  }

  private var amphetamineStatusTone: Color {
    switch server.amphetamineStatus {
    case .idle, .foreignSession: .secondary
    case .active: .green
    case .notInstalled, .permissionDenied, .failed, .batteryFloor, .expired: .orange
    }
  }

  private func chooseCacheDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = settings.cacheDirectory
    panel.prompt = "Choose"
    if panel.runModal() == .OK, let url = panel.url {
      settings.cacheDirectory = url
    }
  }
}

// MARK: - Server

struct ServerSettingsView: View {
  @Environment(AppSettings.self) private var settings
  @Environment(ServerStore.self) private var server

  var body: some View {
    @Bindable var settings = settings
    Form {
      Section {
        VStack(alignment: .leading, spacing: 4) {
          Picker("Backend", selection: $settings.backend) {
            ForEach(BackendChoice.allCases, id: \.self) { choice in
              Text(choice == .auto ? "Automatic (\(choice.title))" : choice.title).tag(choice)
            }
          }
          Text(ServerSettingsView.backendCaption(settings.backend))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Picker("Connection", selection: $settings.transport) {
          Text("USB (comma)").tag(TransportChoice.usb)
          Text("TCP (bench client)").tag(TransportChoice.tcp)
        }
        if settings.transport == .tcp {
          TextField("Port", value: $settings.tcpPort, format: .number.grouping(.never))
        }
      } footer: {
        HStack {
          Text("Changes apply when the server restarts.")
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Restart Server") { server.restart() }
            .disabled(server.runState != .serving)
        }
      }
    }
    .formStyle(.grouped)
  }

  static func backendCaption(_ backend: BackendChoice) -> String {
    switch backend {
    case .auto:
      "Recommended: most efficient on Apple silicon. Initial preparation takes about 20 seconds."
    case .coreml:
      "Less efficient than using ANE, runs inference using the GPU. Use if CoreML with Neural Engine is too slow."
    }
  }
}

#Preview("General") {
  GeneralSettingsView()
    .environment(AppSettings.preview())
    .environment(ServerStore.preview(runState: .serving, info: PreviewData.serverInfo, link: PreviewData.linkWaiting, engine: PreviewData.engineReady))
    .frame(width: 540, height: 420)
}

#Preview("Server") {
  ServerSettingsView()
    .environment(AppSettings.preview())
    .environment(ServerStore.preview(runState: .serving, info: PreviewData.serverInfo, link: PreviewData.linkWaiting, engine: PreviewData.engineReady))
    .frame(width: 540, height: 420)
}
