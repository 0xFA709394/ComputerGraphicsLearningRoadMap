// 20-drs: 动态分辨率缩放(帧时间反馈回路 + 滞回分档)
// 对应 docs/07 §8.3 与 docs/27 案例 C 骨架。空格: 切换合成负载。
// 构建: ./build.sh    运行: ./drs

import AppKit
import MetalKit
import QuartzCore
import simd

let BASE_W = 900, BASE_H = 600

/// DRS 控制器(纯逻辑, 可注入合成帧时间做 headless 断言)
/// EMA 平滑 → 超预算降档(立即) → 低于预算持续 N 帧才升档(滞回, 防抖动)
struct DRSController {
    var scale: Float = 1.0
    var smoothedMs: Float = 0
    var lowStreak = 0
    let budgetMs: Float
    init(budgetMs: Float = 16.6) { self.budgetMs = budgetMs }

    mutating func update(frameMs: Float) {
        smoothedMs = smoothedMs == 0 ? frameMs : smoothedMs * 0.9 + frameMs * 0.1
        if smoothedMs > budgetMs * 1.15 {
            let old = scale
            scale = max(0.5, scale - 0.1)
            lowStreak = 0
            if scale != old { print(String(format: "DRS ↓ scale=%.1f (平滑帧时 %.1fms)", scale, smoothedMs)) }
        } else if smoothedMs < budgetMs * 0.65 {
            lowStreak += 1
            if lowStreak > 25 {
                let old = scale
                scale = min(1.0, scale + 0.1)
                lowStreak = 0
                if scale != old { print(String(format: "DRS ↑ scale=%.1f", scale)) }
            }
        } else {
            lowStreak = 0
        }
    }
}

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>       // x: time, y: loadIter
}
struct ObjUniforms { var model: simd_float4x4; var color: SIMD4<Float> }
struct Vertex { var pos: SIMD3<Float>; var normal: SIMD3<Float> }   // 24B 天然对齐(SIMD3 起点)

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
func rotationY(_ a: Float) -> simd_float4x4 {
    let (c, s) = (cos(a), sin(a))
    return simd_float4x4(SIMD4(c,0,-s,0), SIMD4(0,1,0,0), SIMD4(s,0,c,0), SIMD4(0,0,0,1))
}

func makeSphere(device: MTLDevice, radius: Float, lat: Int, lon: Int)
    -> (vb: MTLBuffer, ib: MTLBuffer, count: Int) {
    var verts: [Vertex] = []
    for i in 0...lat {
        let th = Float.pi * Float(i) / Float(lat), st = sin(th), ct = cos(th)
        for j in 0...lon {
            let ph = 2 * Float.pi * Float(j) / Float(lon)
            let n = SIMD3<Float>(st * cos(ph), ct, st * sin(ph))
            verts.append(Vertex(pos: n * radius, normal: n))
        }
    }
    var idx: [UInt16] = []
    for i in 0..<lat { for j in 0..<lon {
        let a = i * (lon + 1) + j, b = (i + 1) * (lon + 1) + j, c = b + 1, d = a + 1
        idx += [UInt16(a), UInt16(b), UInt16(c), UInt16(a), UInt16(c), UInt16(d)]
    } }
    let vb = device.makeBuffer(bytes: verts, length: verts.count * 24)!
    let ib = device.makeBuffer(bytes: idx, length: idx.count * 2)!
    return (vb, ib, idx.count)
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let sphere: (vb: MTLBuffer, ib: MTLBuffer, count: Int)
    let groundVB: MTLBuffer
    let groundCount: Int
    let scenePSO, upPSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var drs = DRSController()
    var heavyLoad = false
    var lastT: Float = 0
    // 低分辨率 RT 池(按档位)
    var rtCache: [Int: MTLTexture] = [:]
    // headless
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?
    var injectFrameMs: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        sphere = makeSphere(device: device, radius: 1, lat: 24, lon: 32)

        var quads: [Vertex] = []
        let TILES = 6, S: Float = 12
        for iy in 0..<TILES { for ix in 0..<TILES {
            let step = 2 * S / Float(TILES)
            let x0 = -S + Float(ix) * step, x1 = x0 + step
            let z0 = -S + Float(iy) * step, z1 = min(z0 + step, 4)
            if z0 >= 4 { continue }
            for (px_, pz_) in [(x0,z0),(x1,z0),(x1,z1),(x0,z0),(x1,z1),(x0,z1)] {
                quads.append(Vertex(pos: SIMD3(px_, 0, pz_), normal: SIMD3(0,1,0)))
            }
        } }
        groundVB = device.makeBuffer(bytes: quads, length: quads.count * 24)!
        groundCount = quads.count

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let vf = lib.makeFunction(name: "vert"),
              let ff = lib.makeFunction(name: "frag"),
              let uv = lib.makeFunction(name: "upVert"),
              let uf = lib.makeFunction(name: "upFrag") else { return nil }

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 24

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = vf
        sd.fragmentFunction = ff
        sd.vertexDescriptor = vd
        sd.colorAttachments[0].pixelFormat = .rgba16Float
        sd.depthAttachmentPixelFormat = .depth32Float
        scenePSO = try! device.makeRenderPipelineState(descriptor: sd)

        let ud = MTLRenderPipelineDescriptor()
        ud.vertexFunction = uv
        ud.fragmentFunction = uf
        ud.colorAttachments[0].pixelFormat = view.colorPixelFormat
        upPSO = try! device.makeRenderPipelineState(descriptor: ud)

        let dz = MTLDepthStencilDescriptor()
        dz.depthCompareFunction = .less
        dz.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dz)!
    }

    func lowResTarget(_ device: MTLDevice) -> MTLTexture {
        let tier = Int(drs.scale * 10)
        if let t = rtCache[tier] { return t }
        let w = Int(Float(BASE_W) * drs.scale), h = Int(Float(BASE_H) * drs.scale)
        let colorTD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                               width: w, height: h, mipmapped: false)
        colorTD.usage = [.renderTarget, .shaderRead]
        colorTD.storageMode = .private
        let color = device.makeTexture(descriptor: colorTD)!
        let depthTD = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                               width: w, height: h, mipmapped: false)
        depthTD.usage = [.renderTarget]
        depthTD.storageMode = .private
        rtCache[tier] = color
        rtCache[-tier] = device.makeTexture(descriptor: depthTD)!   // 负键存深度
        return color
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let device = view.device,
              let cb = queue.makeCommandBuffer() else { return }
        // 帧时间反馈(GUI: 墙钟; headless: 注入)
        let now = fixedTime ?? Float(CACurrentMediaTime())
        let frameMs = injectFrameMs ?? max((now - lastT) * 1000, 0.1)
        lastT = now
        drs.update(frameMs: frameMs)
        injectFrameMs = nil

        let t = now
        let lowColor = lowResTarget(device)
        let lowDepth = rtCache[-Int(drs.scale * 10)]!
        var u = Uniforms(
            viewProj: perspective(fovY: 46 * .pi / 180, aspect: Float(BASE_W) / Float(BASE_H), n: 0.1, f: 100)
                * lookAt(eye: SIMD3(0, 2.2, 6), target: SIMD3(0, 0.4, 0), up: SIMD3(0, 1, 0)),
            camPos: SIMD4(0, 2.2, 6, 1),
            misc: SIMD4(t, heavyLoad ? 900.0 : 0.0, 0, 0))
        let objs: [(ObjUniforms, Bool)] = [
            (ObjUniforms(model: rotationY(t * 0.5), color: SIMD4(0.9, 0.35, 0.22, 0)), true),
            (ObjUniforms(model: .init(diagonal: SIMD4(1,1,1,1)), color: SIMD4(0.7, 0.7, 0.74, 1)), false),
        ]

        // 1) 低分辨率场景 pass
        let rp1 = MTLRenderPassDescriptor()
        rp1.colorAttachments[0].texture = lowColor
        rp1.colorAttachments[0].loadAction = .clear
        rp1.colorAttachments[0].storeAction = .store
        rp1.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        rp1.depthAttachment.texture = lowDepth
        rp1.depthAttachment.loadAction = .clear
        rp1.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: rp1) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (obj, isSphere) in objs {
                var o = obj
                if isSphere {
                    enc.setVertexBuffer(sphere.vb, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: sphere.count,
                                              indexType: .uint16, indexBuffer: sphere.ib, indexBufferOffset: 0)
                } else {
                    enc.setVertexBuffer(groundVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundCount)
                }
            }
            enc.endEncoding()
        }

        // 2) 放大 pass(bilinear 占位 → MetalFX drop-in)
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(upPSO)
            enc.setFragmentTexture(lowColor, index: 0)
            var si = SIMD4<Float>(drs.scale, 0, 0, 0)
            enc.setFragmentBytes(&si, length: 16, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
        if event.keyCode == 49 { (delegate as? Renderer)?.heavyLoad.toggle() }   // 空格
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
    contentRect: NSRect(x: 0, y: 0, width: CGFloat(BASE_W), height: CGFloat(BASE_H)),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
let mtkView = KeyMTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "DRS 动态分辨率 — CG Roadmap 20 (空格: 合成负载)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
