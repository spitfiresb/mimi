import CoreML
import EvalKit
import Foundation

let dir = URL(fileURLWithPath: "tools/convert/models")
let unitArg = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
let units: MLComputeUnits = switch unitArg {
case "cpu": .cpuOnly
case "gpu": .cpuAndGPU
case "ane": .cpuAndNeuralEngine
default: .all
}
print("computeUnits: \(unitArg)")
let config = MLModelConfiguration(); config.computeUnits = units
let packageName = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "ParakeetEncoder-int8"
print("package: \(packageName)")
let m = try MLModel(
    contentsOf: ParakeetEngine.compiledURL(for: dir.appendingPathComponent("\(packageName).mlpackage")),
    configuration: config)

let melArray = try MLMultiArray(shape: [1, 128, 1501], dataType: .float32)
memset(melArray.dataPointer, 0, melArray.count * 4)
let ptr = melArray.dataPointer.bindMemory(to: Float.self, capacity: 128 * 1501)
for i in 0..<(128 * 1501) { ptr[i] = Float.random(in: -1...1) }
let len = try MLMultiArray(shape: [1], dataType: .int32); len[0] = 1490

let runs = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 8 : 8
var times: [Int] = []
for run in 0..<runs {
    let t0 = ContinuousClock.now
    _ = try m.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": melArray, "length": len]))
    let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
    times.append(ms)
    print("run \(run): \(ms)ms")
}
let steady = times.dropFirst(4).sorted()
print("steady median: \(steady[steady.count/2])ms for 15s audio -> RTF \(Double(steady[steady.count/2]) / 15000.0)")
