# 计算机图形学学习路线图（面向资深 iOS 开发者）

> 目标读者：具备多年 iOS 开发经验，掌握 C/C++/Objective-C/Swift，熟悉 Xcode 工具链与 Apple 生态，希望系统入门并深入图形学开发。
> 总体周期：快速入门约 3 个月，达到深度开发能力约 12~18 个月（按每天 1~2 小时 + 周末投入估算）。

---

## 一、先说结论：你的优势与核心策略

### 1.1 你已经拥有的资产

| 已有经验 | 图形学中的对应物 |
|---|---|
| C/C++ | 图形学事实标准语言（引擎、渲染器、SDK 全是 C++）|
| Metal / API 使用经验 | 唯一需要补的是"管线思维"而非 API 本身 |
| Core Animation | 合成器原理、变换矩阵、display link 渲染循环 |
| Core Image / vImage | GPU 图像处理管线、滤镜链 |
| Instruments 调优 | GPU profiling、性能分析方法论直接复用 |
| 移动端硬件直觉 | 理解移动 GPU（TBDR 架构）的最佳起点 |
| 读源码/读大型工程的能力 | Filament、bgfx、UE 源码阅读毫无障碍 |

### 1.2 核心策略

1. **以 Metal 为主战场**，不要绕道 OpenGL/DirectX 再回来。概念完全可迁移，而 Metal 是你唯一能在 iPhone/Mac 上原生施展的 API，且 Apple Silicon GPU（TBDR）本身就是值得深挖的领域。
2. **用 GAMES101 建立体系**，而不是碎片化看教程。体系感是"会图形学"和"会抄 shader"的分水岭。
3. **数学按需学、并行学**。不要先啃完一本线性代数再开始，而是在写渲染器的过程中缺什么补什么。
4. **每个阶段以"写出可运行的产物"为唯一验收标准**。图形学是极端实践导向的学科，看懂 ≠ 会。
5. **手写一遍软件光栅器和光线追踪器**。绕过 GPU 直接操作像素，是建立"像素从哪来"心智模型的最快路径，也是所有顶级课程（CMU 15-462 等）的共识。

---

## 二、路径总览

```
阶段0 环境准备 ──► 阶段1 数学基础 ──► 阶段2 渲染体系(GAMES101)
 (1 周)             (2~4 周,并行)        (6~8 周)
                                             │
                                             ▼
                    阶段3 软件渲染器 + 光线追踪 (4~6 周)
                                             │
                                             ▼
                    阶段4 Metal 实时渲染实战 (8~12 周)   ←── 主战场
                                             │
                                             ▼
                    阶段5 高级实时渲染 (3~6 个月)
                                             │
                                             ▼
                    阶段6 方向分化 (长期：引擎/离线渲染/移动专家/3D 视觉)
```

---

## 三、分阶段详解

### 阶段 0：环境与心态（1 周）

- 工具：Xcode（Metal 模板 + GPU Debugger）、[RenderDoc](https://renderdoc.org/)（Mac 上可调试 Vulkan，也可远程调试）、笔记系统。
- 建立信息源：GAMES101 课程页、learnopengl-cn、ShaderToy、ACM SIGGRAPH / GDC 演讲目录。
- 心态：图形学知识树庞大，但主干清晰（渲染方程 + 光栅管线 + 光线传播），按本路线走不会迷路。

### 阶段 1：图形学数学（2~4 周，与阶段 2 并行）

只学图形学用到的子集，目标是对以下内容形成直觉而非会证明：

- **向量**：点积（投影/夹角/光照）、叉积（法线/定向）、归一化。
- **矩阵**：仿射变换、旋转（欧拉角/轴角）、**MVP 变换链**（Model→View→Projection→Viewport）、法线矩阵（为什么用逆转置）。
- **四元数**：球面插值 slerp、万向锁问题。
- **微积分速成**：导数与梯度（用于抗锯齿、法线贴图推导）、定积分（渲染方程是积分）。
- **概率论基础**：随机变量、期望、蒙特卡洛积分（现代渲染的地基，阶段 3 会用到）。

资源：
- 3Blue1Brown《线性代数的本质》（B 站有官方翻译，先看，建立几何直觉）
- GAMES101 前 4 讲（就是按上面提纲讲的）
- 工具书（按需查阅，不通读）：《Mathematics for 3D Game Programming and Interactive Graphics》(Lengyel)

### 阶段 2：渲染体系建立 —— GAMES101（6~8 周）

跟完闫令琪 [GAMES101](https://www.bilibili.com/video/BV1X7411F744)（现代计算机图形学入门）全部课程 + 全部作业。这是中文世界质量最高的入门课，没有之一。

必须吃透的概念清单：

- **渲染管线全景**：顶点变换 → 图元装配 → 光栅化 → 片元着色 → 输出合并（深度/模板/混合）。每一步的输入输出要能白板画出来。
- **变换与坐标系**：世界/相机/裁剪/NDC/屏幕空间，透视投影矩阵推导，齐次坐标的意义。
- **光栅化**：三角形覆盖判断、重心坐标插值、透视校正插值（为什么屏幕空间线性插值是错的）。
- **深度与抗锯齿**：z-buffer 原理与非线性深度、MSAA/超采样/FXAA/TAA 对比。
- **纹理**：UV、双线性/三线性采样、mipmap、纹理放大缩小的处理。
- **光照**：Blinn-Phong 模型（ambient/diffuse/specular）、着色频率（flat/gouraud/phong shading）。
- **几何**：曲线曲面基础（Bezier、B 样条）、细分曲面概念、阴影映射（shadow map）入门。
- **光线追踪引入**：whitted-style ray tracing、蒙特卡洛路径追踪入门。

验收标准：**独立完成 GAMES101 全部编程作业，并完成提高部分（软光栅、微表面材质、潜艇场景）**。

补充阅读：《Fundamentals of Computer Graphics》（虎书）选读对应章节，作为工具书常备。

### 阶段 3：手写渲染器 —— 软光栅 + 光线追踪（4~6 周）

两个项目，均用 C++，不用任何图形 API：

1. **软件光栅渲染器**
   - 参考 [tinyrenderer](https://github.com/ssloy/tinyrenderer)（从画线段开始，一步步到带纹理带阴影的完整渲染器）或自己从零写。
   - 关键实现：DDA/Bresenham 画线 → 三角形光栅化（重心坐标）→ z-buffer → 透视投影纹理映射 → 法线贴图 → shadow mapping。
   - 加分：用 SIMD（NEON）加速，为将来 GPU 优化打直觉。

2. **路径追踪器**
   - 跟做 [Ray Tracing in One Weekend](https://raytracing.github.io/) 三部曲（免费在线，代码量不大但含金量极高）。
   - 关键实现：光线-球/三角形求交 → 蒙特卡洛积分 → 各种材质（漫反射/金属/电介质）→ 场景随机采样 → 重要采样 → 后续：体渲染、BVH 加速。
   - 这一步会让你真正理解"渲染方程"和"为什么实时光栅化里全是近似"。

验收标准：两张图——软光栅渲染的带阴影模型 + 路径追踪的Cornell Box。

> 参考实现已就位：[code/09-software-rasterizer](code/09-software-rasterizer/)（~400 行 C++，透视校正插值/z-buffer/软阴影全含）与 [code/10-path-tracer](code/10-path-tracer/)（~330 行 C++，Cornell Box + NEE + 多线程）。**先自己写，卡住再看**——对照参考实现复盘比自己闷头三天更有价值。

### 阶段 4：Metal 实时渲染实战（8~12 周）—— 主战场

目标：独立完成一个 PBR 实时渲染 demo（iOS/macOS 均可），覆盖现代实时渲染管线的核心环节。

学习路径：
1. **Metal 基础**：MetalKit、`MTLDevice/CommandBuffer/RenderPipelineState` 生命周期、Metal Shading Language（MSL，基本是 C++14 子集，对你是零成本）。过一遍 Apple 官方 [Metal 示例代码](https://developer.apple.com/metal/sample-code/)（管线的每个知识点都有对应 sample，质量极高）。
2. **对着 LearnOpenGL 学概念、用 Metal 实现**：[learnopengl-cn](https://learnopengl-cn.github.io/) 教程最系统，把每章的 OpenGL 作业用 Metal 重写一遍（概念一一对应：VAO/VBO ↔ `MTLBuffer` + vertex descriptor，shader ↔ `.metal` 文件）。
3. **进阶读物**：《Metal by Tutorials》(Kodeco)。

必须亲手实现的模块（即 demo 的里程碑）：
- [ ] Hello Triangle：完整管线跑通，理解 Metal 的资源模型与状态模型 → [code/01](code/01-hello-triangle/)
- [ ] 相机系统：FPS/orbit 相机、MVP 传参 → [code/02](code/02-mvp-cube/)
- [ ] 模型加载：OBJ/顶点属性布局（含 macOS 26 MTKMesh 回归绕行）→ [code/03](code/03-obj-viewer/)
- [ ] Blinn-Phong → **PBR**：Cook-Torrance BRDF（GGX + Smith + Fresnel-Schlick）→ [code/05](code/05-pbr-viewer/)，参考 [Filament 文档](https://google.github.io/filament/Filament.html)
- [ ] IBL：环境贴图预滤波、split-sum、HDR 环境 → [code/12](code/12-ibl/)
- [ ] Shadow Mapping：深度 pass + PCF → [code/07](code/07-shadow-map/)；级联 → [code/11](code/11-csm/)
- [ ] 后处理链：离屏 → bloom → ACES → sRGB → [code/06](code/06-offscreen-postfx/)；TAA → [code/13](code/13-taa/)
- [ ] Compute Shader：粒子系统 或 图像模糊 → [code/08](code/08-compute-particles/)
- [ ] 调试与性能：Xcode GPU Debugger（帧捕获、shader 断点）、Instruments 的 Metal System Trace

验收标准：一个可以旋转、有 PBR 材质球、软阴影、bloom 的场景，并且你能解释 draw call 里每一步 GPU 在干什么、用 Instruments 定位一个真实瓶颈。

### 阶段 5：高级实时渲染（3~6 个月，边做边学）

以《Real-Time Rendering (4th edition)》为主干精读（选读），配合 GAMES202（高质量实时渲染，闫令琪续作）：

- **实时阴影**：PCSS、VSM、CSM 级联阴影。
- **实时全局光照**：lightmap 烘焙、light probe、SSAO/SSDO、DDGI；理解 UE5 Lumen 的思路。
- **基于图像的技术**：延迟着色 vs 前向着色 vs TBDR 的前向+tile culling（Apple GPU 天然适合移动前向管线）。
- **高级材质**：次表面散射、各向异性、清漆层（Disney principled BRDF 全家桶）。
- **抗锯齿前沿**：TAA 原理与鬼影问题、时序累积。
- **GPU 架构**：SIMT 执行模型、寄存器/共享内存/带宽的三角关系、occupancy、**TBDR（Apple/移动 GPU）vs IMM（桌面 GPU）的本质差异**——这里你比大多数 PC 图形程序员更有实践条件。
- **优化技术**：实例化、视锥/遮挡剔除、LOD、bundle/indirect draw、MetalFX 超分。
- **硬件光追**：Metal Ray Intersector（`intersection_function`、acceleration structure）。

### 阶段 6：方向分化（第 2 年起，选一个主攻）

| 方向 | 深入路径 | 说明 |
|---|---|---|
| **A. 引擎/游戏开发** | GAMES104 → Unreal Engine 源码（渲染模块）| 工程量最大，天花板最高 |
| **B. 离线/物理正确渲染** | PBRT（pbr-book.org 免费在线）→ 写自己的渲染器 → SIGGRAPH 论文 | 学术味最浓 |
| **C. Apple 平台图形专家** | Metal 深度优化、ARKit+Metal、MetalFX、Core Animation/RealityKit 底层 | 与你背景最契合，市场上极度稀缺 |
| **D. 3D 视觉/神经渲染** | NeRF / 3D Gaussian Splatting、Core ML + Metal | 当前最热交叉领域 |

---

## 四、知识点大纲（完整版）

### 1. 数学基础
- 线性代数：向量运算、基与坐标系、矩阵变换、特征值（主轴）、SVD（理解即可）
- 仿射几何：齐次坐标、刚体变换、法线变换（逆转置矩阵）
- 四元数：旋转、slerp、与旋转矩阵互转
- 微积分：梯度、散度（着色推导）、曲率
- 概率与统计：蒙特卡洛估计、方差、重要采样、低差异序列（Halton/Sobol）
- 数值方法：浮点精度陷阱、牛顿迭代（光线求交）

### 2. 渲染管线（光栅化）
- 固定管线 vs 可编程管线；现代 API（Metal/Vulkan/DX12）的显式状态模型
- 顶点处理：变换、蒙皮、实例化
- 图元装配与裁剪、背面剔除
- 光栅化规则、重心坐标、透视校正插值
- 片元着色器：输入插值、discard、导数（ddx/ddy 与 mipmap 选择）
- 输出合并：深度测试（非线性深度、reversed-z）、模板、混合、sRGB 转换时机
- 前向 vs 延迟 vs 前向+（移动端 tile-based 的带宽优势）

### 3. 光照与材质
- 辐射度学：radiance/irradiance/intensity 定义、Lambert 定律
- 渲染方程（必须能默写并解释每一项）
- 经验模型：Lambert、Phong、Blinn-Phong
- 微表面理论：法线分布（GGX/Beckmann）、几何遮蔽（Smith）、Fresnel（Schlick）
- 能量守恒与色彩空间下的计算（linear vs gamma）
- Disney principled BRDF 参数化
- 材质系统：KHR glTF 2.0 PBR 规范、layered materials
- 次表面散射、各向异性、cleat coat、布料 BRDF（了解）

### 4. 纹理与采样
- 采样与重建：点/双线性/三线性、各向异性过滤
- mipmap 链、roughness map 的 prefilter
- 纹理压缩格式（ASTC 是 Apple 主推）
- 程序化纹理与噪声（Perlin/Worley）
- 法线贴图（切线空间推导）、高度/视差贴图
- Cube map、全景图（equirect）与 IBL 预处理

### 5. 几何与网格处理
- 网格表示：顶点属性布局、索引、半边结构
- 曲线曲面：Bezier、B 样条、NURBS（概念级）
- 细分曲面：Catmull-Clark、Loop
- 网格简化（QEM）、LOD 生成
- 参数化与 UV 展开（了解算法思想）
- 隐式表面：SDF、marching cubes、ray-marching（ShaderToy 主流技术）
- 碰撞与空间结构：BVH、k-d tree（渲染和光追都要用）

### 6. 光线追踪与离线渲染
- 求交算法：光线-三角形（Möller–Trumbore）、光线-AABB
- 加速结构：BVH 构建（SAH）与遍历
- Whitted ray tracing / 路径追踪 / 光子映射 / Metropolis（概念级）
- 蒙特卡洛：Russian roulette、bias vs variance
- 重要性采样：余弦采样、GGX 采样、MIS
- 介质与参与介质：Heney-Greenstein、体渲染
- 降噪：SVGF、OptiX/OIDN 类（了解）
- 硬件光追：Metal `intersector`、binding table

### 7. GPU 架构与性能
- 执行模型：SIMT、warp/subgroup、分支发散
- 内存层级：寄存器 → threadgroup memory → device memory；bank conflict
- 带宽与算力（TFLOPS）的权衡、occupancy
- 移动 TBDR：tile 显存、imageblock、load/store action、带宽优化（Apple GPU 特有优势领域）
- 性能分析方法：counters（ALU/带宽/tile 利用率）、帧捕获、时间线
- 常见优化：draw call 合批、实例化、indirect command buffer、纹理压缩、shader ALU 优化

### 8. 动画
- 关键帧插值：linear/ease/贝塞尔
- 骨骼动画：骨骼层级、蒙皮矩阵调色板、GPU skinning（compute 或 vertex）
- 动画混合、状态机、IK（两骨骼/CCD 概念）
- BlendShape/Morph targets（ARKit 人脸经验直接复用）
- 动画压缩与采样（了解）

### 9. 色彩科学与成像
- 色彩空间：sRGB / Display P3 / Rec.2020 / linear workflow
- 传递函数：gamma 2.2、PQ/HLG
- HDR 管线：EDR（Apple 平台）、tone mapping（Reinhard/ACES）
- dithering、banding 处理

### 10. 工具链与工程
- 调试：Xcode GPU Debugger（帧捕获、shader 调试）、RenderDoc、Metal Validation Layer
- 性能：Instruments（Metal System Trace、GPU Counter）
- 着色器工程：shader 编译流程、宏与 uber shader、permutation 管理
- 资产管线：glTF/OBJ/USD、Model I/O、纹理处理
- 热重载与迭代效率（自建 shader 热重载）

---

## 五、资源清单（精选，不贪多）

### 课程
| 资源 | 阶段 | 说明 |
|---|---|---|
| [GAMES101](https://www.bilibili.com/video/BV1X7411F744) | 2 | 中文最强入门，作业必做 |
| [GAMES202](https://www.bilibili.com/video/BV1YK4y1t7bk) | 5 | 高质量实时渲染（RTR 精讲）|
| [GAMES104](https://www.bilibili.com/video/BV1iZ4y1V7Qv) | 6A | 现代游戏引擎 |
| CMU 15-462 / UCSD CSE 168 | 3/6 | 英文体系课，配合看 |
| [Ray Training in One Weekend](https://raytracing.github.io/) | 3 | 免费三部曲，路径追踪圣经 |

### 书籍
- 《Fundamentals of Computer Graphics》（虎书）—— 工具书
- 《Real-Time Rendering 4th》—— 实时渲染百科全书，阶段 5 主干
- 《Mathematics for 3D Game Programming》—— 数学工具书
- 《Physically Based Rendering: From Theory to Implementation》—— [免费在线](https://www.pbr-book.org/)，离线渲染方向必读
- 《Metal by Tutorials》(Kodeco) —— Metal 实战（英文）
- 《Physically Based Shader Development for Unity》可选

### 在线资源
- [learnopengl-cn](https://learnopengl-cn.github.io/) —— 概念最系统的 GL 教程（用 Metal 重写作业）
- [Filament 官方文档](https://google.github.io/filament/Filament.html) —— 免费的 PBR 权威论述，必读
- Apple [Metal Sample Code](https://developer.apple.com/metal/sample-code/) 与 WWDC Metal Session（每年都有）
- [ShaderToy](https://www.shadertoy.com/) —— 片元着色器练习场，从复刻入门 shader 开始
- siggraph 课程 / GDC Vault —— 前沿技术（很多免费）

### 源码阅读（你的强项）
- Google **Filament**（PBR 引擎，文档与代码质量极高）
- **bgfx**（跨平台抽象层，看抽象设计）
- UE5 渲染模块（方向 A 时）

---

## 六、实战项目清单（由易到难）

1. **ShaderToy 复刻**：水波、ray-marching 场景（阶段 2~3 穿插）
2. **软光栅渲染器**：tinyrenderer 完整流程（阶段 3）
3. **路径追踪器**：One Weekend 三部曲（阶段 3）
4. **Metal PBR Viewer**：glTF 模型查看器，PBR + IBL + 阴影 + 后处理（阶段 4）
5. **粒子系统**：compute shader 驱动 10w+ 粒子（阶段 4）
6. **小渲染引擎**：资源管理 + 前向管线 + 热重载 + 性能面板（阶段 5，检验综合能力）
7. 方向项目：UE 插件 / 自己的离线渲染器 / ARKit+Metal 混合渲染 / 3DGS viewer（阶段 6）

---

## 七、常见误区

1. ❌ 先学完数学再开始 → ✅ 数学跟着项目走，最多提前两周
2. ❌ 只看视频不做作业 → ✅ GAMES101 作业是课程的一半
3. ❌ 一开始就学引擎（Unity/UE）→ ✅ 引擎会隐藏所有本质；先懂管线再用引擎
4. ❌ 跳过软光栅直接上 GPU → ✅ 没有像素级心智模型，GPU 调试时完全抓瞎
5. ❌ 追逐名词（Lumen/Nanite/UE5）→ ✅ 基础（渲染方程、采样、矩阵）不变，名词只是组合
6. ❌ 用 AI 生成 shader 直接交差 → ✅ 先手推手写，再对照；图形学调试能力只能从踩坑中获得
7. ❌ 忽视色彩管理（gamma/linear）→ ✅ 图形 bug 一半来自色彩空间错误，尽早建立 linear workflow 意识

---

## 八、节奏建议

- **工作日**：1~1.5 小时（视频/书 + 小实验）
- **周末**：一次 3~4 小时的整块编码（渲染器项目只能整块推进）
- **每 2 个月**回头写一篇总结（把"能跑"的代码重构成"能看"的代码，工程经验变现）
- 里程碑：3 个月（GAMES101+两个软渲染器）→ 6 个月（Metal PBR demo）→ 12 个月（小引擎/高级特性）→ 18 个月（选定方向纵深）

> 一句话总纲：**GAMES101 建体系 → 手写两个软渲染器建心智模型 → 用 Metal 在 Apple 平台落地 → RTR/GAMES202 拉高度 → 方向纵深**。

---

## 九、知识梗概全书（docs/ 分章详解）

学习路径的配套知识体系，共 12 章（当前约 4.5 万字骨架，按"概念 → 公式 → 工程要点 → 自测清单"组织，持续扩写中）：

| 章节 | 文件 | 内容一句话 |
|---|---|---|
| 01 数学基础 | [docs/01-math.md](docs/01-math.md) | 向量/矩阵/MVP 推导/四元数/蒙特卡洛/浮点陷阱 |
| 02 渲染管线 | [docs/02-pipeline.md](docs/02-pipeline.md) | 管线全景/光栅化/透视校正插值/quad/OM/AA 全谱/架构选型 |
| 03 光照与材质 | [docs/03-lighting-materials.md](docs/03-lighting-materials.md) | 辐射度学/渲染方程/Cook-Torrance 逐项/IBL split-sum/LTC |
| 04 纹理与采样 | [docs/04-texture-sampling.md](docs/04-texture-sampling.md) | 采样理论/mipmap/各向异性/ASTC/法线贴图/程序噪声 |
| 05 几何 | [docs/05-geometry.md](docs/05-geometry.md) | 曲线曲面/细分/QEM 简化/SDF/ray-marching/BVH/网格工程 |
| 06 光线追踪 | [docs/06-raytracing-offline.md](docs/06-raytracing-offline.md) | 求交推导/路径追踪/NEE+MIS/体渲染/降噪/PBRT/Metal RT |
| 07 GPU 架构 | [docs/07-gpu-optimization.md](docs/07-gpu-optimization.md) | SIMT/内存层级/TBDR 深挖/imageblock/性能方法论 |
| 08 动画 | [docs/08-animation.md](docs/08-animation.md) | 骨骼蒙皮推导/混合状态机/IK/BlendShape/GPU 蒙皮 |
| 09 色彩成像 | [docs/09-color-imaging.md](docs/09-color-imaging.md) | 色彩空间/tone map/ACES/管线色彩纪律/EDR/MetalFX |
| 10 工具与工程 | [docs/10-toolchain-engineering.md](docs/10-toolchain-engineering.md) | GPU 调试/shader 工程/资产管线 glTF-USD/渲染器架构 |
| 11 进阶实时 | [docs/11-advanced-realtime.md](docs/11-advanced-realtime.md) | PCSS/CSM/GI 全谱/DDGI/GPU-driven/水云大气/3DGS |
| 12 方向纵深 | [docs/12-specializations.md](docs/12-specializations.md) | 引擎/离线渲染/Apple 专家/神经渲染四路线+面试+作品集 |
| 13 附录速查 | [docs/13-appendix-cheatsheet.md](docs/13-appendix-cheatsheet.md) | 公式速查卡/关键数值表/中英术语表/调试速查/总自测 |
| 14 物理模拟 | [docs/14-physics.md](docs/14-physics.md) | 积分器/刚体/碰撞(GJK-EPA)/PBD-XPBD 布料/流体概念 |
| 15 2D 渲染与 Core Animation | [docs/15-2d-rendering-coreanimation.md](docs/15-2d-rendering-coreanimation.md) | CA 合成器原理/属性图形学对照表/离屏渲染/文字渲染 |
| 16 Metal 快速起步 | [docs/16-metal-quickstart.md](docs/16-metal-quickstart.md) | 从空工程到 PBR 的分步代码/第一周路线/高频坑速查 |
| 17 Shader 模式库 | [docs/17-shader-patterns.md](docs/17-shader-patterns.md) | 卡通/描边/玻璃/水/溶解/皮肤/调试视图等 cookbook |
| 18 毕业项目蓝图 | [docs/18-mini-engine-blueprint.md](docs/18-mini-engine-blueprint.md) | Mini-Engine 设计书：架构/接口/里程碑验收/风险预案 |
| 19 白板代码题集 | [docs/19-whiteboard-coding.md](docs/19-whiteboard-coding.md) | 15 道手写题+考官追问+评分自校 |
| 20 记忆卡片库 | [docs/20-anki-cards.md](docs/20-anki-cards.md) | 120 张间隔重复 Q/A 卡片（公式/数值/因果链锚点）|
| 21 系统设计题 | [docs/21-system-design.md](docs/21-system-design.md) | 6 道大题完整参考答案+六段式作答模板 |
| 22 3DGS 实操 | [docs/22-3dgs-practice.md](docs/22-3dgs-practice.md) | 采集→COLMAP→训练→iOS Metal viewer→AR，四周里程碑 |
| 23 GAMES101 通关 | [docs/23-games101-labs.md](docs/23-games101-labs.md) | 7 次作业的知识映射/常见 bug/验收标准/六周表 |
| 24 故障诊断树 | [docs/24-troubleshooting.md](docs/24-troubleshooting.md) | 十大症状排查决策树（按概率分支+章节引用）|
| 25 信息源雷达 | [docs/25-info-radar.md](docs/25-info-radar.md) | ≤10 信源极简订阅策略+例行动作+质量判据 |
| 26 训练执行计划 | [docs/26-training-plan.md](docs/26-training-plan.md) | 26 周周表：文档×示例×验收物对齐+三条铁律 |

**扩写进度**：25 章 + 附录全部完成，全书约 18 万字，至此收官。学习顺序：README 主线 → 16 章动手 → 20 章每日复习 → 18 章毕业项目 → 13/19/21 面试冲刺 → 24/25 长期工具。

---

## 十、可运行示例代码（code/）

| 示例 | 说明 |
|---|---|
| [code/01-hello-triangle](code/01-hello-triangle/) | macOS MetalKit 最小三角形，**无 Xcode 工程**，`./build.sh` 即跑（已在本机验证编译与运行），对应 16 章 Step 0–1 |
| [code/02-mvp-cube](code/02-mvp-cube/) | 顶点/索引缓冲 + MVP uniform + 深度缓冲，旋转六色立方体（已验证运行），对应 16 章 Step 2 与 01 章矩阵落地 |
| [code/03-obj-viewer](code/03-obj-viewer/) | Model I/O 加载 OBJ + stage_in 描述符 + Blinn-Phong（已验证运行，含真实调试踩坑实录），对应 16 章 Step 3 |
| [code/04-textured](code/04-textured/) | 纹理加载 + sRGB + mipmap 生成 + 半球 mip0/自动对照实验（已验证运行），对应 16 章 Step 4 |
| [code/05-pbr-viewer](code/05-pbr-viewer/) | 35 球 metallic×roughness 实例矩阵 + GGX 三点光 + ACES（已验证运行），对应 16 章 Step 5 收官 |
| [code/06-offscreen-postfx](code/06-offscreen-postfx/) | 手工 RenderPass 五链：HDR 场景→亮部→分离高斯 bloom→ACES 合成（已验证运行），对应 02 章 pass 组织与 09 章后处理 |
| [code/07-shadow-map](code/07-shadow-map/) | 光源深度 pass（depth-only PSO）+ 斜率偏置 + 3×3 PCF（已验证运行，含 stage_in 踩坑实录），对应 11 章阴影基础 |
| [code/08-compute-particles](code/08-compute-particles/) | compute kernel 驱动 26 万粒子（软化引力 + 半隐式欧拉 + 帧率无关阻尼）+ 点精灵 additive 渲染（已验证运行，含 storageModePrivate 驱动崩溃实录），对应 07 章 §6/扩展 C 与 02 章 encoder 顺序 |
| [code/09-software-rasterizer](code/09-software-rasterizer/) | **C++ 零依赖软光栅器**：重心坐标/透视校正插值/z-buffer/软阴影两遍结构，输出 TGA（headless 验证：57% 像素、棋盘透视正确），对应 docs/02 的 CPU 落地，阶段 3 验收件之一 |
| [code/10-path-tracer](code/10-path-tracer/) | **C++ 零依赖路径追踪器**：Cornell Box（NEE 直接光采样 + 余弦间接 + Schlick 玻璃），多线程 480×360@128spp ≈ 0.6s（headless 验证：左红右绿、渗色正确），阶段 3 验收第二张图，对应 docs/06 |
| [code/11-csm](code/11-csm/) | 级联阴影贴图：4 级 λ 切分 + 视锥切片 AABB 拟合 + texel snapping + 逐级 PCF，**空格键切级联调试着色**（仓库首个交互示例；headless 验证 86.8% 覆盖），对应 11 章 §1.2，含五连踩坑实录 |
| [code/12-ibl](code/12-ibl/) | IBL split-sum 三件套：程序化 HDR 环境 → irradiance 卷积 + GGX 预滤波 + BRDF LUT（初始化一次烤制）+ 25 球 PBR 矩阵（headless 验证 metallic/roughness 梯度正确），对应 03 章 §IBL，**阶段 4 九项里程碑收官** |
| [code/13-taa](code/13-taa/) | 时序抗锯齿：Halton(2,3) 8 点抖动 + ping-pong 历史 + 邻域 AABB clamp + 首帧冷启动，**空格开关对比摩尔纹闪烁**（headless 验证时序收敛差=0），对应 11 章 §TAA 与 18 章 M3 |
| [code/14-frame-graph](code/14-frame-graph/) | **收官件·迷你帧图**：声明式 pass + Kahn 拓扑排序 + 死 pass 剔除 + RT 内容寻址池化 + 瞬时深度 + backbuffer 钩子，载荷为 HDR bloom 链（验证：编译序正确、第二帧零新建），对应 18 章 M2，**从示例到引擎的一步** |
| [code/15-skinning](code/15-skinning/) | GPU 骨骼蒙皮：6 骨骼链 FK + 矩阵调色板 + 两骨骼 LBS，行波驱动的挥鞭触手，**空格开关对比**（headless 验证尖端随 t 移位/关蒙皮冻结），对应 08 章——**文档可代码化主题至此全覆盖** |

**起步代码链完成（体系闭环）**：阶段 3 验收对（09/10）+ 阶段 4 九项（01~08、12）+ 18 章 M3 两件（11 CSM、13 TAA）+ **M2 帧图骨架（14）+ 蒙皮（15）**。`code/build-all.sh`（`--run` 冒烟）一键构建全部 15 个示例。学习者在 14 的图上继续挂节点（阴影/TAA/IBL/异步 compute）即是在"写自己的引擎"。

> macOS 26 适配注记：① Xcode 26 起 Metal 编译器为独立组件（`xcodebuild -downloadComponent MetalToolchain`），各 build.sh 已做 CLT→Xcode 自动回退；② 本机工具链 `MTKMesh` 顶点转换输出全零（03/04/05/07/11 已改过程化球体，排障实录见 11 的 README）；③ 混合属性改名 `*BlendFactor`、`newTextureView` 改 descriptor 形式。

> 构建环境注：Xcode 26 起 Metal 编译器为独立组件（`xcodebuild -downloadComponent MetalToolchain`），且新 SDK 将混合状态属性改名 `*BlendFactor`；各示例 build.sh 已做 CLT→Xcode 自动回退。
