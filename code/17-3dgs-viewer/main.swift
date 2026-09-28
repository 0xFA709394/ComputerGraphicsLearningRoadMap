// 17-3dgs-viewer: 3DGS 最小查看器(合成场景 + 真实 ply 往返 + GPU 排序 + instanced splat)
// 对应 docs/22 第 1~2 周与 docs/27 案例 D 的 MVD。空格: 开/关排序(混合序错乱对照)。
// 构建: ./build.sh    运行: ./splat

import AppKit
import MetalKit
import QuartzCore
import simd

let N_SPLATS = 32_768    // 2^15: bitonic 要求 2 的幂(圆环 24k + 地面 8k + 尾巴 768)

struct Splat {
    var pos: SIMD4<Float>          // xyz + 平均尺度(渲染兜底)
    var colorAlpha: SIMD4<Float>   // rgb + alpha
    var scale: SIMD3<Float>        // 各向异性半轴(EWA: 3D 协方差 = R S Sᵀ Rᵀ)
    var rot: SIMD4<Float>          // 单位四元数 (w,x,y,z)
}
struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>         // x: time, y: N, z: sortedOn, w: viewportH
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
func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

/// 合成高斯场景: 彩虹圆环面 + 蓝灰地面 + 一条暖色螺旋尾巴
func makeScene() -> [Splat] {
    var rng: UInt64 = 0x853c49e6748fea9b
    func rnd() -> Float {
        rng = rng &* 6364136223846793005 &+ 1442695040888963407
        return Float(Double((rng >> 33) & 0x7FFF_FFFF) / Double(0x7FFF_FFFF))
    }
    var s = [Splat]()
    s.reserveCapacity(N_SPLATS)
    let R: Float = 1.7, r: Float = 0.55
    // 圆环面 24k: 色相沿主角度
    for _ in 0..<24_576 {
        let u = rnd() * 2 * .pi, v = rnd() * 2 * .pi
        let cx = (R + r * cos(v)) * cos(u), cy = r * sin(v), cz = (R + r * cos(v)) * sin(u)
        let hue = u / (2 * .pi)
        let col = SIMD3<Float>(0.5 + 0.5 * cos(2 * .pi * hue),
                               0.5 + 0.5 * cos(2 * .pi * (hue + 0.33)),
                               0.5 + 0.5 * cos(2 * .pi * (hue + 0.66)))
        // EWA: 沿环面切向拉长的椭球——真实 3DGS 重建出的就是这种"贴表面"形态
        let qw = cos(u / 2), qx = sin(u / 2)   // 绕 y 轴旋转对齐切向
        s.append(Splat(pos: SIMD4(cx, cy, cz, 0),
                       colorAlpha: SIMD4(col.x, col.y, col.z, 0.75),
                       scale: SIMD3(0.09 + rnd() * 0.05, 0.02 + rnd() * 0.01, 0.03 + rnd() * 0.02),
                       rot: SIMD4(qw, 0, qx, 0)))
    }
    // 地面 8k
    for _ in 0..<8192 {
        let a = rnd() * 2 * .pi, rad = 0.2 + rnd() * 3.2
        let g: Float = 0.25 + rnd() * 0.25
        s.append(Splat(pos: SIMD4(cos(a) * rad, -1.35, sin(a) * rad, 0),
                       colorAlpha: SIMD4(g * 0.8, g, g * 1.25, 0.6),
                       scale: SIMD3(0.10 + rnd() * 0.05, 0.015, 0.10 + rnd() * 0.05),
                       rot: SIMD4(1, 0, 0, 0)))
    }
    // 螺旋尾巴(凑满 2 的幂)
    for i in 0..<(N_SPLATS - s.count) {
        let t = Float(i) / Float(N_SPLATS - s.count)
        let a = t * 6 * .pi
        s.append(Splat(pos: SIMD4(cos(a) * (0.3 + t), -1.2 + t * 2.6, sin(a) * (0.3 + t), 0),
                       colorAlpha: SIMD4(0.95, 0.55 + 0.4 * t, 0.2, 0.8),
                       scale: SIMD3(0.08, 0.08, 0.03),
                       rot: SIMD4(1, 0, 0, 0)))
    }
    return s
}

/// 写 3DGS 标准 .ply(binary_little_endian, 21 字段/splat)——与真实训练输出同构
func writePLY(_ splats: [Splat], to path: String) throws {
    var head = """
    ply
    format binary_little_endian 1.0
    element vertex \(splats.count)
    property float x
    property float y
    property float z
    property float nx
    property float ny
    property float nz
    property float f_dc_0
    property float f_dc_1
    property float f_dc_2
    property float opacity
    property float scale_0
    property float scale_1
    property float scale_2
    property float rot_0
    property float rot_1
    property float rot_2
    property float rot_3
    end_header
    """
    head += "\n"
    var data = Data(head.utf8)
    data.reserveCapacity(data.count + splats.count * 21 * 4)
    for s in splats {
        // 逆映射: color = 0.5 + 0.2820948 * f_dc → f_dc = (color-0.5)/0.2820948
        //         alpha 可见值 → opacity = logit
        let fd = SIMD3<Float>(s.colorAlpha.x, s.colorAlpha.y, s.colorAlpha.z)
        let inv: Float = 1 / 0.2820948
        let logit = { (a: Float) in log(max(a, 0.02) / max(1 - a, 0.02)) }
        let fields: [Float] = [
            s.pos.x, s.pos.y, s.pos.z,
            0, 0, 0,
            (fd.x - 0.5) * inv, (fd.y - 0.5) * inv, (fd.z - 0.5) * inv,
            logit(s.colorAlpha.w),
            s.scale.x, s.scale.y, s.scale.z,               // 真各向异性 scale(线性空间)
            s.rot.w, s.rot.x, s.rot.y, s.rot.z,            // (w,x,y,z)
        ]
        for f in fields {
            var v = f.bitPattern.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
    }
    try data.write(to: URL(fileURLWithPath: path))
}

/// 读回(完整 21 字段)——加载器与 writer 的往返即资产链验证
func readPLY(from path: String) throws -> [Splat] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let headerEnd = data.range(of: Data("end_header\n".utf8)) else { throw NSError(domain: "ply", code: 1) }
    let bodyStart = headerEnd.upperBound
    let stride = 17 * 4
    let count = (data.count - bodyStart) / stride
    var out = [Splat]()
    out.reserveCapacity(count)
    data[bodyStart...].withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<count {
            let base = raw.baseAddress! + i * stride
            let floats = (0..<21).map { j in
                base.load(fromByteOffset: j * 4, as: Float.self)
            }
            let c: Float = 0.2820948
            let sig = { (o: Float) in 1 / (1 + exp(-o)) }
            out.append(Splat(
                pos: SIMD4(floats[0], floats[1], floats[2], 0),
                colorAlpha: SIMD4(0.5 + c * floats[6], 0.5 + c * floats[7], 0.5 + c * floats[8],
                                  sig(floats[9])),
                scale: SIMD3(floats[11], floats[12], floats[13]),
                rot: SIMD4(floats[17], floats[14], floats[15], floats[16])))
        }
    }
    return out
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let splatBuf: MTLBuffer
    let sortedBuf: MTLBuffer
    let keyBuf: MTLBuffer
    let keyPSO, bitonicPSO, gatherPSO: MTLComputePipelineState
    let renderPSO: MTLRenderPipelineState
    var sortedOn = true
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        // 生成 → 写 ply → 读回(资产链往返验证)
        let scene = makeScene()
        let plyPath = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("scene.ply").path
        do {
            try writePLY(scene, to: plyPath)
            let loaded = try readPLY(from: plyPath)
            print("ply 往返: 写 \(scene.count) / 读 \(loaded.count) splats (\(plyPath))")
            splatBuf = device.makeBuffer(bytes: loaded, length: N_SPLATS * MemoryLayout<Splat>.stride, options: .storageModeShared)!
        } catch {
            FileHandle.standardError.write("ply 往返失败: \(error)\n".data(using: .utf8)!)
            return nil
        }
        sortedBuf = device.makeBuffer(length: N_SPLATS * MemoryLayout<Splat>.stride, options: .storageModeShared)!
        keyBuf = device.makeBuffer(length: N_SPLATS * 8, options: .storageModeShared)!

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let kf = lib.makeFunction(name: "makeKeys"),
              let bf = lib.makeFunction(name: "bitonicUlong"),
              let gf = lib.makeFunction(name: "gather"),
              let sv = lib.makeFunction(name: "splatVert"),
              let sf = lib.makeFunction(name: "splatFrag") else { return nil }
        keyPSO = try! device.makeComputePipelineState(function: kf)
        bitonicPSO = try! device.makeComputePipelineState(function: bf)
        gatherPSO = try! device.makeComputePipelineState(function: gf)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = sv
        pd.fragmentFunction = sf
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .one               // premultiplied
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .one
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        renderPSO = try! device.makeRenderPipelineState(descriptor: pd)
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let eye = SIMD3<Float>(sin(t * 0.12) * 5.5, 1.2, cos(t * 0.12) * 5.5)
        var u = Uniforms(
            viewProj: perspective(fovY: 50 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, -0.2, 0), up: SIMD3(0, 1, 0)),
            camPos: SIMD4(eye, 1),
            misc: SIMD4(t, Float(N_SPLATS), sortedOn ? 1 : 0, 300))

        let tg = MTLSize(width: 256, height: 1, depth: 1)
        let groups = MTLSize(width: N_SPLATS / 256, height: 1, depth: 1)

        // 1) 键 2) bitonic(升序=近在前) 3) gather(反转=远在前, 混合所需)
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(keyPSO)
            enc.setBuffer(splatBuf, offset: 0, index: 0)
            enc.setBuffer(keyBuf, offset: 0, index: 1)
            var cp = eye
            enc.setBytes(&cp, length: MemoryLayout<SIMD3<Float>>.stride, index: 2)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            if sortedOn {
                enc.setComputePipelineState(bitonicPSO)
                enc.setBuffer(keyBuf, offset: 0, index: 0)
                var k = 2
                while k <= N_SPLATS {
                    var j = k >> 1
                    while j > 0 {
                        var kj = SIMD2<UInt32>(UInt32(k), UInt32(j))
                        enc.setBytes(&kj, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
                        j >>= 1
                    }
                    k <<= 1
                }
            }
            enc.setComputePipelineState(gatherPSO)
            enc.setBuffer(splatBuf, offset: 0, index: 0)
            enc.setBuffer(keyBuf, offset: 0, index: 1)
            enc.setBuffer(sortedBuf, offset: 0, index: 2)
            var nTotal = UInt32(N_SPLATS)
            enc.setBytes(&nTotal, length: 4, index: 3)   // 修复: gather 的 nTotal 此前从未传入(越界→全屏同一 splat)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
        }

        // 4) instanced splat(4 顶点三角带)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(renderPSO)
            enc.setVertexBuffer(sortedBuf, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                               instanceCount: N_SPLATS)
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
        if event.keyCode == 49 { (delegate as? Renderer)?.sortedOn.toggle() }
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
mtkView.clearColor = MTLClearColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)   // 亮底看混合
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "3DGS Viewer — CG Roadmap 17 (空格: 开关排序)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
