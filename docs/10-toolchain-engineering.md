# 10 · 工具链与工程实践

> 从"会写 shader"到"能交付渲染器"的距离就在本章。面向资深工程师：调试武器化、资产管线化、渲染器架构化。

---

## 1. 调试武器库（Xcode 为主）

### 1.1 Xcode GPU Debugger（帧捕获）
- 捕获一帧 → 时间线逐 draw/pass 检查：管线状态（PSO 全量字段）、绑定的 buffer/纹理内容、顶点流预览、输出 RT 各通道。
- **Shader 调试**：片元/顶点逐线程单步、变量监视、对 divergent 线程分组；Metal shader 支持 `printf`（调试版）输出到控制台。
- 常见排障模式：
  - "模型消失"→ 深度/winding/culling 三连查；
  - "UV 错乱"→ 捕获看顶点插值与纹理内容；
  - "颜色发灰"→ sRGB 状态链检查（第 9 章）。

### 1.2 Metal 验证层
- `MTLDevice` API validation（越界绑定/状态冲突自动断言）；GPU 断言（`MTLGPUDebugSample`）标注区间。
- 崩溃调试：GPU crash 时 Xcode 显示 fault 时点；`MTLCommandBufferError` 回调收集；离屏/feedback loop 违规是高发原因。

### 1.3 通用方法论
- 二分法裁剪管线（注释 pass）；"调试视图"模式（albedo/normal/depth/heat 输出一键切换）；参考图对比（diff 模式找回归）。
- RenderDoc（概念迁移：Vulkan/D3D 上同款流程）。

---

## 2. 性能工程

- 工具：**Metal System Trace**（编码/提交/执行三段时间线，CPU-bound vs GPU-bound 归因）、GPU Counters（ALU/带宽/tile/占用率）、`os_signpost` 自定义打点。
- 建立性能基线：目标机矩阵（最低支持机型→最新 Pro）、自动抓帧回归（CI 里跑场景存 counters JSON，diff 报警）。
- 优化循环纪律：复现稳定场景 → 测量 → 归因假设 → 单变量修改 → 复测 → 记录结论（第 7 章方法论）。

---

## 3. Shader 工程化

### 3.1 编译与加载
- `.metal` 源码 → 离线编译 `metallib`（app 内运行时编译首帧卡顿大忌）；appthinning 多 GPU family 版本。
- **function constants**（Metal 特性）：shader 编译期常量特化（同一段代码生成多个变体）——uber shader 与性能的折中利器。

### 3.2 变体管理
- Permutation 爆炸问题（材质特性×光源类型×质量档）：宏组合 → 按需编译 + 缓存 + 预热关键集合；统计与裁剪变体是引擎必修课。
- Uber shader（动态分支）vs 特化变体（编译膨胀）的权衡表。

### 3.3 热重载（生产力倍增器）
- 文件监视 → 重编译 `.metallib` → 替换 PSO → 常量缓冲保持 → 帧内无缝切换。
- 进阶：参数即时调节（ImGui 风格调试面板直接写 uniform）——建议第 4 阶段就自建。

### 3.4 调试输出习惯
- `#define DEBUG_VIEW` 多视图切换；伪彩色热图（数值范围归一化）；`fragment_output` 结构多 target 分别检查。

---

## 4. 资产管线

### 4.1 格式选型
| 格式 | 定位 | 备注 |
|---|---|---|
| OBJ | 教学交换 | 无蒙皮/PBR，生产淘汰 |
| **glTF 2.0** | "3D 界的 JPEG" | PBR/蒙皮/动画/变形/KTX2+meshopt 压缩，运行时事实标准 |
| **USD** | 大规模协作/影视 | 分层组合（LIVRPS 强序）、variant；Apple 生态力推（USDZ/AR/QuickLook）|
| FBX | DCC 交换（封闭） | 商业 SDK，历史悠久 |

- glTF 关键扩展：`KHR_texture_transform`、`EXT_meshopt_compression`、`KHR_materials_*`（PBR 扩展族，见 03 章）。
- USD 组合弧（局部强度序）：**L**ocal → **I**nherits → **V**ariantSets → **R**eferences → **P**ayloads → **S**pecializes——理解后才能读 Pixar/Apple 管线。

### 4.2 Apple 工具
- **Model I/O**：导入（OBJ/USD/ABC）→ 生成法线/切线/包围盒；`MDLAsset ↔ MTKMesh` 转 GPU 网格。
- 资产目录纹理 ASTC 压缩（离线烘焙 mipmap/sRGB 标注/Xcode 自动处理）。
- 离线工具链自建建议：Python（trimesh/assimp 绑定）做网格处理 → 导出自定义二进制；版本化资产（DCC 文件 + 导出脚本同库）。

### 4.3 运行时加载
- 异步加载（专用队列 + fence）；缓冲区 ping-pong 防止加载尖峰；LOD/流式（远处低模）。
- 几何后处理入口：mikktspace 切线、顶点压缩、索引重排（05 章）。

---

## 5. 渲染器架构（从 demo 到引擎）

### 5.1 分层
```
平台层(Metal/窗口/输入) ─► RHI 抽象 ─► 渲染器(pass/材质/光照)
                             ▲
场景/ECS ─► 剔除/LOD ─► 可见集 ─┘
```
- RHI 抽象参考：bgfx（多后端）、Filament（质量标杆）、wgpu（Rust 现代设计）——**读源码学接口切分**。
- ECS（实体-组件-系统）：渲染对象=组件（Transform/Mesh/Material/Light），系统=剔除/排序/提交；DOD 数据布局对缓存友好。

### 5.2 Frame Graph / Render Graph（现代引擎标配概念）
- 声明式：各 pass 声明读/写资源 → 图自动推导执行序、屏障、瞬态资源分配与复用。
- 价值：新增 pass 不再手写同步/内存管理；带宽可视化。
- Metal 对应：pass 描述 + `MTLHeap` 瞬态分配实践。

### 5.3 每帧骨架
```
采集输入/模拟 → 提取渲染状态(snapshot) → 剔除(GPU-driven 可选)
→ 编码 passes(多线程) → 提交 → 呈现(present, 帧节奏控制)
```
- 资源更新三缓冲/环形分配器；常量缓冲池（每 draw 一段 sub-allocation）。

### 5.4 多线程与同步
- 并行编码（每 worker 一 `MTLCommandBuffer`，按序 commit）；资源上传流（staging buffer + blit）；
- fence/event 控 GPU-GPU 依赖；CPU-GPU 用信号量限流（在飞帧数上限）。

### 5.5 质量工程
- GPU 截图金样本测试（CI 回归）；固定 seed 的确定性渲染；feature 宏矩阵冒烟；
- 崩溃上报带帧捕获附件（内部构建）；设备farm 真机 perf 数据（发热/降频曲线）。

---

## 6. Metal 特性路线图（版本/家族速查）

- GPU Family：`MTLGPUFamilyAppleN`（iOS）/ `Mac2`；`supportsFamily:` 运行时探测，功能降级路径。
- 关键节点：**Raster Order Groups（A11/Apple4）**；Argument Buffers Tier 2（较新 A 系列）；**Metal 3（2022）**：mesh shader、MetalFX、光追 API 统一、动态库、更快的 PSO 创建。
- API 差异提醒（相对 GL/D3D 心智）：无隐式状态、资源+PSO 显式、`[[attribute]]` 语义标注、NDC/viewport 差异（02 章）。

---

## 7. 自测清单

- [ ] 用 GPU Debugger 定位一次 UV 错乱并截图说明证据链
- [ ] 搭好 metallib 离线编译 + 热重载工作流
- [ ] 实现 glTF 加载器（含 PBR 材质与蒙皮）
- [ ] 设计 3 层渲染器架构图（平台/RHI/渲染器）并说明依赖方向
- [ ] 写一个 50 行的 mini frame graph（两 pass 自动插屏障）
- [ ] 建立每帧 GPU 计时面板 + 热状态监控

---

# 扩展篇：迷你 Frame Graph 与热重载实现

## A. 50 行 mini render graph（概念验证级）

```cpp
struct Pass {
    std::string name;
    std::vector<ResourceHandle> reads, writes;
    std::function<void(Encoder&)> execute;
};

class FrameGraph {
    std::vector<Pass> passes_;
    std::map<ResourceHandle, PassId> lastWriter_;      // 资源 → 最后写它的 pass
public:
    ResourceHandle addPass(std::string name,
                           std::vector<ResourceHandle> reads,
                           std::vector<ResourceHandle> writes,
                           std::function<void(Encoder&)> fn) {
        // 1) 自动插依赖: reads 依赖 lastWriter_[r]
        auto id = passes_.size();
        for (auto r : reads)
            if (lastWriter_.count(r)) passes_[lastWriter_[r]].successors.push(id);
        for (auto w : writes) lastWriter_[w] = id;      // WAR 依赖: 覆写前等读者
        passes_.push_back({name, reads, writes, fn});
        return {};
    }
    // 2) 拓扑排序(或按声明序) → 逐 pass 执行
    // 3) 附加能力(生产版必备):
    //    - 引用计数: 资源无人再读 → 提前回收/复用内存(MTLHeap aliasing)
    //    - pass 裁剪: 输出不可达的 pass 自动剔除(改开关不用改代码)
    //    - 时序翻转: 把后处理全并成单 pass(Metal: 一个 encoder 多 dispatch)
    void execute(Encoder &e) {
        for (auto &p : passes_) { beginPass(p); p.execute(e); endPass(p); }
    }
};
// 价值: 新增 pass = 声明读写, 不写一行同步代码; 参考 Filament 的 fg 与 UE RDG 的工程级实现
```

## B. Shader 热重载最小实现（Metal）

```cpp
// 文件监视 (DispatchSource / FSEvents):
auto src = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd, 0, queue);
dispatch_source_set_event_handler(src, ^{
    // 1) 重新编译: xcrun metal -c shader.metal -o shader.air
    //                  metallib 从 .air 链接 (NSTask 调用, 或 libmetal 异步)
    // 2) 重建 PSO: newLibrary → newRenderPipelineState
    // 3) 原子换指针: pso = std::atomic_exchange(&pso_, newPso)
    // 4) 旧 PSO 延迟释放 (等在飞帧的 command buffer 完成, 用 addCompletedHandler 计数)
});
dispatch_resume(src);
// 常量/纹理绑定不动 → 帧内无缝换 shader; 参数调试面板(IMGui 类)直改 uniform buffer
// 生产力: 改一行 shader 0.2s 见效 vs 完整重启 30s+ —— 调色阶段效率 10×
```

## C. 帧捕获自动化（CI 回归）

```bash
# Xcode 命令行触发 GPU 帧捕获 (或用 XCTest + MTLGPUTrace):
xcrun xctrace record --template 'Game Performance' \
    --device --launch MyApp --output trace.trace --time-limit 30s
# 从 .trace 提取 GPU counters → JSON → 与基线 diff, 超阈值报 CI 失败
```
配套：固定 seed 演示模式（时间驱动改为帧号驱动，截图可重现）→ 金样本逐像素对比（容差 PSNR>40dB），渲染回归早于人工目测发现。

## D. 发布工程清单（Metal 特有）

- [ ] Release 去掉 API validation / shader printf / GPU 验证层
- [ ] PSO 预热：启动时后台队列编译全部变体（首帧不卡）
- [ ] metallib 随包压缩 + 按需资源（ODR）拆分
- [ ] GPU family 运行时探测 + 降级路径实测（最低支持机型矩阵）
- [ ] 热状态监控埋点（thermalState → 服务器聚合）→ 动态画质策略数据闭环
- [ ] `MTLCommandBufferError` 回调上报 + 对应帧 trace 附件（内部版）

## E. 习题与解答

**Q1：WAR hazard 在单队列上为什么仍可能出问题？**
A：GPU pass 间不保证完成顺序（尤其是 async compute 队列混用）；pass B 读资源 R、pass C 覆写 R，若 C 先执行 B 读到脏数据。单队列图形下驱动常隐式保证，但 compute+graphics 双队列必炸——frame graph 的价值就是把这类正确性从"驱动恩赐"变成"显式声明"。

**Q2：为什么热重载后必须延迟销毁旧 PSO？**
A：在飞 command buffer 仍持有旧 PSO 引用（Metal 对象生命周期由引用计数管理）；立即释放会触发 use-after-free 崩溃或验证层报警。用 `addCompletedHandler` 等上一帧完成计数归零再释放。

**Q3：金样本测试对 TAA/时序类算法失效怎么办？**
A：固定 jitter 序列与帧号驱动（时序算法的随机源全部替换为 frameIdx 的哈希），预热 N 帧后再截图；或对时序 pass 输出"首帧结果"做金样本（TAA resolve 的单步逻辑仍可测）。

**Q4：资产目录的 ASTC 纹理为何常比运行时小？**
A：Xcode 离线压缩可用慢速搜索（per-texture 块尺寸/质量试探）+ app thinning（设备家族拆变体）；运行时压缩（如有）只能用快速档。结论：**永远离线压缩，运行时只加载**。
