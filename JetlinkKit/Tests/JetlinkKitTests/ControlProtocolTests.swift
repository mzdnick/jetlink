import Foundation
import Testing

@testable import JetlinkKit

/// The fixture files, copied into the test bundle as the Fixtures folder.
enum Fixture {
  static let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil)

  static func data(_ name: String) throws -> Data {
    guard let directory else { throw CocoaError(.fileNoSuchFile) }
    return try Data(contentsOf: directory.appending(path: name))
  }

  static func lines(_ name: String) throws -> [Data] {
    let text = try String(decoding: data(name), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map { Data($0.utf8) }
  }
}

struct ControlProtocolTests {
  @Test func commandsReadFromTheirObjects() throws {
    let cases: [(ControlCommand, [String: Any])] = [
      (.status, ["cmd": "status"]),
      (.catalog(refresh: true), ["cmd": "catalog", "refresh": true]),
      (.catalog(refresh: false), ["cmd": "catalog"]),
      (.download(ref: "f877d7a0ccc3cce943c76e285214c020cd65c899", sha256: nil), ["cmd": "download", "ref": "f877d7a0ccc3cce943c76e285214c020cd65c899"]),
      (.download(ref: nil, sha256: "a086"), ["cmd": "download", "ref": NSNull(), "sha256": "a086"]),
      (.cancelDownload(sha256: "a086"), ["cmd": "cancel_download", "sha256": "a086"]),
      (.importModel(path: "/Users/me/Downloads/big.onnx"), ["cmd": "import", "path": "/Users/me/Downloads/big.onnx"]),
      (.prepare(sha256: "a086", frameSkip: 2), ["cmd": "prepare", "sha256": "a086", "frame_skip": 2]),
      (.prepare(sha256: "a086", frameSkip: Pinned.defaultFrameSkip), ["cmd": "prepare", "sha256": "a086"]),
      (.unload, ["cmd": "unload"]),
      (.forget(sha256: "a086", artifacts: true, model: false), ["cmd": "forget", "sha256": "a086"]),
      (.forget(sha256: "a086", artifacts: false, model: true), ["cmd": "forget", "sha256": "a086", "artifacts": false, "model": true]),
      (.inventory, ["cmd": "inventory"]),
      (.shutdown, ["cmd": "shutdown"]),
      (.benchmark(seconds: 30), ["cmd": "benchmark", "seconds": 30]),
      (.benchmark(seconds: 60), ["cmd": "benchmark"]),
      (.cancelBenchmark, ["cmd": "cancel_benchmark"]),
    ]
    for (command, object) in cases {
      #expect(try ControlCommand(object: object) == command, "\(object)")
    }
    #expect(throws: ControlCommand.Invalid.self) { try ControlCommand(object: ["cmd": "prepare"]) }
    #expect(throws: ControlCommand.Invalid.self) { try ControlCommand(object: ["cmd": "reboot"]) }
  }

  func line(_ event: ControlEvent) throws -> [String: Any] {
    let data = event.jsonLine(at: Date(timeIntervalSince1970: 5))
    #expect(data.last == 0x0A && !data.dropLast().contains(0x0A))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test func eventsAreOneLineWithSnakeCaseKeysAndNoNulls() throws {
    let link = try line(.link(LinkEvent(state: .connected, detail: "", peer: "usb", medium: "usb3")))
    #expect(link["event"] as? String == "link" && link["t"] as? Double == 5)
    #expect(link["state"] as? String == "connected" && link["medium"] as? String == "usb3")
    let server = try line(.server(ServerEvent(state: "running", detail: "", backend: "ort", runtimeVersion: nil, device: nil)))
    #expect(server["backend"] as? String == "ort")
    #expect(Set(server.keys) == ["event", "t", "state", "detail", "backend"])
    let reply = try line(.reply(ReplyEvent(id: nil, ok: true, error: nil, extras: ["queued": .bool(true)])))
    #expect(Set(reply.keys) == ["event", "t", "ok", "queued"])
    let shutdown = try line(.shutdownRequest(ShutdownRequestEvent(reason: "car battery")))
    #expect(shutdown["event"] as? String == "shutdown_request" && shutdown["reason"] as? String == "car battery")
    #expect(try line(.hello(HelloEvent(version: "0.7.0"))).count == 3)
  }

  @Test func aBenchmarkReportGoesOutWhole() throws {
    let report = BenchmarkReport(
      sha256: String(repeating: "a", count: 64), device: "ane-Apple A19 Pro", seconds: 60, frames: 1195, frame: BenchmarkStats.empty,
      accelerator: BenchmarkStats.empty, queues: BenchmarkStats.empty, output: BenchmarkStats.empty, build: "Release build, CPU keep-warm on",
      over35: 3, over50: 0, windows: [BenchmarkWindow(startSecond: 0, frame: BenchmarkStats.empty, thermal: "nominal")], thermalAtStart: "nominal",
      thermalAtEnd: "fair", cancelled: false)
    let done = BenchmarkEvent(state: "done", elapsed: 60, total: 60, frames: 1195, frame: nil, report: report, detail: "")
    let object = try line(.benchmark(done))
    #expect(object["event"] as? String == "benchmark" && object["frame"] == nil)
    let written = try #require(object["report"] as? [String: Any])
    #expect(written["thermal_at_end"] as? String == "fair" && written["over35"] as? Int == 3)
    #expect((written["windows"] as? [[String: Any]])?.first?["start_second"] as? Int == 0)
    #expect(report.text.contains("over 35 ms: 3"))
    #expect(report.text.contains("temperature: nominal at start, fair at end"))
  }

  @Test func aReportCarriesTemperaturesAndOldOnesStillRead() throws {
    let temps = BenchmarkTemps(cpu: 58.2, gpu: 60.0)
    let report = BenchmarkReport(
      sha256: String(repeating: "a", count: 64), device: "coreml-GPU", seconds: 60, frames: 1195, frame: BenchmarkStats.empty,
      accelerator: BenchmarkStats.empty, queues: BenchmarkStats.empty, output: BenchmarkStats.empty, build: "Release build", over35: 0,
      over50: 0,
      windows: [BenchmarkWindow(startSecond: 0, frame: BenchmarkStats.empty, thermal: "nominal", temp: temps)],
      thermalAtStart: "nominal", thermalAtEnd: "fair", cancelled: false, tempAtStart: temps, tempAtEnd: BenchmarkTemps(cpu: 61.4, gpu: 70.9))
    let object = try line(.benchmark(BenchmarkEvent(state: "done", elapsed: 60, total: 60, frames: 1195, frame: nil, report: report, detail: "")))
    let written = try #require(object["report"] as? [String: Any])
    let atEnd = written["temp_at_end"] as? [String: Any]
    #expect(atEnd?["cpu"] as? Double == 61.4 && atEnd?["gpu"] as? Double == 70.9)
    #expect((written["windows"] as? [[String: Any]])?.first?["temp"] != nil)
    // The text a report pastes: values in °C, and the words where none exist.
    #expect(report.text.contains("temperature: CPU 58.2 · GPU 60.0 °C at start, CPU 61.4 · GPU 70.9 °C at end"))
    #expect(report.text.contains("by window (CPU/GPU °C):"))
    #expect(report.text.contains(" 58.2/60.0 °C"))
  }

  @Test func aReportWithoutTemperaturesDecodes() throws {
    // A report from before the temperatures, as an older server sent it.
    let json = """
      {"sha256":"a","device":"cpu","seconds":1,"frames":1,"frame":{"mean":1,"p50":1,"p90":1,"p99":1,"max":1},\
      "accelerator":{"mean":1,"p50":1,"p90":1,"p99":1,"max":1},"queues":{"mean":1,"p50":1,"p90":1,"p99":1,"max":1},\
      "output":{"mean":1,"p50":1,"p90":1,"p99":1,"max":1},"build":"b","over35":0,"over50":0,\
      "windows":[{"start_second":0,"frame":{"mean":1,"p50":1,"p90":1,"p99":1,"max":1},"thermal":"nominal"}],\
      "thermal_at_start":"nominal","thermal_at_end":"nominal","cancelled":false}
      """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let report = try decoder.decode(BenchmarkReport.self, from: Data(json.utf8))
    #expect(report.tempAtStart == nil && report.tempAtEnd == nil && report.windows.first?.temp == nil)
    #expect(report.text.contains("temperature: nominal at start, nominal at end"))
  }
}
