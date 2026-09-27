// 21-sdf-raymarch: 全片元 SDF 球体追踪(零网格)
// 构建: ./build.sh    运行: ./sdf

import AppKit
import MetalKit
import QuartzCore
import simd

struct Uniforms {
    var camPos: SIMD4<Float>
    var misc: SIMD4<Float>       // x: time, y: aspect
}

final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pso: MTLRenderPipelineState
    var offRpd: MTLRenderPassDescriptor?
    var fixedTime: Float?

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        guard let lib = try? device.makeLibrary(URL: binDir.appendingPathComponent("default.metallib")),
              let vf = lib.makeFunction(name: "vs"),
              let ff = lib.makeFunction(name: "fs") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vf
        pd.fragmentFunction = ff
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pso = try! device.makeRenderPipelineState(descriptor: pd)
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        let t = fixedTime ?? Float(CACurrentMediaTime())
        var u = Uniforms(camPos: .zero,
                         misc: SIMD4(t, Float(view.drawableSize.width / max(view.drawableSize.height, 1)), 0, 0))
        if let enc = cb.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pso)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]
guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer
window.contentView = mtkView
window.title = "SDF Raymarching — CG Roadmap 21"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
