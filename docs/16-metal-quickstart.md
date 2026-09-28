# 16 · Metal 实战快速起步：从零到 PBR 的分步手册

> 全书唯一"手把手"章节：把 02 章的管线理论接到 Xcode 真机。目标：一个下午从空工程跑到带贴图的旋转模型。Swift + MTKView（macOS/iOS 代码几乎一致，差异处标注）。

---

## Step 0：工程骨架（10 分钟）

1. Xcode 新建 App（iOS 或 macOS），**不勾 Storyboard 依赖也行**——我们代码创建 `MTKView`。
2. `import MetalKit`；新建 `Renderer.swift` 与 `Shaders.metal`（.metal 文件随包编译成 `default.metallib`，运行时 `makeDefaultLibrary()` 取回）。
3. 视图接入（iOS 示例，macOS 把 ViewController 换成 NSViewController 即可）：

```swift
final class GameViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
        view.depthStencilPixelFormat = .depth32Float          // 深度缓冲(02章§7)
        view.clearDepth = 1.0                                  // reversed-z 时不相同
        view.delegate = Renderer(view: view)!
        self.view = view
    }
}
```

**第一坑预警**：`makeDefaultLibrary()` 返回 nil → Build Settings 确认 `.metal` 文件在 Target Membership 里；多 target 工程常漏。

---

## Step 1：三角形（管线全对象跑通）

### Renderer：四个长生命周期对象 + 帧循环

```swift
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipeline: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!

    init?(view: MTKView) {
        device = view.device!; queue = device.makeCommandQueue()!
        guard let lib = device.makeDefaultLibrary(),
              let vs = lib.makeFunction(name: "vertMain"),
              let fs = lib.makeFunction(name: "fragMain") else { return nil }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vs; pd.fragmentFunction = fs
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pd.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: pd)   // 10章: PSO 预编译

        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: dd)
        return nil // 占位错误——真实代码见仓库版
    }

    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: desc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)          // 与 vsync 对齐(15章 drawable 语义)
        cb.commit()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
```

### Shaders.metal

```cpp
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float4 color; };

vertex VOut vertMain(uint vid [[vertex_id]]) {
    const float4 v[3] = { float4(-0.7, -0.5, 0.0, 1),
                          float4( 0.7, -0.5, 0.0, 1),
                          float4( 0.0,  0.7, 0.0, 1) };
    VOut o; o.pos = v[vid];
    o.color = float4(v[vid].xy + 0.5, 0.5, 1);
    return o;
}
fragment float4 fragMain(VOut in [[stage_in]]) { return in.color; }
```

**跑到这你就完成了**：设备/队列/库/PSO/命令缓冲/编码器/呈现——02 章管线全景的每个 API 对象都摸过一遍。

**第二坑预警**：颜色"发灰/过亮" → pixelFormat 是 `_sRGB` 后缀而 shader 输出了线性值（09 章）；Metal NDC y 向下，若三角倒置先想坐标系（01 章 §3.2）。

---

## Step 2：顶点缓冲 + MVP uniform（数据驱动渲染）

```swift
// 顶点结构 (stride 与 shader 的 [[stage_in]] 描述一致)
struct Vertex { var pos: SIMD3<Float>; var uv: SIMD2<Float>; var color: SIMD4<Float> }
var vertices: [Vertex] = [ ... 3~N 个 ... ]
let vbuf = device.makeBuffer(bytes: &vertices, length: MemoryLayout<Vertex>.stride * count)!

// 每帧 uniform: 三个矩阵 + 时间 (按 256 字节对齐, 常量缓冲惯例)
struct Uniforms { var mvp: simd_float4x4; var model: simd_float4x4; var time: Float }
var uni = Uniforms(...)
cb/enc 路径: enc.setVertexBuffer(vbuf, offset: 0, index: 0)
             enc.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 1)
```

```cpp
struct VIn { float3 pos [[attribute(0)]]; float2 uv [[attribute(1)]];
             float4 color [[attribute(2)]]; };
vertex VOut vertMain(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]]) {
    VOut o;
    o.pos = u.mvp * float4(in.pos, 1);     // 01 章: 裁剪空间输出
    ...
}
```

矩阵生成直接用 01 章扩展篇的 `perspectiveMetal` / `lookAt`（simd 自带 `matrix_perspective_right_hand` 等工具函数亦可，但**自己推一遍再对照**，学习价值完全不同）。

---

## Step 3：Model I/O 加载 OBJ/glTF（告别手工三角形）

```swift
import ModelIO

let asset = MDLAsset(url: bundleURL("bunny", "obj"))
guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { return }
mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal,
                creaseThreshold: 0.6)                    // 无法线时生成(05章)
let mtkMesh = try MTKMesh(mesh: mesh, device: device)
// 渲染: vertexDescriptor 直接给 pd.vertexDescriptors
// enc.setVertexBuffer(mtkMesh.vertexBuffers[0].buffer, ...)
// 子网格逐个: submesh.indexBuffer + .indexType + drawIndexedPrimitives
```
注意：OBJ 无切线 → 法线贴图前用 mikktspace 生成（05 章）；glTF 的 Y-Up/单位与 Metal 坐标习惯差异。

---

## Step 4：纹理与采样器

```swift
let tex = try textureLoader.newTexture(name: "albedo", extension: "jpg",
        options: [.SRGB: true, .generateMipmaps: true])   // 04/09 章: sRGB 标注+mip
// shader:
//   texture2d<float> albedo [[texture(0)]];
//   sampler s [[sampler(0)]];  albedo.sample(s, in.uv)
```
工程纪律即刻建立：albedo 标 sRGB、法线/粗糙度 linear（09 章排障表）。

---

## Step 5：光与材质（接 03 章）

到这一步你已有：矩阵、网格、纹理、深度。把 03 章扩展篇 A 的完整 PBR shader 整段拷进 `Shaders.metal`，替换 uniform 结构（lights 数组 + camPos + IBL 两张纹理）——**恭喜，阶段 4 的里程碑 demo 已具雏形**。之后按 10 章扩展篇加热重载，迭代效率立刻 10×。

---

## 第一周路线（配合作业）

```
Day1  Step0-1 三角形+彩色        验收: 改顶点/颜色立见
Day2  Step2 MVP+旋转            验收: 手推矩阵, vs 手写 perspectiveMetal
Day3  Step3 bunny.obj           验收: 深度正确, 网格线模式调试
Day4  Step4 纹理                 验收: sRGB 正反对照截图
Day5  Step5 Blinn-Phong         验收: 三点布光一盏盏开
Day6-7 接 03 章 GGX 直接光       验收: 白炉测试跑通
```

## 高频坑速查

| 症状 | 原因 | 章节 |
|---|---|---|
| makeDefaultLibrary nil | .metal 未入 target | 本页 |
| 模型消失 | winding/cull/深度初始值 | 02 |
| 三角形"倒的" | NDC y 方向误解 | 01 |
| 画面发灰 | sRGB 像素格式×线性输出 | 09 |
| 贴图闪烁 | mip 未生成 / aniso 未开 | 04 |
| 帧率掉一半 | drawableCount=2 且某帧超时 | 07/15 |
| 模拟器跑不了 | 模拟器 Metal 支持有限 → 真机 | — |
| **模型静默消失(仅剩地面)** | macOS 26 工具链 MTKMesh 顶点转换全零(实测回归) → 过程化网格绕行 | 11/14 |
| **满屏皆阴影** | ortho 两种 z 约定混用(正距离 vs view.z 负值边界), 重投影深度全图越界 | 11 |
| **近处错阴影/远处正常** | 阴影图采样 y 多翻了——写入与采样走同一套 ndc→行映射, 不需翻 | 11 |
| **地面大块缺失(见天空)** | 巨型三角形被驱动整片丢弃，两种触发：①顶点在相机后/近平面附近；②**顶点 NDC 超出保护带**(±40 大平面投到 NDC ±30+) → 收缩范围 + 细分瓦片 | 11/14 |
| **第一个 encoder 的输出被擦掉** | 同一 rpd 开第二个 encoder 时 loadAction 仍是 .clear → 改 .load | 12 |
| **天空穹顶噪点碎斑** | 相机在网格内部且未剔除朝外正面, 正反两面采样随机覆盖 | 12 |
| **shader 读到垃圾矩阵** | Uniforms 里放了 Swift Array(引用类型), setBytes 只拷 8 字节指针 → 平铺字段 | 11 |
| **片元读 obj/material 恒为零(字面黑)** | 只 setVertexBytes 没调 setFragmentBytes——**顶点/片元缓冲是两个独立名字空间** | 14 |
| **像素探针结论全错** | 纹理/RT 行序与屏幕坐标上下翻转(Metal NDC y 约定)→ 探针先验朝向 | 14 |
| **新增结构体字段后渲染全乱** | 手写缓冲字节数没跟 MemoryLayout.stride 走(SIMD 对齐使实际 stride > 直觉) | 17 |
| **billboard/splat 偏移看不见** | NDC 偏移加在透视除法前(clip 空间), 被 w 缩成亚像素 → 先除 w 再偏移 | 17 |
| **kernel 参数读垃圾(越界寻址)** | MSL 侧加了 buffer 参数但 draw() 忘了 setBytes——"在验证器里试过"≠"已入库" | 17 |
| **thread_position_in_threadgroup 未定义** | 它是参数属性 `[[...]]` 不是函数——须作为 kernel 参数传入 | 16 |
| **waitUntilCompleted 永久死等** | 忘了 cb.commit()——commit/wait 成对出现 | 16 |
| **metal 找不到** | CLT 无 Metal 工具链; Xcode 26 起为独立下载组件 | 各 build.sh |
| **混合属性编译错** | 新 SDK 改名 sourceRGBBlendFunction → *BlendFactor | 08 |
