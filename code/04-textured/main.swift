// 04-textured: MTKTextureLoader 加载 PNG + sRGB 选项 + mipmap 生成 + 半球 mip 对照
// 对应 docs/16-metal-quickstart.md Step 4 与 docs/04 §2（过滤/mipmap）、docs/09 §3（sRGB 纪律）
// 构建: ./build.sh    运行: ./textured

import AppKit
import MetalKit
import ModelIO
import QuartzCore
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var model: simd_float4x4
    var lightDir: SIMD4<Float>
    var camPos: SIMD4<Float>
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
func rotationY(_ a: Float) -> simd_float4x4 {
    let (c, s) = (cos(a), sin(a))
    return simd_float4x4(SIMD4(c,0,-s,0), SIMD4(0,1,0,0), SIMD4(s,0,c,0), SIMD4(0,0,0,1))
}


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
    let albedo: MTLTexture

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 1) OBJ（同 03 例）----
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

        // ---- 2) 纹理: MTKTextureLoader + sRGB 标注 + mipmap 生成 ----
        // .SRGB: true  → 纹理格式为 *_srgb 变体, 采样时硬件自动解码到线性(docs/09 §3)
        // generateMipmaps: true → 加载后自动建 mip 链(docs/04 §2.2)
        let texURL = binDir.appendingPathComponent("assets/checker.png")
        do {
            albedo = try MTKTextureLoader(device: device).newTexture(
                URL: texURL,
                options: [.SRGB: true, .generateMipmaps: true])
        } catch {
            FileHandle.standardError.write("纹理加载失败: \(error)\n".data(using: .utf8)!)
            return nil
        }

        // ---- 3) PSO ----
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

        self.queue = queue; self.pipeline = pipeline; self.depthState = depthState
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let t = Float(CACurrentMediaTime())
        let model = rotationY(t * 0.4)
        let eye = SIMD3<Float>(0, 0.8, 4)          // 稍远 → 左半球 mip0 走样明显
        let viewM = lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let proj = perspective(fovY: 55 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
        var u = Uniforms(
            viewProj: proj * viewM,
            model: model,
            lightDir: SIMD4(simd_normalize(SIMD3<Float>(-0.5, -1.0, -0.3)), 0),
            camPos: SIMD4(eye, 1))

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(sphereVB, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentTexture(albedo, index: 0)
        enc.drawIndexedPrimitives(type: .triangle,
                                  indexCount: sphereIndexCount,
                                  indexType: .uint16,
                                  indexBuffer: sphereIB,
                                  indexBufferOffset: 0)
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
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
let mtkView = MTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.clearDepth = 1.0
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "Textured — CG Roadmap 04"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
