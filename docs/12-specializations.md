# 12 · 方向纵深与职业路径

> 12~18 个月后选择主攻方向。本章给出四条路线的完整知识地图 + 开源代码阅读路线 + 作品集策略。对 iOS 背景：**方向 C（Apple 图形专家）性价比最高、竞争最小**。

---

## 1. 方向 A：引擎与高级实时（天花板最高）

### 1.1 知识地图（GAMES104 主线）
- 引擎分层：平台层/RHI/核心（内存、作业系统 job system、ECS、数学库）/场景与资产/渲染/动画/物理/脚本/编辑器。
- **作业系统**：work-stealing 队列、依赖图、无锁结构——现代引擎的心脏；帧内流水线并行（模拟/动画/剔除/编码重叠）。
- 物理入门：刚体积分（半隐式欧拉）、碰撞检测宽相（BVH/SAP）/窄相（GJK/EPA）、约束求解（ impulses/Sequential Impulse）；布料/PBD 位置动力学概念。

### 1.2 UE5 源码阅读路线（渲染模块）
- 入口：`FDeferredShadingRenderer::Render`（帧全景）→ 各 pass（PrePass/BasePass/Lighting/PostProcessing）；RHI 抽象层接口切分；RDG（render graph）实现；shader permutation 系统；Nanite/VSM/Lumen 专题文章对照源码。
- 前置：自研 mini-engine 走到阶段 5 再读，否则只见树木。

### 1.3 实践阶梯
- mini engine：ECS + job + frame graph + 前向管线 + 热重载 → 逐步加（阴影/GI/粒子）→ 开源发布（找工作硬通货）。

---

## 2. 方向 B：离线与物理正确渲染

- 主线：PBRT 精读 + 自写渲染器（第 6 章路线）→ 生产渲染器参考：**Cycles**（Blender，代码可读）/ Arnold（统一采样）/ RenderMan；研究向：SIGGRAPH 论文复现（_specular manifold sampling / manifold next event estimation_ 类选题入门）。
- 论文工作流：三遍阅读法（扫结构→精读方法→复现验证）；复现 repo 即简历。
- 就业面：影视动画/工业仿真/照片级广告渲染；与实时融合处（光线重建、MC 降噪）最活跃。

---

## 3. 方向 C：Apple 平台图形专家（推荐主打）

### 3.1 深耕清单
- Metal 深水区特性逐一实战：Argument Buffers、Raster Order Groups（OIT/可编程混合）、imageblock/tile shader、memoryless、sparse texture、MetalFX、Metal RT、mesh shader——每项做 micro-benchmark + 博客。
- 生态互通：**Core Animation + Metal**（`CAMetalLayer`/drawable/与 UI 合成、EDR 元数据）、**Core Image 自定义 kernel** 互操作、**Core ML ↔ Metal**（自定义算子/推理后处理）、Vision 接入。
- ARKit 全栈：session/anchor/平面检测/场景重建/LiDAR 深度 → 自研 Metal 渲染器集成；RealityKit 边界（何时该自绘）；**Object Capture**（拍照建模→USDZ）；RoomPlan。
- visionOS：CompositorService/空间渲染（双目、注视点渲染 foveation、深度安全区）——新平台红利期。

### 3.2 差异化壁垒
- TBDR 优化方法论 + 全系芯片 perf 数据积累（A/M 家族矩阵）+ 热设计（长期性能 release）——内容：移植/优化顾问、3A 手游客户端图形、Apple 生态工具链。

---

## 4. 方向 D：3D 视觉 × 神经渲染（最热交叉）

- 基础：相机模型与标定（Zhang）、对极几何/立体匹配、SfM（COLMAP 流程：特征匹配→增量重建→稠密）。
- NeRF/3DGS 实操：自己采集（环绕视频→COLMAP→训练 3DGS→导出）；Metal/第三方 viewer 集成到 iOS（object capture + 3DGS 混合展示）。
- 进阶课题：可微渲染（nvdiffrast 概念）、SLAM 与 3DGS 融合、生成式 3D（文生 3D 资产管线）。
- 与 AR 结合：真实感混合渲染（光照估计→环境贴图→虚拟物体 PBR/阴影）。

---

## 5. 通用修炼

### 5.1 论文与情报
- 三大源：SIGGRAPH（技术）/ GDC（工程）/ SIGGRAPH Asia Course；图形学论文 arXiv 跟踪（cs.GR）；关键团队博客（Activision/UE/Frostbite/Self-Shadow/Unity Research）。
- 中文社区：GAMES 系列课程与 Webinar、知乎图形学专栏、公众号（"图形学小课堂"类按需甄别）。

### 5.2 代码阅读阶梯（由浅入深）
1. **raytracing.github.io** 系列（<5k 行）→ 2. **Filament**（架构+PBR 文档双绝）→ 3. **bgfx/wgpu**（RHI 抽象）→ 4. **Bevy/O3DE/UE5**（引擎级）。
- 阅读法：带着问题读（"它怎么管理 pass 依赖？"），输出文档/博客才是读进去了。

### 5.3 作品集策略
- 一个**有辨识度的渲染 demo**（技术点明确：如"Metal3 mesh shader + GPU culling 移动端万人同屏"）胜过十个教程复刻。
- 技术博客（中英双语更佳）：实现细节+benchmark 数据+踩坑记录——资深工程师转图形岗的核心敲门砖。
- GitHub 指标不重要，**README 里的 GIF/视频 + 性能表**才重要。

### 5.4 面试知识热点（图形岗）
- 必考：渲染管线全图、PBR 推导、阴影方案、TAA 原理、带宽优化、TBDR/IMR 差异、矩阵/四元数手推。
- 编码：手写 MVP 变换/光栅化器、GGX shader、AABB-BVH 遍历。
- 系统设计：设计移动端多光源管线/后处理链/阴影系统——用第 10 章架构语言回答。

---

## 6. 里程碑总表（对照打卡）

| 时间 | 里程碑 | 证据物 |
|---|---|---|
| 3 个月 | GAMES101 作业全完成 + 软光栅 + 路径追踪 | 两张渲染图 + repo |
| 6 个月 | Metal PBR Viewer（IBL/阴影/后处理/热重载）| demo 视频 + 性能面板 |
| 9 个月 | 小引擎雏形（frame graph/GPU 剔除/TAA）| 博文系列 |
| 12 个月 | 高级特性（GI/RT/超分）+ 选定方向 | 方向深耕地基 |
| 18 个月 | 方向代表作 + 社区输出 | 作品集 + 面试筹码 |

---

## 7. 自测清单

- [ ] 选定方向并写明理由与第一年深耕地基（3 个特性/课题）
- [ ] 完成 Filament 一个子系统（如后处理链）的阅读笔记
- [ ] 产出第一篇技术博客（含 benchmark 数据）
- [ ] 建立 3 台以上真机 perf 矩阵与优化案例库

---

# 扩展篇：源码地图、面试题库与作品集方案

## A. UE5 渲染模块源码阅读地图（含真实路径）

```
Engine/Source/Runtime/Renderer/Private/
├─ SceneRendering.cpp          ★ 入口: FSceneRenderer::Render → FDeferredShadingSceneRenderer::Render
│                                 帧全景 (InitViews/PrePass/BasePass/Lighting/PostProcessing)
├─ BasePassRendering.cpp       GBuffer 写入 (visBuffer 路线在此分叉)
├─ ShadowRendering.cpp         CSF/CSM/PerObject/远场 VSM 调度
├─ LightRendering.cpp          延迟光照 + 阴影采样组合
├─ PostProcess/                TAA(TemporalAA.pp)/Bloom/Tonemap/SSR/GTAO
├─ Nanite/                     ★ 集群管线/软件光栅/vis buffer
└─ System/NaniteResources.cpp  构建期数据处理
Engine/Source/Runtime/RenderCore/Private/RenderGraph*   ★ RDG (frame graph 工业实现)
Engine/Shaders/Private/         全部 .usf (BasePassPixelShader.usf / Nanite/*.usf / RayTracing/)
Engine/Source/Runtime/RHI/ + MetalRHI/                  抽象层与 Metal 后端
```
**六步阅读法**：①SceneRendering 主流程画时序图 ②追一个 draw call 从数据到 PSO ③RDG 的 pass 声明→barrier 推导 ④TAA shader 逐行 ⑤Nanite 官方课程(SIGGRAPH 2021)对照源码 ⑥换 RHI 后端跑通 Metal——每步输出一篇笔记。

## B. Filament 源码阅读地图

```
filament/src/
├─ fg/            ★ FrameGraph 实现 (比 UE RDG 小 20 倍, 教材级)
├─ Renderer.cpp / RenderPass.cpp / Engine.cpp   帧组织与 pass 排序
├─ materials/     Lit 材质编译与参数布局 (PBR 实现与文档 1:1 对应)
├─ details/       FRenderer 内部状态机
└─ backend/       Metal/OpenGL/Vulkan 三后端 (RHI 抽象的活样板)
docs/Filament.md.html   ★ PBR 理论权威文档, 读完代码再读一遍全通
```
建议顺序：backend 接口 → fg → Renderer 帧循环 → materials。两周可通读核心，是"渲染器架构"性价比最高的阅读对象。

## C. 图形岗深水区面试题（附答题骨架）

1. **"从手指触摸到像素发光，描述一帧的完整旅程"**——CADisplayLink→驱动模拟→渲染提取→剔除→编码→提交→TBDR binning/光栅→display 合成。考全局视野，按时间线讲。
2. **"iOS 上 1000 个动态点光怎么设计管线？"**——clustered 前向（3D 网格分桶 + compute 建列表）+ 分辨率降级 + 累积方案；对比 deferred 在 TBDR 的带宽劣势。
3. **"TAA 对半透明物体怎么处理？"**——半透明无法写深度→velocity 缺失；方案：velocity 外推、alpha 加权历史、超采样 dither、粒子单独关闭 TAA 用超高采样。
4. **"给这台手机算一笔带宽账"**——现场用 bpp×分辨率×pass 数×频率估算（02 章公式），再谈 load/store 优化与 tile 内存。
5. **"阴影方案选型：开放世界白天+室内+角色特写"**——CSM(远)+ PerObject 贴花阴影(近) + capsule AO(角色) + 烘焙静态阴影(室内)，讲切换与融合。
6. **"GPU 和 CPU 同时 12ms 但仍 40fps，为什么？"**——提交/等待气泡、验证层、单缓冲 vs 多缓冲、present 阻塞；用 Metal System Trace 的间隙说话。
7. **"fp16 化一个 shader 的完整流程与风险"**——counters 判瓶颈→varying/color 降半→位置矩阵保 float→精度断言(半分辨率的色差)→收益回归。
8. **"半透明玻璃杯要：折射+反射+色散+焦散，移动端怎么取舍"**——分层：抓屏折射(1 次 sample)+菲涅尔反射(SSR/探针)+色散(三通道 UV 偏移)+焦散贴图动画；解释物理正确方案(RT+BDPT)为何不可行。
9. **"OIT 有哪些方案？Apple 上你选哪个？"**——深度剥洋葱/WBOIT/Moment-based/**Raster Order Group 可编程混合**（主场差异点）。
10. **"偶发掉帧（1/300 帧）如何定位？"**——in-flight 标记、内存分配尖峰、驱动 shader 编译、后台任务抢占；方法：长时间 trace + 分桶统计而不是看单帧。

答题通则：**先问约束（平台/预算/风格），再给方案树，最后给取舍数据**——区分"背过"与"做过"的就是这三步。

## D. 作品集三个提案（按差异化排序）

**P1 · 移动端万人同屏（Metal 3 GPU-Driven）**
- 内容：50 万实例城市场景，object/mesh shader + hi-Z 遮挡剔除 + cluster 剔除 + indirect draw + MetalFX。
- 亮点指标：A15 上 60fps、CPU 提交 <1ms、剔除前后 draw 数对比图。
- 讲述点：GPU-driven 数据流闭环（07/11 章）真机复现。

**P2 · TBDR Deferred 探索（imageblock GBuffer）**
- 内容：同一场景 forward / forward+ / imageblock-deferred 三管线实现 + 真机 counters 对比（带宽/ALU/耗电）。
- 亮点价值：全网稀缺的 Apple 平台 deferred 正确姿势数据，博客系列自带流量。
- 讲述点：把 02/07 章的"教科书结论"用数据检验——工程品味证明。

**P3 · 3DGS Viewer for iOS**
- 内容：手机环绕拍摄 → COLMAP → 3DGS 训练 → 自写 Metal splat 渲染器（排序/混合/抗锯齿）→ ARKit 放置。
- 亮点趋势：2023+ 最热方向 + 完整"采集到渲染"闭环，展示学习速度。
- 讲述点：每步都有现成工具，但串起来并优化到移动端 60fps 就是稀缺能力。

公共要求：每个项目 README 首屏放 GIF + 性能表；附 2~3 篇技术博文；代码有最小构建说明（clone 即跑）。

## E. 论文三遍法 + 各方向必读清单

**三遍法**：一遍 5 分钟（图表/结论，判断相关性）→ 二遍 1 小时（方法链路，复述给同事）→ 三遍半天（推导复算 + 最小复现）。**三遍通过才进 Zotero 收藏**，否则只是"读过"。

| 方向 | 必读（年份/作者） |
|---|---|
| 实时渲染 | Karis UE4 PBR (2013)；Heitz 微表面遮蔽综述 (2014)；Jimenez 时序 AA (2014)；Schneider 地平线体积云 (2017)；Heitz VNDF 采样 (2018)；Bitterli ReSTIR (2020) |
| 离线渲染 | Kajiya 渲染方程 (1986)；Veach 博士论文 (1997, MIS/BDPT/MLT 圣经)；Georgiev 联合重要性采样 (2012)；Müller SoA 路径引导 (2017) |
| 硬件光追 | Wyman 入门综述 (2018)；Mara ReSTIR GI 系应用；Burnes "Ray Tracing in Games" GDC 系列 |
| 神经渲染 | Mildenhall NeRF (2020)；Müller Instant-NGP (2022)；Kerbl 3DGS (2023)；Chen Mip-Splatting (2023) |
| Apple 平台 | WWDC Metal Track 每年精选；Feral Interactive 的 Apple 移植 GDC Talk（TBDR 优化一手经验）|

## F. 72 周执行模板（18 个月对照）

```
W01-04   数学 + GAMES101 前半        W05-10  GAMES101 作业全部 + 提高
W11-14   软光栅器(tinyrenderer 级)    W15-20  路径追踪三部曲
W21-32   Metal PBR Viewer(阶段4)     W33-40  阴影/后处理/TAA + 小引擎骨架
W41-52   frame graph/GPU-driven(阶段5) W53-64  GI/RT/超分 + 选定方向
W65-72   方向代表作打磨 + 博客 3 篇 + 面试准备
```
规则：每个 W 段以"可运行产物 + 一篇笔记"双验收；连续两周无产物 → 回退到上一个完成点重排计划（防"教程地狱"）。
