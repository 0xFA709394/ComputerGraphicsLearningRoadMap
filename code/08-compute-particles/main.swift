// 08-compute-particles: compute kernel 驱动 26 万粒子 + 点精灵 additive 渲染
// 对应 docs/07 §6/扩展篇 C 与 docs/02（encoder 顺序）。构建: ./build.sh    运行: ./particles

import AppKit
import MetalKit
import QuartzCore
import simd

let PARTICLE_COUNT = 262_144   // 2^18, 256 的整数倍(线程组对齐)

struct Particle {
    var pos: SIMD4<Float>
    var vel: SIMD4<Float>
}
struct SimParams {
    var attractor: SIMD4<Float>   // xyz 吸引子位置, w 引力强度 G
    var sim: SIMD4<Float>         // dt, drag, 重生半径, 时间
    var counts: SIMD4<Float>      // x 粒子数(越界 guard)
}
struct RenderUniforms {
    var viewProj: simd_float4x4
    var misc: SIMD4<Float>        // time, pointBase, speedScale
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

/// 确定性 LCG: 初值可复现(随机数种子写死, 每次运行画面一致)
struct LCG {
    var state: UInt64 = 0x853c49e6748fea9b
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double((state >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF))
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let particleBuf: MTLBuffer
    let computePSO: MTLComputePipelineState
    let renderPSO: MTLRenderPipelineState
    var lastT: Float = 0

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 初值: 吸引子外球壳 + 切向速度(星系盘式旋转) ----
        var rng = LCG()
        var initParticles = [Particle]()
        initParticles.reserveCapacity(PARTICLE_COUNT)
        for _ in 0..<PARTICLE_COUNT {
            let z = 1 - 2 * rng.next()
            let r = sqrt(max(0, 1 - z * z))
            let an = 2 * Float.pi * rng.next()
            let dir = SIMD3<Float>(r * cos(an), r * sin(an), z)
            let tangent = simd_normalize(simd_cross(SIMD3(0, 1, 0), SIMD3(dir.x, 0.3 * dir.y, dir.z)))
            initParticles.append(Particle(
                pos: SIMD4(dir * (2.5 + 2.0 * rng.next()), 0),
                vel: SIMD4(tangent * (1.8 + 1.6 * rng.next()), 0)))
        }
        // shared 模式 + "创建后 CPU 不再触碰"纪律(统一内存下等效 GPU 私有)。
        // 踩坑实录: 本机(macOS 26/AGXG16G)对 makeBuffer(bytes:options:.storageModePrivate)
        // 必现 SIGSEGV(驱动内 memmove), 换 shared 即好——私有初始化上传走 staging 的路径有 bug
        guard let buf = device.makeBuffer(bytes: initParticles,
                                          length: MemoryLayout<Particle>.stride * PARTICLE_COUNT,
                                          options: .storageModeShared) else { return nil }
        particleBuf = buf

        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let kernelFn = lib.makeFunction(name: "particleUpdate"),
              let vFn = lib.makeFunction(name: "particleVert"),
              let fFn = lib.makeFunction(name: "particleFrag") else { return nil }

        // compute 管线: 只有函数, 无顶点/片元/附件状态
        guard let computePSO = try? device.makeComputePipelineState(function: kernelFn) else { return nil }
        self.computePSO = computePSO

        // render 管线: additive 混合, 无深度附件(透明粒子不需要深度测试)
        let cp = MTLRenderPipelineDescriptor()
        cp.vertexFunction = vFn
        cp.fragmentFunction = fFn
        cp.colorAttachments[0].pixelFormat = view.colorPixelFormat
        cp.colorAttachments[0].isBlendingEnabled = true
        cp.colorAttachments[0].sourceRGBBlendFactor = .one        // 加色: src + dst
        cp.colorAttachments[0].destinationRGBBlendFactor = .one
        cp.colorAttachments[0].sourceAlphaBlendFactor = .one
        cp.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let renderPSO = try? device.makeRenderPipelineState(descriptor: cp) else { return nil }
        self.renderPSO = renderPSO
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime())
        let dt = min(max(t - lastT, 1 / 240), 1 / 30)   // 真实帧间隔, 防暂停后大步长爆炸
        lastT = t

        let attractor = SIMD3<Float>(2.4 * sin(0.21 * t), 1.1 * sin(0.17 * t + 1.7), 2.4 * cos(0.26 * t))
        var sp = SimParams(
            attractor: SIMD4(attractor, 16),     // G = 16
            sim: SIMD4(dt, 0.55, 9, t),          // drag=0.55, 重生半径=9
            counts: SIMD4(Float(PARTICLE_COUNT), 0, 0, 0))

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let eye = SIMD3<Float>(sin(t * 0.12) * 8.5, 3.4, cos(t * 0.12) * 8.5)
        var u = RenderUniforms(
            viewProj: perspective(fovY: 55 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, 0.2, 0), up: SIMD3(0, 1, 0)),
            misc: SIMD4(t, 24, 1 / 4.5, 0))     // pointBase=24, 速度归一 4.5

        // ---- Pass 1: compute 更新(同一 command buffer 内先于 Pass 2 执行 = 隐式同步) ----
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(computePSO)
            enc.setBuffer(particleBuf, offset: 0, index: 0)
            enc.setBytes(&sp, length: MemoryLayout<SimParams>.stride, index: 1)
            enc.dispatchThreadgroups(                        // 向上取整分派
                MTLSize(width: (PARTICLE_COUNT + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            enc.endEncoding()
        }

        // ---- Pass 2: 点精灵绘制 ----
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(renderPSO)
            enc.setVertexBuffer(particleBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<RenderUniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: PARTICLE_COUNT)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
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
let mtkView = MTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.clearColor = MTLClearColor(red: 0.008, green: 0.009, blue: 0.016, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
// 不设 depthStencilPixelFormat: 本例无深度测试
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "Compute Particles — CG Roadmap 08"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
