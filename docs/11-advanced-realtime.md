# 11 · 进阶实时渲染专题

> 阶段 5 的知识主体：阴影、全局光照、反射、大规模场景、水/云/地形、粒子，以及神经渲染前沿。配合 GAMES202 +《Real-Time Rendering 4th》精读。

---

## 1. 阴影（Shadow Mapping 全谱）

### 1.1 基础
- 两遍算法：光视角深度图 → 片元转换到光空间比较深度；** acne（自阴影条纹）/ Peter-panning（阴影脱离）**两大病。
- 偏移组合拳：slope-scaled depth bias + normal offset；front-face culling 渲染深度（几何封闭时）。
- **PCF**：比较多次平均（硬件 depth compare sampler 做 2×2/3×3）；注意 PCF 不能"预过滤深度图"（非线性，均值无意义）。

### 1.2 软阴影
- **PCSS**：blocker search（区域平均深度）→ 估计半影宽度 `penumbra = lightSize·(dReceiver−dBlocker)/dBlocker` → 按半影半径做可变 PCF——物理可信的"越近越硬"。
- **VSM/ESM**：把深度转到可滤波空间（矩/指数）→ 可用 mipmap/高斯预过滤（大面积软阴影便宜）；代价：漏光（light bleeding）。
- **CSM（级联阴影）**：近处高分屏、远处低分屏：
  - 切分公式：`cᵢ = λ·log_split + (1−λ)·uniform_split`（λ≈0.8~0.95）；
  - 稳定化：texel snapping（光空间平移对齐纹素）+ 包围球拟合，消抖动；
  - 级间 blend 过渡带；相机远近裁剪决定级数（3~4 级常态）。
- 其他：距离场阴影（SDF raymarch，UE Lumen 远场）、capsule shadow（角色近地 AO 阴影）、**RT 硬件阴影**（1spp+denoise，接触硬化免费）。

---

## 2. 全局光照（GI）实时方法

### 2.1 烘焙类
- **Lightmap**：UV2 参数化 → 离线路径追踪烘焙辐照（+ 方向 SH/光照方向图存光照方向）——静态场景最高性价比；动态物体用探针。
- **Light Probe（SH 探针）**：空间点采 L2 SH（9 系数/通道）动态物体采样；探针网络插值；法线朝向的低频近似。
- 贴花式：irradiance volume（体素化 SH 场）。

### 2.2 屏幕空间类
- **SSAO**：半球内采样深度比较估遮蔽（HBAO 用水平角更几何正确；GTAO 是现代基准，含多 bounce 能量项）。
- **SSDO/SSGI**：直接在屏幕空间做一次弹射的 GI（小范围间接光）。
- **SSR（屏幕空间反射）**：深度缓冲 raymarch（线性化深度+步进/层级加速+二分细化）→ 命中取历史帧颜色；mask 边缘 + 粗糙度 fade + 未命中回退 IBL/探针；运动物体反射滞后是固有缺陷。

### 2.3 体素/探针动态类
- **LPV**（光传播体积）：体素网格 SH 迭代传播——历史方案。
- **VXGI**：体素化+mipmap cone trace——概念了解。
- **DDGI**（动态探针 GI，当前工业主流）：世界布探针 → 每帧从探针位置渲染小分辨率深度立方图 → 更新辐照纹理（带深度偏置修正漏光）→ 运行时按法线/位置采样插值；hysteresis 稳时序。
- **Lumen**（UE5，集大成概念）：近场屏幕 trace + 世界 SDF trace + 表面缓存 + 探针 final gather，硬件光追可选加速——**读其 SIGSPACE 文章理解"混合级联"思想**。
- 1 spp 路径 + 降噪（SVGF 类，第 6 章 §8）= 实时 RT GI 通用形态。

---

## 3. 反射专题

- 分层反射方案（按重要度）：SSR（接触细节）→ 探针立方图（中距）→ 天空 IBL（远距）——按粗糙度/命中状态 blend。
- 平面反射（镜子/水面）：相机沿平面镜像渲染+斜裁剪（oblique near plane，模板/裁剪矩阵技巧）。
- RT 反射：1 ray + denoise + 半透明命中回退探针； glossy 按粗糙度重要性采样。

---

## 4. 大规模场景与 GPU-Driven 管线

- **剔除级联**：CPU 包围体（场景粗筛）→ GPU compute 视锥/遮挡剔除（hi-Z：上帧深度金字塔测试）→ indirect draw 直接画幸存者（`drawIndexedPrimitives` with indirect buffer）。
- **实例化 + meshlet 簇剔除**：object/task shader 里做簇级剔除（backface/锥剔除）→ mesh shading 管线。
- 流式加载：分块（chunk/tile）资产 + 异步上传 + LOD 切换；远景 impostor（billboard/烘焙立方图代理）。
- **Nanite 思想（UE5）**：微多边形集群树（cluster DAG）+ 软件光栅化路径（小三角形在 compute 上比硬件光栅快）+ 可见性缓冲 + 虚拟阴影图——理解其动机比复现重要。
- 地形：heightmap + clipmap LOD（环形层次）/CDLOD；裙边防裂缝；位移贴图；triplanar 多材质混合。

---

## 5. 自然现象专项

### 5.1 水/海洋
- Gerstner 波（求和，顶点位移+法线解析）；FFT 海洋（Phillips 谱 → 频域 → IFFT，影视/3A）；浅水色/深度吸收（Beer-Lambert）；菲涅尔反射+折射抓屏；泡沫（波峰 Jacobian/噪声）；岸边浪（sdf/shoreline mask）。
- 屏幕空间流体（粒子 → 深度平滑 → 法线重建）。

### 5.2 云/大气
- **大气散射**：Rayleigh（蓝天）+ Mie（日晕/雾霾）单次散射；预计算 LUT（Bruneton：transmittance/scattering 表）——天空盒的正确做法。
- 体云：raymarch fbm-Worley 体积 + Beer-Powder 项（粉末效应）+ 多向光散射近似（Beer×多次衰减）+ 时序重投影降噪。

### 5.3 植被/毛发
- 植被：alpha test + TAA（转子盘抗锯齿 alpha）、风场摆动（顶点权重+噪声）、LOD（距离换 billboard/impostor）。
- 毛发：hair card（主流）/ shell fur/（strand-based TGSR 路线了解）。

---

## 6. 粒子与特效

- GPU 粒子：compute 模拟（发射器原子计数 + 池管理）→ 死活压缩/前缀和重排 → 渲染（billboard/面向速度拉伸）。
- 排序：半透明粒子按深度 bitonic/radix 排序（或放弃改 additive/premultiplied 混合）。
- soft particle（与深度比较的淡出消穿模）；flipbook（序列帧）与程序运动结合。
- 光束/god rays：体积光（raymarch 阴影图）优于屏幕空间径向模糊。

---

## 7. TAA/上采样工程细节（承 02/09 章）

- jitter 序列 Halton(2,3)×N；velocity buffer 生成（当前位置 vs 上帧 VP，蒙皮/形变物体需逐顶点 prev 变换——最大工作量所在）。
- 钳制策略：neighborhood min/max AABB（变差钳制更稳）+ 历史衰减 + 运动失效回退（大位移丢弃历史）。
- 与延迟渲染结合：GBuffer 位置重投影（depth 归还）。
- 上采样同源：MetalFX temporal 要求输入 motion vector+深度，输出重建帧。

---

## 8. 神经渲染前沿（2023+ 必修视野）

- **NeRF**：MLP 拟合 `γ(x,d)→(σ, rgb)` + 体渲染积分；层次采样；Instant-NGP（多分辨率哈希编码 + 小 MLP，秒级训练）。
- **3D Gaussian Splatting（3DGS）**：场景=数百万 3D 高斯基元，splatting（椭圆投影）+ 深度排序 α 混合；训练用可微光栅化；渲染数百 fps → 已上手机（Apple 官方有 Metal 实现/示例；扫描 App 兴起）。
- 神经辅助管线：DLSS/FSR3/MetalFX（超分）、AI 降噪（OIDN）、神经纹理压缩（NTC）、DLSS-Ray Reconstruction（用 ML 替代手工管线降噪）。
- 视角：神经渲染与传统管线的融合（3DGS 作为新"媒体格式"进 AR/QuickLook）是 Apple 生态当前窗口。

---

## 9. 自测清单

- [ ] 实现 PCSS 并解释 blocker search 到半影估计的因果链
- [ ] 配置 CSM（切分/稳定化/级间混合）并消抖
- [ ] 写 GTAO 与 SSR，说明两者的屏幕空间固有缺陷
- [ ] 解释 DDGI 探针更新的漏光修正机制
- [ ] 画出 GPU-driven 剔除到 indirect draw 的数据流
- [ ] 实现大气散射 LUT 天空（不再用渐变天空盒）
- [ ] 用 Metal 跑通一个 3DGS viewer（或官方示例）并解释排序混合

---

# 扩展篇：核心算法代码实现

## A. PCSS 软阴影（完整 shader 片段）

```cpp
// 三个阶段: blocker search → 半影估计 → 可变 PCF
float PCSS(texture2d<float> shadowMap, sampler s,
           float2 uv, float zRecv, float texel, float zLight) // zLight: 光源尺寸(世界单位)
{
    // 1) Blocker Search: 在搜索半径内找平均遮挡深度
    //    搜索半径 = 光源尺寸 * (zRecv - zNear) / zRecv  (按接受者离光距离缩放)
    float searchR = zLight * (zRecv - NEAR) / zRecv;
    float sum = 0; int cnt = 0;
    for (int y = -R; y <= R; ++y)
    for (int x = -R; x <= R; ++x) {
        float zb = shadowMap.sample(s, uv + float2(x, y) * texel).r;
        if (zb < zRecv - BIAS) { sum += zb; ++cnt; }     // 该样本遮挡
    }
    if (cnt == 0) return 1.0;                            // 无遮挡 = 全亮
    float zBlocker = sum / cnt;

    // 2) 半影宽度: 相似三角形  penumbra = wLight * (dRecv - dBlocker) / dBlocker
    float penumbra = zLight * (zRecv - zBlocker) / zBlocker;

    // 3) 可变半径 PCF (半径 ∝ penumbra)
    float pcfR = penumbra * PCF_SCALE;
    float shade = 0;
    for (...) { /* 以 pcfR*texel 为半径的泊松盘采样 compare_average */ }
    return shade / SAMPLES;
}
```
调参经验：BIAS 从 `2.5 * texelSize * tan(acos(NdotL))`（slope-scaled）起步；PCF 采样点用泊松盘+每像素旋转（消 banding）。

## B. GTAO（Ground-Truth AO，现代基准）

```cpp
// 每像素: 以法线构建切线方向, 在 [-π/2, π/2] 的 N 个方向角上:
//   1) 沿该方向步进 raymarch 深度, 求 1~2 个 horizon 角 (h1, h2)
//   2) 线积分 ∫cos(θ) - cos(h) dθ  (考虑法线与方向的夹角权重)
//   3) 多方向平均 × 厚度/多弹射能量项
float gtao(float2 uv, texture2d<float> depthTex, float3 N, ...) {
    float3 viewV = reconstructViewPos(uv, depth);
    float2 dir = orthonormalBasis(N);
    float sum = 0;
    for (int i = 0; i < DIRECTIONS; ++i) {              // 8
        float phi = PI * i / DIRECTIONS;
        float2 d = float2(cos(phi), sin(phi));
        // 两端 horizon: 各 ~6 步指数步进 raymarch
        float h1 = findHorizon( d, uv, viewV, N);
        float h2 = findHorizon(-d, uv, viewV, N);
        // 积分闭合形式 (略): 按法线投影分段积分 cos
        sum += integrateArc(N, d, h1, h2);
    }
    return sum / DIRECTIONS;   // 输出 0..1, 需与 albedo 解耦(存 AO buffer)
}
```
要点：与 SSAO 不同点——hemi 球内几何正确积分（"ground truth"对参考离线渲染）；输出带 **厚度/多 bounce 项**（UE 的 GTAO 变体）接近离线 AO；时序累积 + 半分辨率 + upscale 是标准工程配置。

## C. SSR 屏幕空间反射（raymarch 骨架）

```cpp
float3 ssr(float2 uv, float3 N, float3 V, float rough,
           texture2d<float> depthTex, texture2d<float> sceneColor)
{
    float3 ro = viewPos(uv);
    float3 rd = normalize(reflect(-V, N));
    // 1) 起点: 把 rd 外推到近平面外 (避免立刻自命中)
    float t = exitToNear(ro, rd);
    // 2) 步进: dither 起始相位 (blue noise) + 指数步长
    float len = MAX_DIST;
    for (int i = 0; i < STEPS; ++i) {                   // 32~64
        t *= 1.25f;                                     // 指数增长
        float3 p = ro + rd * t;
        float2 suv = projectToScreen(p);
        if (outOfScreen(suv)) break;
        float sz = linearDepth(depthTex, suv);
        float diff = p.z - sz;                          // 穿过表面?
        if (diff > 0 && diff < thickness(t)) {
            // 3) 二分细化 4 次精确交点
            suv = refine(ro, rd, t);
            float3 hit = sceneColor(suv, mipByRoughness(rough, t));
            float fade = edgeFade(suv) * (1 - rough);   // 屏幕边缘/粗糙衰减
            return hit * fade;
        }
    }
    return 0;   // 交回上层(探针/IBL) 兜底
}
```
质量三件套：**hierarchical raymarch**（深度 mip 金字塔加速，步数减半）、roughness→mip 采样（粗糙反射取预模糊颜色）、每像素 dither+时序累积（消条带）。固有缺陷：屏幕外/被遮挡几何不反射——只能靠混合层兜底。

## D. 体积云 raymarch（分形噪声 + 光照近似）

```cpp
float3 clouds(Ray ray) {
    // 1) 与云层(两球壳)求交得 [t0, t1]
    float3 sum = 0; float T = 1;                        // 累计透射率
    float t = t0 + dither(uv) * stepLen;
    for (int i = 0; i < 48 && t < t1; ++i) {
        float3 p = ray.o + ray.d * t;
        float d = cloudDensity(p);                      // fbm(3~4oct Worley+Perlin)
        if (d > 0) {
            // 2) 光照: 向太阳 4~6 步 march 估透射 (Beer-Lambert)
            float lightT = marchSun(p);                 // exp(-σ * L)
            // 3) 能量汇集: Henyey-Greenstein 相函数 + powder(前向暗化修正)
            float3 S = sunColor * lightT * phaseHG(cosθ, 0.2) * d
                     + ambientSky * d;
            // 4) 前向积分 (energy-conserving):
            float sigma = d * EXTINCTION;
            float tr = exp(-sigma * stepLen);
            sum += T * (S - S * tr) / sigma;            // 解析段积分
            T *= tr;
            if (T < 0.01) break;                        // early out
        }
        t += stepLen;                                   // 可指数增长
    }
    return sum;                                          // alpha = 1 - T
}
```
性能三板斧：半分辨率渲染 + 时序重投影、early-out（T<0.01）、噪声 dither 消 banding。`S−S·tr)/σ` 是体渲染 segment 积分的解析形式（比朴素 `sum += S·T·stepLen` 能量守恒更好）。

## E. GPU-Driven 剔除数据流（整合图）

```
CPU: 上传实例数据(包围球/LOD) → 一次 indirect dispatch
GPU: [compute] 视锥剔除 → 写 visibleCount
     [compute] hi-Z 遮挡测试(上帧深度金字塔) → 剔除 → 紧凑实例列表
     [compute] LOD 选择 + meshlet 簇剔除(backface/锥测试)
     [compute] scan 生成 indirect draw 参数(count/instanceOffset)
     [graphics] 用 indirect buffer 直接画幸存簇 (CPU 不知道也不需要知道数量)
```
关键：**CPU→GPU 单向数据流 + GPU 自产 draw 参数**；同步只需一次 fence；配合 mesh shading（第 2 章）即为现代引擎标准形态。调试：先可视化 compact 后的实例数（readback 一个 uint），确认剔除正确再接渲染。

## F. 习题与解答

**Q1：PCSS 为什么必须先做 blocker search？跳过会怎样？**
A：半影宽度由"遮挡物到接受者的距离"决定（相似三角形）；无 blocker 距离信息时只能固定 PCF 半径 → 全场景阴影边界同宽（假）。blocker search 把"接触处硬、远处软"的物理规律还原。

**Q2：CSM 的 texel snapping 为什么能消除阴影闪烁？**
A：相机移动时光空间视锥平移是亚像素的 → 深度图采样在纹素间跳变 → 阴影边缘闪烁。把光空间平移量对齐到整 texel 步长（`round(offset/texelSize)*texelSize`），深度图内容随相机"整格"移动，时序稳定。

**Q3：SSR 在粗糙表面直接采样场景颜色为何会"太锐利"？**
A：粗糙反射应模糊（BRDF 瓣宽），但屏幕命中点取得是锐利像素。修复：按 roughness 与命中距离选 mip（越粗糙/越远取越糊的 mip）——等价于对反射光做 BRDF 加权预模糊。

**Q4：为什么体积云要 powder 项？**
A：HG 相函数强前向散射会让"太阳方向"的云底过亮过平；powder（`1−exp(−2ρ)`）在高密度处压暗，还原云的自阴影层次感——物理不严格、观感必需的"艺术修正"。

**Q5：3DGS 为什么必须深度排序而 mesh 渲染不需要？**
A：高斯 splat 是半透明椭球片元，α 混合顺序敏感（同 Q2/02 章）；mesh 光栅化有 z-buffer 硬件排序。3DGS 实现按 tile 级排序（深度分桶→基数排序），GPU 每 tile 按序 blend；这也是它动画化（每帧重排）的主要成本。
