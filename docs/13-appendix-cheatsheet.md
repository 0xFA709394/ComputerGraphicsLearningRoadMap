# 13 · 附录：公式速查 / 数值表 / 术语对照

> 全书速查卡。面试前、编码时、code review 时的单页参考。

---

## A. 核心公式速查

### 数学与变换
```
透视投影(GL, f=1/tan(fov/2))     行3: [0 0 (n+f)/(n-f) 2nf/(n-f)], 行4: [0 0 -1 0]
Metal z∈[0,1] 变体               行3: [0 0 f/(n-f) -1], 行4 偏移 nf/(n-f), y 行取负
Rodrigues 旋转                   R = I·cosθ + sinθ·[k]ₓ + (1-cosθ)kkᵀ
四元数→矩阵                       见 01 章 §4.2（三行九元素）
法线矩阵                          n' = (M⁻¹)ᵀn
透视校正插值                      a = Σ(αᵢaᵢ/wᵢ) / Σ(αᵢ/wᵢ)
逆 CDF 采样                       解 F(x) = ξ
```

### 光照与 BRDF
```
渲染方程                          Lo = Le + ∫Ω f·Li·(n·l) dl
Cook-Torrance                     f = kd·ρ/π + D·G·F / [4(n·l)(n·v)]
GGX 法线分布                      D(h) = α² / [π((n·h)²(α²-1)+1)²],  α = roughness²
Schlick-Ggx 遮蔽                  G₁ = (n·v)/[(n·v)(1-k)+k], k=(r+1)²/8
菲涅尔 Schlick                    F = F₀ + (1-F₀)(1-v·h)⁵
F₀(metallic 工作流)               F₀ = lerp(0.04, baseColor, metallic)
蒙特卡洛估计                      ∫f dx ≈ (1/N)Σ f(xᵢ)/p(xᵢ)
余弦加权 pdf                      p(ω) = cosθ/π
MIS balance                       wᵢ = pᵢ/Σpⱼ
面积↔立体角                       dω = cosθ'·dA/r²,  pdf_ω = pdf_A·r²/cosθ'
split-sum                         ∫f·Li·cosθ ≈ prefilter(rough,R) × LUT(NdotV,r)
```

### 光线与体积
```
Möller–Trumbore                   t=(s₂·e₂)/det, u=(s·s₁)/det, v=(d·s₂)/det, 命中: u,v≥0, u+v≤1
Beer–Lambert 衰减                 T = e^(−σt·d)
HG 相函数                         p(θ) = (1-g²)/[4π(1+g²-2g·cosθ)^{3/2}]
```

### 纹理与成像
```
mip 级                            λ = log₂(max(‖∂uv/∂x‖, ‖∂uv/∂y‖))
sRGB 解码                         c≤0.04045 ? c/12.92 : ((c+0.055)/1.055)^2.4
ACES 拟合(Narkowicz)              x(2.51x+0.03)/[x(2.43x+0.59)+0.14], 输入先乘0.6
PCSS 半影                         penumbra = wLight·(dRecv−dBlocker)/dBlocker
CSM 实用切分                      cᵢ = λ·c_log + (1-λ)·c_uniform, λ≈0.8~0.95
```

### 动画与管线
```
蒙皮                              v' = Σ wᵢ(CᵢBᵢ⁻¹)v ；矩阵先混合再乘顶点(4×省算)
slerp                             [sin((1-t)θ)q₀ + sin(tθ)q₁]/sinθ
TAA 重投影                        uvPrev = uv − (curNDC−prevNDC)/2
带宽估算                          pass带宽 ≈ W·H·bpp·(load+store系数)
```

---

## B. 关键数值表

### 帧预算
| fps | 预算 | 说明 |
|---|---|---|
| 30 | 33.3 ms | 手游低端基准 |
| 60 | 16.6 ms | 主流目标 |
| 90 | 11.1 ms | VR 下限(防晕) |
| 120 | 8.3 ms | ProMotion |

### F₀ 常用值
| 材质 | F₀ |
|---|---|
| 水/玻璃 | 0.02 |
| 皮肤 | 0.028 |
| 塑料/通用电介质 | 0.04 |
| 铁 | 0.56 (带色 sRGB 0.56,0.57,0.58) |
| 铜 | (0.95, 0.64, 0.54) |
| 金 | (1.00, 0.71, 0.29) |
| 铝 | 0.91 |

### 显存占用（含 mip 约 ×1.33）
```
4096² RGBA8  = 64 MB      4096² ASTC6×6 ≈ 7 MB
2048² RGBA8  = 16 MB      2048² ASTC6×6 ≈ 1.8 MB
1080p RGBA16F 单帧 RT = 16 MB
```

### 带宽量级
```
手机 SoC 共享内存: 30~70 GB/s    Apple M 系列: 100~800 GB/s
桌面独显: 500~1000+ GB/s
结论: 移动端一帧 60fps 的总带宽预算 ≈ 0.5~1.2 GB
```

### Apple GPU Family（近似对应，以文档为准）
| Family | 设备代 | 里程碑特性 |
|---|---|---|
| Apple3 | A9/A10 | TBDR imageblock 可编程性 |
| Apple4 | A11 | Raster Order Groups |
| Apple5 | A12 | argument buffers 强化 |
| Apple6 | A13 | **Metal 3 起点**（mesh shader/MetalFX/统一 RT）|
| Apple7+ | A14/M1→ | 全特性 + 更大 tile |

---

## C. 中英术语对照表（高频 40 条）

| 英文 | 中文 | 一句话含义 |
|---|---|---|
| rasterization | 光栅化 | 图元→像素覆盖的转换 |
| fragment | 片元 | 候选像素的着色单位 |
| draw call | 绘制调用 | 一次图元提交（CPU 成本单位）|
| PSO | 管线状态对象 | shader+状态的不可变打包 |
| barrier | 屏障 | 资源读写依赖的显式同步 |
| hazard | 险象 | RAW/WAR/WAW 访问冲突 |
| occupancy | 占用率 | SM 上活跃线程比例 |
| divergence | 分支发散 | warp 内走不同分支 |
| coalescing | 访存合并 | 相邻线程访问合并成宽事务 |
| TBDR | 瓦片延迟渲染 | Apple GPU 架构 |
| binning | 分桶 | TBDR 第一阶段的三角形分 tile |
| imageblock | 图像块内存 | tile 内每像素片上可编程内存 |
| Raster Order Group | 光栅顺序组 | Apple 可编程混合/OIT |
| BRDF/BSDF/BSSRDF | 双向(表面/次表面)散射函数 | 反射模型谱系 |
| radiance/irradiance | 辐射亮度/辐照度 | 渲染基本量/入射积分 |
| IBL | 基于图像的光照 | 环境贴图光照 |
| SH | 球谐函数 | 球面低频函数基 |
| LUT | 查找表 | 预计算表 |
| mipmap | 多级渐远纹理 | 预过滤金字塔 |
| anisotropic filtering | 各向异性过滤 | 椭圆足迹多次采样 |
| ASTC | 自适应可伸缩纹理压缩 | Apple 移动标准 |
| TBN | 切线基矩阵 | 切线空间法线变换 |
| PCF/PCSS/CSM/VSM | 阴影滤波/软阴影/级联/方差阴影 | 阴影技术族 |
| SSAO/GTAO | 屏幕空间环境光遮蔽 | AO 近似族 |
| SSR | 屏幕空间反射 | 深度缓冲 raymarch 反射 |
| GI | 全局光照 | 间接光总称 |
| lightmap/probe | 光照图/探针 | 烘焙辐照/SH 采样点 |
| DDGI | 动态探针 GI | 实时动态全局光方案 |
| Lumen | (UE5 GI 系统) | 混合级联实时 GI |
| Nanite | (UE5 微多边形系统) | 集群软件光栅 |
| meshlet/mesh shader | 网格簇/网格着色器 | 新几何管线 |
| TAA | 时序抗锯齿 | 历史帧累积重投影 |
| MetalFX/DLSS | 超分技术族 | 低清渲染+时序重建 |
| deferred/forward+ | 延迟/分块前向 | 管线架构 |
| visibility buffer | 可见性缓冲 | 只存 ID 的极简 GBuffer |
| path tracing | 路径追踪 | MC 求解渲染方程 |
| NEE/MIS | 直接光采样/多重要性采样 | 方差缩减组合 |
| Russian roulette | 俄罗斯轮盘 | 无偏随机终止 |
| BVH/TLAS/BLAS | 层次包围盒(顶层/底层) | 加速结构 |
| SDF | 有向距离场 | 隐式表面表示 |
| ray marching | 光线步进 | 步进式体/场求交 |
| NeRF/3DGS | 神经辐射场/三维高斯泼溅 | 神经渲染双雄 |
| EDR | 扩展动态范围 | Apple HDR 机制 |
| tone mapping | 色调映射 | HDR→显示范围 |
| ACES | 学院色彩编码系统 | 行业 tone/色彩标准 |
| linear workflow | 线性工作流 | 光照全程线性空间 |
| frame graph | 帧图 | 声明式 pass/资源管理 |
| ECS | 实体组件系统 | 数据导向架构 |
| LOD/impostor | 层级细节/广告牌代理 | 降级渲染手段 |
| skinning/LBS/DQS | 蒙皮/线性混合/对偶四元数 | 骨骼变形族 |
| blend shape | 混合形状 | 顶点增量动画(ARKit 人脸) |
| IK | 反向动力学 | 末端约束求骨骼 |
| retargeting | 重定向 | 骨架间动画迁移 |

---

## D. 常用调试速查（Xcode/Metal）

```
帧捕获                  Cmd+C (Debug ▸ Capture GPU Frame)
shader 断点/单步         捕获后点击 draw → shader 源码行断点
printf 调试(MSL)         调试构建可用, 输出在捕获 UI
计数器                  Debug ▸ Gauge ▸ GPU / Instruments Metal 模板
验证层                  Scheme ▸ Diagnostics ▸ Metal API Validation
GPU 时间                MTLCommandBuffer addCompletedHandler GPUStartTime/EndTime
热状态                  NSProcessInfo.processInfo.thermalState
EDR 能力                CAMetalLayer.maximumExtendedColorValue
```

---

## E. 全书自测总清单（面试前过一遍）

- [ ] 01：白板推透视投影 + slerp + 蒙特卡洛估计式
- [ ] 02：画全管线图 + 透视校正插值推导 + TAA 流程
- [ ] 03：默写渲染方程与 Cook-Torrance 三项 + split-sum 原理
- [ ] 04：mip 公式 + sRGB 纪律 + ASTC 选型
- [ ] 05：Catmull-Clark 掩模 + QEM 代价 + SDF 布尔
- [ ] 06：Möller–Trumbore + NEE/MIS 主循环 + RR 无偏性
- [ ] 07：TBDR 两阶段 + imageblock + counters 三问
- [ ] 08：蒙皮公式 + two-bone IK + 预蒙皮取舍
- [ ] 09：线性工作流三查 + ACES 链 + EDR 纪律
- [ ] 10：frame graph 职责 + 热重载 + WAR hazard
- [ ] 11：PCSS 因果链 + GTAO/SSR 要点 + GPU-driven 数据流
- [ ] 12：方向选型论证 + 一道深水区题完整作答
