// 14-frame-graph: 迷你帧图 —— 声明式 pass 组织 + 拓扑排序 + 死 pass 剔除 + 渲染目标池化
// 对应 docs/18 蓝图 M2(frame graph + 资源管理)。载荷: HDR 场景 → 亮部 → 分离高斯 → 合成。
// 构建: ./build.sh    运行: ./framegraph (首帧打印图编译结果与 RT 池分配)

import AppKit
import MetalKit
import QuartzCore
import simd

// ============ 帧图核心(docs/18 M2 的最小可信实现) ============

/// 渲染目标描述: 名字唯一标识逻辑资源; scale 为相对屏幕的比例(半分辨率=0.5)
struct RTDesc {
    let name: String
    let format: MTLPixelFormat
    let scale: Float
    let clear: MTLClearColor?
    var clearDepth: Float? = nil
    var store: Bool = false           // 深度类默认瞬时(dontCare); 阴影图 = true(要被后续 pass 读)
}

/// 一个 pass: 声明读写哪些 RT, 以及怎么画。execute 拿到编译后分配好的纹理。
final class FGPass {
    let name: String
    let writes: [String]
    let reads: [String]
    /// backbuffer 是特殊资源(每帧轮换), 不进池: 用钩子直接给 drawable 的 pass 描述符
    var customTarget: (() -> MTLRenderPassDescriptor?)?
    let execute: (_ enc: MTLRenderCommandEncoder, _ rts: [String: MTLTexture]) -> Void
    init(name: String, writes: [String], reads: [String] = [],
         execute: @escaping (_ enc: MTLRenderCommandEncoder, _ rts: [String: MTLTexture]) -> Void) {
        self.name = name; self.writes = writes; self.reads = reads; self.execute = execute
    }
}

/// 帧图: 收集 pass → 编译(剔除 + 拓扑排序) → 执行; 附带跨帧 RT 池(带宽/内存复用的地基)
final class FrameGraph {
    let device: MTLDevice
    var passes: [FGPass] = []
    private var rtDescs: [String: RTDesc] = [:]
    private var pool: [String: MTLTexture] = [:]     // 池键: desc 的内容哈希
    private var poolHits = 0, poolMisses = 0

    init(device: MTLDevice) { self.device = device }

    func declare(_ rt: RTDesc) { rtDescs[rt.name] = rt }

    /// 编译: 从输出 pass 反向标记可达(死 pass 剔除) + Kahn 拓扑排序(读先于写)
    func compile(outputs: [String]) -> [FGPass] {
        var live = Set(outputs)
        var changed = true
        while changed {                          // 不动点: 被活 pass 读到的也是活的
            changed = false
            for p in passes where live.contains(p.name) {
                for r in p.reads where !live.contains(r) { live.insert(r); changed = true }
            }
        }
        // "RT 名"与"生产它的 pass 名"同名约定(本图的简化; 真引擎是资源句柄)
        var inDeg: [String: Int] = [:]
        for p in passes where live.contains(p.name) { inDeg[p.name] = 0 }
        var consumers: [String: [String]] = [:]
        for p in passes where live.contains(p.name) {
            for r in p.reads where inDeg[r] != nil {
                inDeg[p.name]! += 1
                consumers[r, default: []].append(p.name)
            }
        }
        var queue = live.filter { (inDeg[$0] ?? 1) == 0 }.sorted()
        var order: [FGPass] = []
        var qi = 0
        while qi < queue.count {
            let n = queue[qi]; qi += 1
            if let p = passes.first(where: { $0.name == n }) { order.append(p) }
            for c in consumers[n] ?? [] {
                inDeg[c]! -= 1
                if inDeg[c] == 0 { queue.append(c) }
            }
        }
        assert(order.count == live.count, "帧图存在环或悬空引用")
        return order
    }

    /// 池键: **持久资源(store=true)按名字寻址**(跨帧语义资源不可合并);
    /// 瞬时资源按 格式+尺寸 合并。
    /// 踩坑实录: 最初纯按规格寻址 → 场景瞬时深度 z 与持久阴影图共用一张纹理,
    /// 场景 pass 清深度时擦掉阴影图 + 同 pass 采样深度附件(未定义行为) → 满屏皆阴影。
    /// 这就是真帧图要做"生命期重叠分析"的原因(见 README 练习)。
    private func poolKey(desc: RTDesc, w: Int, h: Int) -> String {
        desc.store ? "persist:\(desc.name)" : "\(desc.format.rawValue)|\(w)x\(h)"
    }

    func execute(order: [FGPass], queue cmdQueue: MTLCommandQueue,
                 width: Int, height: Int) -> [String: MTLTexture] {
        guard let cb = cmdQueue.makeCommandBuffer() else { return [:] }
        var rts: [String: MTLTexture] = [:]
        for p in order {
            for w in p.writes where p.customTarget == nil {
                let d = rtDescs[w]!
                let tw = max(8, Int(Float(width) * d.scale)), th = max(8, Int(Float(height) * d.scale))
                let key = poolKey(desc: d, w: tw, h: th)
                var tex = pool[key]
                if tex == nil {
                    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: d.format,
                                                                     width: tw, height: th, mipmapped: false)
                    td.usage = d.format == .depth32Float ? [.renderTarget] : [.renderTarget, .shaderRead]
                    td.storageMode = .private
                    tex = device.makeTexture(descriptor: td)
                    pool[key] = tex; poolMisses += 1
                } else { poolHits += 1 }
                rts[w] = tex
            }
        }
        for p in order {
            let rp: MTLRenderPassDescriptor
            if let custom = p.customTarget, let c = custom() {
                rp = c                                   // backbuffer 路径
            } else {
                rp = MTLRenderPassDescriptor()
                for w in p.writes {                              // 深度格式→深度附件(瞬时), 其余→颜色
                    let d = rtDescs[w]!
                    if d.format == .depth32Float {
                        rp.depthAttachment.texture = rts[w]
                        rp.depthAttachment.loadAction = .clear
                        rp.depthAttachment.clearDepth = Double(d.clearDepth ?? 1.0)
                        rp.depthAttachment.storeAction = d.store ? .store : .dontCare   // 阴影图持久/场景深度瞬时
                    } else {
                        rp.colorAttachments[0].texture = rts[w]
                        rp.colorAttachments[0].loadAction = .dontCare
                        rp.colorAttachments[0].storeAction = .store
                        if let c = d.clear {
                            rp.colorAttachments[0].loadAction = .clear
                            rp.colorAttachments[0].clearColor = c
                        }
                    }
                }
            }
            if let enc = cb.makeRenderCommandEncoder(descriptor: rp) {
                p.execute(enc, rts)
                enc.endEncoding()
            }
        }
        cb.commit()
        cb.waitUntilCompleted()
        return rts
    }

    var poolStats: String { "RT 池: 命中 \(poolHits) / 新建 \(poolMisses)" }
}

// ============ 场景素材(复用既有模式) ============
struct Uniforms {
    var viewProj: simd_float4x4
    var lightVP: simd_float4x4
    var camPos: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var misc: SIMD4<Float>
    var texel: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4; var color: SIMD4<Float> }
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
func rotationY(_ a: Float) -> simd_float4x4 {
    let (c, s) = (cos(a), sin(a))
    return simd_float4x4(SIMD4(c,0,-s,0), SIMD4(0,1,0,0), SIMD4(s,0,c,0), SIMD4(0,0,0,1))
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
    let graph: FrameGraph
    let sphereVB: MTLBuffer
    let sphereIB: MTLBuffer
    let sphereIndexCount: Int
    let groundVB: MTLBuffer
    let groundVertexCount: Int
    let scenePSO, brightPSO, blurPSO, compositePSO, shadowPSO: MTLRenderPipelineState
    let depthState, shadowDepthState: MTLDepthStencilState
    var frame = 0
    var offRpd: MTLRenderPassDescriptor?      // headless 验证用
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        graph = FrameGraph(device: device)

        let (vb, ib, count) = makeSphereBuffers(device: device, radius: 1, lat: 24, lon: 32)
        sphereVB = vb; sphereIB = ib; sphereIndexCount = count

        var quads: [SphereVertex] = []
        let TILES = 8, S: Float = 40
        for iy in 0..<TILES {
            for ix in 0..<TILES {
                let step = 2 * S / Float(TILES)
                let x0 = -S + Float(ix) * step, x1 = x0 + step
                let z0 = -S + Float(iy) * step
                let z1 = min(z0 + step, 5)     // 相机在 z=7: 地面收缩到相机前(11 号踩坑: 相机后顶点→三角形消失)
                if z0 >= 5 { continue }
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
        groundVertexCount = quads.count

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sv = lib.makeFunction(name: "sceneVert"),
              let sf = lib.makeFunction(name: "sceneFrag"),
              let qv = lib.makeFunction(name: "quadVert"),
              let bf = lib.makeFunction(name: "brightFS"),
              let uf = lib.makeFunction(name: "blurFS"),
              let cf = lib.makeFunction(name: "compositeFS") else { return nil }

        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32

        func ps(_ vf: MTLFunction, _ ff: MTLFunction, _ fmt: MTLPixelFormat, vd: MTLVertexDescriptor? = nil) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.vertexDescriptor = vd
            d.colorAttachments[0].pixelFormat = fmt
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let scenePD = MTLRenderPipelineDescriptor()
        scenePD.vertexFunction = sv
        scenePD.fragmentFunction = sf
        scenePD.vertexDescriptor = mtlVD
        scenePD.colorAttachments[0].pixelFormat = .rgba16Float
        scenePD.depthAttachmentPixelFormat = .depth32Float
        let shPD = MTLRenderPipelineDescriptor()
        shPD.vertexFunction = lib.makeFunction(name: "shadowVert")
        shPD.fragmentFunction = nil                       // depth-only(07 模式)
        shPD.vertexDescriptor = mtlVD
        shPD.depthAttachmentPixelFormat = .depth32Float
        guard let s0 = try? device.makeRenderPipelineState(descriptor: shPD),
              let s1 = try? device.makeRenderPipelineState(descriptor: scenePD),
              let s2 = ps(qv, bf, .rgba16Float),
              let s3 = ps(qv, uf, .rgba16Float),
              let s4 = ps(qv, cf, view.colorPixelFormat) else { return nil }
        scenePSO = s1; brightPSO = s2; blurPSO = s3; compositePSO = s4; shadowPSO = s0

        let dz = MTLDepthStencilDescriptor()
        dz.depthCompareFunction = .less
        dz.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dz)!
        shadowDepthState = device.makeDepthStencilState(descriptor: dz)!   // 同款(图内不区分写掩码)
    }

    func draw(in view: MTKView) {
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let W = 900, H = 600
        let aspect = Float(W) / Float(H)

        let lightView = lookAt(eye: simd_normalize(SIMD3<Float>(-0.35, -0.85, -0.4)) * -18,
                               target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        func orthoZNZF(_ l: Float, _ r: Float, _ b: Float, _ tp: Float, _ zn: Float, _ zf: Float) -> simd_float4x4 {
            simd_float4x4(SIMD4(2/(r-l), 0, 0, 0), SIMD4(0, 2/(tp-b), 0, 0),
                          SIMD4(0, 0, 1/(zf-zn), 0),
                          SIMD4(-(r+l)/(r-l), -(tp+b)/(tp-b), -zn/(zf-zn), 1))
        }
        let u = Uniforms(
            viewProj: perspective(fovY: 46 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: SIMD3(0, 3, 7), target: SIMD3(0, 0.4, 0), up: SIMD3(0, 1, 0)),
            lightVP: orthoZNZF(-7, 7, -7, 7, -6, -34) * lightView,   // view.z 负值边界(11 号教训)
            camPos: SIMD4(0, 3, 7, 1),
            lightDir: SIMD4(simd_normalize(SIMD3<Float>(0.35, 0.85, 0.4)), 0),
            misc: SIMD4(t, 0, 0, 0),
            texel: SIMD4(1 / Float(W), 1 / Float(H), 0, 0))

        // ---- 每帧声明图(pass 集合可随状态增减 —— 这正是 frame graph 的意义) ----
        graph.passes.removeAll()
        graph.declare(RTDesc(name: "scene", format: .rgba16Float, scale: 1.0,
                             clear: MTLClearColor(red: 0.01, green: 0.015, blue: 0.025, alpha: 1)))
        graph.declare(RTDesc(name: "bright", format: .rgba16Float, scale: 0.5, clear: nil))
        graph.declare(RTDesc(name: "blurH", format: .rgba16Float, scale: 0.5, clear: nil))
        graph.declare(RTDesc(name: "blurV", format: .rgba16Float, scale: 0.5, clear: nil))
        graph.declare(RTDesc(name: "z", format: .depth32Float, scale: 1.0, clear: nil, clearDepth: 1.0))
        graph.declare(RTDesc(name: "shadowMap", format: .depth32Float, scale: 1.0, clear: nil,
                             clearDepth: 1.0, store: true))          // 持久: 场景 pass 要读
        let objs: [(ObjUniforms, Bool)] = [
            (ObjUniforms(model: rotationY(t * 0.4) * scaleMat(1.0), color: SIMD4(0.92, 0.30, 0.20, 0)), true),
            (ObjUniforms(model: translateMat(SIMD3(2.6, 0.8, -0.5)) * scaleMat(0.8), color: SIMD4(0.95, 0.75, 0.25, 0)), true),
            (ObjUniforms(model: translateMat(SIMD3(-2.4, 0.6, 1.0)) * scaleMat(0.6), color: SIMD4(0.3, 0.6, 0.95, 0)), true),
            (ObjUniforms(model: .init(diagonal: SIMD4(1,1,1,1)), color: SIMD4(0.7, 0.7, 0.74, 1)), false),
        ]
        buildScenePass(u: u, sharedObjs: objs)
        let objsShadow = objs
        var uShadow = u
        graph.passes.append(FGPass(name: "shadowMap", writes: ["shadowMap"]) { enc, _ in
            enc.setRenderPipelineState(self.shadowPSO)
            enc.setDepthStencilState(self.shadowDepthState)
            enc.setVertexBytes(&uShadow, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (obj, isSphere) in objsShadow where isSphere {
                var o = obj
                enc.setVertexBuffer(self.sphereVB, offset: 0, index: 0)
                enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: self.sphereIndexCount,
                                          indexType: .uint16, indexBuffer: self.sphereIB, indexBufferOffset: 0)
            }
        })
        buildScenePass(u: u, sharedObjs: objs)
        buildPostChain()

        let order = graph.compile(outputs: ["composite"])
        if frame == 0 {
            print("帧图编译: " + order.map { $0.name }.joined(separator: " → "))
        }
        // backbuffer 钩子: GUI 用 drawable, headless 用离屏纹理
        if let composite = order.last, composite.name == "composite" {
            composite.customTarget = { [weak view] in view?.currentRenderPassDescriptor }
        }
        guard let drawable = view.currentDrawable else { return }
        _ = graph.execute(order: order, queue: queue, width: W, height: H)
        if frame == 1 { print(graph.poolStats) }
        frame += 1
        // 呈现: 图执行时已把 composite 画进 drawable, 补一个 present
        // (execute 内部 waitUntilCompleted 了, present 依旧有效)
        // 为此重开一个 command buffer 只做 present
        if let cb = queue.makeCommandBuffer() {
            cb.present(drawable)
            cb.commit()
        }
    }

    func buildScenePass(u: Uniforms, sharedObjs: [(ObjUniforms, Bool)]) {
        graph.passes.removeAll { $0.name == "scene" }
        let objs = sharedObjs
        var uu = u
        graph.passes.insert(FGPass(name: "scene", writes: ["scene", "z"], reads: ["shadowMap"]) { enc, rts in
            enc.setRenderPipelineState(self.scenePSO)
            enc.setDepthStencilState(self.depthState)
            enc.setVertexBytes(&uu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uu, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(rts["shadowMap"], index: 0)
            for (obj, isSphere) in objs {
                var o = obj
                if isSphere {
                    enc.setVertexBuffer(self.sphereVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: self.sphereIndexCount,
                                              indexType: .uint16, indexBuffer: self.sphereIB, indexBufferOffset: 0)
                } else {
                    enc.setVertexBuffer(self.groundVB, offset: 0, index: 0)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjUniforms>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: self.groundVertexCount)
                }
            }
        }, at: 0)
    }

    func buildPostChain() {
        let texel = SIMD4<Float>(1 / 450.0, 1 / 300.0, 0, 0)   // 半分辨率 texel
        var brightParams = SIMD4<Float>(1.3, 0, 0, 0)
        var blurH = SIMD4<Float>(1 / 450.0, 0, 0, 0)
        var blurV = SIMD4<Float>(0, 1 / 300.0, 0, 0)
        var compParams = SIMD4<Float>(0.8, 0, 0, 0)
        graph.passes.append(FGPass(name: "bright", writes: ["bright"], reads: ["scene"]) { enc, rts in
            enc.setRenderPipelineState(self.brightPSO)
            enc.setFragmentTexture(rts["scene"], index: 0)
            enc.setFragmentBytes(&brightParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        })
        graph.passes.append(FGPass(name: "blurH", writes: ["blurH"], reads: ["bright"]) { enc, rts in
            enc.setRenderPipelineState(self.blurPSO)
            enc.setFragmentTexture(rts["bright"], index: 0)
            enc.setFragmentBytes(&blurH, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        })
        graph.passes.append(FGPass(name: "blurV", writes: ["blurV"], reads: ["blurH"]) { enc, rts in
            enc.setRenderPipelineState(self.blurPSO)
            enc.setFragmentTexture(rts["blurH"], index: 0)
            enc.setFragmentBytes(&blurV, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        })
        graph.declare(RTDesc(name: "final", format: .bgra8Unorm, scale: 1.0, clear: nil))
        graph.passes.append(FGPass(name: "composite", writes: ["final"], reads: ["scene", "blurV"]) { enc, rts in
            enc.setRenderPipelineState(self.compositePSO)
            enc.setFragmentTexture(rts["scene"], index: 0)
            enc.setFragmentTexture(rts["blurV"], index: 1)
            enc.setFragmentBytes(&compParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        })
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
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "Frame Graph + Bloom — CG Roadmap 14"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
