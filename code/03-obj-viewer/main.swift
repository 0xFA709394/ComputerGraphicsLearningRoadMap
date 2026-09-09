// 03-obj-viewer: Model I/O 加载 OBJ + [[stage_in]] 顶点描述符 + Blinn-Phong
// 对应 docs/16-metal-quickstart.md Step 3 与 docs/10 §4.2（资产管线）
// 构建: ./build.sh    运行: ./obj-viewer

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

// MARK: - 数学（与 02 示例一致）
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

// MARK: - Renderer
final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let mesh: MTKMesh
    let submesh: MTKSubmesh

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }

        // ---- 1) Model I/O 加载 OBJ（docs/16 Step 3）----
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let objURL = binDir.appendingPathComponent("assets/sphere.obj")
        // MTKMeshBufferAllocator: 让顶点缓冲落在 MTLBuffer 上（MTKMesh 转换的前提）
        let asset = MDLAsset(url: objURL,
                             vertexDescriptor: nil,
                             bufferAllocator: MTKMeshBufferAllocator(device: device))
        guard let mdlMesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else {
            FileHandle.standardError.write("OBJ 加载失败: \(objURL.path)\n".data(using: .utf8)!)
            return nil
        }
        if mdlMesh.vertexDescriptor.attributeNamed(MDLVertexAttributeNormal) == nil {
            mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        }
        // ---- 2) 顶点布局 stride 32: pos3f|normal3f|uv2f；转 MDL 描述符后设置给网格 ----
        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32
        // 索引 0/1/2 自动映射为 position/normal/textureCoordinate（MetalKit 约定）
        let mdlVD = MTKModelIOVertexDescriptorFromMetal(mtlVD)
        mdlMesh.vertexDescriptor = mdlVD

        do {
            let mesh = try MTKMesh(mesh: mdlMesh, device: device)
            guard let submesh = mesh.submeshes.first else {
                FileHandle.standardError.write("网格无 submesh\n".data(using: .utf8)!)
                return nil
            }
            self.mesh = mesh; self.submesh = submesh
        } catch {
            FileHandle.standardError.write("MTKMesh 转换失败: \(error)\n".data(using: .utf8)!)
            return nil
        }

        // ---- 3) PSO：shader 入口 + 顶点描述符（[[stage_in]] 的来源）----
        let binLib = binDir.appendingPathComponent("default.metallib")
        guard let lib = try? device.makeLibrary(URL: binLib),
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
        let eye = SIMD3<Float>(0, 0.8, 3)
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
        enc.setVertexBuffer(mesh.vertexBuffers[0].buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: submesh.primitiveType,
                                  indexCount: submesh.indexCount,
                                  indexType: submesh.indexType,
                                  indexBuffer: submesh.indexBuffer.buffer,
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
window.title = "OBJ Viewer — CG Roadmap 03"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
