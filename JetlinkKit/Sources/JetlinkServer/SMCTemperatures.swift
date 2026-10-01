import Foundation
import JetlinkKit
#if os(macOS)
import IOKit
#endif

/// The CPU and GPU temperatures a Mac reports through the SMC, the same
/// numbers macmon shows, read in-process without privileges. Apple documents
/// none of the key names, so the reader takes the keys the way macmon does:
/// every key the SMC will list, kept when its name says which die it belongs
/// to ("Tp", "Te" and "Ts" are CPU-side, "Tg" is the GPU) and its type is one
/// the reader can decode. The values are averaged per die, placeholders for
/// disabled cores included, so the numbers line up with `macmon pipe`; the
/// average runs a little under the hottest sensor at load.
enum SMCTemperatures {
  /// A reading in °C the SMC could plausibly mean, as macmon accepts one.
  static func saneCelsius(_ value: Double) -> Bool {
    value > 0 && value <= 150
  }

  /// The mean of the sane readings, to a tenth of a degree; nil with none.
  static func average(_ celsius: [Double]) -> Double? {
    let values = celsius.filter(saneCelsius)
    guard !values.isEmpty else { return nil }
    return (values.reduce(0, +) / Double(values.count) * 10).rounded() / 10
  }

  /// A key's bytes as °C, by the encodings Apple's SMCs have used: `flt ` is
  /// a little-endian float on Apple Silicon, `sp78` the 7.8 fixed point of
  /// Intel Macs, `fpe2` their older halves-of-degrees form. nil, a type the
  /// reader does not know.
  static func celsius(bytes: [UInt8], type: String) -> Double? {
    switch type.prefix(4) {
    case "flt " where bytes.count >= 4:
      let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
      return Double(Float(bitPattern: bits))
    case "sp78" where bytes.count >= 2:
      return Double(Int8(bitPattern: bytes[0])) + Double(bytes[1]) / 256
    case "fpe2" where bytes.count >= 2:
      return Double(Int(bytes[0]) << 8 | Int(bytes[1])) / 4
    default:
      return nil
    }
  }

  /// Which die a listed key belongs to: nil, neither, or one an average would
  /// mislead with.
  static func die(ofKey name: String) -> BenchmarkTemps.Die? {
    guard name.count == 4 else { return nil }
    if name.hasPrefix("Tg") { return .gpu }
    if name.hasPrefix("Tp") || name.hasPrefix("Te") || name.hasPrefix("Ts") { return .cpu }
    return nil
  }
}

#if os(macOS)
/// The SMC connection of this process: opened once, its sensor keys listed
/// once, then every read is a pair of calls per key. The calls are serialized,
/// because one user-client connection is not; the benchmark reads from its own
/// thread, so a stuck SMC costs a window's temperature, never a frame.
final class SMCSensors: @unchecked Sendable {
  static let shared = SMCSensors()

  private let lock = NSLock()
  private var connection: io_connect_t = 0
  private var cpuKeys: [String] = []
  private var gpuKeys: [String] = []
  private var opened = false

  func read() -> BenchmarkTemps? {
    lock.lock()
    defer { lock.unlock() }
    guard openAndList() else { return nil }
    let cpu = readings(cpuKeys)
    let gpu = readings(gpuKeys)
    if cpu.isEmpty && gpu.isEmpty { return nil }
    return BenchmarkTemps(cpu: SMCTemperatures.average(cpu), gpu: SMCTemperatures.average(gpu))
  }

  private func readings(_ keys: [String]) -> [Double] {
    keys.compactMap { value($0) }
  }

  /// The connection and the key lists, once; false, for good, without them.
  private func openAndList() -> Bool {
    if opened { return !cpuKeys.isEmpty || !gpuKeys.isEmpty }
    opened = true
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == kIOReturnSuccess else {
      return false
    }
    let service = IOIteratorNext(iterator)
    IOObjectRelease(iterator)
    guard service != 0, IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else {
      if service != 0 { IOObjectRelease(service) }
      return false
    }
    IOObjectRelease(service)
    for name in keyNames() {
      guard let die = SMCTemperatures.die(ofKey: name), decodable(name) else { continue }
      switch die {
      case .cpu: cpuKeys.append(name)
      case .gpu: gpuKeys.append(name)
      }
    }
    return !cpuKeys.isEmpty || !gpuKeys.isEmpty
  }

  /// Every key the SMC lists, by index: "#KEY" with selector 8 answers the
  /// i'th name.
  private func keyNames() -> [String] {
    guard let info = call("#KEY", 9), let countBytes = valueBytes("#KEY", info) else { return [] }
    let count = Int(countBytes[0]) << 24 | Int(countBytes[1]) << 16 | Int(countBytes[2]) << 8 | Int(countBytes[3])
    var names: [String] = []
    names.reserveCapacity(count)
    for i in 0..<count {
      var input = SMCParamStruct()
      input.key = Self.fourCC("#KEY")
      input.data8 = 8
      input.data32 = UInt32(i)
      guard let out = invoke(input) else { continue }
      names.append(Self.ccString(out.key))
    }
    return names
  }

  private func decodable(_ key: String) -> Bool {
    guard let info = call(key, 9), let bytes = valueBytes(key, info) else { return false }
    return SMCTemperatures.celsius(bytes: bytes, type: info.type) != nil
  }

  private func value(_ key: String) -> Double? {
    guard let info = call(key, 9), let bytes = valueBytes(key, info) else { return nil }
    return SMCTemperatures.celsius(bytes: bytes, type: info.type)
  }

  private func valueBytes(_ key: String, _ info: KeyInfo) -> [UInt8]? {
    var input = SMCParamStruct()
    input.key = Self.fourCC(key)
    input.data8 = 5
    input.keyInfo.size = info.size
    input.keyInfo.type = Self.fourCC(info.type)
    guard let out = invoke(input) else { return nil }
    return Array(out.byteArray.prefix(Int(info.size)))
  }

  private func call(_ key: String, _ selector: UInt8) -> KeyInfo? {
    var input = SMCParamStruct()
    input.key = Self.fourCC(key)
    input.data8 = selector
    guard let out = invoke(input) else { return nil }
    return KeyInfo(size: out.keyInfo.size, type: Self.ccString(out.keyInfo.type))
  }

  private func invoke(_ input: SMCParamStruct) -> SMCParamStruct? {
    var output = SMCParamStruct()
    var size = MemoryLayout<SMCParamStruct>.stride
    let result = withUnsafeBytes(of: input) { raw in
      IOConnectCallStructMethod(connection, 2, raw.baseAddress, MemoryLayout<SMCParamStruct>.stride, &output, &size)
    }
    guard result == kIOReturnSuccess, output.result == 0 else { return nil }
    return output
  }

  deinit {
    if connection != 0 { IOServiceClose(connection) }
  }

  private struct KeyInfo {
    let size: UInt32
    let type: String
  }

  static func fourCC(_ string: String) -> UInt32 {
    string.utf8.prefix(4).reduce(0) { ($0 << 8) + UInt32($1) }
  }

  static func ccString(_ code: UInt32) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? ""
  }
}

/// The SMC's one call: key, selector and payload in, result and bytes out.
/// This 80-byte C struct is the protocol itself, so its layout is not to be
/// rearranged.
private struct SMCVersion {
  var major: UInt8 = 0
  var minor: UInt8 = 0
  var build: UInt8 = 0
  var reserved: UInt8 = 0
  var release: UInt16 = 0
}

private struct SMCPLimitData {
  var version: UInt16 = 0
  var length: UInt16 = 0
  var cpuPLimit: UInt32 = 0
  var gpuPLimit: UInt32 = 0
  var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
  var size: UInt32 = 0
  var type: UInt32 = 0
  var attributes: UInt8 = 0
}

private struct SMCParamStruct {
  var key: UInt32 = 0
  var vers = SMCVersion()
  var pLimitData = SMCPLimitData()
  var keyInfo = SMCKeyInfoData()
  var padding: UInt16 = 0
  var result: UInt8 = 0
  var status: UInt8 = 0
  var data8: UInt8 = 0
  var data32: UInt32 = 0
  var bytes: (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
  ) = (
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0
  )

  var byteArray: [UInt8] {
    withUnsafeBytes(of: bytes) { Array($0) }
  }
}
#endif
