// 15-skinning: GPU 骨骼蒙皮(6 骨骼链 FK + 矩阵调色板 + 两骨骼 LBS)
// 对应 docs/08 §蒙皮推导。空格: 开/关蒙皮。构建: ./build.sh    运行: ./skinning

import AppKit
import MetalKit
import QuartzCore
import simd

let BONES = 6
let ARM_LEN: Float = 3.2

struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>       // x: time, y: skinOn
}
struct Skin {                    // 平铺调色板(与 MSL 一致)
    var b0, b1, b2, b3, b4, b5: simd_float4x4
    static let identity = Skin(b0: .init(diagonal: SIMD4(1,1,1,1)), b1: .init(diagonal: SIMD4(1,1,1,1)),
                               b2: .init(diagonal: SIMD4(1,1,1,1)), b3: .init(diagonal: SIMD4(1,1,1,1)),
                               b4: .init(diagonal: SIMD4(1,1,1,1)), b5: .init(diagonal: SIMD4(1,1,1,1)))
}
struct Vertex {
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
func rotationZ(_ a: Float) -> simd_float4x4 {
    let (c, s) = (cos(a), sin(a))
    return simd_float4x4(SIMD4(c,s,0,0), SIMD4(-s,c,0,0), SIMD4(0,0,1,0), SIMD4(0,0,0,1))
}

final class ArmMesh {
    let vb: MTLBuffer
    let ib: MTLBuffer
    let indexCount: Int
    init?(device: MTLDevice) {
        var verts: [Vertex] = []
        let rings = 24, sides = 16
        let r0: Float = 0.45, r1: Float = 0.13
        let slope = (r1 - r0) / ARM_LEN
        for i in 0...rings {
            let y = ARM_LEN * Float(i) / Float(rings)
            let r = r0 + (r1 - r0) * y / ARM_LEN
            let v = Float(i) / Float(rings)
            for j in 0...sides {
                let ph = 2 * Float.pi * Float(j) / Float(sides)
                let (c, s) = (cos(ph), sin(ph))
                verts.append(Vertex(pos: SIMD3(r * c, y, r * s),
                                    normal: simd_normalize(SIMD3(c, -slope, s)),
                                    uv: SIMD2(Float(j) / Float(sides), v)))
            }
        }
        var idx: [UInt16] = []
        for i in 0..<rings {
            for j in 0..<sides {
                let a = i * (sides + 1) + j, b = (i + 1) * (sides + 1) + j, c = b + 1, d = a + 1
                idx += [UInt16(a), UInt16(b), UInt16(c), UInt16(a), UInt16(c), UInt16(d)]
            }
        }
        vb = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count)!
        ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count)!
        indexCount = idx.count
    }
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let arm: ArmMesh
    let groundVB: MTLBuffer
    let skinPSO, groundPSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    var skinOn = true
    var offRpd: MTLRenderPassDescriptor?      // headless 验证用
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        guard let arm = ArmMesh(device: device) else { return nil }
        self.arm = arm

        var quads: [Vertex] = []
        let TILES = 6, S: Float = 14
        for iy in 0..<TILES {
            for ix in 0..<TILES {
                let step = 2 * S / Float(TILES)
                let x0 = -S + Float(ix) * step, x1 = x0 + step
                let z0 = -S + Float(iy) * step, z1 = z0 + step
                quads.append(Vertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(Vertex(pos: SIMD3(x1, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(Vertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(Vertex(pos: SIMD3(x0, 0, z0), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(Vertex(pos: SIMD3(x1, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
                quads.append(Vertex(pos: SIMD3(x0, 0, z1), normal: SIMD3(0,1,0), uv: .zero))
            }
        }
        var fdata = [Float]()
        fdata.reserveCapacity(quads.count * 8)
        for v in quads { fdata += [v.pos.x, v.pos.y, v.pos.z, v.normal.x, v.normal.y, v.normal.z, v.uv.x, v.uv.y] }
        // 踩坑实录: SIMD3 对齐 16 → 结构体 stride 48 ≠ 描述符 32, GPU 读到交错垃圾
        // (球体稠密网格侥幸"看着对", 稀疏瓦片大面积消失); 手动交错 32B 打包
        groundVB = device.makeBuffer(bytes: fdata, length: fdata.count * 4)!

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sv = lib.makeFunction(name: "skinVert"),
              let sf = lib.makeFunction(name: "skinFrag"),
              let gv = lib.makeFunction(name: "groundVert"),
              let gf = lib.makeFunction(name: "groundFrag") else { return nil }

        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32

        func ps(_ vf: MTLFunction, _ ff: MTLFunction) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            d.vertexDescriptor = mtlVD
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let s1 = ps(sv, sf), let s2 = ps(gv, gf) else { return nil }
        skinPSO = s1; groundPSO = s2

        let dz = MTLDepthStencilDescriptor()
        dz.depthCompareFunction = .less
        dz.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dz)!
    }

    /// 骨骼链 FK: 行波旋转 → 调色板(docs/08 §骨骼层级)
    static func buildPalette(t: Float) -> Skin {
        let bl = ARM_LEN / Float(BONES)
        var mats = [simd_float4x4](repeating: .init(diagonal: SIMD4(1,1,1,1)), count: BONES)
        var acc = rotationZ(sin(t * 2.2) * 0.10)              // 骨 0(基部小幅)
        mats[0] = acc
        for i in 1..<BONES {
            let amp = 0.12 + 0.42 * Float(i) / Float(BONES - 1)   // 越靠尖越甩
            let ang = sin(t * 2.2 - Float(i) * 0.62) * amp
            acc = acc * translateMat(SIMD3(0, bl, 0)) * rotationZ(ang)
            // 调色板条目 = Wi · T(−joint_i): 把绑定姿态顶点搬到摆后位置
            mats[i] = acc * translateMat(SIMD3(0, -Float(i) * bl, 0))
        }
        return Skin(b0: mats[0], b1: mats[1], b2: mats[2], b3: mats[3], b4: mats[4], b5: mats[5])
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        var u = Uniforms(
            viewProj: perspective(fovY: 44 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: SIMD3(5.5, 3.2, 7.5), target: SIMD3(0, 1.6, 0), up: SIMD3(0, 1, 0)),
            camPos: SIMD4(5.5, 3.2, 7.5, 1),
            misc: SIMD4(t, skinOn ? 1 : 0, 0, 0))
        var sk = skinOn ? Self.buildPalette(t: t) : .identity

        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 地面
            enc.setRenderPipelineState(groundPSO)
            enc.setVertexBuffer(groundVB, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6 * 6 * 6)
            // 触手(蒙皮)
            enc.setRenderPipelineState(skinPSO)
            enc.setVertexBuffer(arm.vb, offset: 0, index: 0)
            enc.setVertexBytes(&sk, length: MemoryLayout<Skin>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: arm.indexCount,
                                      indexType: .uint16, indexBuffer: arm.ib, indexBufferOffset: 0)
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
        if event.keyCode == 49 { (delegate as? Renderer)?.skinOn.toggle() }   // 空格
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
mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "GPU Skinning — CG Roadmap 15 (空格: 开关蒙皮)"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
