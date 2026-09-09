# 01 · 图形学数学基础

> 本章是全书的地基。原则：**对每个概念建立几何直觉，能推导 MVP，而不是会证明定理**。建议与 GAMES101 前 5 讲、3Blue1Brown《线性代数的本质》配合使用。

---

## 1. 向量

### 1.1 基本概念
- 图形学只用 2D/3D/4D 实向量；代码里点与向量同类型，语义不同（点=位置，向量=方向+长度）。
- 归一化 `v/‖v‖`；`‖v‖ = √(Σvi²)`（NEON：`vdotq_f32` + `vsqrtq_f32`）。

### 1.2 点积（内积）
- 代数：`a·b = Σ aᵢbᵢ`；几何：`a·b = ‖a‖‖b‖cosθ`。
- 图形学用途清单（必须条件反射级熟练）：
  - 求夹角/判断朝向：`>0` 同向、`=0` 垂直、`<0` 反向。
  - 投影：`proj_b(a) = (a·b̂)b̂`。
  - **Lambert 余弦光照项 `N·L`**：本质是"单位法线接收到的单位光强的投影"。
  - 背面判断 `N·V`、菲涅尔项 `1−N·V`、BRDF 中无数 cos 因子。
- SIMD 提示：Apple GPU/M 系列 NEON 有 `vdotq_f32`，点积是向量化收益最高的原语之一。

### 1.3 叉积（外积）
- `a×b` 垂直于两者（右手系），`‖a×b‖ = ‖a‖‖b‖sinθ` = 平行四边形面积。
- 性质：`a×b = −b×a`、`a×a = 0`。
- 图形学用途：
  - 三角形法线 `n = normalize((p1−p0)×(p2−p0))`；面积 = `‖叉积‖/2`。
  - 判定点在三角形内：三条边叉积同号。
  - 构造正交基：`right = normalize(forward × worldUp)`。
  - 求解三角形重心坐标、Möller–Trumbore 光线求交（见第 6 章）。

### 1.4 坐标系与正交基
- 任意坐标系 = 原点 + 3 个单位正交基。**"把物体变到某坐标系" = "把该坐标系的基作为矩阵列"**——这句话想通，所有变换矩阵不再需要死记。
- Gram–Schmidt 正交化；实用构造（已知 forward 求 up/right）。

---

## 2. 矩阵与变换

### 2.1 矩阵 = 线性变换
- 列向量惯例（图形学标准）：`M·v`，**矩阵的每一列 = 原基向量变换后的落点**。
- 旋转保持长度与角度；缩放/错切不保持。
- 基本矩阵手写能力：平移 T、绕三轴旋转 Rx/Ry/Rz、缩放 S、错切。

### 2.2 齐次坐标（4D）
- 引入 w 分量把"线性变换+平移"统一成 4×4：
  - 点 w=1，方向 w=0（方向不受平移影响）。
  - 透视除法伏笔：投影后 w 携带深度信息。
- 复合顺序：`M = T·R·S`，**从右往左生效**；矩阵乘法不可交换（举一例：先旋转再平移 vs 反之）。
- 逆变换：刚体变换逆 = 转置（`R⁻¹ = Rᵀ`）。

### 2.3 绕任意轴旋转：Rodrigues 公式
```
R = I·cosθ + sinθ·[k]ₓ + (1−cosθ)·k·kᵀ
其中 k 为单位轴，[k]ₓ 为反对称叉积矩阵
```

### 2.4 法线变换：逆转置矩阵（高频考点）
- 切向量随 `M` 变换：`t' = Mt`；法线必须用 `n' = (M⁻¹)ᵀn`。
- 推导思路：要求 `n'·t' = n·t = 0` 恒成立 → `n' = (M⁻¹)ᵀn` 是唯一解。
- 刚体变换时退化为 `M` 本身（这就是为什么旋转物体可以直接转法线）。

### 2.5 LookAt / View 矩阵
- 输入 eye/target/up；构造 forward/right/up 三个轴 + 平移。
- View 矩阵 = **相机模型矩阵的逆**：把世界变到"相机在原点、看 −Z"的相机空间。

---

## 3. MVP 变换与投影（全书最重要的推导）

### 3.1 三个矩阵
| 矩阵 | 作用 |
|---|---|
| Model | 局部/物体空间 → 世界空间 |
| View | 世界空间 → 相机空间 |
| Projection | 相机空间 → 裁剪空间（随后透视除法 → NDC）|

### 3.2 透视投影推导（必须亲手推一遍）
- 视锥由 near/far/fovY/aspect 定义，相机看 −Z。
- 相似三角形：`x' = x·n/(−z)`，`y' = y·n/(−z)`——除以 z 是透视的本质。
- 矩阵技巧：把除法推迟到 w：令 `w_clip = −z`。
- OpenGL 惯例结果（f = 1/tan(fovY/2)）：
```
P = | f/aspect  0   0                        0                      |
    | 0         f   0                        0                      |
    | 0         0   (far+near)/(near−far)    2·far·ear/(near−far)   |
    | 0         0   −1                       0                      |
```
- **API 差异（Metal 踩坑点）**：Metal/D3D 的 NDC z∈[0,1]（OpenGL 是 [−1,1]）；Metal 的 NDC y 向下、viewport 原点在左上。初学时强烈建议按 OpenGL 推导理解，再对照 Metal 修正第三行与 y 翻转。

### 3.3 透视除法与视口变换
- 裁剪在 w>0 空间完成（对 6 个裁剪平面做 Sutherland–Hodgman）。
- `xyz/w` → NDC → 视口矩阵（缩放平移到像素坐标）。

### 3.4 深度的非线性与 Reversed-Z
- `z_ndc = A/z + B` 形式 → **近处精度高、远处精度低**，1/z 分布。
- z-fighting：共面/近共面物体闪烁。对策：拉近平面间隔、polygon offset、**Reversed-Z**（near→1，far→0，配合浮点深度缓冲可获得远距离均匀精度；Metal 推荐）。

### 3.5 视锥体与包围体
- 视锥 6 平面可从 `VP` 矩阵直接提取（Gribb–Hartmann：每行组合）。
- 包围球/AABB 与平面做剔除测试——CPU 剔除和 GPU-driven 剔除的基础原语。

---

## 4. 四元数

### 4.1 定义与性质
- `q = w + xi + yj + zk`，`i²=j²=k²=ijk=−1`；单位四元数表示 3D 旋转。
- **q 与 −q 表示同一旋转**（双倍覆盖），插值时注意取短弧（`if dot<0: q=−q`）。
- 轴角互换：`q = [cos(θ/2), sin(θ/2)·axis]`；旋转点：`p' = q·p·q⁻¹`。
- 四元数→矩阵（3×3，务必抄写并测试）：
```
| 1−2(y²+z²)   2(xy−wz)   2(xz+wy) |
| 2(xy+wz)   1−2(x²+z²)   2(yz−wx) |
| 2(xz−wy)    2(yz+wx)  1−2(x²+y²) |
```

### 4.2 为什么不用欧拉角/矩阵插值
- 欧拉角：万向锁（第二次旋转 ±90° 时第一次与第三次轴重合）、插值路径不自然。
- 矩阵：9 个数 6 个自由度冗余，插值后需正交化。
- 四元数：**slerp 球面插值**给出恒定角速度的最短弧。nlerp 是廉价近似（小角度够用）。

### 4.3 应用场景
- 相机平滑跟随（slerp 朝向目标）、骨骼动画旋转轨道、IMU/ARKit 姿态数据（iOS 开发者天天接触的 `simd_quatf` 就是它）。

---

## 5. 微积分（图形学最小集）

- **偏导/屏幕空间导数**：GPU 上 `ddx/ddy` = 相邻像素函数值之差（由 2×2 quad 保证，见第 2 章）。核心用途：mipmap 选择、法线贴图 TBN 构造、抗锯齿宽度 `fwidth`。
- **梯度→法线**：高度场 h(x,y) 的法线 `n = normalize(−∂h/∂x, −∂h/∂y, 1)`。
- **定积分**：irradiance = 对半球 radiance 的 cos 加权积分——渲染方程（第 3 章）就是积分，实时渲染 = 对积分做各种近似，离线渲染 = 蒙特卡洛数值积分。
- 积分大多解不出解析解 → 一切指向 §6 蒙特卡洛。

---

## 6. 概率与蒙特卡洛（现代渲染的地基）

### 6.1 基础
- 随机变量、PDF/PMF、CDF；期望 `E[X] = ∫x·p(x)dx`；方差 `Var = E[X²]−E[X]²`。
- 大数定律：样本均值→期望；估计量的**无偏/一致**之分（无偏 = 期望等于真值；一致 = 样本够多收敛于真值）。

### 6.2 蒙特卡洛积分（背下来）
```
∫ f(x) dx ≈ (1/N) Σ f(xᵢ)/p(xᵢ),   xᵢ ~ p
```
- p 与 f 形状越接近方差越小 → **重要性采样**的全部动机。
- 唯一硬性要求：p 必须覆盖 f 的支撑集（f≠0 处 p≠0）。

### 6.3 采样技术
- **逆 CDF 法**：解 `F(x) = ξ` 得 x。例：幂律分布 p(x)=nxⁿ⁻¹ → `x = ξ^(1/n)`。
- 常用目标分布：均匀圆盘（concentric 映射避免方格畸变）、半球均匀、**余弦加权**（pdf = cosθ/π，生成式：`φ=2πξ₁; r=√ξ₂; z=√(1−ξ₂)`）。
- 方差缩减四板斧：分层采样、重要性采样、MIS、Russian Roulette（详见第 6 章）。

### 6.4 低差异序列与蓝噪声
- Halton（基数 2,3,5,…）、Sobol：比随机数更快收敛，TAA/DLSS 的 jitter 序列来源（Halton(2,3)）。
- Owen 扰乱、Cranley 旋转：给低差异序列加随机化防条纹。
- 蓝噪声：误差在像素邻域不相关 → 观感好；游戏用时空蓝噪声（STBN）。

---

## 7. 浮点与数值常识

- IEEE 754：符号/指数/尾数；float32 / **half(fp16)** / bfloat16。
- **Apple GPU fp16 满速率（fp32 一半吞吐）** → Metal shader 里能用 `half` 就用 `half`，这是移动端第一优化课。
- 精度陷阱：大数吃小数、灾难性抵消；大世界坐标顶点抖动 → **相机相对渲染**（世界原点挂在相机上）。
- 永远不要 `==` 比较浮点；用相对 epsilon。
- Newton 迭代：光线-球求交的快速精确解、`rsqrt` 精化。

---

## 8. 常用几何速查

- 点到平面距离 `d = n·p + D`（单位 n）；三点定平面。
- 线段最近点对（胶囊体碰撞的基础）。
- 三角形：重心坐标、内心/外心；AABB 相交测试；Ritter 包围球。
- 平面内点测试与半空间；半边数据结构见第 5 章。

---

## 9. 自测清单

- [ ] 白板推导透视投影矩阵与透视校正插值
- [ ] 解释法线为什么用逆转置
- [ ] 手写四元数→矩阵并在代码中验证
- [ ] 写出蒙特卡洛估计式并解释 p 的选择对方差的影响
- [ ] 用逆 CDF 法采样余弦加权半球方向（代码验证 pdf=cosθ/π）
- [ ] 解释 ddx/ddy 在 GPU 上如何实现（2×2 quad）

---

# 扩展篇：完整推导与代码

## A. 透视投影逐步推导（从相似三角形到矩阵）

**设定**：相机位于原点看向 −Z；近平面 z=−n，远平面 z=−f；fovY 与 aspect。

**Step 1 投影几何**：点 (x, y, z)（z<0）与相机连线交近平面于：
由相似三角形 `x_p = n·x/(−z)`，`y_p = n·y/(−z)`——**除以 −z 是透视的全部秘密**。

**Step 2 设计矩阵**：希望矩阵乘法后 `w_clip = −z`，则透视除法自动完成 Step 1：
```
P = | n      0      0                    0        |      x_clip = n·x
    | 0      n      0                    0        |      y_clip = n·y
    | 0      0      α                    β        |      z_clip = αz+β
    | 0      0      −1                   0        |      w_clip = −z
```
（n = 1/tan(fovY/2) 时 fov 已包含；aspect 乘进第一行 x。）

**Step 3 解 α、β**（OpenGL 约定 z=−n→−1，z=−f→+1）：
```
z_ndc = (αz+β)/(−z)
z=−n:  (−αn+β)/n = −1  →  −αn + β = −n
z=−f:  (−αf+β)/f = +1  →  −αf + β = +f
两式相减: −α(n−f) = −(n+f)  →  α = (n+f)/(n−f)
回代:  β = 2nf/(n−f)
```

**Step 4 Metal 修正**（z∈[0,1]，y 向下）：同法解得 `α = f/(n−f)`，`β = nf/(n−f)`；y 行取负翻转。验证：z=−n → 0 ✓，z=−f → 1 ✓。

```cpp
// Metal 可直接使用的透视矩阵（simd_float4x4 为列主序）
simd_float4x4 perspectiveMetal(float fovY, float aspect, float n, float f) {
    float t = 1.0f / tanf(fovY * 0.5f);
    return {
        simd_float4{t / aspect, 0, 0, 0},
        simd_float4{0, -t, 0, 0},               // y 取负：Metal NDC y 向下
        simd_float4{0, 0, f / (n - f), -1},     // w_clip = -z, z∈[0,1]
        simd_float4{0, 0, n * f / (n - f), 0}
    };
}
```

## B. 透视校正插值：为什么与怎么修

**错误做法**：屏幕空间重心 (α,β,γ) 直接 `a = α·a_A + β·a_B + γ·a_C`。
**病根**：投影是非线性映射（除以 z），属性在**世界空间随 1/z 线性**变化，屏幕空间线性插值 ≠ 世界空间线性。

**修复**（可推导）：把 `a/w` 与 `1/w` 当作屏幕空间线性量插值，再相除：
```
a = (α·a_A/w_A + β·a_B/w_B + γ·a_C/w_C) / (α/w_A + β/w_B + γ/w_C)
```
**直觉验证**：纹理在远处三角形上应均匀压缩，若用错误插值，中点属性会偏向某个顶点（经典贴图扭曲 bug）。

```cpp
// 软光栅器内的正确写法（iwX = 1/w_clip 预计算）
float iw = a*iwA + b*iwB + c*iwC;
float u  = (a*iwA*uvA.x + b*iwB*uvB.x + c*iwC*uvC.x) / iw;
```

## C. LookAt / View 矩阵代码

```cpp
simd_float4x4 lookAt(simd_float3 eye, simd_float3 target, simd_float3 up) {
    simd_float3 f = simd_normalize(target - eye);      // forward
    simd_float3 r = simd_normalize(simd_cross(f, up)); // right
    simd_float3 u = simd_cross(r, f);                  // 正交后的 up
    // 世界→相机：相机看 -Z；R 的行 = 相机基向量（列主序故这样排）
    return {
        simd_float4{r.x, u.x, -f.x, 0},
        simd_float4{r.y, u.y, -f.y, 0},
        simd_float4{r.z, u.z, -f.z, 0},
        simd_float4{-simd_dot(r, eye), -simd_dot(u, eye), simd_dot(f, eye), 1}
    };
}
```
要点：**View = 相机 Model 矩阵的逆**；平移列 = −(相机基·eye)。

## D. slerp 推导与实现

- 目标：单位四元数球面上**恒定角速度**从 q₀ 到 q₁。
- 推导骨架：把 q₁ 分解为平行于 q₀ 的分量 + 垂直分量 `q⊥ = q₁ − (q₀·q₁)q₀`（归一化）；t 时刻位于 `q(t) = q₀·cos(tθ) + q̂⊥·sin(tθ)`，θ = 两四元数夹角。用 sin 展开整理即得：
```
slerp(q₀, q₁, t) = [sin((1−t)θ)·q₀ + sin(tθ)·q₁] / sinθ,   cosθ = q₀·q₁
```
```cpp
simd_quatf slerp(simd_quatf q0, simd_quatf q1, float t) {
    float d = simd_dot(q0, q1);
    if (d < 0) { q1 = -q1; d = -d; }          // 取短弧
    if (d > 0.9995f) return simd_normalize(simd_mix(q0.vector, q1.vector, t)); // 近似退化
    float th = acosf(d), s = sinf(th);
    return simd_quatf(simd_mix(q0.vector * sinf((1-t)*th), q1.vector * sinf(t*th), 1/s));
    // 即 (q0*sin((1-t)θ) + q1*sin(tθ)) / sinθ
}
```
- 近距离用 nlerp（归一化线性插值）足够且更快；大角度（>90°）必须 slerp。

## E. 余弦加权采样：推导 + 代码

**目标**：半球上按 `pdf(ω) = cosθ/π` 采样（漫反射 BRDF 采样的最优 pdf）。

**构造**：先均匀采样单位圆盘，再"抬升"到半球：
```
r = √ξ₁ （√ 保证圆盘均匀——面积微元 r·dr·dφ），φ = 2π·ξ₂
方向 = (r·cosφ, r·sinφ, z)，z = √(1−ξ₁)
```
**验证 pdf**：立体角微元 `dω = dA_proj/r² = dA_disk/z`（把圆盘点垂直投影到单位半球）；
`pdf = z/π` ✓（分母 π 是半球余弦积分归一化 `∫cosθdω = π`）。

```cpp
Vec3 cosineSample(float xi1, float xi2, float &pdf) {
    float phi = 2 * PI * xi1, r = sqrtf(xi2), z = sqrtf(1 - xi2);
    pdf = z / PI;
    return {r * cosf(phi), r * sinf(phi), z};   // 局部坐标系（法线=+Z）
}
```

## F. 视锥平面提取（Gribb–Hartmann）

从 `M = P·V` 直接取 6 个平面（行向量约定，clip = v·M 时）：`left = row3+row0`、`right = row3−row0`、`bottom = row3+row1`、`top = row3−row1`、`near = row2`（z∈[0,1] 约定）、`far = row3−row2`。平面 `(a,b,c,d)` 归一化后，球剔除：
```cpp
bool sphereCulled(simd_float4 plane, simd_float3 c, float r) {
    return simd_dot(plane.xyz, c) + plane.w < -r;   // 距离 < -r → 整球在外
}
```
工程要点：**每帧只算一次**；场景树自顶向下可提前整枝剪掉。

## G. 习题与解答

**Q1：为什么深度是非线性的？Reversed-Z 为什么能救精度？**
A：`z_ndc = (αz+β)/(−z) = −α − β/z`，是 **1/z 的仿射函数**——NDC 均匀步长对应 1/z 均匀步长 → 近密远疏。定点深度缓冲的均匀量化与 1/z 分布错配（远处大量 z 共享一个码）。**浮点深度在 0 附近有指数级细密度**，把近平面映射到 1（reversed-Z），恰好让浮点 mantissa 的对数分布匹配近处的高精度需求。

**Q2：Model 含非均匀缩放，直接 `n' = M·n` 会发生什么？**
A：法线不再垂直于变换后的切平面。例：切向 (1,0)/法向 (0,1) 被 S=diag(2,1) 缩放后 `t'=(2,0)`、`n'=(0,1)` 仍垂直；但旋转 45° 后再缩放即失垂直。修正 `n' = (M⁻¹)ᵀ·n`（见正文推导）；刚体变换 `(M⁻¹)ᵀ = M` 退化为直接乘。

**Q3：逆 CDF 采样 p(x)=2x（x∈[0,1]）？**
A：`F(x) = x²`；解 `F(x)=ξ` → **x = √ξ**。三行代码胜过拒绝采样。

**Q4：fp32 世界坐标 10 km 处的顶点为什么会抖动？**
A：fp32 尾数 23 位 ≈ 8×10⁶ 相对精度。坐标 10⁵ m 量级时，可分辨步长 ~10⁵/2²³ ≈ 0.012 m > 毫米级动画位移 → 帧间跳变。**相机相对渲染**（提交前把所有矩阵/顶点减去相机位置）把数值拉回原点量级，一步根治。

**Q5：四元数插值为什么先 `if dot<0: q=−q`？**
A：q 与 −q 同旋转但球面上是两个对跖点；不处理会绕远路（插值转 300° 而非 60°）。
