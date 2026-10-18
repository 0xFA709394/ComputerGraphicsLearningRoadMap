// 16 号 radix 驱动: 只依赖 default.metallib + 4 kernel, 不 import 示例源码
import Metal
import Foundation

let device = MTLCreateSystemDefaultDevice()!
let lib = try! device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let N = 32768
let histPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "radixHist")!)
let scanPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "radixScan")!)
let scatterPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "radixScatter")!)
let clearPSO = try! device.makeComputePipelineState(function: lib.makeFunction(name: "clearBins")!)

let keys = device.makeBuffer(length: N * 8, options: .storageModeShared)!
let scratch = device.makeBuffer(length: N * 8, options: .storageModeShared)!
let hist = device.makeBuffer(length: 64, options: .storageModeShared)!
let cursor = device.makeBuffer(length: 64, options: .storageModeShared)!

// 随机 ulong 键(高32=距离, 低32=索引)
var rng: UInt64 = 0xDEADBEEF
let kp = keys.contents().bindMemory(to: UInt64.self, capacity: N)
for i in 0..<N {
    rng = rng &* 6364136223846793005 &+ 1442695040888963407
    kp[i] = (UInt64((rng >> 33) & 0x7FFF_FFFF) << 32) | UInt64(i)
}

let tg = MTLSize(width: 256, height: 1, depth: 1)
let groups = MTLSize(width: N / 256, height: 1, depth: 1)
var srcBuf = keys, dstBuf = scratch
let cb = queue0(device: device)!
func queue0(device: MTLDevice) -> MTLCommandQueue? { device.makeCommandQueue() }
let q = device.makeCommandQueue()!
let enc0 = q.makeCommandBuffer()!
_ = enc0
var result = true
// 8 次独立验证(每次重新填键; 原子散射非稳定, 但键全唯一时排序唯一确定)
for trial in 0..<8 {
    var rng2: UInt64 = 0xDEADBEEF &+ UInt64(trial)
    for i in 0..<N {
        rng2 = rng2 &* 6364136223846793005 &+ 1442695040888963407
        kp[i] = (UInt64((rng2 >> 33) & 0x7FFF_FFFF) << 32) | UInt64(i)
    }
    var srcBuf = keys, dstBuf = scratch
    // v2 终版: 每 pass 一个 command buffer——CPU 算 hist/cursor 与 GPU scatter 严格交替,
    // 消除 CPU/GPU 混写竞态(教学版正确优先; 工业版全 GPU + 栅栏)
    for pass in 0..<16 {
        var shift = UInt32(pass * 4)
        let hp = hist.contents().bindMemory(to: UInt32.self, capacity: 16)
        let cp = cursor.contents().bindMemory(to: UInt32.self, capacity: 16)
        let ksrc = srcBuf.contents().bindMemory(to: UInt64.self, capacity: N)
        for b in 0..<16 { hp[b] = 0 }
        for i in 0..<N { hp[Int((ksrc[i] >> shift) & 0xF)] += 1 }
        var run: UInt32 = 0
        for b in 0..<16 { let v = hp[b]; cp[b] = run; run += v }
        let cbuf = q.makeCommandBuffer()!
        guard let enc = cbuf.makeComputeCommandEncoder() else { exit(1) }
        enc.setComputePipelineState(scatterPSO)
        enc.setBuffer(srcBuf, offset: 0, index: 0)
        enc.setBuffer(dstBuf, offset: 0, index: 1)
        enc.setBuffer(cursor, offset: 0, index: 2)
        enc.setBytes(&shift, length: 4, index: 3)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cbuf.commit(); cbuf.waitUntilCompleted()
        let tmp = srcBuf; srcBuf = dstBuf; dstBuf = tmp
    }
    // 16 pass 偶数 → 结果回 keys
    var bad = 0
    for i in 1..<N where kp[i-1] > kp[i] {
        if bad < 2 { print("  失序对@\(i): \(String(kp[i-1], radix: 16)) > \(String(kp[i], radix: 16))") }
        bad += 1
    }
    var seen = Set<UInt32>(); var dup = 0
    for i in 0..<N { if !seen.insert(UInt32(truncatingIfNeeded: kp[i])).inserted { dup += 1 } }
    print("  唯一索引: \(seen.count)/\(N) 重复:\(dup)")
    if bad != 0 { print("trial \(trial): 违例 \(bad)"); result = false; break }
}
print(result ? "radix 8 trials: 全部有序 ✓" : "FAIL")
exit(result ? 0 : 1)
