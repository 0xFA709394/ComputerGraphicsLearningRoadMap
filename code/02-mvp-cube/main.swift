// 02-mvp-cube: 顶点/索引缓冲 + MVP uniform + 深度缓冲（对应 docs/16-metal-quickstart.md Step 2）
// 矩阵函数来自 docs/01-math.md 扩展篇（perspective 为 Metal 约定: z∈[0,1], y 翻转）
// 构建: ./build.sh    运行: ./mvp-cube

import AppKit
import MetalKit
import QuartzCore
import simd

// MARK: - 几何数据
struct Vertex {
    var pos: SIMD3<Float>
    var color: SIMD4<Float>
}
struct Uniforms {
    var mvp: simd_float4x4
}

// 24 顶点立方体（每面独立顶点便于上色）
let cubeVertices: [Vertex] = [
    // +X 红
    Vertex(pos: SIMD3( 1,-1,-1), color: SIMD4(1,0,0,1)),
    Vertex(pos: SIMD3( 1, 1,-1), color: SIMD4(1,0,0,1)),
    Vertex(pos: SIMD3( 1, 1, 1), color: SIMD4(1,0,0,1)),
    Vertex(pos: SIMD3( 1,-1, 1), color: SIMD4(1,0,0,1)),
    // -X 绿
    Vertex(pos: SIMD3(-1,-1, 1), color: SIMD4(0,1,0,1)),
    Vertex(pos: SIMD3(-1, 1, 1), color: SIMD4(0,1,0,1)),
    Vertex(pos: SIMD3(-1, 1,-1), color: SIMD4(0,1,0,1)),
    Vertex(pos: SIMD3(-1,-1,-1), color: SIMD4(0,1,0,1)),
    // +Y 蓝
    Vertex(pos: SIMD3(-1, 1,-1), color: SIMD4(0,0,1,1)),
    Vertex(pos: SIMD3(-1, 1, 1), color: SIMD4(0,0,1,1)),
    Vertex(pos: SIMD3( 1, 1, 1), color: SIMD4(0,0,1,1)),
    Vertex(pos: SIMD3( 1, 1,-1), color: SIMD4(0,0,1,1)),
    // -Y 黄
    Vertex(pos: SIMD3(-1,-1, 1), color: SIMD4(1,1,0,1)),
    Vertex(pos: SIMD3(-1,-1,-1), color: SIMD4(1,1,0,1)),
    Vertex(pos: SIMD3( 1,-1,-1), color: SIMD4(1,1,0,1)),
    Vertex(pos: SIMD3( 1,-1, 1), color: SIMD4(1,1,0,1)),
    // +Z 品红
    Vertex(pos: SIMD3(-1,-1, 1), color: SIMD4(1,0,1,1)),
    Vertex(pos: SIMD3( 1,-1, 1), color: SIMD4(1,0,1,1)),
    Vertex(pos: SIMD3( 1, 1, 1), color: SIMD4(1,0,1,1)),
    Vertex(pos: SIMD3(-1, 1, 1), color: SIMD4(1,0,1,1)),
    // -Z 青
    Vertex(pos: SIMD3( 1,-1,-1), color: SIMD4(0,1,1,1)),
    Vertex(pos: SIMD3(-1,-1,-1), color: SIMD4(0,1,1,1)),
    Vertex(pos: SIMD3(-1, 1,-1), color: SIMD4(0,1,1,1)),
    Vertex(pos: SIMD3( 1, 1,-1), color: SIMD4(0,1,1,1)),
]
let cubeIndices: [UInt16] = {
    var idx: [UInt16] = []
    for face in 0..<6 {
        let b = UInt16(face * 4)
        idx += [b, b+1, b+2, b, b+2, b+3]
    }
    return idx
}()

// MARK: - 数学（docs/01 扩展篇 B/C 的 Swift 落地）
func perspective(fovY: Float, aspect: Float, n: Float, f: Float) -> simd_float4x4 {
    let t = 1 / tan(fovY * 0.5)
    return simd_float4x4(
        SIMD4(t / aspect, 0, 0, 0),
        SIMD4(0, -t, 0, 0),              // y 取负: Metal NDC y 向下
        SIMD4(0, 0, f / (n - f), -1),    // w_clip = -z, z∈[0,1]
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
func rotationX(_ a: Float) -> simd_float4x4 {
    let (c, s) = (cos(a), sin(a))
    return simd_float4x4(SIMD4(1,0,0,0), SIMD4(0,c,s,0), SIMD4(0,-s,c,0), SIMD4(0,0,0,1))
}

// MARK: - Renderer
final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let vbuf: MTLBuffer
    let ibuf: MTLBuffer

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }

        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let vs = lib.makeFunction(name: "vertMain"),
              let fs = lib.makeFunction(name: "fragMain") else { return nil }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.depthAttachmentPixelFormat = view.depthStencilPixelFormat   // 深度必须写进 PSO!

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd),
              let depthState = device.makeDepthStencilState(descriptor: dd),
              let vbuf = device.makeBuffer(bytes: cubeVertices,
                                            length: MemoryLayout<Vertex>.stride * cubeVertices.count),
              let ibuf = device.makeBuffer(bytes: cubeIndices,
                                           length: MemoryLayout<UInt16>.stride * cubeIndices.count)
        else { return nil }

        self.queue = queue; self.pipeline = pipeline; self.depthState = depthState
        self.vbuf = vbuf; self.ibuf = ibuf
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // 每帧更新 MVP（docs/01 §3: clip = P·V·M·v）
        let t = Float(CACurrentMediaTime())
        let model = rotationY(t * 0.6) * rotationX(t * 0.35)
        let eye = SIMD3<Float>(0, 1.2, 4)
        let viewM = lookAt(eye: eye, target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let proj = perspective(fovY: 60 * .pi / 180, aspect: aspect, n: 0.1, f: 100)
        var u = Uniforms(mvp: proj * viewM * model)

        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: cubeIndices.count,
                                  indexType: .uint16, indexBuffer: ibuf, indexBufferOffset: 0)
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
mtkView.depthStencilPixelFormat = .depth32Float   // 深度缓冲
mtkView.clearDepth = 1.0
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "MVP Cube — CG Roadmap 02"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
