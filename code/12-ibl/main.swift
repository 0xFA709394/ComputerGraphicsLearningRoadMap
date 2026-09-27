// 12-ibl: 基于图像的光照(程序化 HDR 环境 + irradiance/GGX 预滤波/BRDF LUT + PBR 球阵)
// 对应 docs/03 §IBL split-sum。README 阶段 4「必须亲手实现」最后一块。
// 构建: ./build.sh    运行: ./ibl

import AppKit
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var sunDir: SIMD4<Float>
    var misc: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4; var mr: SIMD4<Float> }
struct FaceBasis { var r, u, f: SIMD4<Float> }
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

func makeSphereBuffers(device: MTLDevice, radius: Float, lat: Int, lon: Int)
    -> (verts: MTLBuffer, indices: MTLBuffer, indexCount: Int) {
    var verts: [SphereVertex] = []
    for i in 0...lat {
        let th = Float.pi * Float(i) / Float(lat), st = sin(th), ct = cos(th)
        for j in 0...lon {
            let ph = 2 * Float.pi * Float(j) / Float(lon)
            let n = SIMD3<Float>(st * cos(ph), ct, st * sin(ph))
            verts.append(SphereVertex(pos: n * radius, normal: n,
                                      uv: SIMD2(Float(j) / Float(lon), 1 - Float(i) / Float(lat))))
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
    let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<SphereVertex>.stride * verts.count)!
    let ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count)!
    return (vb, ib, idx.count)
}

// ---- 立方体面基向量(GL 约定): CPU 生成与 shader 采样共用 ----
let FACE_BASIS: [FaceBasis] = [
    FaceBasis(r: SIMD4(0,0,-1,0), u: SIMD4(0,-1,0,0), f: SIMD4(1,0,0,0)),   // +X
    FaceBasis(r: SIMD4(0,0, 1,0), u: SIMD4(0,-1,0,0), f: SIMD4(-1,0,0,0)),  // -X
    FaceBasis(r: SIMD4(1,0, 0,0), u: SIMD4(0,0, 1,0), f: SIMD4(0,1,0,0)),   // +Y
    FaceBasis(r: SIMD4(1,0, 0,0), u: SIMD4(0,0,-1,0), f: SIMD4(0,-1,0,0)),  // -Y
    FaceBasis(r: SIMD4(1,0, 0,0), u: SIMD4(0,-1,0,0), f: SIMD4(0,0,1,0)),   // +Z
    FaceBasis(r: SIMD4(-1,0,0,0), u: SIMD4(0,-1,0,0), f: SIMD4(0,0,-1,0)),  // -Z
]

let SUN_DIR = simd_normalize(SIMD3<Float>(0.45, 0.62, -0.4))   // 指向光源

/// 程序化 HDR 环境: 天空渐变 + 太阳 + 两条彩色带光(摄影棚感)
func envRadiance(_ d: SIMD3<Float>) -> SIMD3<Float> {
    let up = simd_clamp(d.y, 0, 1)
    var c = simd_mix(SIMD3(0.06, 0.07, 0.10), SIMD3(0.28, 0.45, 0.85),
                     SIMD3(repeating: up * up * (3 - 2 * up)))
    if d.y < 0 { c = SIMD3(0.045, 0.05, 0.06) }               // 地面暗
    let s = max(0, simd_dot(d, SUN_DIR))
    c += SIMD3(1.0, 0.93, 0.80) * pow(s, 1200) * 90           // 太阳盘(高亮)
    c += SIMD3(1.0, 0.85, 0.65) * pow(s, 10) * 0.30           // 大气辉光
    c += SIMD3(1.4, 0.25, 0.55) * pow(max(0, simd_dot(d, simd_normalize(SIMD3(0.9, 0.25, 0.2)))), 24) * 1.6
    c += SIMD3(0.15, 1.0, 1.2) * pow(max(0, simd_dot(d, simd_normalize(SIMD3<Float>(-0.7, 0.35, -0.5)))), 24) * 1.6
    return c
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let device: MTLDevice
    let sphereVB: MTLBuffer
    let sphereIB: MTLBuffer
    let sphereIndexCount: Int
    let envTex: MTLTexture          // 256/面 rgba16Float
    let irradianceTex: MTLTexture   // 32/面
    let prefilteredTex: MTLTexture  // 64/面, mip 0..4 对应 roughness 0..1
    let lutTex: MTLTexture          // 256 rg32Float
    let quadPSOs: [String: MTLRenderPipelineState]   // irradiance/prefilter/lut
    let bgPSO, scenePSO: MTLRenderPipelineState
    let depthWriteState: MTLDepthStencilState
    let depthOffState: MTLDepthStencilState

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        let (vb, ib, count) = makeSphereBuffers(device: device, radius: 0.42, lat: 24, lon: 32)
        sphereVB = vb; sphereIB = ib; sphereIndexCount = count

        // ---- 环境立方体贴图(CPU 生成 rgba16Float) ----
        guard let envTex = Renderer.makeCubeTex(device: device, size: 256, format: .rgba16Float,
                                                mips: 1, renderTarget: false) else { return nil }
        for face in 0..<6 {
            var data = [Float16]()
            data.reserveCapacity(256 * 256 * 4)
            let fb = FACE_BASIS[face]
            for y in 0..<256 {
                let ndcY = 1 - 2 * Float(y) / 255
                for x in 0..<256 {
                    let ndcX = 2 * Float(x) / 255 - 1
                    let dir = SIMD3<Float>(fb.f.x, fb.f.y, fb.f.z)
                        + SIMD3<Float>(fb.r.x, fb.r.y, fb.r.z) * ndcX
                        + SIMD3<Float>(fb.u.x, fb.u.y, fb.u.z) * ndcY
                    let c = envRadiance(simd_normalize(dir))
                    data += [Float16(c.x), Float16(c.y), Float16(c.z), Float16(1)]
                }
            }
            data.withUnsafeBytes { raw in
                envTex.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, slice: face,
                               withBytes: raw.baseAddress!, bytesPerRow: 256 * 8, bytesPerImage: 256 * 256 * 8)
            }
        }
        self.envTex = envTex

        guard let irradianceTex = Renderer.makeCubeTex(device: device, size: 32, format: .rgba16Float,
                                                       mips: 1, renderTarget: true),
              let prefilteredTex = Renderer.makeCubeTex(device: device, size: 64, format: .rgba16Float,
                                                        mips: 5, renderTarget: true) else { return nil }
        self.irradianceTex = irradianceTex
        self.prefilteredTex = prefilteredTex

        let lutDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: 256,
                                                               height: 256, mipmapped: false)
        lutDesc.usage = [.renderTarget, .shaderRead]
        lutDesc.storageMode = .private
        guard let lutTex = device.makeTexture(descriptor: lutDesc) else { return nil }
        self.lutTex = lutTex

        // ---- PSO ----
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let qv = lib.makeFunction(name: "quadVert"),
              let irF = lib.makeFunction(name: "irradianceFS"),
              let pfF = lib.makeFunction(name: "prefilterFS"),
              let lutF = lib.makeFunction(name: "brdfLutFS"),
              let bgV = lib.makeFunction(name: "bgVert"),
              let bgF = lib.makeFunction(name: "bgFrag"),
              let sv = lib.makeFunction(name: "sceneVert"),
              let sf = lib.makeFunction(name: "sceneFrag") else { return nil }

        func quadPSO(_ fs: MTLFunction) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = qv
            d.fragmentFunction = fs
            d.colorAttachments[0].pixelFormat = .rgba16Float
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        var psos: [String: MTLRenderPipelineState] = [:]
        guard let i1 = quadPSO(irF), let i2 = quadPSO(pfF) else { return nil }
        psos["irradiance"] = i1; psos["prefilter"] = i2
        let ld = MTLRenderPipelineDescriptor()
        ld.vertexFunction = qv
        ld.fragmentFunction = lutF
        ld.colorAttachments[0].pixelFormat = .rg32Float
        guard let i3 = try? device.makeRenderPipelineState(descriptor: ld) else { return nil }
        psos["lut"] = i3
        quadPSOs = psos

        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32

        let bgd = MTLRenderPipelineDescriptor()
        bgd.vertexFunction = bgV
        bgd.fragmentFunction = bgF
        bgd.vertexDescriptor = mtlVD
        bgd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let bgPSO = try? device.makeRenderPipelineState(descriptor: bgd) else { return nil }
        self.bgPSO = bgPSO

        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = sv
        sd.fragmentFunction = sf
        sd.vertexDescriptor = mtlVD
        sd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        sd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        guard let scenePSO = try? device.makeRenderPipelineState(descriptor: sd) else { return nil }
        self.scenePSO = scenePSO

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthWriteState = device.makeDepthStencilState(descriptor: dd)!
        let od = MTLDepthStencilDescriptor()
        od.depthCompareFunction = .always
        od.isDepthWriteEnabled = false
        depthOffState = device.makeDepthStencilState(descriptor: od)!

        // ---- 一次性 IBL 预计算(irradiance + 预滤波 + LUT) ----
        super.init()
        guard precomputeIBL() else { return nil }
    }

    static func makeCubeTex(device: MTLDevice, size: Int, format: MTLPixelFormat, mips: Int,
                            renderTarget: Bool) -> MTLTexture? {
        let d = MTLTextureDescriptor.textureCubeDescriptor(pixelFormat: format,
                                                           size: size, mipmapped: mips > 1)
        d.mipmapLevelCount = mips
        d.usage = renderTarget ? [.renderTarget, .shaderRead] : .shaderRead
        if !renderTarget { d.storageMode = .managed }
        return device.makeTexture(descriptor: d)
    }

    /// 离屏把三件套烤出来(初始化时执行一次; docs/03: 运行时也可以做成异步热更新)
    func precomputeIBL() -> Bool {
        guard let cb = queue.makeCommandBuffer() else { return false }
        func faceView(_ tex: MTLTexture, face: Int, mip: Int) -> MTLTexture? {
            let vd = MTLTextureViewDescriptor()
            vd.pixelFormat = tex.pixelFormat
            vd.textureType = .type2D
            vd.levelRange = mip..<mip+1
            vd.sliceRange = face..<face+1
            return tex.newTextureView(with: vd)
        }
        // irradiance × 6 面
        for face in 0..<6 {
            guard let view = faceView(irradianceTex, face: face, mip: 0) else { return false }
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = view
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
            enc.setRenderPipelineState(quadPSOs["irradiance"]!)
            enc.setFragmentTexture(envTex, index: 0)
            var fb = FACE_BASIS[face]
            enc.setFragmentBytes(&fb, length: MemoryLayout<FaceBasis>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        // GGX 预滤波 × 6 面 × 5 mip(roughness = mip/4)
        for mip in 0..<5 {
            for face in 0..<6 {
                guard let view = faceView(prefilteredTex, face: face, mip: mip) else { return false }
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = view
                rpd.colorAttachments[0].loadAction = .dontCare
                rpd.colorAttachments[0].storeAction = .store
                guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return false }
                enc.setRenderPipelineState(quadPSOs["prefilter"]!)
                enc.setFragmentTexture(envTex, index: 0)
                var fb = FACE_BASIS[face]
                enc.setFragmentBytes(&fb, length: MemoryLayout<FaceBasis>.stride, index: 1)
                var params = SIMD4<Float>(Float(mip) / 4, 0, 0, 0)
                enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
        }
        // BRDF LUT
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = lutTex
        rpd.colorAttachments[0].loadAction = .dontCare
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(quadPSOs["lut"]!)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilCompleted()
        return true
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let eye = SIMD3<Float>(sin(t * 0.1) * 6.5, 1.6, cos(t * 0.1) * 6.5)
        var u = Uniforms(
            viewProj: perspective(fovY: 42 * .pi / 180, aspect: aspect, n: 0.1, f: 200)
                * lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0)),
            camPos: SIMD4(eye, 1),
            sunDir: SIMD4(SUN_DIR, 3.2),
            misc: SIMD4(t, 0, 0, 0))

        // 背景: 天空穹顶(复用球网格放大 60 倍, 按方向采样环境图; 先画, 不写深度)
        // 剔除朝外正面——相机在穹顶内, 只留面向相机的内壁, 避免正反两面随机覆盖
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(bgPSO)
            enc.setDepthStencilState(depthOffState)
            enc.setCullMode(.front)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(envTex, index: 0)
            var bgObj = ObjUniforms(model: translateMat(eye), mr: .zero)
            enc.setVertexBytes(&bgObj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount,
                                      indexType: .uint16, indexBuffer: sphereIB, indexBufferOffset: 0)
            enc.endEncoding()
        }
        // 第二个 encoder 必须改成 load, 否则会把背景清掉(同一 rpd 的 loadAction 逐 encoder 生效)
        rpd.colorAttachments[0].loadAction = .load
        rpd.depthAttachment?.loadAction = .clear

        // 25 球: 列 = metallic 0→1, 行 = roughness 0.05→0.95
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthWriteState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(irradianceTex, index: 0)
            enc.setFragmentTexture(prefilteredTex, index: 1)
            enc.setFragmentTexture(lutTex, index: 2)
            for row in 0..<5 {
                for col in 0..<5 {
                    let x = (Float(col) - 2) * 1.15
                    let z = (Float(row) - 2) * 1.15
                    var obj = ObjUniforms(
                        model: translateMat(SIMD3(x, 0, z)),
                        mr: SIMD4(Float(col) / 4, 0.05 + 0.9 * Float(row) / 4, 0, 0))
                    enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
                    enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.setFragmentBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: sphereIndexCount,
                                              indexType: .uint16, indexBuffer: sphereIB, indexBufferOffset: 0)
                }
            }
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
mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else {
    FileHandle.standardError.write("初始化失败\n".data(using: .utf8)!)
    exit(1)
}
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "IBL Split-Sum — CG Roadmap 12"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
