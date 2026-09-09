# 18 · 毕业项目蓝图：Mini-Engine 设计书

> 把 17 章知识变成一个可执行工程。这是 12 章作品集 P1/P2 的设计文档：目标范围、架构、模块接口、里程碑验收标准全部落纸。资深工程师做图形项目的正确姿势：**先写设计书，再写代码**。

---

## 1. 目标与非目标

**目标（12~16 周业余时间）**
- Apple 平台（iOS/macOS 双 target）实时 PBR 渲染器 + 小型引擎骨架
- 50k+ 三角形 glTF 场景稳定 60fps（iPhone 12 级基线机）
- 热重载、调试视图、性能面板三件套齐备

**非目标（明确写进 README 防跑偏）**
- ❌ 跨平台 RHI（不做 Vulkan/D3D 后端——单 Metal 后端深挖比广撒网约值 10 倍）
- ❌ 脚本系统/编辑器 GUI（用代码+JSON 配场景）
- ❌ 网络 multiplayer、物理全家桶（只做 14 章的粒子/布料即可）

## 2. 技术选型

| 项 | 选型 | 理由 |
|---|---|---|
| 语言 | Swift（引擎）+ MSL（shader）| ARC/并发成熟；C++ 仅在需要贴 bgfx/Filament 时 |
| 数学 | simd（`simd_float4x4`）| 01 章代码直接复用 |
| 窗口 | MTKView | 16 章 |
| 资产 | glTF 2.0 + Model I/O 混合 | 10 章；skin/morph 需自写解析 |
| UI | 自绘 debug HUD（17 章 §11）| 不引第三方依赖，练习合批 |
| 依赖 | 零第三方 | 资深直觉：依赖越少，学到的越多 |

## 3. 目录结构（实际落纸版）

```
MiniEngine/
├─ App/                    // 入口、MTKView 装配、设置面板
├─ Core/
│  ├─ Math/                // 01 章扩展篇全部代码
│  ├─ Collections/         // RingAllocator(常量缓冲), HandleTable
│  └─ Jobs/                // actor 简版任务池(苹果 DispatchQueue 优先)
├─ RHI/                    // Metal 封装: Device/Buffer/Texture/Pipeline 的 handle 化
│  └─ Metal/               // 唯一后端(见非目标)
├─ Render/
│  ├─ FrameGraph/          // 10 章扩展篇 A 的生产化
│  ├─ Passes/              // DepthPre/Opaque/Skybox/Shadow/Post/*
│  ├─ Materials/           // 材质模板 + 变体管理
│  └─ Debug/               // 调试视图/热重载/性能面板
├─ Scene/                  // 场景图(变换层级) + RenderObject 提取
├─ Assets/                 // glTF 加载、纹理导入、缓存
├─ Sim/                    // 动画采样(08章) + 粒子/布料(14章)
└─ Tests/                  // 金样本截图 + 白炉测试 + counters CI
```

## 4. 核心数据结构（handle 化资源管理）

```swift
// 资源句柄: 世代计数防悬空(资深工程师的肌肉记忆)
struct Handle<T>: Hashable { let index: UInt32; let generation: UInt32 }

final class HandleTable<T> {
    private var slots: [Slot] = []      // generation + Optional<T>
    func create(_ v: T) -> Handle<T>    // 复用空槽, generation+1
    func resolve(_ h: Handle<T>) -> T?  // 世代不符 → nil (资源已释放)
    func destroy(_ h: Handle<T>)
}

// 渲染对象: 场景 → 渲染的提取快照(和模拟解耦)
struct RenderObject {
    var mesh: Handle<Mesh>
    var material: Handle<Material>
    var transform: simd_float4x4
    var prevTransform: simd_float4x4    // TAA motion vector 用(11章)
    var flags: RenderFlags              // castShadow/receivesShadow/...
}

// 材质: 模板 + 参数块(变体爆炸的解药, 10 章 §3.2)
struct MaterialTemplate { let shader: Handle<ShaderVariant>; let layout: UniformLayout }
final class Material { let template: Handle<MaterialTemplate>; var params: [Float] /*...*/ }
```

## 5. 帧流程（固定骨架，所有功能往里挂）

```
1 update(dt)          模拟: 动画/物理/相机 —— 固定步长(14章)
2 extract()           Scene → [RenderObject] 快照, 无锁读取
3 cull()              视锥剔除(CPU 起步) → GPU-driven(里程碑 M5 升级)
4 sort()              不透明 near→far + 按材质 PSO/纹理分桶; 透明 far→near
5 encode()            frameGraph.execute(): 声明式 pass 依序编码(多线程按 pass 分)
6 submit+present      双/三缓冲 ring, drawable 呈现
```

## 6. 里程碑与验收（对应 12 章 72 周表）

| 里程碑 | 内容 | 验收标准（量化）|
|---|---|---|
| M0 (W1-2) | 16 章全部 + Ring 常量缓冲 | bunny 贴图旋转 60fps，CPU 提交 <2ms |
| M1 (W3-4) | 场景图 + 多物体 + 排序 | 1000 实例（instancing）<3ms GPU |
| M2 (W5-7) | 材质系统 + 03 章 PBR/IBL | 白炉测试通过（亮度曲线 CI 化）|
| M3 (W8-10) | frame graph + 阴影 + 后处理链 | CSM+PCSS+bloom+ACES 截图对比集 |
| M4 (W11-12) | 热重载 + 调试视图 + 性能面板 | 改 shader <0.5s 生效；计数器实时刷新 |
| M5 (W13-14) | GPU-driven 剔除 + TAA/MetalFX | 50k 实例场景 draw 数 <100；无可见闪跳 |
| M6 (W15-16) | 动画蒙皮 + 粒子 + 打磨 | 带骨骼动画角色 + 10w GPU 粒子；博客一篇 |

## 7. 质量工程（资深差异化所在）

- **金样本 CI**：固定 seed 场景每 PR 截图比对（PSNR>40dB），渲染回归零人工。
- **计数器基线**：每里程碑存 JSON（GPU ms/带宽/ALU），性能退化 >10% 阻断合并。
- **白炉/棋盘测试**常驻单元测试——03/06 章两套"物理正确性"考卷。
- **取舍记录**：`DECISIONS.md` 记每个架构决策的备选与理由（例如"为什么 TAA 放 M5 而非 M3"）——面试时这份文件比代码更能证明工程成熟度。

## 8. 风险与预案

| 风险 | 信号 | 预案 |
|---|---|---|
| 范围蔓延 | 里程碑延期 2 周+ | 回非目标清单砍功能，先验收再扩展 |
| TBDR 陷阱 | 计数器带宽异常 | 回 07 章 load/store 纪律逐 pass 审计 |
| shader 变体爆炸 | metallib 体积失控 | 回 10 章 §3.2：function constants 归并 |
| 动力衰减 | 连续两周无产物 | 回 12 章 72 周规则：回退上一个完成点重排 |
