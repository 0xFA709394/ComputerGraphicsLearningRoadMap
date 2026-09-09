// 01-hello-triangle: macOS MetalKit 最小可运行示例（对应 docs/16-metal-quickstart.md Step 0-1）
// 构建: ./build.sh    运行: ./hello-triangle

import AppKit
import MetalKit

// MARK: - Renderer: 持有长生命周期 GPU 对象, 实现每帧绘制
final class Renderer: NSObject, MTKViewDelegate {
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init?(view: MTKView) {
        guard let device = view.device,
              let queue = device.makeCommandQueue() else { return nil }

        // CLI 二进制没有 bundle -> 从可执行文件旁加载编译好的 metallib
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        let libURL = binDir.appendingPathComponent("default.metallib")
        guard let lib = try? device.makeLibrary(URL: libURL),
              let vs = lib.makeFunction(name: "vertMain"),
              let fs = lib.makeFunction(name: "fragMain") else {
            FileHandle.standardError.write("无法加载 Shaders.metal 编译产物: \(libURL.path)\n".data(using: .utf8)!)
            return nil
        }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs
        pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }

        self.queue = queue
        self.pipeline = pipeline
    }

    func draw(in view: MTKView) {
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - App 启动（无 storyboard, 全代码）
guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write("此设备不支持 Metal\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered, defer: false)

let mtkView = MTKView(frame: window.contentView?.bounds ?? .zero, device: device)
mtkView.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
mtkView.colorPixelFormat = .bgra8Unorm
mtkView.autoresizingMask = [.width, .height]

guard let renderer = Renderer(view: mtkView) else { exit(1) }
mtkView.delegate = renderer

window.contentView = mtkView
window.title = "Hello Triangle — CG Roadmap 01"
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
app.run()
