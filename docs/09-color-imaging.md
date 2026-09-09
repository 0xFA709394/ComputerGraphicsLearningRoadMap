# 09 · 色彩科学与成像

> 色彩管理 bug 是新手渲染图"发灰/发暗/过饱和"的第一元凶。本章把管线从物理量到显示器像素的每一步色彩变换讲清楚——display P3/EDR 是 iOS 开发者主场。

---

## 1. 光与颜色感知

- 物理光 = 光谱功率分布 SPD；人眼三种视锥 → **三色理论**；**同色异谱**（不同光谱同感受）→ RGB 表示合法。
- CIE 1931 配色函数 x̄ȳz̄ → XYZ 三刺激值；色度图（xy 色域马蹄图）；白点（D65 等）。
- **色域 gamut** = 三原色+白点定义的三角形：sRGB（最小公分母）/ **Display P3（Apple 全线设备默认）** / Rec.2020 / ACEScg（渲染工作空间）。

---

## 2. 色彩空间与传递函数（两个必须分开的概念）

- 色彩空间（ primaries+white，定义"哪三种光"）≠ 传递函数（编码"怎么存数值"）。
- **线性 ↔ sRGB 编码**：
  ```
  编码: c ≤ 0.0031308 ? 12.92c : 1.055c^(1/2.4) − 0.055
  解码: c ≤ 0.04045   ? c/12.92 : ((c+0.055)/1.055)^2.4
  ```
- 为什么存 gamma 编码：人眼对暗部敏感 → 非线性编码下 8bit 无 banding；**所有光照计算必须在线性空间**（gamma 空间乘法=物理错误，"塑料感"来源）。
- HDR 传递函数：**PQ（SMPTE 2084）**/HLG——绝对亮度曲线（10,000 nit 上限）。

---

## 3. 渲染管线中的色彩纪律（工程核心）

1. 纹理：albedo 标 sRGB（硬件采样时自动解码），normal/roughness/metallic/AO 标 linear——**错误标注是渲染 bug 万恶之源**。
2. 中间 RT：**线性 fp16（如 RGBA16F）**——HDR 范围 + 精度；LDR RT 上做光照=亮部截断+暗部 banding。
3. 混合/模糊/卷积：线性空间进行（sRGB 格式 RT 硬件自动处理 OM 出入口）。
4. 输出：最后一步 tone map 后再 sRGB/PQ 编码（或 EDR 直通，见 §6）。
- banding 处理：fp16 RT + 抖动（bayer/triangular PDF dither）注入 ±0.5/255 噪声。

---

## 4. 曝光与 Tone Mapping

### 4.1 曝光
- EV（曝光值）/测光：直方图/中心加权/自动曝光（eye adaptation：目标亮度指数趋近，进出洞穴的瞳孔适应）。

### 4.2 Tone Mapping 算子（HDR→显示范围的映射）
- Reinhard：`L/(1+L)` 简单可用；extended Reinhard 带白点。
- **Filmic**（Uncharted 2，Hable）：S 曲线，高光滚降有"胶片感"。
- **ACES**（学院色彩编码系统）：行业标准 RRT+ODT；游戏常用 fitted 近似：
  ```
  (x(2.51x+0.03)) / (x(2.43x+0.59)+0.14)
  ```
- AgX（Blender 新默认）：防高光色相漂移（ neon 色彩碎裂问题）。
- 工程结构：exposure → tone curve → 显示编码三段分离，便于调色。

---

## 5. 后处理成像链（典型顺序）

```
线性HDR ─► 曝光 ─► bloom ─► (lens flare/ghost) ─► tone map
      ─► 色彩分级(LUT) ─► 锐化 ─► vignette/grain/CA ─► 显示编码
```
- **Bloom**：亮部提取（soft knee 阈值）→ 金字塔降采样模糊（dual Kawase 高效）→ 加回；尺度与阈值决定"廉价感 vs 电影感"。
- 色彩分级：3D LUT（`.cube`）在 log/大色域空间调色；lift-gamma-gain 与 ASC-CDL。
- 杂质特效：暗角（vignette）、色差（chromatic aberration）、胶片颗粒（grain）——用得节制。

---

## 6. HDR 显示与 Apple EDR（主场知识）

- **EDR（Extended Dynamic Range）**：Apple 平台 HDR 头显/超视网膜屏的扩展亮度机制——
  - `CAMetalLayer.wantsExtendedDynamicRange = true`
  - `maximumExtendedColorValue`（如 8.0 表示白色可到 8× SDR 白）
  - shader 输出线性值 >1.0 → 系统按显示能力映射；`EDRMetadata` 可自定义曲线。
- 内容管线：渲染线性 HDR → 可选 tone map 到 [0, EDRmax] → 直通（避免二次 tone map 变灰）。
- 参考官方示例 "Support HDR" / WWDC 相关 Session（EDR 每年有更新，看最新）。
- 跨平台概念对应：Windows ScRGB/SDR 白点约定、PQ 直通；游戏主机 HDR10。

---

## 7. 分辨率策略与超分

- **DRS（动态分辨率）**：按帧耗时缩放渲染目标 → 稳帧率；上采样（bilinear/CAS）补回。
- 超分三代：空间算法（FSR1/CAS+锐化）、**时序算法**（FSR2/TSR/**MetalFX Temporal**——依赖 motion vector + 历史帧重建，与 TAA 同源）、ML 类（DLSS）。
- Apple：**MetalFX**（空间+时序两版）——iOS 高画质标配；渲染 1080p 输出 4K 可省 2~3ms。

---

## 8. 自测清单

- [ ] 区分色彩空间与传递函数并写出 sRGB 编解码公式
- [ ] 排查"画面发灰"的三步法（纹理 sRGB 标注/中间RT线性/输出转换位置）
- [ ] 解释为什么混合和 bloom 必须线性空间、fp16 RT
- [ ] 说出 ACES fitted 公式并接入 shader 管线
- [ ] 在 Metal 层开启 EDR 并显示 >1.0 的白色而不被二次 tone map
- [ ] 接入 MetalFX temporal 并说明 motion vector 的生成要求

---

# 扩展篇：色彩管线代码与排障手册

## A. ACES / tone map 代码全家桶（MSL）

```cpp
// Narkowicz 拟合 ACES (2015): 一行级近似, 引擎事实标准
float3 ACESFitted(float3 x) {
    x *= 0.6f;                                   // 曝光预缩放
    return saturate((x * (2.51f * x + 0.03f)) /
                    (x * (2.43f * x + 0.59f) + 0.14f));
}

// 扩展 Reinhard (带白点, 防 1.0 处截断)
float3 ReinhardExt(float3 x, float whiteSq) {
    return x * (1.0f + x / whiteSq) / (1.0f + x);
}

// 完整输出链: 曝光 → tone curve → sRGB 编码
half3 outputTransform(half3 c, float exposure) {
    c *= exposure;
    c = ACESFitted(c);
    return powr(c, 1.0h / 2.2h);   // 近似 sRGB; 严格版用分段函数(02 章 §2)
}
```

## B. EDR 实战代码（Metal Layer 配置 + shader）

```cpp
// 1) CAMetalLayer 配置 (viewDidLoad):
layer.wantsExtendedDynamicRange = YES;
layer.pixelFormat = MTLPixelFormatRGBA16Float;      // EDR 必须浮点格式
float edrMax = layer.maximumExtendedColorValue;     // 如 8.0 (8× SDR 白)
// 2) 跟随系统/环境光变化:
//    -[MTKView drawableSizeWillChange:] 或 CADisplayLink 里查询
//    layer.currentEDRMetadata = ...; // 可自定义压缩曲线

// 3) shader: 输出线性值, 1.0 = SDR 参考白, >1.0 进入 EDR 区间
fragment float4 edrMain(...) {
    float3 hdrColor = pathTracedOrDirectLit(...);  // 线性, 可到 10+nits×
    // 不做 tone map 到 1.0! 只需把物理亮度映射到 [0, edrMax] :
    float3 outC = hdrColor * exposure;
    outC = min(outC, float3(edrMax));
    return float4(outC, 1);
}
// UI 元素(SDR)输出 1.0, 高光(太阳/灯光)自然 >1 —— 系统合成器处理显示映射
```
**最大坑**：链条上任何一环做了 tone map/截断（如把 RT 用 RGBA8）就前功尽弃；调试时先输出 `edrMax` 常量色验证层配置。

## C. 自动曝光（直方图 + 眼适应）

```cpp
// 1) compute: 降采样亮度图 → 直方图 64 bins (log 域)
// 2) 中心加权平均 or 98% 分位裁剪均值 → targetLum
// 3) 时间平滑(眼适应): 指数趋近, 快进慢出
exposure = mix(exposure, key / max(targetLum, 1e-4), 1 - exp(-dt / adaptTime));
// adaptTime: 变亮 0.5s / 变暗 2.5s (瞳孔生物学差异) —— 手感的关键细节
```

## D. 排障手册：症状 → 病因 → 药方

| 症状 | 病因 | 药方 |
|---|---|---|
| 画面整体发灰发暗 | albedo 纹理没标 sRGB（被当线性读了，暗部被抬高后再被光照）| 纹理属性勾 sRGB |
| 亮部惨白、暗部死黑 | 中间 RT 用了 RGBA8（LDR 截断）| 换 RGBA16F |
| 混合边缘/光晕处色带 | sRGB 空间做了 blend/blur | RT 用 sRGB 格式（硬解）或手工线性化 |
| 渐变天空出现 banding | 8bit 精度 + 大暗面积 | fp16 RT + dither 抖动 |
| tone map 后颜色"脏橙" | ACES 输入没做 RRT 输入变换（色彩空间错位）| 统一在线性空间曝光后再曲线 |
| P3 屏上饱和度异常 | 假定 sRGB 输出但显示是 P3 | `CAMetalLayer` colorspace 设 displayP3 |

## E. 习题与解答

**Q1：为什么"在 sRGB 空间做光照"会得到塑料感？**
A：光照是物理量的乘加，必须在线性（辐射量）域进行；gamma 空间的乘法等效于先做幂运算干扰——高光衰减曲线被指数化、漫反射过度衰减，"中间灰不接近日光响应"。经典对照图：gamma 光照的球像"黏土"。

**Q2：fp16 中间 RT 为什么同时解决 HDR 和 banding？**
A：半精度有 10 位尾数 + 指数动态范围 2^±15——暗部精度高于 RGBA8 的固定 1/255 步长，亮部可到 65504；10bit 等效精度 + 30+ 档动态范围，正是 tone map 前的"缓存域"需求。Apple GPU 上 fp16 RT 消耗与 RGBA8 相当（TBDR 片上），无理由不用。

**Q3：EDR 模式下 UI（SDR 内容）和 3D 场景如何同帧合成？**
A：以 1.0 为 SDR 参考白锚点：UI 输出 [0,1]，场景输出 [0, edrMax]；系统合成器按显示器能力把 >1 部分映射到更高背光/亮度。开发者唯一纪律：**不做双重 tone map**（系统或你，只选一层）。

**Q4：ACES 近似式为什么先乘 0.6？**
A：ACES RRT 的输入缩放（filmic 前的曝光归一），0.6 是拟合出的经验值——去掉它整体过曝约 1.7 档。这说明 tone curve 是"曲线族+曝光锚点"的组合，移植参数必须成套。
