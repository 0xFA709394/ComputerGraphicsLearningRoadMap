# 03 · 光照与材质（PBR 核心）

> 本章是实时图形学的心脏。目标：默写渲染方程、吃透 Cook-Torrance 每一项、能徒手写一个直接光 PBR shader。配合阅读：[Filament PBR 文档](https://google.github.io/filament/Filament.html)（免费、工业级权威）。

---

## 1. 辐射度学：物理量的语言

### 1.1 四个基本量
| 量 | 符号 | 单位 | 直觉 |
|---|---|---|---|
| Radiant flux | Φ | W | 每秒能量（"功率"）|
| Intensity | I | W/sr | 点光源每立体角功率 |
| Irradiance | E | W/m² | 单位**面积**接收的通量 |
| **Radiance** | L | W/(m²·sr) | 单位**投影面积**单位**立体角**的通量 |

- 立体角：球面面积/r²；整球 4π sr、半球 2π sr。
- **Radiance 是渲染的基本量**：①相机像素记录的就是 radiance（乘曝光）；②**真空 中 radiance 沿光线不变** → 光线追踪沿光线取值即可。
- 核心关系：`E = ∫_Ω L(ω)·cosθ dω`（irradiance = 入射 radiance 的 cos 加权半球积分）。
- **Lambert 定律** `E ∝ cosθ` 的物理出处：同一束光斜照时摊在更大面积上。`N·L` 不是经验 trick，是投影。

### 1.2 光度单位（工程补充）
- 流明/坎德拉/勒克斯 = 辐射量乘人眼响应曲线 V(λ)。引擎光强常直接用光度单位（如 point light 用 lm）。

---

## 2. BRDF 与渲染方程

### 2.1 BRDF 定义
```
f(l, v) = dL_o / dE(l)        单位: 1/sr
```
- 描述"给定入射方向 l，向观察方向 v 反射的比例分布"。
- 公理：非负；**reciprocity** `f(l,v)=f(v,l)`；**能量守恒** `∀v: ∫f(l,v)cosθ_l dl ≤ 1`。
- 家族：BRDF(反射) + BTDF(透射) = BSDF；进出不同点 = BSSRDF（次表面）。

### 2.2 渲染方程（Kajiya 1986，全书之锚）
```
L_o(x, ω_o) = L_e(x, ω_o) + ∫_Ω f(x, l, ω_o) · L_i(x, l) · (n·l) dl
```
- 读法：出射 radiance = 自发光 + 【所有入射方向】×【表面散射比例】×【入射光】×【投影】的积分。
- **一切渲染算法 = 求解该方程的某种近似**：光栅化=对 Li 做离散光源+环境贴图近似；路径追踪=蒙特卡洛数值积分。
- 算子形式：`L = E + K·L` → Neumann 级数 `L = E + KE + K²E + …`，每一项 = 一次弹射 → 路径追踪的数学合法性来源（第 6 章）。

---

## 3. 经验模型（历史阶梯）

- 三段式：`ambient + diffuse + specular`。
- Lambert 漫反射：`f_d = ρ/π`（除以 π 是能量守恒归一化，白色 Lambert 表面在白炉中积分恰好 1）。
- Phong 高光 `k_s(R·V)^α` → **Blinn-Phong** `k_s(N·H)^s`，`H = normalize(L+V)`：免 reflect 计算、高光更快；归一化因子使其随指数能量守恒。
- 局限：物理不正确、粗糙度与高光形状耦合差 → 被微表面模型取代（但仍是移动低端 fallback 与调色起点）。

---

## 4. 微表面理论（PBR 核心，必须逐项吃透）

### 4.1 Cook-Torrance 框架
```
f(l,v) = k_d·(ρ/π) + k_s · [ D(h)·G(l,v)·F(v,h) ] / [ 4·(n·l)·(n·v) ]
```
- 假设：表面=大量微小理想镜面；统计分布 D 描述微表面法线 → 粗糙度。
- 分母 `4(n·l)(n·v)`：宏观↔微表面立体角换算的雅可比（不必会推，要知道它不是凑的）。

### 4.2 D 项（法线分布：多尖）
```
GGX/Trowbridge–Reitz:  D(h) = α² / [ π·((n·h)²(α²−1)+1)² ]
参数: α = roughness²  （Burley 感知线性化）
```
- GGX 特征：**重尾**——高光核心外拖出光晕（打磨金属/湿地的视觉特征），Beckmann 做不到；电影界用 GTR 家族泛化尾巴指数。
- Blinn-Phong NDF 是它的历史亲戚（`s ≈ 2/α² − 2`）。

### 4.3 G 项（几何遮蔽：多暗）
- Smith 联合遮蔽（Height-Correlated Smith-Schlick-GGX 为主流）：
```
G(l,v) = G₁(l)·G₁(v)（独立近似）
G₁ = (n·v) / [(n·v)(1−k) + k],   直接光: k = (roughness+1)²/8
```
- 物理意义：粗糙表面上微表面互相挡光/挡视线；粗糙度↑ → 能量↓。

### 4.4 F 项（菲涅尔：多亮）
```
Schlick:  F(v,h) = F₀ + (1−F₀)(1 − v·h)⁵
```
- F₀ = 垂直入射反射率：**电介质 ≈ 0.04**（塑料/水/皮肤/布），**金属 0.6~1.0（=材料本色）**。
- **Metallic 工作流**（glTF/UE/Filament 标准）：
  ```
  F₀ = lerp(vec3(0.04)·specular, baseColor, metallic)
  diffuse = (1−metallic)·baseColor/π      // 金属无漫反射
  ```
- 菲涅尔直觉：掠射角（视线越平）反射越强——湖面倒影只在远处出现的物理原因。

### 4.5 漫反射项
- Lambert（ρ/π）仍是实时主流；进阶：Oren–Nayar（粗糙漫表面、逆反射）、Disney diffuse（含逆反射项，参数化更好）。

### 4.6 能量守恒与多重散射
- 单次散射微表面模型在**高粗糙度下损失能量**（微表面间多次反弹被忽略）。
- **白炉测试**（furnace test）：均匀白环境里正确材质应渲染成纯白；GGX 单次散射呈现变暗 → Kulla–Conty 多重散射补偿项是引擎级必修。

### 4.7 参数化标准
- glTF 2.0：baseColor + metallic + roughness（+ normal/emissive/occlusion）。
- Disney principled 12 参数（baseColor, subsurface, metallic, specular, specularTint, roughness, anisotropic, sheen, sheenTint, clearcoat, clearcoatGloss, ior）——现代 DCC/引擎材质的通用语；了解每个参数控制的视觉现象。

---

## 5. 环境光照 IBL（Image-Based Lighting）

### 5.1 问题
- 环境贴图的渲染方程积分 `∫ f·L_i·cosθ dω` 每像素算不起 → 预计算。

### 5.2 Split-Sum（Karis, SIGGRAPH 2013，实时标准）
```
∫ f(l,v)·L_i(l)·cosθ dl  ≈  PrefilterEnvMap(roughness, R) × ∫ f·cosθ dl (2D LUT)
```
- 第一步：对环境立方图按 **GGX 重要性采样**卷积，**mip 级 = roughness**（越粗糙的 mip 越模糊且已含 BRDF 权重）。
- 第二步：镜面 BRDF 积分存 128×128 的 2D LUT，索引 `(NdotV, roughness)`，R=scale、G=bias → `F₀·R + G`。
- 漫反射：irradiance map（超模糊的环境立方图）或 **SH 球谐** 9 系数。

### 5.3 球谐（SH）速览
- 函数在球面上的低频投影：L0/L1/L2 = 1/4/9 系数；环境漫反射用 L2 足够。
- irradiance env → SH 系数按频段衰减（1, 2/3, 1/4）；Light Probe（光照探针）= 世界中采样的 SH → 给动态物体提供环境光。

### 5.4 工程细节
- 探针放置/盒体视差修正（parallax correction）/探针间混合；镜面探针按粗糙度选 mip。
- 动态环境：每帧对 64px 小立方图卷积（移动可承受）或转向 DDGI（第 11 章）。

---

## 6. 解析光源

- 方向光 / 点光（`1/d²` 衰减 + 窗函数防远处爆掉）/ 聚光（内外锥角 smoothstep 软边）。
- 光源单位规范：强度 I(W/sr) → 表面照度 `E = I·cosθ/d²`。
- **面光源 = 真软阴影的来源**（解析点光源阴影永远全硬）。
- **LTC（Linearly Transformed Cosines）**：把多边形面光变换到余弦域做解析积分——实时矩形/圆盘/线光源的工业方案，软阴影+高光形状一次解决。
- 多光源剔除：tiled/clustered（第 2 章 Forward+）。

---

## 7. 材质专题（进阶特性）

### 7.1 分层材质
- **Clearcoat**：双层结构（清漆层高光 + 底层 BRDF），车漆/碳纤；glTF/Disney 标准参数。
- **Sheen**：绒毛状边缘散射（天鹅绒/织物），Charlie NDF。

### 7.2 次表面散射（SSS）
- 皮肤/蜡/玉石：光进入表面下传播一段再出射（BSSRDF）。
- 实时梯度：① preintegrated skin（曲率烘焙贴图，游戏经典）② 屏幕空间模糊（深度权重分离）③ 贴图透射（耳朵/树叶 backlight）。
- 离线：dipole 偶极子扩散近似 / 路径追踪体采样。

### 7.3 各向异性
- 拉丝金属/锅底/头发：反射沿切线方向拉长 → GGX 各向异性（αx/αy 两个粗糙度 + tangent）；旧 Kajiya-Kay。

### 7.4 其他
- 头发：Marschner R/TT/TRT 三通道模型（概念级）；布料 micro-flake；薄膜干涉（肥皂泡/甲油，thin-film iridescence）。
- glTF 材质扩展族：transmission / volume / ior / clearcoat / sheen / anisotropy / specular——**开放 PBR 的权威定义，写材质系统时对齐它**。

---

## 8. 采样与实现

### 8.1 关键采样分布
- 余弦加权：`pdf = cosθ/π`；生成式见 01 章 §6.3。
- GGX：采样 D（经典）→ **采样 VNDF（可见法线分布）方差更低**（Heitz 2018，现代标准）。
- 多策略 → **MIS**（multiple importance sampling，第 6 章）。

### 8.2 直接光 PBR shader 骨架（MSL 风格伪代码）
```cpp
half3 N = normalMap(...); half3 V = normalize(camPos - P);
half3 L = normalize(lightPos - P);
half NdotL = saturate(dot(N,L)); if (NdotL <= 0) return emissive;
half3 H = normalize(L+V);
half3 F0 = mix(half3(0.04), baseColor, metallic);
// specular
half D = D_GGX(NdotH, a2);
half G = SmithJoint(NdotV, NdotL, k);
half3 F = F0 + (1-F0)*pow(1-VdotH, 5);
half3 spec = D*G*F / (4*NdotV*NdotL + 1e-4);
// diffuse
half3 diff = (1-metallic) * baseColor / PI;
half3 Li = lightColor * NdotL;              // 点光再乘衰减
return emissive + (diff + spec) * Li + IBL(NdotV, roughness, F0)…
```

### 8.3 调试方法论
- 白炉测试（能量守恒）、棋盘测试（积分正确性）、albedo/金属度/粗糙度三视图分离、单光源独立开关、"光照分解"面板（diffuse/specular/IBL/阴影分色输出）——工程上比会写 BRDF 更稀缺的习惯。

---

## 9. 自测清单

- [ ] 默写渲染方程并解释每一项
- [ ] 解释 radiance 为何是渲染基本量（沿光线不变）
- [ ] 推导/解释 Cook-Torrance 分母与三项物理意义
- [ ] 手写 GGX+Smith+Schlick 直接光 shader（不查资料）
- [ ] 解释 split-sum 两步各预计算了什么、为什么 mip=roughness
- [ ] 说明 metallic 工作流中 F0 与 diffuse 的计算规则
- [ ] 白炉测试发现粗糙度 0.9 时变暗，定位原因（多重散射缺失）

---

# 扩展篇：完整代码与采样实现

## A. 完整 PBR 片元着色器（MSL，可直接接入 Metal 工程）

```cpp
#include <metal_stdlib>
using namespace metal;

struct Light { float3 posOrDir; float3 color; float intensity; int type; }; // 0 dir / 1 point

fragment float4 pbrFragment(FragIn in [[stage_in]],
    constant float3 &camPos     [[buffer(1)]],
    constant Light *lights      [[buffer(2)]],
    constant int   &lightCount  [[buffer(3)]],
    texture2d<float>   albedoMap    [[texture(0)]],   // sRGB
    texture2d<float>   normalMap    [[texture(1)]],
    texture2d<float>   mraMap       [[texture(2)]],   // R:metallic G:roughness B:AO (linear)
    texturecube<float> envPrefilter [[texture(3)]],   // mip=roughness 的预卷积环境图
    texture2d<float>   brdfLUT      [[texture(4)]],
    sampler s [[sampler(0)]])
{
    constexpr float PI = 3.14159265f;
    float3 albedo    = albedoMap.sample(s, in.uv).rgb;
    float3 mra       = mraMap.sample(s, in.uv).rgb;
    float  metallic  = mra.r, roughness = mra.g, ao = mra.b;

    // ---- TBN 法线贴图 ----
    float3 N = normalize(in.normal);
    float3 T = normalize(in.tangent - N * dot(in.tangent, N));  // 再正交化
    float3 B = cross(N, T);
    float3 nTS = normalMap.sample(s, in.uv).xyz * 2.0f - 1.0f;
    N = normalize(T * nTS.x + B * nTS.y + N * nTS.z);

    float3 V = normalize(camPos - in.world);
    float NdotV = max(dot(N, V), 1e-4f);
    float3 F0 = mix(float3(0.04f), albedo, metallic);
    float  a = roughness * roughness, a2 = a * a;

    // ---- 直接光（解析光源循环）----
    float3 color = float3(0.0f);
    for (int i = 0; i < lightCount; ++i) {
        constant Light &L = lights[i];
        float3 toL = L.posOrDir - in.world * float(L.type); // dir: 常向量
        float dist = length(toL); float3 ldir = toL / max(dist, 1e-6f);
        if (L.type == 0) ldir = -normalize(L.posOrDir);
        float atten = (L.type == 0) ? 1.0f : 1.0f / (dist * dist + 1.0f);
        float NdotL = dot(N, ldir); if (NdotL <= 0.0f) continue;

        float3 H = normalize(ldir + V);
        float NdotH = saturate(dot(N, H));
        float VdotH = saturate(dot(V, H));

        float D = a2 / (PI * powr(NdotH * NdotH * (a2 - 1.0f) + 1.0f, 2.0f));
        float k = (roughness + 1.0f) * (roughness + 1.0f) / 8.0f;
        float G = (NdotL / (NdotL * (1.0f - k) + k))
                * (NdotV / (NdotV * (1.0f - k) + k));
        float3 F = F0 + (1.0f - F0) * powr(1.0f - VdotH, 5.0f);

        float3 spec = D * G * F / (4.0f * NdotV * NdotL + 1e-4f);
        float3 diff = (1.0f - metallic) * albedo / PI;
        color += (diff + spec) * L.color * L.intensity * NdotL * atten;
    }

    // ---- IBL（split-sum 两块查表）----
    float3 irradiance = envIrradiance.sample(s, N).rgb;          // 漫反射环境（或 SH）
    float3 diffIBL = (1.0f - metallic) * albedo * irradiance;
    float3 R = reflect(-V, N);
    float3 preF = envPrefilter.sample(s, R, level(roughness * 6.0f)).rgb;
    float2 envBRDF = brdfLUT.sample(s, float2(NdotV, roughness)).rg;
    float3 specIBL = preF * (F0 * envBRDF.x + float3(envBRDF.y));

    color += (diffIBL + specIBL) * ao;
    return float4(color, 1.0f);
}
```
接入检查点：纹理 sRGB 标注正确、切线用 mikktspace 生成、`half` 化改造（第 7 章）。

## B. GGX VNDF 采样（Heitz 2018，现代标准）

比"采样 NDF"方差更低（把视角可见性并入分布），路径追踪与预滤波都应使用：

```cpp
// Ve: 视线方向（局部系, +Z=法线）；α: roughness²；返回半向量 H
float3 sampleGGX_VNDF(float3 Ve, float alpha, float U1, float U2) {
    // 1) 拉伸视线到各向同性球
    float3 Vh = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // 2) 正交基
    float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    float3 T1 = lensq > 0 ? float3(-Vh.y, Vh.x, 0) * rsqrt(lensq) : float3(1, 0, 0);
    float3 T2 = cross(Vh, T1);
    // 3) 圆盘采样 + 半球投影修正
    float r = sqrt(U1), phi = 2.0f * PI * U2;
    float t1 = r * cos(phi), t2 = r * sin(phi);
    float s = 0.5f * (1.0f + Vh.z);
    t2 = (1.0f - s) * sqrt(1.0f - t1 * t1) + s * t2;
    // 4) 重投影回半球并反拉伸
    float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0f, 1.0f - t1*t1 - t2*t2)) * Vh;
    return normalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0f, Nh.z)));
}
// 光线方向: L = reflect(-V, H)；pdf 可由 Smith-Lambda 公式解析算出（见 Heitz 原文）
```

## C. Split-Sum 预卷积与 LUT 生成（Karis 流程）

```cpp
// 1) 环境预滤波（离线/compute 对每个 mip 做）
float3 prefilterEnv(texturecube<float> env, float3 N, float roughness, uint Nsamples) {
    float3 V = N, sum = float3(0.0f); float wsum = 0.0f;
    float a = roughness * roughness;
    for (uint i = 0; i < Nsamples; ++i) {          // 1024 次足够
        float2 Xi = hammersley(i, Nsamples);
        // GGX 采样半向量（经典 NDF 版）
        float phi = 2 * PI * Xi.x;
        float cosT = sqrt((1 - Xi.y) / (1 + (a*a - 1) * Xi.y));
        float sinT = sqrt(1 - cosT * cosT);
        float3 H = tangentToWorld(float3(sinT*cos(phi), sinT*sin(phi), cosT), N);
        float3 L = normalize(2.0f * dot(V, H) * H - V);   // 反射方向
        float NdotL = max(dot(N, L), 0.0f);
        if (NdotL > 0.0f) { sum += env.sample(s, L).rgb * NdotL; wsum += NdotL; }
    }
    return sum / wsum;   // 存入 mip ≈ roughness × maxLevel
}

// 2) BRDF LUT（64×64 compute，输出 R=scale, G=bias）
float2 integrateBRDF(float NdotV, float roughness, uint Nsamples) {
    float3 V(sqrt(1 - NdotV*NdotV), 0, NdotV), N(0, 0, 1); float2 sum(0, 0);
    for (uint i = 0; i < Nsamples; ++i) {
        float2 Xi = hammersley(i, Nsamples);
        float3 H = sampleGGX(Xi, N, roughness);         // B 中同理
        float3 L = normalize(2.0f * dot(V,H) * H - V);
        float NdotL = L.z, VdotH = max(dot(V,H), 0.0f);
        if (NdotL > 0) {
            // 数值求解 F 与 G（F0=1 积分后拟合）
            float G = geometrySmith(NdotV, NdotL, roughness);
            float G_Vis = G * VdotH / (NdotV * H.z);    // 注意含雅可比项
            float Fc = powr(1 - VdotH, 5);
            sum.x += G_Vis * (1 - Fc);                  // scale → 乘 F0
            sum.y += G_Vis * Fc;                        // bias  → 直接加
        }
    }
    return sum / float(Nsamples);
}
```
理解要点：`prefilter` 求的是 `∫Li·f·cosθ` 中与 Li 有关的部分；LUT 求的是与 F0 有关的线性部分——**两者相乘 = split-sum**。

## D. 白炉测试实现

```cpp
// 场景: 无几何, 环境 Li ≡ 1（纯白）; 相机看一个 roughness 渐变球
// 断言: 输出亮度 ≈ 1.0 (能量守恒的 BRDF 在白炉中"消失")
for (float r = 0; r <= 1; r += 0.05) {
    float lum = renderFurnace(r);
    printf("roughness %.2f -> lum %.3f\n", r, lum);
}
// 预期: 单次散射 GGX 在 r>0.6 后明显 < 1 (能量丢失)
// 修复: 多重散射补偿 (Kulla-Conty): f_ms = (1-E(v))(1-E(l)) / (π(1-E_avg))
//       E(v)/E_avg 是预积分的 1D/标量查表 (对 F0=1 的 GGX 积分)
//       彩色金属再乘 F_avg 缩放
```
把这条曲线存进引擎的 CI——它能在一次提交里抓出"BRDF 改坏"的回归。

## E. LTC 面光源实现路线（Heitz 2016）

1. 离线：把 **余弦瓣** 经矩阵 M 变换拟合 GGX（不同 roughness/NdotV 采样 → 存 64×64 的 **M⁻¹ 矩阵纹理**）。
2. 运行时：着色点法线/粗糙度查 M⁻¹ → 把多边形面光顶点变换到"余弦域" → 余弦域多边形积分有**解析解**（Fresnel 分解为 F₀ 项 + Fresnel 项两块）。
3. 输出：面光辐照度（含柔和高光形状）——矩形/圆盘/线光同一套代码。
工程要点：多边形需在半球上裁剪（`arealight LTC clip` 参考实现到处有）；矩阵纹理 4×RGBA32F 或打包 3×half。

## F. 习题与解答

**Q1：为什么漫反射除以 π，而镜面 D 项"自带" 1/π？**
A：两者都是半球积分归一化的结果。`∫cosθdω = π`，Lambert 反射率 ρ 均匀分配到 π 立体角 → f=ρ/π；GGX 的 D 设计为微表面法线密度、其定义 `∫D(h)(n·h)dh = 1` 中已含 1/π 因子（对比 Phong 需手加归一化 `(n+2)/2π`）。

**Q2：α = roughness² 的意义？**
A：Burley 感知重参数化——让"粗糙度参数 0.5"在人眼/美术上对应中间散射角分布；直接把美术参数当 α 用会导致低粗糙度区难以调出差异（参数曲线前段死区）。

**Q3：prefiltered mip 与 LUT 各近似了积分的哪部分？**
A：渲染方程 IBL 项 = `∫ f·Li·cosθ dω`。split-sum 拆成 `E[Li 加权采样]（与场景有关→预卷积进 mip）` × `∫f·cosθ dω（只与 BRDF 有关→LUT）`。独立性假设（Li 与 f 的相关性被切断）是其全部误差来源——所以窄而亮的光源（窗光）在 IBL 下会"糊"，需探针/面光补充。

**Q4：金属的 F0 为什么等于 baseColor？**
A：金属无漫反射（自由电子吸收透射光），界面对不同波长反射率不同→反射率带色。电介质 F0 由折射率决定（(n−1/n+1)²≈0.02~0.08，水/塑料/皮肤几乎无差别）→ 常数 0.04 统一近似。

**Q5：为什么 IBL 漫反射用 irradiance（超模糊）而镜面用 prefiltered（按粗糙度分级）？**
A：Lambert 是 δ-般钝的瓣（只依赖法线，与视线无关）→ 低频环境足够；镜面瓣随粗糙度在"镜面δ"到"宽瓣"间变化 → 需要多级卷积（mip）。本质是**BRDF 瓣的频率决定环境表达所需的分辨率**。
