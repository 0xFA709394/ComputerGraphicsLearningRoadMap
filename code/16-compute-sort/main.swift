// 16-compute-sort: GPU bitonic 排序(65536 键/帧, 逐 pass 多 dispatch, 零 CPU 回读)
// 对应 docs/07 §6「排序」与 docs/27 案例 D 的核心深水区。空格: 开/关排序(颜色乱序对照)。
// 构建: ./build.sh    运行: ./computesort

import AppKit
import MetalKit
import QuartzCore
import simd

let N = 65_536   // 2^16: bitonic 要求 2 的幂

struct Uniforms {
    var viewProj: simd_float4x4
    var misc: SIMD4<Float>       // x: time, y: N, z: sortedOn
}

func perspective(fovY: Float, aspect: Float, n: Float, f: Float) -> simd_float4x4 {
    let t = 1 / tan(fovY * 0.5)
    return simd_float4x4(
        SIMD4(t / aspect, 0, 0, 0),
        SIMD4(0, -t, 0, 0),
        SIMD4(0, 0, f / (n - f), -1),
        SIMD4(0, 0, n * f / (n - f), 0))
}
func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let fz = simd_normalize(target - eye)
    let rx = simd_normalize(simd_cross(fz, up))
    let uy = simd_cross(rx, fz)
    return simd_float4x4(
        SIMD4(rx.x, uy.x, -fz.x, 0),
        SIMD4(rx.y, uy.y, -fz.y, 0),
        SIMD4(rx.z, uy.z, -fz.z, 0),
        SIMD4(-simd_dot(rx, eye), -simd_dot(uy, eye), simd_dot(fz, eye), 1))
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let points: MTLBuffer           // xyz + w(键)
    let sortPSO: MTLComputePipelineState
    let renderPSO: MTLRenderPipelineState
    var sortedOn = true
    // headless 验证钩子
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // 球壳随机点云(初始乱序)
        var rng: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double((rng >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF))
        }
        var data = [SIMD4<Float>](repeating: .zero, count: N)
        for i in 0..<N {
            let z = 1 - 2 * rnd()
            let r = sqrt(max(0, 1 - z * z))
            let an = 2 * Float.pi * rnd()
            data[i] = SIMD4(r * cos(an) * 3.2, z * 3.2, r * sin(an) * 3.2, 0)
        }
        points = device.makeBuffer(bytes: data, length: N * 16, options: .storageModeShared)!

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let stepFn = lib.makeFunction(name: "bitonicStep"),
              let pv = lib.makeFunction(name: "ptVert"),
              let pf = lib.makeFunction(name: "ptFrag") else { return nil }
        sortPSO = try! device.makeComputePipelineState(function: stepFn)

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = pv
        pd.fragmentFunction = pf
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        renderPSO = try! device.makeRenderPipelineState(descriptor: pd)
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let eye = SIMD3<Float>(sin(t * 0.15) * 9, 2.5, cos(t * 0.15) * 9)
        var u = Uniforms(
            viewProj: perspective(fovY: 50 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0)),
            misc: SIMD4(t, Float(N), sortedOn ? 1 : 0, 0))

        // ---- Pass 1: 写入本帧视深键 + bitonic 网络 ----
        if let enc = cb.makeComputeCommandEncoder() {
            // 键 = 视线深(-z_view): CPU 写 w(65536 次 SIMD 乘加, 也可并入第一个 sort pass 作练习)
            let p = points.contents().bindMemory(to: SIMD4<Float>.self, capacity: N)
            let fwd = simd_normalize(SIMD3<Float>(0,0,0) - eye)
            for i in 0..<N { p[i].w = simd_dot(fwd, SIMD3<Float>(p[i].x, p[i].y, p[i].z) - eye) }   // 深越大越远 → 升序 = 近在前

            enc.setComputePipelineState(sortPSO)
            enc.setBuffer(points, offset: 0, index: 0)
            let tg = MTLSize(width: 256, height: 1, depth: 1)
            var k = 2
            while k <= N {
                var j = k >> 1
                while j > 0 {
                    var kj = SIMD2<UInt32>(UInt32(k), UInt32(j))
                    enc.setBytes(&kj, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                    enc.dispatchThreadgroups(MTLSize(width: N / 256, height: 1, depth: 1),
                                             threadsPerThreadgroup: tg)
                    j >>= 1
                }
                k <<= 1
            }
            enc.endEncoding()
        }

        // ---- Pass 2: 点精灵(颜色=名次) ----
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(renderPSO)
            enc.setVertexBuffer(points, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: N)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

final class KeyMTKView: MTKView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { (delegate as? Renderer)?.sortedOn.toggle() }   // 空格
    }
}

// MARK: - App 启动
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("此设备不支持 Metal\n".data(using: .utf8)!)
    exit(1)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
let mtkView = KeyMTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.clearColor = MTLClearColor(red: 0.015, green: 0.015, blue: 0.025, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "GPU Bitonic Sort — CG Roadmap 16 (空格: 开关排序)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
