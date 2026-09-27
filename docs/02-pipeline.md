# 02 · 渲染管线与光栅化

> 参考实现：[code/01](../code/01-hello-triangle/)~[06](../code/06-offscreen-postfx/)（管线逐环节）· CPU 侧对照 → [code/09-software-rasterizer](../code/09-software-rasterizer/)（透视校正插值/z-buffer 手写版）

> 本章建立 GPU 渲染管线的完整心智模型：数据从顶点缓冲到屏幕像素的每一步。目标：能白板画出管线全景图，并解释每个阶段的输入/输出/硬件行为。

---

## 1. 管线总览

```
顶点缓冲+索引 ──► 输入装配 ──► 顶点着色(VS)
        (可选) 曲面细分: HS ──► TS(固定) ──► DS
        (可选) 几何着色(GS, 已过时) / 网格着色(object+mesh, 新标准)
   ──► 图元装配 ──► 裁剪&背面剔除 ──► 光栅化
   ──► 片元着色(FS/PS) ──► 输出合并(深度/模板/混合) ──► RenderTarget
```

### 现代 Explicit API（Metal/Vulkan/DX12）三大特征
1. **PSO（Pipeline State Object）预编译**：着色器+混合+顶点布局打包成不可变状态，消灭运行时状态验证开销（GL 时代 draw call 贵的根源）。
2. **CommandBuffer 显式录制/提交**：编码与执行解耦 → 多线程录制（Metal：每 worker 一个 `MTLCommandBuffer`）。
3. **资源同步显式化**：手动管理 hazard（写后读等）、屏障、fence——图形程序员进阶必修。

图形与计算边界模糊化：剔除、粒子、后处理、Bloom、TAA 累积大量使用 compute pass。

---

## 2. 输入装配与顶点着色

### 2.1 顶点数据
- 属性：position / normal / uv / tangent(切线，法线贴图用) / color / blendIndices+blendWeights(蒙皮)。
- 布局：interleaved（AoV，缓存友好，常规选择）vs planar（SoA，compute 流式处理友好）。
- 顶点格式压缩：`half` 位置、`uint8` 法线（octahedral 编码省一维）、R8G8B8A8_UNORM 颜色。

### 2.2 索引与图元
- Index buffer 复用顶点（共享顶点Cache）；primitive restart 索引拼接 strip。
- 图元类型：point / line / triangle list、strip、fan；winding order（CW/CCW）决定正面，配合 `cullMode`。

### 2.3 VS 的职责
- 输出 clip space 位置（Metal: `[[position]]`）；其余输出（UV、法线等）将被插值。
- 常见工作：MVP 变换、蒙皮（见第 8 章）、程序化位移（风场、波浪）、实例变换。
- **Vertex Pulling**（Metal 特性）：VS 里直接 `vertex_id` 索引读原始 buffer，绕开固定 fetch——mesh shader 与自定义压缩格式的主流做法。

### 2.4 实例化
- `instanceID` + per-instance buffer（step function）一次 draw 画 N 个副本；draw call 是 CPU/驱动成本的大头，实例化 + indirect draw 是减负核心手段（详见第 7 章）。

---

## 3. 曲面细分与网格着色（可选阶段）

### 3.1 曲面细分管线
- HS(hull)：按距离/屏幕面积计算细分因子 → TS(固定功能)：在域上生成参数点 → DS(domain)：壳插值生成新顶点。
- 用途：LOD 地形、位移贴图、毛发。移动端成本高，常被"预细分+compute 位移"替代。
- 平滑技术：PN-Triangles、Phong Tessellation。

### 3.2 Mesh Shading（Metal 3）
- 新两段式：**object(task) shader** 生成 meshlet 实例 → **mesh shader** 输出顶点数组+图元数组。
- Meshlet：64~128 顶点的网格簇，配合 GPU-driven 剔除（第 11 章）与顶点复用（Nanite 的基石）。
- 对 iOS：Metal 3 起全系支持，是 Apple 平台做高密度几何的正确方向。

---

## 4. 裁剪与剔除

- **视锥剔除**：CPU 包围球测试（场景级）或 GPU compute（实例级）；6 平面从 VP 矩阵提取。
- **Guard band**：硬件在裁剪前保留带宽，小三角形直接交给光栅化，减少裁剪开销。
- **背面剔除**：屏幕空间有符号面积判号；注意 Metal 默认 winding 与 OBJ/glTF 导入差异（常见"模型消失"第一原因）。
- 软件裁剪算法（手写软光栅时用）：Sutherland–Hodgman 逐平面裁剪多边形。
- 遮挡剔除（occlusion/hi-Z）→ 第 11 章 GPU-driven pipeline。

---

## 5. 光栅化（本章核心）

### 5.1 三角形设置与边函数
- 边函数 `E(x,y) = (x−x₀)(y₁−y₀) − (y−y₀)(x₁−x₀)`；像素遍历时**增量求值**（+Δx/Δy 一步加法）。
- **Top-Left Rule**：保证相邻三角形不重复不遗漏覆盖同一像素（光栅化规则决定性）。
- 保守光栅化（Conservative Rasterization）：扩大三角形覆盖所有触碰像素——体素化、碰撞检测用。

### 5.2 重心坐标插值
- `P = αA + βB + γC`，`α+β+γ=1`，系数=对角子三角形面积比；任何顶点属性线性插值。
- **透视校正插值（必须理解）**：屏幕空间直接线性插值是错的——属性随 1/w 线性。正确做法：
  ```
  attr = (α·attr_A/w_A + β·attr_B/w_B + γ·attr_C/w_C) / (α/w_A + β/w_B + γ/w_C)
  ```
  GPU 对 varying 自动做；手写软光栅时这是最经典的 bug 点。

### 5.3 Quad 与导数（GPU 的隐藏行为）
- 片元着色以 **2×2 quad** 为单位调度：即便三角形只覆盖 quad 中 1 个像素，4 个都执行（helper lanes）→ 这就是 `ddx/ddy` 的来源。
- 后果 1：细三角形 quad 利用率暴跌（4 像素算 1 个有效）→ 微多边形效率问题 → Nanite 软光栅动机。
- 后果 2：**非均匀控制流（分支）中不能取导数/不能采样需要 mip 的纹理**（quad 内 divergence 无意义）。

### 5.4 Early-Z 与 Hi-Z
- Early-Z：深度测试提前到着色前（不透明物 near→far 排序可显著受益）。
- alpha test/discard 会使 early-Z 失效或降级（历史行为，现代硬件有 depth bounds 等优化）。
- Z-Prepass：先画一遍纯深度，复杂材质 pass 完全免 overdraw（权衡：多一遍几何成本）。

---

## 6. 片元着色

- 输入：插值 varyings + 常量缓冲(灯光/相机) + 纹理 + push constants。
- 导数指令：`ddx/ddy/fwidth`；mip 选择公式（纹理细节在第 4 章）。
- `discard`（alpha test）语义与代价；alpha-to-coverage 借 MSAA 掩码做植被边缘。
- 着色频率：per-pixel / per-vertex(Gouraud) / per-triangle(flat)；可变速率着色 VRS（按区域降频，性能杠杆，Apple 家族支持有限、了解概念即可）。

---

## 7. 输出合并（OM）

### 7.1 深度测试
- 比较函数（less/lequal…）；**Reversed-Z**（far→0, near→1）+ 浮点深度 = 最均匀精度分布（第 1 章 §3.4）。
- z-fighting 缓解：分离几何、polygon offset、提高深度缓冲精度。

### 7.2 模板测试
- `ref & mask` 与缓冲比较，按深度测试结果执行操作（keep/zero/replace/invert/inc/dec）。
- 经典应用：阴影体（shadow volume，历史）、平面反射裁剪、贴花（decal）。

### 7. 混合（Blending）
- `out = src·srcFactor ⟨op⟩ dst·dstFactor`；常见组合：`SrcAlpha,OneMinusSrcAlpha`（透明）、`One,One`（加色发光/粒子）、`One,OneMinusSrcAlpha`（**premultiplied alpha**）。
- **Premultiplied alpha**：iOS Core Animation 默认约定！纹理/渲染输出到 CA 层时理解它可避免一圈"颜色发灰"的 bug。
- 原则：**混合应在线性空间进行**（sRGB RT 由硬件在 OM 出口自动编解码，Metal 的 sRGB 格式自动做对）。
- 透明排序：不透明 near→far（early-z 受益）；透明 far→near（混合不可交换）；无法排序 → 加色混合/OIT(顺序无关透明，Apple 有 raster order group 方案，第 7 章)。

---

## 8. 抗锯齿（AA 全谱系）

### 8.1 走样的本质
- 采样定理：低于信号 Nyquist 频率采样 → 走样；边缘=阶跃=无限高频 → 必然锯齿/闪烁/摩尔纹。

### 8.2 几何采样类
- **SSAA**：全分辨率渲染后下采样——参考方案，最贵。
- **MSAA**：几何采样 ×2/×4/×8，着色每像素一次（质心修正插值防半采样偏移）；sample shading 可强制逐样本（alpha test 场景）。
- **TBDR 上 MSAA 近乎免费**：Apple GPU 在 tile 显存内多采样、on-tile resolve，无带宽爆炸——iOS 开发者应当默认考虑 4xMSAA。

### 8.3 后处理类
- FXAA：边缘检测+局部方向模糊，便宜、会糊细节。
- MLAA/CMAA：形态学抗锯齿。

### 8.4 时序类（现代标准）
- **TAA**：每帧 jitter 相机（Halton(2,3) 序列）→ 渲染 → 用 motion vector 把历史帧颜色 reprojection 到当前 → 邻域钳制（3×3 min/max 或方差钳制防鬼影）→ 指数混合（历史权重 ~0.9）。
- 副作用：鬼影/拖影/细节损失 → 配合锐化（RCAS/CAS）；高光闪烁需要 clamp 策略调优。
- TAA 是虚幻引擎默认 AA，也是 DLSS/FSR2/MetalFX-Temporal 的基础（低分辨率渲染+时序重建=一体化 AA+超分）。

---

## 9. 管线组织形态（架构选型）

| 形态 | 原理 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| Forward | 逐物体逐光源着色 | 简单、MSAA/透明友好、带宽低 | 光源数线性开销 | 移动端默认 |
| Deferred | GBuffer(albedo/normal/roughness/depth…) + 全屏光照 pass | 光照解耦、overdraw 免疫 | 材质表达受限、MSAA 贵、带宽大 | 桌面多光源 |
| Forward+/Clustered | compute 按 tile/锥体划分光源列表，前向着色 | 多光源+移动端 TBDR 亲和 | 实现复杂度 | 手游高端/主机 |
| Visibility Buffer | 只写 instanceID/triID/重心，第二 pass 解析材质 | 极简 GBuffer、与微多边形/光追协同 | 材质 pass 二次取属性 | 新一代引擎（UE5 路线）|

**iOS 决策树**：默认 Forward(+tile 光源剔除)；延迟渲染在 TBDR 上会放大带宽劣势，慎用。

---

## 10. RenderPass 与帧组织

- **RenderPass = 一组 attachment + load/store action**。Metal 显式描述；TBDR 上 pass 边界=tile 生命周期——**控制带宽的第一杠杆**：`loadAction=DontCare`（清屏）、`storeAction=DontCare`（中间 pass）、memoryless RT（深度/模板不回写显存）。
- 帧内 pass 序列典型：DepthPrepass → 不透明 → 天空盒 → 透明 → 后处理链 → UI。
- 多视口/多层渲染：VR 双目单 pass、立方体阴影 6 层 instancing。
- RenderGraph/FrameGraph 概念（声明 pass+资源，自动排屏障与瞬态分配）→ 第 10 章工程化。

---

## 11. 自测清单

- [ ] 白板画出完整管线，标注每阶段输入输出与可编程点
- [ ] 推导透视校正插值并解释为什么屏幕空间线性插值出错
- [ ] 解释 quad/helper lane 机制与它导致的两个性能问题
- [ ] 写出 MSAA 与 TAA 的原理差异；解释 TAA 鬼影与钳制
- [ ] 在 Metal 里把一个 pass 的 load/store 配置到最优并解释带宽收益
- [ ] 说明 Forward/Deferred/Forward+/VisBuffer 的取舍，并给出 iOS 上的选型理由

---

# 扩展篇：软光栅渲染器与关键代码

## A. 软光栅器核心（C++，可直接改造）

```cpp
struct V2F { float x, y;      // 屏幕/像素坐标
             float zNdc;      // 透视除法后的深度
             float iw;        // 1/w_clip —— 透视校正插值之钥
             float u, v; };

float edge(float ax, float ay, float bx, float by, float px, float py) {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);  // cross(b-a, p-a).z
}

void rasterize(FrameBuffer &fb, V2F A, V2F B, V2F C,
               const std::function<Vec3f(float u, float v, float z)> &shader)
{
    float area = edge(A.x, A.y, B.x, B.y, C.x, C.y);
    if (fabsf(area) < 1e-9f) return;               // 退化三角形
    float inv = 1.0f / area;
    int minX = std::max(0,   (int)floorf(std::min({A.x, B.x, C.x})));
    int maxX = std::min(fb.w-1, (int)ceilf (std::max({A.x, B.x, C.x})));
    int minY = std::max(0,   (int)floorf(std::min({A.y, B.y, C.y})));
    int maxY = std::min(fb.h-1, (int)ceilf (std::max({A.y, B.y, C.y})));

    for (int y = minY; y <= maxY; ++y)
    for (int x = minX; x <= maxX; ++x) {
        float px = x + 0.5f, py = y + 0.5f;        // 像素中心采样
        float e0 = edge(B.x,B.y, C.x,C.y, px,py);  // 对边 A
        float e1 = edge(C.x,C.y, A.x,A.y, px,py);  // 对边 B
        float e2 = edge(A.x,A.y, B.x,B.y, px,py);  // 对边 C
        float s = area > 0 ? 1.0f : -1.0f;         // 统一绕向
        if (s*e0 < 0 || s*e1 < 0 || s*e2 < 0) continue;   // 外部（含 top-left 修正见 B）
        float a = e0 * inv, b = e1 * inv, c = e2 * inv;    // 重心坐标

        // 透视校正插值：先插 1/w 再翻回来
        float iw  = a*A.iw + b*B.iw + c*C.iw;
        float z   = 1.0f / iw;
        if (z >= fb.zbuf[y*fb.w + x]) continue;    // z ∈ [0,1]，near=0
        fb.zbuf[y*fb.w + x] = z;
        float u = (a*A.iw*A.u + b*B.iw*B.u + c*C.iw*C.u) / iw;
        float v = (a*A.iw*A.v + b*B.iw*B.v + c*C.iw*C.v) / iw;
        fb.color[y*fb.w + x] = shader(u, v, z);
    }
}
```
性能升级路线：增量求值（每步 x 加 `B.y−A.y` 常量）、`int` 定点化（防浮点抖动）、按 tile 分块并行——正是 GPU 的做法，做完你会"懂硬件"。

## B. Top-Left Rule（共享边的去重规则）

- **问题**：像素中心恰在两三角形共享边上/顶点上，若无规则会双重绘制（透明物体出现亮线）或漏绘。
- **规则**（D3D 约定，屏幕 y 向下）：像素恰在边上时，仅当该边是 **top edge**（水平边且三角形主体在下方）或 **left edge**（非水平且在左侧）才计入。
- 实现惯例（Giesen 的 bias 法）：预计算每条边 bias（top-left 为 0，否则 −1），判定改为 `E + bias > 0`（bias 单位与 E 同量级缩放）。
- **验收测试**（必须写）：渲染两个共享斜边 + 两个共享水平边的三角形，逐像素检查"恰好一方覆盖"；把三角形位置平移 100 个像素重复测试。绕向/坐标约定的差异是此规则 bug 的唯一来源，测试驱动比背公式可靠。

## C. Sutherland–Hodgman 多边形裁剪（裁剪空间实现）

```cpp
// 对一个半空间裁剪：d = sign*v[axis] - v.w ≥ 0 为内侧（含 w，先除后裁是错的）
std::vector<Vec4f> clipPlane(const std::vector<Vec4f> &poly, int axis, float sign) {
    std::vector<Vec4f> out;
    for (size_t i = 0; i < poly.size(); ++i) {
        Vec4f cur = poly[i], prev = poly[(i + poly.size() - 1) % poly.size()];
        float dc = sign * cur[axis] - cur.w, dp = sign * prev[axis] - prev.w;
        auto lerpC = [](Vec4f a, Vec4f b, float t) { return a + (b - a) * t; };
        if (dc >= 0) {                                  // cur 在内
            if (dp < 0) out.push_back(lerpC(prev, cur, dp / (dp - dc)));
            out.push_back(cur);
        } else if (dp >= 0)                             // cur 外 prev 内 → 交点
            out.push_back(lerpC(prev, cur, dp / (dp - dc)));
    }
    return out;
}
// 用法：对 6 个半空间 (x±w, y±w, z±w, 含 near: z≥0) 依次裁剪，再透视除法
```
**为什么在裁剪空间做**：交点插值在 w 未除时线性正确；先除 w 再裁剪会破坏透视校正（亲手踩一次坑胜过读十篇文）。

## D. TAA resolve 着色器骨架

```cpp
// 前置：本帧相机加了 subpixel jitter（Halton(2,3)×8 周期）
// velocity buffer: v = (curNDC.xy − prevNDC.xy) * 0.5（同一顶点 prevVP 变换）
half3 taaResolve(float2 uv, float2 velocity) {
    float2 uvPrev = uv - velocity;
    half3 hist = prevColor.sample(s, uvPrev).rgb;
    half3 cur  = curColor.sample(s, uv).rgb;
    // 邻域钳制：3×3 min/max 盒（或方差钳制 AABB）
    half3 mn = min3x3(curColor, uv), mx = max3x3(curColor, uv);
    hist = clamp(hist, mn, mx);                 // 防 ghosting 的关键一步
    half alpha = 0.1h;                          // 当前帧权重
    if (reprojectFailed(uvPrev)) alpha = 1.0h;  // 出屏/大位移 → 弃历史
    return mix(hist, cur, alpha);
}
```
调参顺序建议：先关钳制看鬼影 → 开 min/max → 换 variance clip → 最后调 alpha（0.05~0.2）。

## E. 带宽估算公式（load/store action 分析用）

```
单 pass 带宽 ≈ W×H×bpp × ( load系数 + store系数 + 深度/模板附加 )
示例: 1080p(1920×1080) RGBA16F(8B) RT, load=1, store=1:
     1920×1080×8×2 ≈ 33 MB/帧/层 —— 叠加 5 个后处理 pass ≈ 165 MB/帧
60fps → ~10 GB/s，对 30~50 GB/s 的手机 GPU 是 20~30% 预算
```
结论：**能 DontCare 的绝不 load，中间 RT 尽量合 pass，TBDR 上把工作留在 tile 内**——数字自己算一遍，"带宽直觉"就建立了。

## F. 习题与解答

**Q1：MSAA 为什么救不了高光闪烁和 alpha-test 边缘？**
A：MSAA 只提升**几何覆盖率**的采样（边缘锯齿），着色每像素仍一次。高光闪烁是**着色信号本身的高频**（时序/像素间），需 SSAA/TAA；alpha-test 边缘在着色内 discard，几何覆盖无锯齿但着色值有——需 sample shading 或 TAA。

**Q2：一个只覆盖 1 个像素的三角形，quad 利用率是多少？**
A：4 个 lane 执行 1 个有效片元 = **25%**。微多边形场景（体积植被/远处 LOD）整帧可能 <40% 着色器利用率——这就是"小三角形是光栅化黑洞"的定量版本，也是 meshlet/软件光栅化的动机。

**Q3：premultiplied alpha 与 straight alpha 的混合公式差异？**
A：straight：`out = src.rgb·a + dst·(1−a)`；premultiplied：纹理已存 rgb·a，直接 `out = src.rgb + dst·(1−a)`。Core Animation 层默认 premultiplied——图不透明区域 rgb>a（"白边"bug）说明忘了预乘。GPU 上 premultiplied 还允许混合因子统一为 `(One, OneMinusSrcAlpha)`，bloom/粒子更简洁。

**Q4：为什么透明物体必须从后往前，而加色混合（One,One）不用排序？**
A：普通 alpha 混合 `out = s·a + d·(1−a)` 对 d 非对称（不满足交换律），顺序错则层叠关系错；加色混合 `out = s + d` 可交换，无序也正确——粒子系统用加色混合省掉排序的经典依据。

**Q5：Early-Z 在什么情况下失效？**
A：片元着色器写深度/discard（alpha test）时，硬件无法保证提前剔除的合法性 → 退化到着色后测试。对策：Z-prepass 先写纯深度，主 pass 用 `equal` 深度比较 + 无 discard。
