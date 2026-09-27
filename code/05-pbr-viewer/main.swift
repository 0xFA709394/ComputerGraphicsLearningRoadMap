// 05-pbr-viewer: 实例化 35 球 metallic×roughness 参数矩阵 + Cook-Torrance GGX 三点光 + ACES
// 对应 docs/03 全章（PBR 核心）与 docs/16 Step 5 —— 16 章示例代码的收官
// 构建: ./build.sh    运行: ./pbr-viewer

import AppKit
import MetalKit
import ModelIO
import QuartzCore
import simd

struct Light { var pos: SIMD4<Float>; var color: SIMD4<Float> }
struct Uniforms {
    var viewProj: simd_float4x4
    var camPos: SIMD4<Float>
    var lightPos: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    var lightColor: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}
struct InstanceData {
    var model: simd_float4x4
    var mat: SIMD4<Float>      // x=metallic, y=roughness
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

// 列数 = metallic 0→1, 行数 = roughness 0→1（经典 PBR 参数图）
let COLS = 7, ROWS = 5


struct SphereVertex {   // 与 mtlVD 布局一致: pos3f|normal3f|uv2f, stride 32
    var pos: SIMD3<Float>
    var normal: SIMD3<Float>
    var uv: SIMD2<Float>
}
/// 过程化经纬球(法线=归一化位置)。
/// 踩坑实录: macOS 26 工具链上 Model I/O 到 MTKMesh 的转换, 顶点位置全为 0(球体静默消失),
/// 自建 MTLBuffer 绕开; 布局与原 OBJ 流程完全一致, shader 不变。
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

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let sphereVB: MTLBuffer
    let sphereIB: MTLBuffer
    let sphereIndexCount: Int
    let instanceBuf: MTLBuffer
    var uniforms: Uniforms

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 网格（同 03/04）----
        let objURL = binDir.appendingPathComponent("assets/sphere.obj")
        // ---- 顶点布局 stride 32: pos3f|normal3f|uv2f ----
        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32
        // 过程化球体(原 OBJ 加载流程在 macOS 26 上顶点清零, 见 makeSphereBuffers 注释)
        let (vb, ib, idxCount) = makeSphereBuffers(device: device, radius: 1, lat: 24, lon: 32)
        sphereVB = vb; sphereIB = ib; sphereIndexCount = idxCount

        // ---- 实例数据: 平移 × 均匀缩放 ----
        let s: Float = 0.30
        var instances: [InstanceData] = []
        for row in 0..<ROWS {
            for col in 0..<COLS {
                let x = (Float(col) - Float(COLS - 1) / 2) * 0.95
                let y = (Float(ROWS - 1 - row) - Float(ROWS - 1) / 2) * 0.95   // roughness 从上往下
                let model = simd_float4x4(
                    SIMD4(s, 0, 0, 0), SIMD4(0, s, 0, 0), SIMD4(0, 0, s, 0), SIMD4(x, y, 0, 1))
                instances.append(InstanceData(model: model,
                                              mat: SIMD4(Float(col) / Float(COLS - 1),
                                                         Float(row) / Float(ROWS - 1), 0, 0)))
            }
        }
        guard let instanceBuf = device.makeBuffer(
            bytes: instances, length: MemoryLayout<InstanceData>.stride * instances.count) else { return nil }
        self.instanceBuf = instanceBuf

        // ---- PSO ----
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let vs = lib.makeFunction(name: "vertMain"),
              let fs = lib.makeFunction(name: "fragMain") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.vertexDescriptor = mtlVD
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd),
              let depthState = device.makeDepthStencilState(descriptor: dd) else { return nil }

        // ---- 灯光: 暖主光 / 冷补光 / 背后轮廓光 ----
        let lights: [Light] = [
            Light(pos: SIMD4( 3.5,  3.0, 4.0, 1), color: SIMD4(26.0, 22.0, 17.0, 0)),
            Light(pos: SIMD4(-4.0,  0.5, 3.0, 1), color: SIMD4( 6.0,  9.0, 14.0, 0)),
            Light(pos: SIMD4( 0.0, -2.0, -4.0, 1), color: SIMD4(10.0,  3.0,  3.0, 0)),
        ]
        uniforms = Uniforms(
            viewProj: simd_float4x4(),
            camPos: SIMD4(0, 0, 7.5, 1),
            lightPos: (lights[0].pos, lights[1].pos, lights[2].pos),
            lightColor: (lights[0].color, lights[1].color, lights[2].color))

        self.queue = queue; self.pipeline = pipeline; self.depthState = depthState
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let eye = SIMD3<Float>(0, 0, 7.5)
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        var u = uniforms
        u.viewProj = perspective(fovY: 42 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
            * lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setVertexBuffer(instanceBuf, offset: 0, index: 2)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: sphereIndexCount,
                                  indexType: .uint16,
                                  indexBuffer: sphereIB,
                                  indexBufferOffset: 0,
                                  instanceCount: ROWS * COLS)
        enc.endEncoding()
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
mtkView.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.clearDepth = 1.0
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "PBR Viewer — CG Roadmap 05"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
