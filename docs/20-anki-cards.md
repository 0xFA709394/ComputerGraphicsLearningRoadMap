# 20 · 记忆卡片库（间隔重复 · 120 张）

> 公式与数值类知识必须进入长期记忆才有用。用法：复制 Q/A 到 Anki（或任意间隔重复 App），建议每天 15 分钟。卡片刻意做成"一句话可答"，答案全部可在对应章节展开。

---

## 使用说明

- 导入 Anki：每行 `问题<Tab>答案` 制表符分隔；或用 Markdown 表格插件直接导本文件。
- 认知原则：卡片只记"锚点"（公式形态/数值量级/因果链），推导与代码回章节复习。
- 自定义删除：已经内化的卡片及时挂起——卡片库是脚手架，不是目的。

---

## 01 数学（16 张）

| Q | A |
|---|---|
| 点积的几何公式？ | a·b = ‖a‖‖b‖cosθ |
| 叉积模长的几何意义？ | 平行四边形面积 |
| 法线变换用什么矩阵？ | (M⁻¹)ᵀ（逆转置）|
| 透视投影中 w_clip 等于？ | −z（视线深度）|
| GL 与 Metal 的 NDC z 范围？ | [−1,1] vs [0,1]（Metal y 还向下）|
| 深度为什么非线性？ | z_ndc 是 1/z 的仿射函数 |
| Reversed-Z 的两个前提？ | far→0 映射 + 浮点深度缓冲 |
| 万向锁发生的条件？ | 欧拉角第二次旋转 ±90° |
| q 与 −q 的关系？ | 同一旋转（双倍覆盖）|
| slerp 公式形态？ | [sin(1−t)θ·q₀+sin(tθ)q₁]/sinθ |
| 蒙特卡洛估计式？ | (1/N)Σf(xᵢ)/p(xᵢ) |
| 余弦加权 pdf？ | cosθ/π |
| 低差异序列代表作？ | Halton/Sobol |
| 相机相对渲染解决什么？ | 大世界 fp32 顶点抖动 |
| Apple GPU fp16 相对 fp32 速率？ | 满速率（fp32 一半吞吐）|
| 逆 CDF 采样 p=2x 的结果？ | x=√ξ |

## 02 管线（14 张）

| Q | A |
|---|---|
| PSO 打包了什么？ | shader+混合+顶点布局等不可变状态 |
| 背面剔除的判据？ | 屏幕空间三角形有符号面积 |
| 透视校正插值公式？ | 先插 属性/w 与 1/w，再相除 |
| helper lane 是什么？ | quad 中被三角形覆盖外但仍执行的 lane |
| ddx/ddy 从哪来？ | 2×2 quad 相邻像素差 |
| discard 对 early-z 的影响？ | 使其失效/降级 |
| 混合应发生在什么空间？ | 线性空间 |
| premultiplied alpha 混合因子？ | (One, OneMinusSrcAlpha) |
| 不透明物体的排序方向？ | near→far（early-z 受益）|
| MSAA 与 SSAA 的本质区别？ | 几何多样本、着色一次 |
| TBDR 上 MSAA 为什么便宜？ | tile 内多采样+on-tile resolve |
| TAA 的三步核心？ | jitter→重投影→邻域钳制混合 |
| GBuffer 的致命移动端问题？ | 带宽（应走 imageblock）|
| iOS 首选管线架构？ | Forward/Forward+ |

## 03 光照（15 张）

| Q | A |
|---|---|
| 渲染方程右边两项？ | 自发光 + BRDF·入射·cos 的半球积分 |
| radiance 的单位？ | W/(m²·sr) |
| radiance 为何是基本量？ | 沿光线不变；相机记录的量 |
| Cook-Torrance 分母？ | 4(n·l)(n·v) |
| GGX D 公式分子？ | α²（α=roughness²）|
| 直接光的 k 公式？ | (r+1)²/8 |
| Schlick 菲涅尔形态？ | F₀+(1−F₀)(1−v·h)⁵ |
| 电介质典型 F₀？ | 0.04 |
| metallic 工作流的 diffuse？ | (1−metallic)·albedo/π |
| split-sum 拆成哪两块？ | 预滤波环境图 × BRDF LUT(R=scale,G=bias) |
| 环境图 mip 的含义？ | mip 级=roughness |
| 白炉测试验证什么？ | 能量守恒（输出≈1）|
| 高粗糙度变暗的原因？ | 缺多重散射（Kulla-Conty 补偿）|
| 面光实时主流方案？ | LTC |
| 面积↔立体角换算？ | dω=cosθ'·dA/r² |

## 04 纹理（10 张）

| Q | A |
|---|---|
| mip 层级公式？ | λ=log₂(max(‖ddx uv‖,‖ddy uv‖)) |
| 三线性解决什么？ | mip 级间跳变 |
| 各向异性解决什么？ | 斜视角椭圆足迹欠采样 |
| mip 生成必须在什么空间？ | 线性（且 alpha 预乘）|
| Apple 移动纹理压缩标准？ | ASTC |
| ASTC 甜点块尺寸？ | 6×6（albedo 通用）|
| 法线贴图存什么空间？ | 切线空间（TBN 变换）|
| 切线生成的事实标准？ | mikktspace |
| 八面体编码压缩什么？ | 单位向量→RG8 两通道 |
| albedo/法线的 sRGB 标注？ | albedo=sRGB；法线=linear |

## 05 几何（8 张）

| Q | A |
|---|---|
| de Casteljau 的本质？ | 逐层 lerp 的 Bezier 求值 |
| Catmull-Clark 一次细分后？ | 全四边形化；奇异点=度≠4 |
| QEM 简化的代价？ | vᵀ(Q₁+Q₂)v |
| SDF 并/交/差？ | min/max/max(a,−b) |
| SDF 法线求法？ | 梯度（中心差分 4 tap）|
| sphere tracing 步长？ | 当前点的 SDF 值 |
| BVH 动态场景策略？ | refit（快/退化）vs rebuild |
| TLAS/BLAS 分层动机？ | BLAS 随刚体复用，TLAS 轻量重构 |

## 06 光追（12 张）

| Q | A |
|---|---|
| Möller–Trumbore 命中域？ | u≥0,v≥0,u+v≤1,t 在区间 |
| NEE 是什么？ | 显式向光源采样的直接光估计 |
| NEE 与 BRDF 采样的双计由谁解决？ | MIS（balance/power 权重）|
| RR 为什么除以 P？ | 保持期望不变（无偏）|
| firefly 成因？ | 低概率高贡献样本 |
| HG 相函数控制什么？ | 前/后向散射（g 参数）|
| Beer–Lambert？ | T=e^(−σt·d) |
| 非均匀介质采样法？ | delta tracking (Woodcock) |
| SVGF 三层结构？ | 时间累积+盒测试+引导 atrous 滤波 |
| 实时 RT 的定式？ | 1~2spp + 降噪 |
| Metal RT 两级结构？ | BLAS(网格)+TLAS(实例) |
| 路径追踪每跳核心式？ | beta ×= f·cosθ/pdf |

## 07 GPU（12 张）

| Q | A |
|---|---|
| Apple simdgroup 宽度？ | 32 |
| 分支发散代价？ | warp 两边顺序执行，算力减半 |
| 访存合并要求？ | warp 内相邻线程访问相邻地址 |
| threadgroup memory 是什么？ | 片上共享内存（KB 级）|
| TBDR 两阶段？ | binning → 逐 tile 光栅化 |
| HSR 的意义？ | 被遮挡片元不执行着色 |
| imageblock 是什么？ | tile 内每像素片上可编程内存 |
| Raster Order Groups 提供什么？ | 光栅顺序=可编程混合/OIT |
| memoryless RT 用于？ | 深度/模板不回显存 |
| 带宽三问？ | ALU 用了多少/带宽多少/占用率够吗 |
| mobile 带宽量级？ | 30~70 GB/s（桌面 500~1000+）|
| 60fps/120fps 预算？ | 16.6ms / 8.3ms |

## 08–09 动画与色彩（14 张）

| Q | A |
|---|---|
| 蒙皮公式？ | v'=Σwᵢ(CᵢBᵢ⁻¹)v |
| inverse bind matrix？ | 绑定姿态世界矩阵的逆（预计算）|
| LBS 糖果纸效应原因？ | 矩阵线性混合失去正交性 |
| 两骨 IK 的数学工具？ | 余弦定理+极向量 |
| ARKit 人脸标准 morph 数？ | 52 blendshapes |
| sRGB 解码阈值？ | 0.04045 ? c/12.92 : 幂 2.4 |
| 光照必须在什么空间？ | 线性 |
| 中间 RT 首选格式？ | RGBA16F |
| ACES fitted 公式形态？ | x(2.51x+0.03)/(x(2.43x+0.59)+0.14) |
| EDR 的锚点？ | 1.0=SDR 白；maximumExtendedColorValue |
| MetalFX temporal 的输入要求？ | motion vector+深度 |
| tone mapping 发生位置？ | 曝光后、显示编码前 |
| bloom 的结构？ | 亮部提取(soft knee)→金字塔模糊→加回 |
| display P3 vs sRGB？ | 更大色域（红更饱和），Apple 默认 |

## 10–19 工程与实战（19 张）

| Q | A |
|---|---|
| frame graph 的核心声明？ | pass 的读/写资源（自动屏障与复用）|
| WAR 险象场景？ | B 读旧值的同时 C 覆写 |
| shader 热重载的释放时机？ | 在飞 command buffer 完成后（fence）|
| glTF 的定位？ | 3D 界的 JPEG（PBR/蒙皮/动画开放标准）|
| USD 组合弧强度序？ | Local→Inherits→Variants→References→Payloads→Specializes |
| PCSS 的三步？ | blocker search→半影估计→可变 PCF |
| CSM 稳定化手段？ | texel snapping+包围球拟合 |
| DDGI 是什么？ | 动态探针 GI（深度图更新辐照纹理）|
| SSR 未命中回退？ | 探针/IBL 混合 |
| Nanite 核心思想？ | 微多边形集群+软件光栅+可见性缓冲 |
| 半隐式欧拉公式顺序？ | 先 v 后 x |
| PBD 的哲学？ | 位置修正替代硬弹簧力 |
| XPBD 相比 PBD？ | 柔度物理化，与迭代次数解耦 |
| CA 动画为何主线程阻塞仍流畅？ | 插值在 Render Server 侧 |
| cornerRadius+mask 的代价本质？ | 单 pass 顺序合成不可能→离屏中间纹理 |
| Color Blended Layers 红色？ | UI 界的 overdraw/混合指示 |
| makeDefaultLibrary nil 的首选检查？ | .metal 文件 target membership |
| 顶点缓存优化目标指标？ | ACMR（每三角形平均顶点取数）|
| 白板题最高频失分三题？ | 投影推导/透视校正/MC 无偏性 |

---

## 复习节奏建议

```
第 1 个月: 每天新卡 20 张（跟随学习章节）
第 2~6 个月: 每天 15 分钟维护（复习为主）
面试前 2 周: 全库过一遍 + 19 章白板题重写
```
