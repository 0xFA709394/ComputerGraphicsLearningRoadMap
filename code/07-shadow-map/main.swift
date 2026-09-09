// 07-shadow-map: 光源深度 pass + 斜率偏置 + 3×3 PCF（docs/11 §1.1 基础形态）
// 构建: ./build.sh    运行: ./shadow-map

import AppKit
import MetalKit
import ModelIO
import QuartzCore
import simd

struct Uniforms {
    var viewProj: simd_float4x4
    var lightVP: simd_float4x4
    var lightDir: SIMD4<Float>
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>
}
struct ObjUniforms { var model: simd_float4x4 }
struct QuadVertex {   // 与 mtlVD 布局一致: pos3f|normal3f|uv2f, stride 32
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
func ortho(l: Float, r: Float, b: Float, t: Float, n: Float, f: Float) -> simd_float4x4 {
    // 光源正交投影（z∈[0,1]; 阴影只需自洽映射, y 不翻转）
    simd_float4x4(
        SIMD4(2 / (r - l), 0, 0, 0),
        SIMD4(0, 2 / (t - b), 0, 0),
        SIMD4(0, 0, -1 / (f - n), 0),
        SIMD4(-(r + l) / (r - l), -(t + b) / (t - b), -n / (f - n), 1))
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

let LIGHT_DIR = simd_normalize(SIMD3<Float>(-0.5, -1.0, -0.35))   // 光传播方向
let GROUND_Y: Float = -1.4

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let mesh: MTKMesh
    let submesh: MTKSubmesh
    let quadBuf: MTLBuffer
    let albedo: MTLTexture
    let shadowMap: MTLTexture
    let scenePSO, shadowPSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 球体（投射者）----
        let asset = MDLAsset(url: binDir.appendingPathComponent("assets/sphere.obj"),
                             vertexDescriptor: nil,
                             bufferAllocator: MTKMeshBufferAllocator(device: device))
        guard let mdlMesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { return nil }
        let mtlVD = MTLVertexDescriptor()
        mtlVD.attributes[0].format = .float3; mtlVD.attributes[0].offset = 0;  mtlVD.attributes[0].bufferIndex = 0
        mtlVD.attributes[1].format = .float3; mtlVD.attributes[1].offset = 12; mtlVD.attributes[1].bufferIndex = 0
        mtlVD.attributes[2].format = .float2; mtlVD.attributes[2].offset = 24; mtlVD.attributes[2].bufferIndex = 0
        mtlVD.layouts[0].stride = 32
        mdlMesh.vertexDescriptor = MTKModelIOVertexDescriptorFromMetal(mtlVD)
        do {
            let mesh = try MTKMesh(mesh: mdlMesh, device: device)
            guard let submesh = mesh.submeshes.first else { return nil }
            self.mesh = mesh; self.submesh = submesh
        } catch { return nil }

        // ---- 地面四边形（接收者; 世界空间直存, model=I）----
        let S: Float = 3.5, R: Float = 7   // R = uv 重复次数
        let quad: [QuadVertex] = [
            QuadVertex(pos: SIMD3(-S, GROUND_Y, -S), normal: SIMD3(0,1,0), uv: SIMD2(0, 0)),
            QuadVertex(pos: SIMD3( S, GROUND_Y, -S), normal: SIMD3(0,1,0), uv: SIMD2(R, 0)),
            QuadVertex(pos: SIMD3( S, GROUND_Y,  S), normal: SIMD3(0,1,0), uv: SIMD2(R, R)),
            QuadVertex(pos: SIMD3(-S, GROUND_Y, -S), normal: SIMD3(0,1,0), uv: SIMD2(0, 0)),
            QuadVertex(pos: SIMD3( S, GROUND_Y,  S), normal: SIMD3(0,1,0), uv: SIMD2(R, R)),
            QuadVertex(pos: SIMD3(-S, GROUND_Y,  S), normal: SIMD3(0,1,0), uv: SIMD2(0, R)),
        ]
        quadBuf = device.makeBuffer(bytes: quad,
                                    length: MemoryLayout<QuadVertex>.stride * quad.count)!

        do {
            albedo = try MTKTextureLoader(device: device).newTexture(
                URL: binDir.appendingPathComponent("assets/checker.png"),
                options: [.SRGB: true, .generateMipmaps: true])
        } catch { return nil }

        // ---- 阴影图 1024²（depth32Float, RT+读; docs/04 §3: 深度图也是纹理）----
        let sd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 1024, height: 1024, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        sd.storageMode = .private
        shadowMap = device.makeTexture(descriptor: sd)!

        // ---- PSO ×2 ----
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sVS = lib.makeFunction(name: "shadowVert"),
              let sFS = lib.makeFunction(name: "sceneFrag"),
              let mVS = lib.makeFunction(name: "vertMain") else { return nil }

        // depth-only: fragmentFunction = nil（Metal 允许无颜色附件时省略片元）
        let sp = MTLRenderPipelineDescriptor()
        sp.vertexFunction = sVS
        sp.fragmentFunction = nil
        sp.vertexDescriptor = mtlVD        // [[stage_in]] 同样需要顶点描述符!
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

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime())
        let eye = SIMD3<Float>(2.2, 1.6, 4.2)
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let lightEye = -LIGHT_DIR * 10   // 光源位于场景中心逆光方向 10 处
        var u = Uniforms(
            viewProj: perspective(fovY: 50 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, -0.4, 0), up: SIMD3(0, 1, 0)),
            lightVP: ortho(l: -5, r: 5, b: -5, t: 5, n: 0.1, f: 30)
                * lookAt(eye: lightEye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0)),
            lightDir: SIMD4(LIGHT_DIR, 0),
            camPos: SIMD4(eye, 1),
            misc: SIMD4(t, 0, 0, 0))

        var sphereObj = ObjUniforms(model: rotationY(t * 0.4))
        var groundObj = ObjUniforms(model: simd_float4x4(diagonal: SIMD4(1, 1, 1, 1)))

        // ---- Pass 1: 光源深度 ----
        let shadowDesc = MTLRenderPassDescriptor()
        shadowDesc.depthAttachment.texture = shadowMap
        shadowDesc.depthAttachment.loadAction = .clear
        shadowDesc.depthAttachment.storeAction = .store
        shadowDesc.depthAttachment.clearDepth = 1.0
        if let enc = cb.makeRenderCommandEncoder(descriptor: shadowDesc) {
            enc.setRenderPipelineState(shadowPSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            // 球（投射者）与地面都写深度（地面自阴影可省略, 此处简化）
            enc.setVertexBuffer(mesh.vertexBuffers[0].buffer, offset: 0, index: 0)
            enc.setVertexBytes(&sphereObj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawIndexedPrimitives(type: submesh.primitiveType,
                                      indexCount: submesh.indexCount,
                                      indexType: submesh.indexType,
                                      indexBuffer: submesh.indexBuffer.buffer,
                                      indexBufferOffset: 0)
            enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
            enc.setVertexBytes(&groundObj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // ---- Pass 2: 场景 + PCF ----
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(albedo, index: 0)
            enc.setFragmentTexture(shadowMap, index: 1)
            // 地面
            enc.setVertexBuffer(quadBuf, offset: 0, index: 0)
            enc.setVertexBytes(&groundObj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            // 球
            enc.setVertexBuffer(mesh.vertexBuffers[0].buffer, offset: 0, index: 0)
            enc.setVertexBytes(&sphereObj, length: MemoryLayout<ObjUniforms>.stride, index: 2)
            enc.drawIndexedPrimitives(type: submesh.primitiveType,
                                      indexCount: submesh.indexCount,
                                      indexType: submesh.indexType,
                                      indexBuffer: submesh.indexBuffer.buffer,
                                      indexBufferOffset: 0)
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
mtkView.clearColor = MTLClearColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.depthStencilPixelFormat = .depth32Float
mtkView.clearDepth = 1.0
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "Shadow Map — CG Roadmap 07"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
