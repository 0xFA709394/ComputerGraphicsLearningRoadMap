// 06-offscreen-postfx: 离屏 HDR 场景 → 亮部提取 → 分离高斯 bloom → ACES 合成
// 对应 docs/02 §10（RenderPass 组织）与 docs/09 §5（后处理链）
// 构建: ./build.sh    运行: ./postfx

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
    var misc: SIMD4<Float>       // x=time
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

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let mesh: MTKMesh
    let submesh: MTKSubmesh
    let albedo: MTLTexture
    let mtlVD: MTLVertexDescriptor

    // 四条 pass 的 PSO
    let scenePSO, brightPSO, blurPSO, compositePSO: MTLRenderPipelineState
    let depthState: MTLDepthStencilState

    // 离屏目标（尺寸跟随 view 变化重建）
    var sceneTex: MTLTexture!      // 全分辨率 HDR
    var depthTex: MTLTexture!
    var bloomA: MTLTexture!        // 半分辨率 bloom 链 ping-pong
    var bloomB: MTLTexture!
    var size = CGSize()

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()

        // ---- 网格与纹理（同 04/05）----
        let objURL = binDir.appendingPathComponent("assets/sphere.obj")
        let asset = MDLAsset(url: objURL,
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
        self.mtlVD = mtlVD
        do {
            albedo = try MTKTextureLoader(device: device).newTexture(
                URL: binDir.appendingPathComponent("assets/checker.png"),
                options: [.SRGB: true, .generateMipmaps: true])
        } catch { return nil }

        // ---- PSO 家族: 四条 pass 各自的颜色格式 ----
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let sVS = lib.makeFunction(name: "vertMain"),
              let sFS = lib.makeFunction(name: "sceneFrag"),
              let fsVS = lib.makeFunction(name: "fullscreenVert"),
              let brightFS = lib.makeFunction(name: "brightFrag"),
              let blurFS = lib.makeFunction(name: "blurFrag"),
              let compFS = lib.makeFunction(name: "compositeFrag") else { return nil }

        func makePSO(vertex: MTLFunction?, fragment: MTLFunction?,
                     colorFormat: MTLPixelFormat, depth: Bool, vd: MTLVertexDescriptor? = nil) -> MTLRenderPipelineState? {
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vertex
            pd.fragmentFunction = fragment
            if let vd = vd { pd.vertexDescriptor = vd }
            pd.colorAttachments[0].pixelFormat = colorFormat
            if depth { pd.depthAttachmentPixelFormat = .depth32Float }
            return try? device.makeRenderPipelineState(descriptor: pd)
        }

        guard let scenePSO = makePSO(vertex: sVS, fragment: sFS,
                                     colorFormat: .rgba16Float, depth: true, vd: mtlVD),
              let brightPSO = makePSO(vertex: fsVS, fragment: brightFS, colorFormat: .rgba16Float, depth: false),
              let blurPSO   = makePSO(vertex: fsVS, fragment: blurFS,   colorFormat: .rgba16Float, depth: false),
              let compositePSO = makePSO(vertex: fsVS, fragment: compFS,
                                         colorFormat: view.colorPixelFormat, depth: false) else { return nil }
        self.scenePSO = scenePSO; self.brightPSO = brightPSO
        self.blurPSO = blurPSO; self.compositePSO = compositePSO

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)!
    }

    // ---- 离屏目标创建/重建（docs/07 §5.3: pass 边界即 tile 生命周期）----
    func recreateTargets(device: MTLDevice, size: CGSize) {
        guard size.width > 8, size != self.size else { return }
        self.size = size
        let w = Int(size.width), h = Int(size.height)

        func target(_ fmt: MTLPixelFormat, _ tw: Int, _ th: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt,
                                                             width: tw, height: th, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        sceneTex = target(.rgba16Float, w, h)
        depthTex = target(.depth32Float, w, h)
        bloomA = target(.rgba16Float, max(w / 2, 1), max(h / 2, 1))   // 半分辨率 bloom
        bloomB = target(.rgba16Float, max(w / 2, 1), max(h / 2, 1))
    }

    private func passDescriptor(_ color: MTLTexture, clear: MTLClearColor? = nil) -> MTLRenderPassDescriptor {
        let d = MTLRenderPassDescriptor()
        d.colorAttachments[0].texture = color
        d.colorAttachments[0].loadAction = clear != nil ? .clear : .dontCare
        d.colorAttachments[0].storeAction = .store
        if let c = clear { d.colorAttachments[0].clearColor = c }
        return d
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        recreateTargets(device: view.device!, size: size)
    }

    func draw(in view: MTKView) {
        recreateTargets(device: view.device!, size: view.drawableSize)   // 首帧
        guard let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }

        let t = Float(CACurrentMediaTime())
        let eye = SIMD3<Float>(0, 0.8, 4)
        let aspect = Float(size.width / max(size.height, 1))
        var u = Uniforms(
            viewProj: perspective(fovY: 55 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
                * lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0)),
            model: rotationY(t * 0.4),
            lightDir: SIMD4(simd_normalize(SIMD3<Float>(-0.5, -1.0, -0.3)), 0),
            camPos: SIMD4(eye, 1),
            misc: SIMD4(t, 0, 0, 0))

        // ---- Pass 1: 场景 → HDR sceneTex ----
        let sceneDesc = passDescriptor(sceneTex, clear: MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
        sceneDesc.depthAttachment.texture = depthTex
        sceneDesc.depthAttachment.loadAction = .clear
        sceneDesc.depthAttachment.storeAction = .dontCare          // 后续不再读深度
        if let enc = cb.makeRenderCommandEncoder(descriptor: sceneDesc) {
            enc.setRenderPipelineState(scenePSO)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(mesh.vertexBuffers[0].buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(albedo, index: 0)
            enc.drawIndexedPrimitives(type: submesh.primitiveType,
                                      indexCount: submesh.indexCount,
                                      indexType: submesh.indexType,
                                      indexBuffer: submesh.indexBuffer.buffer,
                                      indexBufferOffset: 0)
            enc.endEncoding()
        }

        // ---- Pass 2: 亮部提取（半分辨率）----
        if let enc = cb.makeRenderCommandEncoder(descriptor: passDescriptor(bloomA)) {
            enc.setRenderPipelineState(brightPSO)
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- Pass 3/4: 分离高斯 H → V（ping-pong）----
        var dirH = SIMD2<Float>(1 / Float(bloomA.width), 0)
        var dirV = SIMD2<Float>(0, 1 / Float(bloomA.height))
        if let enc = cb.makeRenderCommandEncoder(descriptor: passDescriptor(bloomB)) {
            enc.setRenderPipelineState(blurPSO)
            enc.setFragmentTexture(bloomA, index: 0)
            enc.setFragmentBytes(&dirH, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        if let enc = cb.makeRenderCommandEncoder(descriptor: passDescriptor(bloomA)) {
            enc.setRenderPipelineState(blurPSO)
            enc.setFragmentTexture(bloomB, index: 0)
            enc.setFragmentBytes(&dirV, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ---- Pass 5: 合成 → drawable ----
        if let rpd = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(compositePSO)
            enc.setFragmentTexture(sceneTex, index: 0)
            enc.setFragmentTexture(bloomA, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()
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
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
let mtkView = MTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "Offscreen + Bloom — CG Roadmap 06"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
