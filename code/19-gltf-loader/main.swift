// 19-gltf-loader: glTF 2.0 最小资产管线(程序化网格 → 写 .gltf+.bin → 读回 → 渲染)
// 对应 docs/10 §资产管线 与 docs/27 案例 A 第 3~4 周。构建: ./build.sh    运行: ./gltf

import AppKit
import Foundation
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var misc: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4; var baseColor: SIMD4<Float> }

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

// ============ glTF 生成: 环面结管道网格(18 号的 Swift 移植) ============
struct GlbMesh {
    var positions: [Float] = []
    var normals: [Float] = []
    var indices: [UInt16] = []
    var baseColor: [Float] = [0.85, 0.45, 0.18, 1]

    init(segT: Int = 220, segR: Int = 36, tube: Float = 0.16) {
        func curve(_ t: Float) -> SIMD3<Float> {
            SIMD3(sin(t) + 2 * sin(2 * t), cos(t) - 2 * cos(2 * t), -sin(3 * t))
        }
        var ring = [SIMD3<Float>]()
        ring.reserveCapacity(segT * segR)
        for i in 0..<segT {
            let t = 2 * Float.pi * Float(i) / Float(segT)
            let p = curve(t)
            let tan = simd_normalize(curve(t + 0.01) - curve(t - 0.01))
            let n1 = simd_normalize(simd_cross(tan, SIMD3(0.01, 1, 0)))
            let n2 = simd_cross(tan, n1)
            for j in 0..<segR {
                let a = 2 * Float.pi * Float(j) / Float(segR)
                ring.append(p + n1 * (cos(a) * tube) + n2 * (sin(a) * tube))
            }
        }
        // 收缩到单位盒内 + 法线=径向
        var mn = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var mx = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for p in ring { mn = simd_min(mn, p); mx = simd_max(mx, p) }
        let scale = 1.6 / simd_reduce_max(mx - mn)
        let center = (mn + mx) * 0.5
        for p in ring {
            let q = (p - center) * scale
            positions += [q.x, q.y, q.z]
            let n = simd_normalize(q)
            normals += [n.x, n.y, n.z]
        }
        for i in 0..<segT {
            for j in 0..<segR {
                let a = i * segR + j, b = ((i + 1) % segT) * segR + j,
                    c = ((i + 1) % segT) * segR + (j + 1) % segR, d = i * segR + (j + 1) % segR
                indices += [UInt16(a), UInt16(b), UInt16(c), UInt16(a), UInt16(c), UInt16(d)]
            }
        }
    }
}

// ============ glTF 2.0 写入(分体 .gltf + .bin, docs/10 §glTF 结构) ============
enum GlbWriter {
    static func write(_ mesh: GlbMesh, to stem: String) throws {
        var bin = Data()
        func append(_ floats: [Float]) {
            floats.withUnsafeBytes { bin.append(contentsOf: $0) }
        }
        // 段布局: indices(u16) | positions(f32×3) | normals(f32×3), 4 字节对齐
        var offset = 0
        mesh.indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        let idxBytes = mesh.indices.count * 2
        offset = idxBytes + ((4 - idxBytes % 4) % 4)
        bin.append(Data(repeating: 0, count: offset - idxBytes))
        let posStart = offset
        append(mesh.positions)
        offset += mesh.positions.count * 4
        let nrmStart = offset
        append(mesh.normals)
        offset += mesh.normals.count * 4
        try bin.write(to: URL(fileURLWithPath: stem + ".bin"))

        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "cg-roadmap-19"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "name": "TorusKnot"]],
            "meshes": [["primitives": [[
                "attributes": ["POSITION": 1, "NORMAL": 2],
                "indices": 0,
                "material": 0,
                "mode": 4]]]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": mesh.baseColor]]],
            "buffers": [["byteLength": offset]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": idxBytes, "target": 34963],
                ["buffer": 0, "byteOffset": posStart, "byteLength": mesh.positions.count * 4, "target": 34962],
                ["buffer": 0, "byteOffset": nrmStart, "byteLength": mesh.normals.count * 4, "target": 34962],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5123, "count": mesh.indices.count, "type": "SCALAR"],
                ["bufferView": 1, "componentType": 5126, "count": mesh.positions.count / 3,
                 "type": "VEC3", "min": [-1, -1, -1], "max": [1, 1, 1]],
                ["bufferView": 2, "componentType": 5126, "count": mesh.normals.count / 3, "type": "VEC3"],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: gltf, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: stem + ".gltf"))
    }
}

// ============ glTF 读回(JSON 场景图 + accessor 反解) ============
enum GlbLoader {
    struct Loaded {
        var positions: [Float]
        var normals: [Float]
        var indices: [UInt16]
        var baseColor: SIMD4<Float>
    }
    static func load(stem: String) throws -> Loaded {
        let data = try Data(contentsOf: URL(fileURLWithPath: stem + ".gltf"))
        let doc = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let buffers = doc["buffers"] as! [[String: Any]]
        let views = doc["bufferViews"] as! [[String: Any]]
        let accessors = doc["accessors"] as! [[String: Any]]
        let meshes = doc["meshes"] as! [[String: Any]]
        let materials = doc["materials"] as! [[String: Any]]

        // 单 buffer(分体文件)
        let bin = try Data(contentsOf: URL(fileURLWithPath: stem + ".bin"))
        func readAccessor(_ ai: Int) -> (array: [Float], count: Int, componentType: Int, type: String) {
            let a = accessors[ai]
            let v = views[a["bufferView"] as! Int]
            let off = v["byteOffset"] as! Int
            let count = a["count"] as! Int
            let ct = a["componentType"] as! Int
            let type = a["type"] as! String
            let comps = type == "SCALAR" ? 1 : 3
            var out = [Float]()
            out.reserveCapacity(count * comps)
            let byteLen = v["byteLength"] as! Int
            bin.subdata(in: off..<(off + byteLen)).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                if ct == 5123 {          // UNSIGNED_SHORT
                    for i in 0..<(count * comps) {
                        out.append(Float(raw.load(fromByteOffset: i * 2, as: UInt16.self)))
                    }
                } else {                 // FLOAT
                    for i in 0..<(count * comps) {
                        out.append(raw.load(fromByteOffset: i * 4, as: Float.self))
                    }
                }
            }
            return (out, count, ct, type)
        }
        let prim = (meshes[0]["primitives"] as! [[String: Any]])[0]
        let attrs = prim["attributes"] as! [String: Int]
        let idx = readAccessor(prim["indices"] as! Int)
        let pos = readAccessor(attrs["POSITION"]!)
        let nrm = readAccessor(attrs["NORMAL"]!)
        var color = SIMD4<Float>(0.8, 0.8, 0.8, 1)
        if let mi = prim["material"] as? Int {
            let pbr = materials[mi]["pbrMetallicRoughness"] as! [String: Any]
            if let f = pbr["baseColorFactor"] as? [Float] {
                color = SIMD4(f[0], f[1], f[2], f[3])
            }
        }
        return Loaded(positions: pos.array, normals: nrm.array,
                      indices: idx.array.map { UInt16($0) }, baseColor: color)
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let vb: MTLBuffer            // pos3f|nrm3f 交错(24B)
    let ib: MTLBuffer
    let indexCount: Int
    let baseColor: SIMD4<Float>
    let pso: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let stem = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().appendingPathComponent("knot").path
        let mesh = GlbMesh()
        do {
            try GlbWriter.write(mesh, to: stem)
            let loaded = try GlbLoader.load(stem: stem)
            print("glTF 往返: 写 \(mesh.indices.count) 索引 / 读回 \(loaded.indices.count); 顶点 \(loaded.positions.count / 3)")
            var interleaved = [Float]()
            interleaved.reserveCapacity(loaded.positions.count * 2)
            for i in 0..<(loaded.positions.count / 3) {
                interleaved += [loaded.positions[i*3], loaded.positions[i*3+1], loaded.positions[i*3+2],
                                loaded.normals[i*3], loaded.normals[i*3+1], loaded.normals[i*3+2]]
            }
            vb = device.makeBuffer(bytes: interleaved, length: interleaved.count * 4)!
            ib = device.makeBuffer(bytes: loaded.indices, length: loaded.indices.count * 2)!
            indexCount = loaded.indices.count
            baseColor = loaded.baseColor
        } catch {
            FileHandle.standardError.write("glTF 往返失败: \(error)\n".data(using: .utf8)!)
            return nil
        }

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let vf = lib.makeFunction(name: "vert"),
              let ff = lib.makeFunction(name: "frag") else { return nil }
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = 0;  vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
        vd.layouts[0].stride = 24
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pso = try! device.makeRenderPipelineState(descriptor: pd)
        let dz = MTLDepthStencilDescriptor()
        dz.depthCompareFunction = .less
        dz.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dz)!
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let eye = SIMD3<Float>(sin(t * 0.15) * 4.2, 1.4, cos(t * 0.15) * 4.2)
        var u = Uniforms(
            viewProj: perspective(fovY: 44 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0)),
            camPos: SIMD4(eye, 1),
            lightDir: SIMD4(simd_normalize(SIMD3<Float>(0.4, 0.85, 0.35)), 0),
            misc: SIMD4(t, 0, 0, 0))
        var obj = ObjUniforms(model: rotationY(t * 0.3), baseColor: baseColor)

        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pso)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(vb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.setFragmentBytes(&obj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint16, indexBuffer: ib, indexBufferOffset: 0)
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
mtkView.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "glTF Loader — CG Roadmap 19"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
