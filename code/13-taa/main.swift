// 13-taa: 时序抗锯齿(Halton(2,3) 8 点抖动 + 历史累积 + 邻域 AABB clamp)
// 对应 docs/11 §TAA、18 章蓝图 M3。空格键: 开/关 TAA。构建: ./build.sh    运行: ./taa

import AppKit
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>      // x: time, y: taaOn
    var texel: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4; var color: SIMD4<Float> }   // color.a: 是否地面
struct SphereVertex {
    var pos: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
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
func translateMat(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(SIMD4(1,0,0,0), SIMD4(0,1,0,0), SIMD4(0,0,1,0), SIMD4(t.x, t.y, t.z, 1))
}
func scaleMat(_ s: Float) -> simd_float4x4 { simd_float4x4(diagonal: SIMD4(s, s, s, 1)) }
func ndcOffsetMat(_ x: Float, _ y: Float) -> simd_float4x4 {   // NDC 平移(抖动)
    simd_float4x4(SIMD4(1,0,0,0), SIMD4(0,1,0,0), SIMD4(0,0,1,0), SIMD4(x, y, 0, 1))
}

/// Halton(2,3) 低差异序列(docs/01): 8 点覆盖一个像素内的亚像素位置
func halton(_ index: Int, _ base: Int) -> Float {
    var f: Float = 1, r: Float = 0, i = index
    while i > 0 {
        f /= Float(base)
        r += f * Float(i % base)
        i /= base
    }
    return r
}

func makeSphereBuffers(device: MTLDevice, radius: Float, lat: Int, lon: Int)
    -> (verts: MTLBuffer, indices: MTLBuffer, indexCount: Int) {
    var verts: [SphereVertex] = []
    for i in 0...lat {
        let th = Float.pi * Float(i) / Float(lat), st = sin(th), ct = cos(th)
        for j in 0...lon {
            let ph = 2 * Float.pi * Float(j) / Float(lon)
            let n = SIMD3<Float>(st * cos(ph), ct, st * sin(ph))
            verts.append(SphereVertex(pos: n * radius, normal: n, uv: .zero))
        }
    }
    var idx: [UInt16] = []
    idx.reserveCapacity(lat * lon * 6)
    for i in 0..<lat {
        for j in 0..<lon {
            let a = i * (lon + 1) + j, b = (i + 1) * (lon + 1) + j, c = b + 1, d = a + 1
            idx += [UInt16(a), UInt16(b), UInt16(c), UInt16(a), UInt16(c), UInt16(d)]
        }
    }
    var fdata = [Float]()
        fdata.reserveCapacity(verts.count * 8)
        for v in verts { fdata += [v.pos.x, v.pos.y, v.pos.z, v.normal.x, v.normal.y, v.normal.z, v.uv.x, v.uv.y] }
        // 踩坑实录: SIMD3 对齐 16 → 结构体 stride 48 ≠ 描述符 32, GPU 读到交错垃圾
        // (球体稠密网格侥幸"看着对", 稀疏瓦片大面积消失); 手动交错 32B 打包
        let vb = device.makeBuffer(bytes: fdata, length: fdata.count * 4)!
    let ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count)!
    return (vb, ib, idx.count)
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let sphereVB: MTLBuffer
    let sphereIB: MTLBuffer
    let sphereIndexCount: Int
    let groundVB: MTLBuffer
    let sceneColor: MTLTexture      // 抖动后的当帧(线性 HDR)
    let sceneDepth: MTLTexture
    let history: [MTLTexture]       // ping-pong 历史
    let scenePSO, resolvePSO, blitPSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var histIdx = 0
    var frame = 0
    var taaOn = true
    var resetHistory = true   // headless: 每段序列从空历史开始
    // headless 验证钩子
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        let W = 900, H = 600

        let (vb, ib, count) = makeSphereBuffers(device: device, radius: 1, lat: 24, lon: 32)
        sphereVB = vb; sphereIB = ib; sphereIndexCount = count

        // 条纹地面(细分瓦片: 大平面裁剪边界问题的教训, 见 11 的踩坑 4)
        var quads: [SphereVertex] = []
        let TILES = 8, S: Float = 40
        for iy in 0..<TILES {
            for ix in 0..<TILES {
                let step = 2 * S / Float(TILES)
                let x0 = -S + Float(ix) * step, x1 = x0 + step
                let z0 = -S + Float(iy) * step, z1 = z0 + step
                quads.append(SphereVertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(SphereVertex(pos: SIMD3(x1, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(SphereVertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(SphereVertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(SphereVertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(SphereVertex(pos: SIMD3(x0, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
            }
        }
        var fdata = [Float]()
        fdata.reserveCapacity(quads.count * 8)
        for v in quads { fdata += [v.pos.x, v.pos.y, v.pos.z, v.normal.x, v.normal.y, v.normal.z, v.uv.x, v.uv.y] }
        // 踩坑实录: SIMD3 对齐 16 → 结构体 stride 48 ≠ 描述符 32, GPU 读到交错垃圾
        // (球体稠密网格侥幸"看着对", 稀疏瓦片大面积消失); 手动交错 32B 打包
        groundVB = device.makeBuffer(bytes: fdata, length: fdata.count * 4)!

        func rgba16(_ w: Int, _ h: Int, rt: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = rt ? [.renderTarget, .shaderRead] : .shaderRead
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let sc = rgba16(W, H, rt: true),
              let h0 = rgba16(W, H, rt: true),
              let h1 = rgba16(W, H, rt: true) else { return nil }
        sceneColor = sc; history = [h0, h1]
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: W, height: H, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .private
        guard let depth = device.makeTexture(descriptor: dd) else { return nil }
        sceneDepth = depth

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sv = lib.makeFunction(name: "sceneVert"),
              let sf = lib.makeFunction(name: "sceneFrag"),
              let qv = lib.makeFunction(name: "quadVert"),
              let rf = lib.makeFunction(name: "taaResolveFS"),
              let bf = lib.makeFunction(name: "blitFS") else { return nil }

        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = sv
        sd.fragmentFunction = sf
        sd.vertexDescriptor = mtlVD
        sd.colorAttachments[0].pixelFormat = .rgba16Float
        sd.depthAttachmentPixelFormat = .depth32Float
        guard let scenePSO = try? device.makeRenderPipelineState(descriptor: sd) else { return nil }
        self.scenePSO = scenePSO

        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction = qv
        rd.fragmentFunction = rf
        rd.colorAttachments[0].pixelFormat = .rgba16Float
        guard let resolvePSO = try? device.makeRenderPipelineState(descriptor: rd) else { return nil }
        self.resolvePSO = resolvePSO

        let bd = MTLRenderPipelineDescriptor()
        bd.vertexFunction = qv
        bd.fragmentFunction = bf
        bd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let blitPSO = try? device.makeRenderPipelineState(descriptor: bd) else { return nil }
        self.blitPSO = blitPSO

        let dz = MTLDepthStencilDescriptor()
        dz.depthCompareFunction = .less
        dz.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dz)!
    }

    func drawFrame(cb: MTLCommandQueue, t: Float, aspect: Float) -> MTLCommandBuffer? {
        guard let cbuf = queue.makeCommandBuffer() else { return nil }
        let W = 900, H = 600
        // 1) 抖动投影: Halton(2,3) 亚像素偏移(相机静止 → 无需速度缓冲重投影)
        var jx: Float = 0, jy: Float = 0
        if taaOn {
            let i = frame % 8
            jx = (halton(i + 1, 2) - 0.5) * 2 / Float(W)
            jy = (halton(i + 1, 3) - 0.5) * 2 / Float(H)
        }
        let vp = ndcOffsetMat(jx, jy)
            * perspective(fovY: 46 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
            * lookAt(eye: SIMD3(0, 2.2, 6.5), target: SIMD3(0, 0.4, 0), up: SIMD3(0, 1, 0))
        var u = Uniforms(viewProj: vp, camPos: SIMD4(0, 2.2, 6.5, 1),
                         misc: SIMD4(t, taaOn ? 1 : 0, resetHistory ? 1 : 0.1, 0),
                         texel: SIMD4(1 / Float(W), 1 / Float(H), 0, 0))

        // 场景: 中央球 + 卫星球(绕行, 考验历史拒绝) + 条纹地面
        let sat = SIMD3<Float>(cos(t * 0.7) * 2.6, 0.5, sin(t * 0.7) * 2.6)
        let objs: [(ObjUniforms, Bool)] = [
            (ObjUniforms(model: translateMat(SIMD3(0, 1, 0)), color: SIMD4(0.9, 0.25, 0.2, 0)), true),
            (ObjUniforms(model: translateMat(sat) * scaleMat(0.45), color: SIMD4(0.95, 0.8, 0.3, 0)), true),
            (ObjUniforms(model: .init(diagonal: SIMD4(1,1,1,1)), color: SIMD4(0.75, 0.75, 0.78, 1)), false),
        ]

        // 2) 渲染当帧(线性 HDR)
        let rp1 = MTLRenderPassDescriptor()
        rp1.colorAttachments[0].texture = sceneColor
        rp1.colorAttachments[0].loadAction = .clear
        rp1.colorAttachments[0].storeAction = .store
        rp1.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1)
        rp1.depthAttachment.texture = sceneDepth
        rp1.depthAttachment.loadAction = .clear
        rp1.depthAttachment.storeAction = .dontCare
        if let enc = cbuf.makeRenderCommandEncoder(descriptor: rp1) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (obj, isSphere) in objs {
                var o = obj
                if isSphere {
                    enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.setFragmentBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount,
                                              indexType: .uint16, indexBuffer: sphereIB, indexBufferOffset: 0)
                } else {
                    enc.setVertexBuffer(groundVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.setFragmentBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 8 * 8 * 6)
                }
            }
            enc.endEncoding()
        }

        // 3) resolve: 历史 clamp + 10% 混合 → 写入另一张历史
        let dst = history[histIdx ^ 1]
        let rp2 = MTLRenderPassDescriptor()
        rp2.colorAttachments[0].texture = dst
        rp2.colorAttachments[0].loadAction = .dontCare
        rp2.colorAttachments[0].storeAction = .store
        if let enc = cbuf.makeRenderCommandEncoder(descriptor: rp2) {
            enc.setRenderPipelineState(resolvePSO)
            enc.setFragmentTexture(sceneColor, index: 0)
            enc.setFragmentTexture(history[histIdx], index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        histIdx ^= 1
        frame += 1
        resetHistory = false
        return cbuf
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        guard let cbuf = drawFrame(cb: queue, t: t, aspect: aspect) else { return }
        // 4) 输出: ACES + gamma
        if let enc = cbuf.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(blitPSO)
            enc.setFragmentTexture(history[histIdx], index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cbuf.present(drawable)
        cbuf.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

final class KeyMTKView: MTKView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { (delegate as? Renderer)?.taaOn.toggle() }   // 空格
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
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "TAA Temporal AA — CG Roadmap 13 (空格: 开关对比)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
