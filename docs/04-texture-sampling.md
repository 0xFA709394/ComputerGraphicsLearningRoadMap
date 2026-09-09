# 04 · 纹理与采样

> 纹理是 GPU 最大的带宽来源，也是材质表现的载体。核心线索：**采样理论 → 过滤 → mipmap → 压缩 → 各类应用技术**。

---

## 1. 采样理论

- 连续信号离散采样、重建；**走样 = 高频分量伪装成低频**（锯齿/摩尔纹/闪烁）。
- Nyquist：采样率 ≥ 2×最高频率才可无损；纹理缩小（minification）时每像素覆盖多 texel → 必须低通滤波后再采样。
- 理想低通 = sinc 卷积（无限核，不可用）；实用近似：box（快、质量差）、双线性（2×2）、高斯（mipmap 生成常用）、Mitchell–Netravali（图像缩放优质折中）。

---

## 2. 纹理过滤

### 2.1 放大（Magnification）
- Nearest（像素风）/ **Bilinear**：2×2 双线性插值（x 方向两次 lerp + y 方向一次）。
- 放大无需 mipmap；配合 detail 纹理或程序噪声补充细节。

### 2.2 缩小（Minification）与 Mipmap
- **mip 选择公式**（GPU 实际执行）：
  ```
  ρ = max(‖∂(u,v)/∂x‖, ‖(∂(u,v))/∂y‖)   // 屏幕空间足迹
  λ = log₂(ρ)                              // mip 级
  ```
  导数来自 quad 的 ddx/ddy（第 2 章）。
- **Trilinear**：相邻两级双线性结果再插值（消除 mip 层级跳变线）。
- mip 生成：逐级 2×2 box（快）或高斯（质量）；**必须在线性空间过滤**（sRGB 纹理先解码再过滤再编码，硬件 sRGB 格式自动做）。

### 2.3 各向异性过滤
- 斜视角时屏幕像素足迹是**细长椭圆**而非方形 → 三线性欠采样 → 远处地面糊/闪。
- 各向异性：沿椭圆主轴多次采样（2/4/8/16x），质量↑带宽↑；EWA（椭圆加权平均）是理论最优参考。
- Apple GPU 的 aniso 支持良好，地面/墙面材质应开启。

---

## 3. 纹理类型与组织

- 1D/2D/3D（体数据、LUT）、**Cube map**（环境：方向 → 面插值，采样前需 normalize 方向向量；seamless filtering）、纹理数组（同格式不同内容单 bind）、图集 atlas（UV 紧凑排布 + bleeding/padding 防渗色）。
- **阴影贴图也是纹理**：depth compare sampler（硬件做 PCF 2×2/4×4），详见第 11 章阴影。
- **虚拟纹理 VT / 稀疏纹理**：超大分辨率按需驻留（Metal sparse textures）；feedback pass 记录需求页 → 异步换页。3A 开放世界标配，iOS 了解概念。

---

## 4. 纹理压缩（移动端重点）

### 4.1 为什么块压缩
- 未压缩 RGBA8 4096² = 64MB；块压缩 6~8bpp → 8~16×缩减，且 GPU 直接解码采样（省带宽+省内存）。

### 4.2 家族速览
- 桌面：BCn/DXT（BC1 RGB、BC3 RGBA、BC5 双通道（法线）、BC7 高质量 RGBA）。
- 移动_legacy：PVRTC（淘汰中）、ETC2（Android 基线）。
- **ASTC（iOS 必修）**：Apple 全系硬件支持；固定 128bit/块，足迹可选 4×4~12×12（含 3D 块）→ 质量与码率自由权衡；支持 LDR/HDR。Xcode 资产目录 `astc` 压缩；4×4≈8bpp（高质量）→ 8×8≈2bpp（远景/漫反射可用）。
- 法线贴图压缩：BC5 双通道重建 z（桌面）；ASTC 直接压效果尚可或用八面体编码。

---

## 5. UV 与常规应用技术

### 5.1 UV 基础
- UV 空间、texel density（每米多少 texel，决定细节均匀性，跨材质需统一）；UV 重叠/镜像（烘焙光照图禁止重叠）。
- Wrap 模式：repeat/clamp/mirror；`HalfPixelOffset` 类历史坑（D3D9 时代，Metal 无此问题）。

### 5.2 法线贴图（高频重点）
- 存储：**切线空间**法线（蓝紫色为主 = +Z 为主方向）。
- **TBN 矩阵**：由顶点切线（随 uv 导数方向）+ bitangent + 法线构成；shader 内：
  ```
  N = normalize(TBN * (texNormal*2 − 1))
  ```
- 切线生成标准：**mikktspace**（引擎事实标准，保证建模软件/引擎一致，否则法线贴图出现接缝光照差）。
- 平台差异历史：DXT5nm/swizzle（存 x,y 重建 z）；ASTC 下常规 RGB 即可。
- 世界空间法线贴图（特殊用途，不能复用）。

### 5.3 视差类技术
- Parallax mapping：用高度图按视线偏移 UV（近似，边缘露馅）。
- **POM（Parallax Occlusion Mapping）**：沿视线 ray-march 高度图步进求交 → 强烈浮雕感；steep POM + 自阴影；适合砖墙/地面，性能敏感（步数 16~64）。

### 5.4 其他
- 高度/混合贴图（地形 splatting：多材质按高度混合）、**triplanar**（无 UV 三面投影，岩石/程序地形）、detail 纹理（近处叠加高频）。

---

## 6. 程序化纹理与噪声

### 6.1 噪声族谱
- Hash → 白噪声（值随机的像素图）。
- **Value noise**（格点随机值插值）、**Perlin**（格点梯度插值，Ken Perlin；比 value 少块状感）、**Simplex**（单纯形剖分，更少运算、无轴向伪影）。
- **Worley/Voronoi**（细胞噪声：到最近特征点距离）——鹅卵石/陶瓷/云。
- **fbm（分形布朗运动）**：多倍频叠加 `Σ aᵢ·noise(2ⁱ·f·x)`，a 衰减 ~0.5；**domain warping**（用噪声扰动噪声输入）——大理石/云的流动感。
- 实现注意：GPU 上 hash 要用整数 hash（`fract(sin(x))` 在大坐标下崩）；法线可由噪声导数解析求或有限差分。

### 6.2 应用
- 云/地形/木纹/大理石（ShaderToy 主战场）；噪声烘焙进贴图省运行时算力；影视级： substances/Houdini 程序化工作流（了解）。

---

## 7. 特殊用途纹理

- **LUT**：BRDF 积分 LUT（第 3 章）、tone mapping 曲线 LUT、3D LUT 调色（`.cube`）。
- **Prefiltered env map**：mip=roughness 的预卷积环境图（第 3 章 IBL）。
- **SDF 纹理**：Valve 2007 符号距离字体——单通道存距离场，任意缩放锐利+描边/阴影 shader；通道打包多张 SDF。
- **光照图/探针**：lightmap（UV2）、SH 探针数据纹理（第 11 章 GI）。
- Look-up 一切昂贵函数：BRDF、大气散射 LUT（Bruneton）——实时渲染的普适技巧。

---

## 8. 工程要点（iOS）

- 资产目录统一 ASTC；按材质选择块尺寸（法线/高光 4×4，漫反射 6×6~8×8）。
- mip 必开（省带宽抗闪烁）除非 UI 纹理精确 1:1。
- 纹理格式与 sRGB 标注正确（albedo=sRGB，normal/roughness/metallic=linear）——一半"画面发灰/过亮"的 bug 源于此。
- 带宽账本：渲染时纹理带宽常占大头 → 压缩+分辨率预算+采样次数控制（一个 shader 里 4+ 次 texure sample 就该审视）。

---

## 9. 自测清单

- [ ] 推导 mip 选择公式，解释 ρ 与屏幕足迹的关系
- [ ] 解释三线性 vs 各向异性过滤的适用场景
- [ ] 手写 TBN 构建与法线贴图采样 shader
- [ ] 说明 ASTC 块尺寸/质量/码率的权衡决策
- [ ] 实现 fbm + domain warping 噪声并用于程序纹理
- [ ] 指出 albedo 与 roughness 纹理的 sRGB 标注错误会导致什么现象

---

# 扩展篇：编码、噪声与选型代码

## A. 八面体法线编码（octahedral，移动端标配）

把单位法线压进 2 个 8bit 通道（比 RGB10x2 或立体映射利用率高、解码便宜）：

```cpp
float2 signNotZero(float2 v) { return (v >= 0.0) ? 1.0 : -1.0; }

float2 octEncode(float3 n) {
    n /= (abs(n.x) + abs(n.y) + abs(n.z));        // 投影到八面体展开面
    float2 e = (n.z >= 0) ? n.xy
              : (1 - abs(n.yx)) * signNotZero(n.xy); // 下半球折叠包裹
    return e * 0.5 + 0.5;                          // 存 [0,1]
}

float3 octDecode(float2 f) {
    f = f * 2 - 1;
    float3 n = float3(f.x, f.y, 1 - abs(f.x) - abs(f.y));
    float t = saturate(-n.z);
    n.xy += (n.xy >= 0) ? -t : t;                  // 逆包裹
    return normalize(n);
}
// RG8_UNORM 两通道 = 法线精度 16bit (对比 RGB10A2 需 32bit 且采样器插值更好)
// 顶点压缩管线: pos(half3) + normal(oct RG8) + tangent(oct RG8) + uv(half2)
```

## B. Mipmap 生成（gamma 正确 + alpha 预乘）

```cpp
void genMipLevels(Image &img) {
    for (int level = 1; level < maxLevels; ++level) {
        for (each pixel (x,y) of level) {
            // 1) 从上级取 2×2: 先解码到线性!
            Vec4 c[4] = { srgbDecode(img(level-1, 2x,   2y  )),
                          srgbDecode(img(level-1, 2x+1, 2y  )),
                          srgbDecode(img(level-1, 2x,   2y+1)),
                          srgbDecode(img(level-1, 2x+1, 2y+1)) };
            // 2) alpha 预乘后再平均 (防透明像素颜色渗进不透明区域 → 深色描边)
            Vec3 rgb = ((c[0].rgb*c[0].a) + (c[1].rgb*c[1].a)
                      + (c[2].rgb*c[2].a) + (c[3].rgb*c[3].a)) / 4;
            float a = (c[0].a + c[1].a + c[2].a + c[3].a) / 4;
            rgb = (a > 1e-4) ? rgb / a : 0;
            // 3) 重编码 sRGB 存储
            img(level, x, y) = { srgbEncode(rgb), a };
        }
    }
}
```
两个高频 bug 一次预防：**gamma 空间滤波**（mip 越深越暗）与**非预乘 alpha 渗色**（贴花边缘黑边）。高质量版把 box 换成 Kaiser/Gaussian（钢锯齿更少）。

## C. 各向异性过滤的"足迹椭圆"几何

- 屏幕像素反投影到纹理空间是仿射变换 `J = ∂uv/∂xy`；其奇异值 σ₁≥σ₂ 给出椭圆长短轴。
- 三线性 = 用 σ₂ 决定 mip（各向同性）→ 沿长轴欠采样（远处地面闪）。
- 各向异性 = 沿长轴取 ~σ₁/σ₂ 次（上限 2/4/8/16x）三线性样本平均。
- EWA = 椭圆内高斯加权积分（理论最优、贵）。理解 J 矩阵后，**TAA 的 reprojection 误差、DoF 的 CoC、POM 的步进全都同一套微分几何**。

## D. 噪声库（可直接抄进 shader）

```cpp
// 1) 整数 hash (代替 fract(sin(x)) 大坐标崩溃的老写法)
uint pcg(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint r = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (r >> 22u) ^ r;
}
float hash12(float2 p) { return pcg(uint(p.x) * 1973u + uint(p.y) * 9277u) / 4294967295.0; }

// 2) Value noise: 格点随机值 + 五次平滑插值
float vnoise(float2 x) {
    float2 i = floor(x), f = fract(x);
    f = f * f * f * (f * (f * 6 - 15) + 10);              // quintic fade
    float a = hash12(i),       b = hash12(i + float2(1,0));
    float c = hash12(i + float2(0,1)), d = hash12(i + float2(1,1));
    return mix(mix(a,b,f.x), mix(c,d,f.x), f.y);
}

// 3) Perlin: 格点"梯度"与偏移点积 (无 value noise 的块状感)
float perlin(float2 x) {
    float2 i = floor(x), f = fract(x);
    float2 g00 = grad2(i), g10 = grad2(i+float2(1,0)),
            g01 = grad2(i+float2(0,1)), g11 = grad2(i+float2(1,1)); // pcg 生成单位梯度
    float fade = quintic(f);
    return mix(mix(dot(g00,f),        dot(g10,f-float2(1,0)), fade.x),
               mix(dot(g01,f-float2(0,1)), dot(g11,f-float2(1,1)), fade.x), fade.y);
}

// 4) Worley (细胞): 邻域 3×3 最近特征点距离
float worley(float2 x) {
    float2 i = floor(x); float md = 1e9;
    for (int dy=-1; dy<=1; ++dy) for (int dx=-1; dx<=1; ++dx) {
        float2 c = i + float2(dx,dy);
        float2 p = c + hash22(c);                        // 特征点在格内随机
        md = min(md, length(x - p));
    }
    return md;
}

// 5) fbm + domain warp = "所有自然纹理的母亲"
float fbm(float2 p) { float s=0, a=0.5; for(int i=0;i<5;++i){ s+=a*vnoise(p); p*=2.03; a*=0.5;} return s; }
float cloudLike(float2 p) { return fbm(p + fbm(p + fbm(p))); }   // 三层扭曲
```
选型：value（平滑低频）/ perlin（自然连续）/ worley（离散颗粒）/ fbm（地形云层）；导数需求时用解析导数版本（有限差分在压缩法线时出条纹）。

## E. Triplanar（无 UV 三面投影）

```cpp
float3 triplanar(float3 p, float3 N, float blendSharp = 4.0) {
    float3 w = pow(abs(N), blendSharp);            // 法线主导权重, 锐化过渡带
    w /= (w.x + w.y + w.z);
    float3 x = tex(YZ, p.yz).rgb, y = tex(XZ, p.xz).rgb, z = tex(XY, p.xy).rgb;
    return x * w.x + y * w.y + z * w.z;            // 岩石/程序地形无 UV 首选
}
```
接缝处理：三通道采同图差异小则自然；高要求场景用"最大权重主导 + blend 区域 ramp"。

## F. POM（视差遮蔽映射）核心循环

```cpp
// 切线空间实现; viewTS.z<0 时翻 UV/步进方向 (背面看)
float2 parallaxUV(float2 uv, float3 viewTS, texture2d<float> hmap, float scale) {
    float layers = mix(32.0, 8.0, abs(viewTS.z));     // 掠射角加密(否则条纹)
    float2 delta = (viewTS.xy / max(abs(viewTS.z), 0.05)) * scale / layers;
    float2 stepUV = uv, curH = 1.0;
    float2 prevUV = stepUV; float prevH = curH;
    for (float i = 0; i < layers; ++i) {
        stepUV -= delta;                              // 向视线反方向走
        float h = 1.0 - hmap.sample(s, stepUV).r;     // 高度图: 1=顶
        if (h >= curH) break;                         // 穿过表面 → 交点在上一段
        prevUV = stepUV; prevH = curH; curH += 1.0/layers*scale; // 近似线性深度
    }
    // 二分细化 4 次 (省略) → prevUV/stepUV 间插值
    return mix(prevUV, stepUV, ...);
}
```
成本控制：层数按 |viewTS.z| 自适应；仅近处材质启用；阴影/自遮蔽版再翻倍。本质是"高度场的 raymarch"——与 SDF sphere tracing（05 章）是同一思想在不同域。

## G. ASTC 选型速查

| 块尺寸 | bpp | 相对原始 | 典型用途 |
|---|---|---|---|
| 4×4 | 8.0 | 1/4 | 法线/金属度粗糙度、特写 albedo |
| 5×5 | 5.12 | 1/6.2 | 高质量 albedo |
| 6×6 | 3.56 | 1/9 | 通用 albedo（性价比甜点）|
| 8×8 | 2.0 | 1/16 | UI/远景/低频漫反射 |
| 12×12 | 0.89 | 1/36 | 光照图/超低频数据 |
| 5×5 HDR | 5.12 | — | HDR 环境图（如不支持 BC6H 场景）|

决策规则：**人眼对亮度误差敏感、对色度迟钝**——法线/粗糙度影响光照响应（放大误差）用 4×4；albedo 是乘性低频权重，6×6 起。

## H. 习题与解答

**Q1：mip 生成不转线性空间，远处材质会怎样？**
A：gamma 空间平均 = 幂平均偏高 → mip 越深越亮/发灰；纹理含高频对比色（红绿格）时远处色相漂移。验收：红黑格纹远处应收敛到暗红（线性），错版收敛到亮粉。

**Q2：cube map 采样方向为什么要 normalize？**
A：GPU 按方向绝对值最大分量选面 + 该面 2D 插值；插值后的 varyings（如反射向量插值）长度不均匀，直接用会让面选择在三角形内跳变（接缝）。normalize 恒定方向才能保证面连续。

**Q3：oct 编码比球面坐标 (θ,φ) 编码好在哪？**
A：球面编码在极点附近 u 对 θ 的导数 →∞（经线汇聚），8bit 量化在极点严重失真；八面体是等面积性质的展开，误差分布均匀。且解码无三角函数（SFU 省了）。

**Q4：POM 在掠射角为什么闪烁？**
A：视线足迹在高度场上的路径变长 + 固定步数欠采样 → 命中点抖动。缓解：层数随 N·V 自适应、距离 fade 成普通视差/法线贴图。

**Q5：为什么法线贴图必须 linear 标注而 albedo 必须 sRGB？**
A：albedo 是"感知色"的编码（人眼域），采样后参与物理计算前要解码回线性；法线是**几何数据**（方向分量，非感知量），任何 gamma 变换都是对其数学含义的破坏。
