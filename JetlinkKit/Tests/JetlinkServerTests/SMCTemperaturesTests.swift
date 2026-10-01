import Foundation
import JetlinkKit
import Testing

@testable import JetlinkServer

/// The SMC decode, the die a key belongs to, and the average over readings:
/// everything but the hardware itself.
struct SMCTemperaturesTests {
  @Test func littleEndianFloatIsAppleSiliconDegrees() {
    // 45.25 as a little-endian float: what a "Tp" key answered on an M3 Max.
    let bits = Float(45.25).bitPattern
    let bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
    #expect(SMCTemperatures.celsius(bytes: bytes, type: "flt ") == 45.25)
  }

  @Test func sp78IsIntelDegrees() {
    // 61 and 128/256: an Intel Mac's "sp78" form.
    #expect(abs((SMCTemperatures.celsius(bytes: [61, 128], type: "sp78") ?? 0) - 61.5) < 0.001)
    // Below zero stays negative, as a cold sensor can be.
    #expect(abs((SMCTemperatures.celsius(bytes: [0xFF, 0x80], type: "sp78") ?? 0) + 0.5) < 0.001)
  }

  @Test func fpe2IsHalves() {
    #expect(SMCTemperatures.celsius(bytes: [0x00, 0xA8], type: "fpe2") == 42)
  }

  @Test func unknownTypeIsNil() {
    #expect(SMCTemperatures.celsius(bytes: [1, 2, 3, 4], type: "ui8 ") == nil)
    #expect(SMCTemperatures.celsius(bytes: [1], type: "flt ") == nil)
  }

  @Test func dieByKeyName() {
    #expect(SMCTemperatures.die(ofKey: "Tp05") == .cpu)
    #expect(SMCTemperatures.die(ofKey: "Te0P") == .cpu)
    #expect(SMCTemperatures.die(ofKey: "Ts0S") == .cpu)
    #expect(SMCTemperatures.die(ofKey: "Tg05") == .gpu)
    #expect(SMCTemperatures.die(ofKey: "TC0P") == nil)
    #expect(SMCTemperatures.die(ofKey: "F0Ac") == nil)
  }

  @Test func averageSkipsTheImpossibleAndKeepsTenths() {
    // The 40.00 placeholders of disabled cores and a dead 0.0 sensor ride
    // along; the answer is still one digit after the point.
    #expect(SMCTemperatures.average([61.24, 58.36, 40.0, 0.0]) == 53.2)
    #expect(SMCTemperatures.average([]) == nil)
    #expect(SMCTemperatures.average([0, 200]) == nil)
  }

  @Test(arguments: [true, false])
  func tempsTextNamesItsDies(cpuOnly: Bool) {
    let temps = cpuOnly ? BenchmarkTemps(cpu: 61.2, gpu: nil) : BenchmarkTemps(cpu: 61.2, gpu: 70.4)
    #expect(cpuOnly ? temps.text == "CPU 61.2 °C" : temps.text == "CPU 61.2 · GPU 70.4 °C")
  }

  #if os(macOS)
    @Test func sharedReaderAnswersOnThisMac() {
      // Live hardware: an Apple Silicon Mac answers both dies, in a range a
      // machine can be in, to a tenth. CI runners without sensors say nil.
      let temps = SMCSensors.shared.read()
      if let temps {
        #expect(temps.cpu == nil || (temps.cpu! > 0 && temps.cpu! <= 150))
        #expect(temps.gpu == nil || (temps.gpu! > 0 && temps.gpu! <= 150))
        #expect(temps.cpu == nil || temps.cpu == (temps.cpu! * 10).rounded() / 10)
      }
    }
  #endif
}
