# 06 · 光线追踪与离线渲染

> 参考实现：[code/10-path-tracer](../code/10-path-tracer/)（Cornell Box + NEE + 玻璃，C++ 零依赖多线程）

> 从 whitted 到路径追踪到 PBRT。本章让你的理解越过"实时近似"抵达物理正确的源头，反过来理解实时渲染每个 hack 在近似什么。实践主线：《Ray Tracing in One Weekend》三部曲 → PBRT。

---

## 1. 光线与求交

### 1.1 光线定义
- `r(t) = o + t·d`，t ∈ (t_min, t_max) 区间管理（自遮挡 ε：t_min ≈ 1e-3 按场景尺度）。

### 1.2 基本求交（全部要求能手推）
- **球**：`‖o+td−c‖² = r²` → 一元二次 `t² + 2t·d·(o−c) + ‖o−c‖²−r² = 0`；判别式<0 擦过；法线 `p−c`（球面 UV 由经纬角计算）。
- **平面/三角形**：
- **Möller–Trumbore（背熟）**：
  ```
  e₁=v₁−v₀, e₂=v₂−v₀, s=o−v₀
  s₁=d×e₂,  s₂=s×e₁
  det = s₁·e₁  (|det|<ε → 平行)
  t = (s₂·e₂)/det;  u = (s·s₁)/det;  v = (d·s₂)/det
  命中 ⇔ u≥0, v≥0, u+v≤1, t∈区间
  ```
- **AABB（slab 法）**：每轴求 [t_enter, t_exit] 区间取交非空 → 命中；BVH 遍历的核心原语（GPU 上分支友好写法）。
- 求交健壮性：watertight mesh（共享边无缝隙，PBRT 有专章）；浮点误差重投影。

### 1.3 加速结构回顾
- BVH 遍历（栈式，非递归）：先近后远、节点剔除 t>t_hit；SAH 建树（第 5 章 §6）。

---

## 2. Whitted 光线追踪（1980，入门算法）

- 递归：primary ray → 命中点按材质派生 **shadow ray**（向光源，查遮挡）、**reflection/refraction ray**（Snell 折射 + 全内反射 + Fresnel 分光）。
- Snell：`n₁sinθ₁ = n₂sinθ₂`；全内反射（TIR）条件；精确 Fresnel（dielectric 公式）与 Schlick 近似关系。
- 局限：仅镜面/折射传播、点光源硬阴影——是"路径追踪的特例"。

---

## 3. 路径追踪（Kajiya 1986，现代离线渲染核心）

### 3.1 从渲染方程到估计器
- 算子级数 `L = E + KE + K²E + …`，每项 = 多一次弹射。
- **路径追踪 = 对该级数做随机游走采样**：
  ```
  从相机发射光线 → 命中表面：
    1) 直接光采样（NEE，见下）
    2) 按 BRDF pdf 弹一条新光线（俄罗斯轮盘 RR 概率终止）
    3) 累积 throughput × (BRDF·cosθ / pdf)
  ```
- 单条路径/像素 → 低成本但高方差 → 每像素成百上千样本（spp）平均。

### 3.2 直接光采样（NEE, Next Event Estimation）
- 每个命中点显式向光源（按光源立体角/面积分布）采样 shadow ray → 方差骤降（无需碰运气弹中光源）。
- 面积↔立体角转换：`dω = cosθ·dA / r²`（光追最常用的几何换算，务必手推一次）。
- 剩余弹射仍按 BRDF 采样 → **同一路径上 NEE 与 BRDF 命中光源重复计数问题 → MIS 解决**。

### 3.3 MIS（Multiple Importance Sampling）
- 组合多个采样策略，权重 `wᵢ = nᵢpᵢ / Σⱼnⱼpⱼ`（balance heuristic；power heuristic 略优）。
- 直觉：BRDF 采样在高光区强、光采样在大面积光强，MIS 自动取长——一个公式兼容两者。

### 3.4 方差控制工具箱
- **重要性采样**：pdf ∝ 被积函数形状（GGX VNDF、cosine、发光分布）。
- **Russian Roulette**： throughput 低时以概率 P 继续并除以 P（无偏省算力）。
- 分层采样（每像素 2×2 分层）；样本重用；相关采样（同一随机数跨像素 → 噪声成结构化更好去）。
- 诊断：逐 bounce 灰度输出、方差图、firefly（低概率高贡献样本）→ clamp / 特殊采样。

---

## 4. 高级离线算法（概念地图）

- **双向路径追踪 BDPT**：从相机和光源同时建子路径再连接——适合焦散/间接主导场景（小光源 + 毛玻璃）。
- **Metropolis Light Transport**：马尔可夫链扰动已有路径 → 极端光路（水波焦散）收敛快；噪声结构不均匀。
- **Photon Mapping**（两遍）：光子从光源弹射存储 → 命中点密度估计（KNN）重建入射光；有偏但一致；progressive photon mapping 收敛到无偏。GPU 实时变体：光子 splatting。
- **VCM/UPS**：BDPT + photon merging 合体（ Production 主力之一）。

---

## 5. 参与介质与体积渲染

### 5.1 辐射传输方程（RTE）
```
dL/ds = −σₜL + σₛ∫p(ω',ω)L(ω')dω' + Q
σₜ = σₐ(吸收) + σₛ(散射)
```
- **Henyey–Greenstein 相函数**：`p(θ) = (1−g²)/(4π(1+g²−2g·cosθ)^{3/2})`，g 控制前向/后向散射（皮肤 g≈0.8~0.9，烟 g≈0）。

### 5.2 体积采样
- 均匀介质 ray marching（步进积分）；**delta tracking / Woodcock**（自由程采样，处理非均匀密度，无偏）；equiangular 采样（光源附近低方差）。
- 单次散射 vs 多次散射；云/雾/天空的表现力来源。
- 实时对应：体积雾/云 raymarch（第 11 章），体渲染神经化（NeRF，第 11 章）。

---

## 6. 相机与成像

- 针孔 vs **薄透镜**（thin lens）：光圈 f 数、对焦距离 → 景深 DoF；CoC（circle of confusion）公式与实时 DoF 后处理的对应。
- Bokeh 形状=光圈形状（ blades）；色散（色差）模拟。
- 快门/运动模糊：时间维度采样（分布式中的一维 jitter）； rolling shutter 果冻效应。

---

## 7. 采样器

- 随机 / 分层 / **Halton / Sobol**（低差异，收敛加速 ~O(1/N) vs O(1/√N) 随机）；Owen 扰乱随机化；**蓝噪声**像素层扰动（观感优化）。
- 时空复用：帧间样本渐进累积（progressive rendering，PBRT/抓帧工具默认行为）。

---

## 8. 降噪（低 spp 的救命稻草，实时光追同款技术）

- 输入辅助 buffer：albedo / normal / depth（第一 bounce 的 GBuffer）。
- **SVGF**（时空方差引导滤波）：时间累积 + 颜色盒测试 + 多尺度 atrous 联合双边滤波（以深度/法线/albedo 为引导）。
- 机器学习类：**OIDN / OptiX Denoiser**——1~4 spp 输入近乎干净输出；训练于 Monte Carlo 噪声对。
- 实时管线标配：1spp 光追 + AI/滤波重建 = "RTX ON" 的真实构成。

---

## 9. PBRT 阅读与实现路线

- [pbr-book.org](https://www.pbr-book.org/)（第 4 版免费在线）。
- 建议顺序：Ch1-2 系统/数学 → Ch4 采样 → Ch5-6 形状/加速 → Ch7-8 相机/材质 → Ch11-14 积分器（路径追踪/BDPT/光子映射/体渲染）。
- 实现里程碑：相机+球+Lambert → 三角网格+BVH → NEE+MIS → GGX 金属/玻璃 → 体渲染 → BDPT。
- 同级开源可读渲染器：**Cycles**（Blender，工程参考）、Falcor（NVIDIA 研究框架）、mitsuba。

---

## 10. 硬件光追（Metal RT，实机必修）

### 10.1 API 形态（Metal 3）
- 加速结构：**BLAS**（网格，`intersector` 遍历）+ **TLAS**（实例变换层）。
- Shader：光追着色器阶段（`[[intersection(...)]]`）或 compute 里 `intersector<...>` ray query。
- 命中属性：instance ID / primitive ID / 重心 / 距离；自定义 intersection（alpha-tested 几何、SDF）。
- 绑定表（binding table）按材质分桶命中 shader。

### 10.2 实践认知
- 光追成本 = 射线数 × BVH 遍历；A13/M1 后 Apple 全系支持。
- 1~2 spp + 降噪是实时唯一定式：RT 阴影 / RT 反射 / RT GI 各自管线化（第 11 章）。
- 加速结构内存可观（场景三角数 × ~48B 量级）；动态物体 TLAS 重构成本要摊帧。
- Apple 官方示例："Rendering reflections"/"Global illumination" sample 必读必跑。

---

## 11. 自测清单

- [ ] 手推 Möller–Trumbore 与 slab AABB
- [ ] 推导面积↔立体角转换 `dω = cosθ·dA/r²`
- [ ] 写出路径追踪主循环（含 NEE + RR + MIS 三件套）
- [ ] 解释 MIS balance heuristic 为何能自动偏向好的策略
- [ ] 说明 delta tracking 如何处理非均匀密度介质
- [ ] 阐述 SVGF 的三层结构（累积/盒测试/引导滤波）
- [ ] 说出 TLAS/BLAS 分层的工程动机；在 Metal 里跑通官方 RT 示例

---

# 扩展篇：路径追踪器完整实现

## A. 带直接光采样（NEE）+ MIS 的路径追踪主循环（C++17）

```cpp
struct Material {
    Vec3 albedo; float rough, metallic;      // GGX 参数化
    Vec3 Le = Vec3(0);                       // 自发光
    bool isLight() const { return Le.max() > 0; }
};

Vec3 evalBRDF(const Material &m, const Vec3 &n, const Vec3 &v, const Vec3 &l);
float pdfBRDF(const Material &m, const Vec3 &n, const Vec3 &v, const Vec3 &l);  // VNDF 版

Vec3 radiance(const Scene &sc, Ray ray, Rng &rng, int maxBounce = 8) {
    Vec3 L(0), beta(1);                       // beta = 累计 throughput
    bool specularBounce = true;               // 上一跳是否镜面(决定能否计发光)

    for (int b = 0; b < maxBounce; ++b) {
        Hit h;
        if (!sc.intersect(ray, h)) return L + beta * sc.environment(ray.d);

        const Material &m = *h.m;
        Vec3 n = h.n, v = -ray.d;

        // ---- 1) 相机/镜面路径命中光源: 直接计发光 (与 NEE 互斥由 MIS 权重处理) ----
        if (m.isLight() && specularBounce) L += beta * m.Le;

        // ---- 2) NEE: 对面光源采样 (均匀面积采样) ----
        if (!m.isLight() && sc.lights.size()) {
            float lightPdf;                  // 面积 pdf (1/A)
            Vec3 lp = sampleLight(sc, rng, lightPdf);
            Vec3 wi = lp - h.p; float dist2 = dot(wi, wi);
            float dist = sqrt(dist2); wi /= dist;
            float NdotL = dot(n, wi);
            if (NdotL > 0 && !sc.occluded(h.p + n * 1e-3f, lp)) {   // shadow ray
                float cosLight = max(dot(lightNormal(lp), -wi), 0.f);
                // 面积 pdf → 立体角 pdf: p_w = p_A * dist² / cosLight
                float pdfLightW = lightPdf * dist2 / max(cosLight, 1e-4f);
                float pdfBsdfW = pdfBRDF(m, n, v, wi);
                // MIS (balance): 光采样策略权重
                float wLight = pdfLightW / (pdfLightW + pdfBsdfW);
                L += beta * evalBRDF(m, n, v, wi) * NdotL * m.LeOf(lp) * wLight / pdfLightW;
            }
        }

        // ---- 3) BRDF 采样: 继续路径 ----
        Vec3 wi; float pdf;
        Vec3 f = sampleBRDF(m, n, v, rng, wi, pdf);      // VNDF 采样
        if (pdf <= 0 || f.isBlack()) break;
        float NdotL = dot(n, wi);
        if (NdotL <= 0) break;

        // 若本方向直射光源: BRDF 采样的 MIS 权重 (与 2) 互补)
        if (hitsLight(sc, h.p, wi) ) {
            float pdfLightW = ...; // 同上换算
            L += beta * f * NdotL * LeOf(...) * (pdf / (pdf + pdfLightW)) / pdf;
        }

        beta *= f * NdotL / pdf;
        specularBounce = isDelta(m);          // 镜面材质无 NEE

        // ---- 4) Russian Roulette: throughput 低时概率终止 (除以 P 保持无偏) ----
        float p = std::min(0.95f, beta.max());
        if (rng.next() > p) break;
        beta /= p;

        ray = Ray{h.p + n * 1e-3f, wi};
    }
    return L;
}
```
结构要点：**NEE 与"BRDF 采样恰好命中光源"是同一积分的两种采样策略**，MIS 权重防双计；`beta *= f·cosθ/pdf` 是每跳的核心公式；RR 的 `除以 P` 是无偏性的关键。

## B. SAH 建 BVH（生产级建树准则）

```cpp
// 代价模型: 遍历成本 1 次 = 计算成本 80 次(经验值); 
// Cost(split) = tTrav + leftArea/countL * SAH ... 经典形式:
//   C = C_trav + (SA_L * N_L + SA_R * N_R) / SA_parent
int bvhBuild(std::vector<Prim> &prims, int l, int r, std::vector<Node> &nodes) {
    // 1) 求当前区间包围盒/质心盒
    // 2) 对 3 轴: 按质心排序后线性扫描 (N 次前后面积累积), 记录最小代价切分
    //    for (i = l; i < r; ++i) {
    //        boxL = 累并[l..i], boxR = 累并[i+1..r-1];
    //        cost = boxL.area() * (i-l+1) + boxR.area() * (r-i);
    //    }
    // 3) 叶子判定: count <= 4 或最优代价 > 直接叶代价
    // 4) 递归左右
    // 复杂度 O(n log²n) 排序版; binned SAH (32 bins) 是生产标准, O(n log n)
}
```
**Binned SAH**：每层把包围盒切成 32 个桶，只评估桶边界（32 种）切分——三 A 引擎/HW AS 的标准建法。

## C. 面积 ↔ 立体角换算（推导+代码）

**推导**：面元 dA 距离 r、其法线与连线夹角 θ'。它对观察点张的立体角：
```
dω = dA·cosθ' / r²      （投影面积 / 距离平方球面）
```
**采样换算**：均匀采样面光（pdf_A = 1/A）等价于立体角域：
```
pdf_ω = pdf_A · r² / cosθ' = r² / (A·cosθ')
```
```cpp
Vec3 sampleRectLight(const RectLight &L, const Vec3 &p, Rng &rng,
                     Vec3 &wi, float &pdfW, float &dist) {
    Vec2 u{rng.next(), rng.next()};
    Vec3 lp = L.corner + L.ex * u.x + L.ey * u.y;
    Vec3 d = lp - p; dist = length(d); wi = d / dist;
    float cosL = max(dot(L.normal(), -wi), 0.0f);
    pdfW = (cosL > 0) ? dist * dist / (L.area() * cosL) : 0;   // 不可见返回 0
    return lp;
}
```
cosθ'≤0 时返回 pdf=0（背面不发光）；忘掉 `dist²/cosθ'` 是新手路径追踪"亮度不对"的头号原因。

## D. 蒙特卡洛三连实验（亲手做，胜读十篇）

1. **收敛率**：渲染 Cornell Box，spp ∈ {16, 64, 256, 1024}，算与 16384spp 参考图的 RMSE——验证 `误差 ∝ 1/√N`。
2. **重要性采样收益**：同一场景 cosine 采样 vs VNDF 采样，粗糙金属球在低 spp 下的噪声对比（后者干净一个量级）。
3. **MIS 必要性**：只开 NEE（镜面高光糊）vs 只开 BRDF 采样（小光源噪声爆炸）vs 双开——三张图对比，MIS 的意义一目了然。

## E. 习题与解答

**Q1：为什么 NEE + BRDF 命中会双计？MIS 如何消除？**
A：同一个积分 `∫f·L_e·cosθdω` 用两种采样策略各算一次估计量，简单相加期望翻倍。MIS 用 `w_light + w_bsdf = 1` 的权重把两个估计量合并为一个混合 pdf 的单估计量（`f/p_mixed`，p_mixed = 加权 pdf）——期望不变、方差取两者之短。

**Q2：RR 为什么除以继续概率 P 仍无偏？**
A：`E[X·B/P] = E[E[X·B/P | X]] = E[X·P/P] = E[X]`（B 为伯努利指示）——期望不变、方差略增，用可控方差换算力。

**Q3：firefly（白色亮斑）成因与三种对策？**
A：低概率高贡献样本（如玻璃 caustics 路径）。对策：①针对该光路改进采样（MNEE/LTC-光采样）②clamp 单样本贡献（有偏但稳定）③按亮度分层累积样本（先平均后 clamp）。

**Q4：为什么 BVH 遍历"先近后远"能提前剔除？**
A：维护当前最近命中距离 t_hit；若节点最近盒交点 t > t_hit，整个子树不可能更近 → 剪枝。实现要点：子节点按射线参数排序入栈。

**Q5：金属球上渲染自身倒影出现黑斑，最可能的原因？**
A：shadow ray 的自遮挡 ε 不足（起点仍在表面内）——按场景尺度放大 t_min（1e-3~1e-2）或沿法线偏移起点；工程级方案是 robust self-intersection avoidance（沿法线+按曲面曲率缩放偏移）。
