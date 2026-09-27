// 11-csm: 级联阴影贴图(4 级 λ 切分 + texel snapping + 逐级 PCF)
// 对应 docs/11 §1.2。空格键: 切换级联调试着色。构建: ./build.sh    运行: ./csm

import AppKit
import MetalKit
import QuartzCore
import simd

let CASCADES = 4
let SMAP = 1024
let CAM_NEAR: Float = 0.1, CAM_FAR: Float = 60, LAMBDA: Float = 0.8

struct Uniforms {
    var viewProj: simd_float4x4
    var lightVP0, lightVP1, lightVP2, lightVP3: simd_float4x4   // 平铺: Swift Array 是引用, setBytes 拷不到内容(MSL 侧 float4x4[4] 布局一致)
    var splits: SIMD4<Float>         // 级 0..2 远平面, w = 调试开关
    var lightDir: SIMD4<Float>
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4 }
struct CascadeMat { var lightVP: simd_float4x4 }
struct QuadVertex {                  // 与 mtlVD 布局一致: pos3f|normal3f|uv2f
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
/// 正交投影, z 映射 [0,1]。zn/zf 直接给光空间 view.z 边界(**负值**, 靠光的一侧数值更大)——
/// 与 07 的"正距离约定"不可混用(本例踩坑: 混用导致重投影 z 全图越界 → 满屏皆阴影)
func ortho(l: Float, r: Float, b: Float, t: Float, zn: Float, zf: Float) -> simd_float4x4 {
    simd_float4x4(
        SIMD4(2 / (r - l), 0, 0, 0),
        SIMD4(0, 2 / (t - b), 0, 0),
        SIMD4(0, 0, 1 / (zf - zn), 0),
        SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), -zn / (zf - zn), 1))
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
func scaleMat(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4(s, s, s, 1))
}
/// cᵢ = λ·log_split + (1−λ)·uniform_split(docs/11 §1.2, λ=0.8)
func splitDistance(_ i: Int) -> Float {
    let id = Float(i), n = Float(CASCADES)
    let lin = CAM_NEAR + (id / n) * (CAM_FAR - CAM_NEAR)
    let log = CAM_NEAR * pow(CAM_FAR / CAM_NEAR, id / n)
    return LAMBDA * log + (1 - LAMBDA) * lin
}

let LIGHT_DIR = simd_normalize(SIMD3<Float>(0.4, -1.0, -0.22))

/// 过程化经纬球(法线=归一化位置), 布局 pos3f|normal3f|uv2f, stride 32。
/// 踩坑实录: 本机 macOS 26 工具链上 MTKMesh/ModelIO 转换出的顶点位置全为 0
/// (无论事后赋 vertexDescriptor 还是加载时传入), 自写生成器绕开——见 README。
func makeSphereBuffers(device: MTLDevice, radius: Float, lat: Int, lon: Int)
    -> (verts: MTLBuffer, indices: MTLBuffer, indexCount: Int) {
    var verts: [QuadVertex] = []
    for i in 0...lat {
        let th = Float.pi * Float(i) / Float(lat), st = sin(th), ct = cos(th)
        for j in 0...lon {
            let ph = 2 * Float.pi * Float(j) / Float(lon)
            let n = SIMD3<Float>(st * cos(ph), ct, st * sin(ph))
            verts.append(QuadVertex(pos: n * radius, normal: n,
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
    let quadBuf: MTLBuffer
    let groundVertexCount: Int
    let albedo: MTLTexture
    let shadowMap: MTLTexture           // depth32Float × 4 slices
    let cascadeViews: [MTLTexture]      // 每级一个 2D 视图供深度附件
    let shadowPSO, scenePSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var showTint = false

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 球体(过程化生成, 32 段×24 环) ----
        let (vb, ib, count) = makeSphereBuffers(device: device, radius: 1, lat: 24, lon: 32)
        sphereVB = vb; sphereIB = ib; sphereIndexCount = count

        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32

        // ---- 走廊地面: 8×8 瓦片(uv 全局重复 60 次)。
        // 踩坑实录: 单个 ±120 巨型四边形在部分顶点落远平面外/相机后时整三角形消失,
        // 细分瓦片是生产引擎对大地面/大墙面的标准做法
        let S: Float = 120, R: Float = 60, TILES = 8
        let zf: Float = 5   // z 收缩到相机(z=7)前方
        var quads: [QuadVertex] = []
        for iy in 0..<TILES {
            for ix in 0..<TILES {
                let step = 2 * S / Float(TILES)
                let x0 = -S + Float(ix) * step, x1 = x0 + step
                let z1 = zf - Float(iy) * step, z0 = z1 - step
                let u0 = (x0 + S) / (2 * S) * R, u1 = (x1 + S) / (2 * S) * R
                let v1 = (zf - z1) / (2 * S) * R, v0 = (zf - z0) / (2 * S) * R
                quads.append(QuadVertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: SIMD2(u0, v0)))
                quads.append(QuadVertex(pos: SIMD3(x1, 0, z0), normal: SIMD3(0,1,0), uv: SIMD2(u1, v0)))
                quads.append(QuadVertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: SIMD2(u1, v1)))
                quads.append(QuadVertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: SIMD2(u0, v0)))
                quads.append(QuadVertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: SIMD2(u1, v1)))
                quads.append(QuadVertex(pos: SIMD3(x0, 0, z1), normal: SIMD3(0,1,0), uv: SIMD2(u0, v1)))
            }
        }
        groundVertexCount = quads.count
        var qdata = [Float]()
        qdata.reserveCapacity(quads.count * 8)
        for v in quads { qdata += [v.pos.x, v.pos.y, v.pos.z, v.normal.x, v.normal.y, v.normal.z, v.uv.x, v.uv.y] }
        quadBuf = device.makeBuffer(bytes: qdata, length: qdata.count * 4)!   // 32B 手动交错(见上)

        do {
            albedo = try MTKTextureLoader(device: device).newTexture(
                URL: binDir.appendingPathComponent("assets/checker.png"),
                options: [.SRGB: true, .generateMipmaps: true])
        } catch { return nil }

        // ---- 级联阴影: depth32Float 2D array × 4 ----
        let sd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: SMAP, height: SMAP, mipmapped: false)
        sd.textureType = .type2DArray
        sd.arrayLength = CASCADES
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        guard let shadowMap = device.makeTexture(descriptor: sd) else { return nil }
        self.shadowMap = shadowMap
        // macOS 26 SDK: newTextureView 改为 descriptor 形式(levelRange/sliceRange 为 Range<Int>)
        var views: [MTLTexture] = []
        for i in 0..<CASCADES {
            let vd = MTLTextureViewDescriptor()
            vd.pixelFormat = .depth32Float
            vd.textureType = .type2D
            vd.levelRange = 0..<1
            vd.sliceRange = i..<i+1
            guard let v = shadowMap.newTextureView(with: vd) else { return nil }
            views.append(v)
        }
        cascadeViews = views

        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sVS = lib.makeFunction(name: "shadowVert"),
              let mVS = lib.makeFunction(name: "sceneVert"),
              let sFS = lib.makeFunction(name: "sceneFrag") else { return nil }

        // depth-only PSO(07 踩坑: stage_in 必须设 vertexDescriptor)
        let sp = MTLRenderPipelineDescriptor()
        sp.vertexFunction = sVS
        sp.fragmentFunction = nil
        sp.vertexDescriptor = mtlVD
        sp.depthAttachmentPixelFormat = .depth32Float
        guard let shadowPSO = try? device.makeRenderPipelineState(descriptor: sp) else { return nil }

        let cp = MTLRenderPipelineDescriptor()
        cp.vertexFunction = mVS
        cp.fragmentFunction = sFS
        cp.vertexDescriptor = mtlVD
        cp.colorAttachments[0].pixelFormat = view.colorPixelFormat
        cp.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        guard let scenePSO = try? device.makeRenderPipelineState(descriptor: cp) else { return nil }
        self.shadowPSO = shadowPSO; self.scenePSO = scenePSO

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!
    }

    /// 相机视锥切片的 8 个世界空间角点
    static func frustumCorners(eye: SIMD3<Float>, fwd: SIMD3<Float>, right: SIMD3<Float>,
                               up: SIMD3<Float>, tanV: Float, aspect: Float,
                               zn: Float, zf: Float) -> [SIMD3<Float>] {
        var corners: [SIMD3<Float>] = []
        for z in [zn, zf] {
            let hh = tanV * z, hw = hh * aspect
            corners.append(eye + fwd*z - right*hw - up*hh)
            corners.append(eye + fwd*z + right*hw - up*hh)
            corners.append(eye + fwd*z - right*hw + up*hh)
            corners.append(eye + fwd*z + right*hw + up*hh)
        }
        return corners
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let fovY: Float = 55 * .pi / 180
        let eye = SIMD3<Float>(0, 1.4, 7)
        let target = SIMD3<Float>(0, 0.8, -30)

        let camVP = perspective(fovY: fovY, aspect: aspect, n: CAM_NEAR, f: CAM_FAR)
            * lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
        let fwd = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(fwd, SIMD3(0, 1, 0)))
        let up = simd_cross(right, fwd)
        let lightView = lookAt(eye: LIGHT_DIR * -40, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))

        // ---- 每级: 视锥切片 AABB 拟合 + texel snapping ----
        var lightVPs = [simd_float4x4](repeating: simd_float4x4(diagonal: SIMD4(1,1,1,1)), count: CASCADES)
        var splits: [Float] = []
        for i in 0..<CASCADES {
            let zn = i == 0 ? CAM_NEAR : splits[i - 1]
            let zf = splitDistance(i + 1)
            splits.append(zf)
            let corners = Self.frustumCorners(eye: eye, fwd: fwd, right: right, up: up,
                                              tanV: tan(fovY * 0.5), aspect: aspect, zn: zn, zf: zf)
            // 角点变换到光空间取 AABB——正交箱只包住这一片视锥
            var lmn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var lmx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for c in corners {
                let v4 = lightView * SIMD4(c, 1)
                let v = SIMD3(v4.x, v4.y, v4.z)
                lmn = simd_min(lmn, v); lmx = simd_max(lmx, v)
            }
            // texel snapping: 光空间平移量对齐纹素网格(消抖动; docs/11 §1.2)
            let texelX = (lmx.x - lmn.x) / Float(SMAP)
            lmn.x = (lmn.x / texelX).rounded(.down) * texelX
            lmx.x = (lmx.x / texelX).rounded(.up) * texelX
            let texelY = (lmx.y - lmn.y) / Float(SMAP)
            lmn.y = (lmn.y / texelY).rounded(.down) * texelY
            lmx.y = (lmx.y / texelY).rounded(.up) * texelY
            lightVPs[i] = ortho(l: lmn.x, r: lmx.x, b: lmn.y, t: lmx.y,
                                zn: lmn.z - 4, zf: lmx.z + 20) * lightView
        }

        var u = Uniforms(
            viewProj: camVP,
            lightVP0: lightVPs[0], lightVP1: lightVPs[1],
            lightVP2: lightVPs[2], lightVP3: lightVPs[3],
            splits: SIMD4(splits[0], splits[1], splits[2], showTint ? 1 : 0),
            lightDir: SIMD4(LIGHT_DIR, 0),
            camPos: SIMD4(eye, 1),
            misc: SIMD4(t, 0, 0, 0))

        // 场景物体: 走廊两列球(近→远, 检验各级覆盖)
        var objs: [(ObjUniforms, Bool)] = []   // (model, isSphere)
        for i in 0..<14 {
            let z = Float(2 - i * 4)
            let x: Float = (i % 2 == 0 ? -1.8 : 1.8)
            objs.append((ObjUniforms(model: translateMat(SIMD3(x, 0.85, z)) * scaleMat(0.85)), true))
        }
        objs.append((ObjUniforms(model: simd_float4x4(diagonal: SIMD4(1,1,1,1))), false))

        // ---- Pass 1: ×4 级联深度 ----
        for i in 0..<CASCADES {
            let d = MTLRenderPassDescriptor()
            d.depthAttachment.texture = cascadeViews[i]
            d.depthAttachment.loadAction = .clear
            d.depthAttachment.storeAction = .store
            d.depthAttachment.clearDepth = 1.0
            guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { continue }
            enc.setRenderPipelineState(shadowPSO)
            enc.setDepthStencilState(depthState)
            var cm = CascadeMat(lightVP: lightVPs[i])
            enc.setVertexBytes(&cm, length: MemoryLayout<CascadeMat>.stride, index: 1)
            for (obj, isSphere) in objs where isSphere {   // 地面不投影(简化)
                var o = obj
                enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
                enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle,
                                          indexCount: sphereIndexCount,
                                          indexType: .uint16,
                                          indexBuffer: sphereIB,
                                          indexBufferOffset: 0)
            }
            enc.endEncoding()
        }

        // ---- Pass 2: 场景 + 逐级 PCF ----
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(albedo, index: 0)
            enc.setFragmentTexture(shadowMap, index: 1)
            for (obj, isSphere) in objs {
                var o = obj
                if isSphere {
                    enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle,
                                              indexCount: sphereIndexCount,
                                              indexType: .uint16,
                                              indexBuffer: sphereIB,
                                              indexBufferOffset: 0)
                } else {
                    enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: groundVertexCount)
                }
            }
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

/// 支持空格键切换调试视图(本仓库第一个交互示例)
final class KeyMTKView: MTKView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { (delegate as? Renderer)?.showTint.toggle() }   // 空格
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
mtkView.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.clearDepth = 1.0
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "CSM Cascaded Shadows — CG Roadmap 11 (空格: 级联调试)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
