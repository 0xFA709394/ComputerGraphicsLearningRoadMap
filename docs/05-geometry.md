# 05 · 几何与网格处理

> 几何是图形学的另一半：表示、变形、简化、细分与求交。实时方向重点：网格组织/优化/SDF；离线方向重点：曲线曲面与网格算法。

---

## 1. 网格表示

### 1.1 显式表示
- **三角形汤**（每三角形独立顶点）→ **索引网格**（vertex buffer + index buffer，顶点复用）。
- 属性：position/normal/uv/tangent；法线来源：顶点法线（面积加权平均相邻面法线，平滑着色）vs 面法线（flat 着色）；**折痕/硬边处理**：按 UV/平滑组拆分顶点。
- **半边结构（Half-edge）**：每条边拆成两个有向半边，互指 opposite；提供 O(1) 遍历一顶点邻域/一面邻域——**网格处理算法（简化、平滑、细分、参数化）的标准底座**（运行时渲染不用它，DCC/离线工具用）。

### 1.2 其他表示
- 隐式（SDF/CSG）：易于布尔运算与稳健求交，显示需 marching cubes——见 §5。
- 参数曲面（Bezier/NURBS）：CAD/影视建模，游戏管线最终都离散成三角网格。
- 点云（扫描/LiDAR 原始数据）→ 重建（泊松重建概念）。

---

## 2. 曲线（动画/相机的数学）

### 2.1 Bezier
- **Bernstein 基**：`B(t) = Σ C(n,i)·tⁱ(1−t)^(n−i)·Pᵢ`；工程主力是三次（4 控制点）。
- **de Casteljau 递推求值**（数值稳定、几何直观：层层 lerp）。
- 性质：端点插值、凸包包含、仿射不变性、variation diminishing（不会比控制多边形更摆动）。
- 缺点：全局性（动一个控制点整条曲线变）→ 分段。

### 2.2 分段曲线与连续性
- C⁰（连）/C¹（切连续）/C²（曲率连续）；G¹（几何切连续）弱于 C¹。
- Hermite（端点+切线）；**Catmull–Rom**（过点样条，动画路径经典）。
- **B 样条**：局部支撑（改一点只影响局部）、C² 自动保证；节点向量概念。
- **NURBS** = B 样条 + 齐次加权（能精确表示圆弧）——CAD 标准，图形程序员了解即可。
- 应用：相机路径/动画曲线（ UIKit 的 `UIViewAnimationCurve` 就是 easing 子集）/字体轮廓（TrueType=二次 Bezier，PostScript=三次）。

---

## 3. 曲面与细分

### 3.1 细分曲面（影视标准，实时被 meshlet 路线吸收）
- **Loop 细分**（三角网格）：新边点 = `3/8·(端点) + 1/8·(对点)`；新顶点 = `(1−nβ)·V + β·Σ邻居`，`β = (1/n)(5/8 − (3/8 + ¼cos(2π/n))²)`；极限曲面 C¹（普通点 C²）。
- **Catmull–Clark**（四边形网格）：面点=面平均；边点=`(两端+两面点)/4`；新顶点=`(F + 2R + (n−3)P)/n`（F=相邻面点平均，R=边中点平均）；**奇异点=度≠4 的点**，一次细分后全为四边形。
- 折痕（crease）：半锐度控制硬边保留——角色建模的裤缝/指甲。
- 实时廉价替代：PN-Triangles（法线位移假平滑）、Phong tessellation。

### 3.2 位移与法线的关系
- 法线贴图=假装弯曲（光照变、轮廓不变）；真位移（tessellation/预细分高模烘焙）=几何真实。烘焙法线流程：高模细节 → 低模 UV 空间（ray cast）→ 切线空间法线图。

---

## 4. 网格处理算法

### 4.1 平滑
- Laplacian 平滑（顶点移向邻居平均）——收敛但收缩；**Taubin λ|μ** 双步防收缩（保体积感）。

### 4.2 简化（LOD 核心）
- **QEM（二次误差度量，Garland–Heckbert）**：每顶点累积其相邻平面基本误差二次型 `Q = Σ ppᵀ`（p=平面方程系数）；边折叠代价 `vᵀ(Q₁+Q₂)v`，贪心堆式折叠。
- 产物：LOD 链（高/中/低模，按屏幕面积切换 + 抖动过渡/几何 morph 防 pop）。
- 与烘焙结合：法线细节转移到法线贴图补偿几何损失。

### 4.3 参数化（UV 展开）
- 目标：3D→2D 等距/保角映射，畸变度量（角度/面积）；算法概念：LSCM（最小二乘保角）、ABF++；自动切割 seam、打包图集（利用率）。
- 网格处理管线位置：建模→展 UV→烘焙→简化→引擎导入（tangent 生成/顶点压缩/顶点缓存优化）。

### 4.4 顶点缓存优化（运行时性能）
- **Tom Forsyth 线性速度算法**（FIFO 顶点缓存模型重排索引）：提升 Post-T&L cache 命中 → 顶点着色器少跑；配合 overdraw 优化（网格重排成"空间连贯三角形顺序"）。
- Meshlet 化：把网格切成 64~124 顶点簇（顶点复用最大化 + 可 GPU 剔除单元）——mesh shading 与 Nanite 的组织基础。

---

## 5. 隐式表面与 Ray-marching

### 5.1 SDF（有向距离场）
- 定义：`f(x)` = 到最近表面距离（内负外正）。
- 布尔运算：并 `min(a,b)`、交 `max(a,b)`、差 `max(a,−b)`；**平滑混合 `smin`**（指数/多项式）——软体/圆润融合。
- 法线：中心差分梯度 `n = normalize(∇f)`（4 次 tap）。
- 应用：字体（Valve SDF 字体）、阴影/SDF 烘焙的 GI（UE Lumen 的世界 SDF 追踪）、3D 建模（blender/magica voxel 的 CSG）。

### 5.2 网格化
- **Marching Cubes**（Lorensen）：体素立方体 8 角符号 → 256 种（15 基础）三角剖分查表；二义面需处理。
- **Dual Contouring**：面在对偶、锐边特征保留（QEF 合并）；Surface Nets（简单平滑）。
- 行业趋势：UE5 Nanite 直接对"体素/SDF 烘焙+重网格化"管线化（了解）。

### 5.3 Sphere Tracing（光线步进）
- 沿视线步进 `t += sdf(p)`（最近距离=安全步长）直到 < ε → ShaderToy 3D 场景渲染的标准技术；可加软阴影/AO（步进计数近似）。

---

## 6. 加速结构（渲染与光追公用地基）

- **均匀网格**：简单、缓存差、Teapot-in-stadium 问题（密度不均）。
- **八叉树**：自适应；动态场景更新麻烦。
- **kd 树**：完美空间剖分（SAH 代价启发建树），静态场景离线光追经典；不适合动态。
- **BVH（当前工业标准）**：物体包围盒树；中间节点=子盒并集；建树（中位数/SAH 划分）O(n log n)；动态场景 **refit**（只更新包围盒，质量退化）vs **rebuild/重构**（STBVH 等折中）。
- **TLAS/BLAS 两层结构**：BLAS=单物体 BVH（刚体变换即可复用），TLAS=顶层实例树——硬件光追（Metal RT）的官方组织形式（第 6 章）。
- 参考：Embree（Intel，BVH 工业级实现）。

---

## 7. 三角形级几何工具箱

- 求交：Möller–Trumbore（第 6 章推导）；点到三角形最近点（含边/顶点区域）。
- 面积/法线/重心（01 章）；三角形质量（Delaunay 准则，网格质量）。
- **Delaunay 三角化** & **Voronoi 图**（对偶）：散点重建/地形生成；约束 Delaunay（带边界）。
- 凸包（Quickhull）；凸分解（碰撞体生成）。
- 网格修复：孔洞填充、非流形检测、重定向（法线一致性）——资产管线工具库（如 MeshLab/libigl 能力清单）。

---

## 8. 实用工程（iOS/Metal 视角）

- 导入链：glTF/USD → 生成 tangent（mikktspace）→ 顶点压缩（half/oct 法线）→ 索引重排（Forsyth）→ Meshlet（可选）→ `.mesh` GPU 缓冲。
- Apple **Model I/O**：导入 OBJ/ABC/USD，生成切线/法线/包围盒；`MDLMesh` 与 `MTKMesh` 桥接。
- 动态网格（蒙皮结果）体积大：compute 预蒙皮输出到 ping-pong buffer（第 7/8 章）。
- 大世界：几何流式加载 + 虚拟纹理 + LOD/Impostor（第 11 章）。

---

## 9. 自测清单

- [ ] 用 de Casteljau 手算三次 Bezier 在 t=0.5 的点
- [ ] 解释 Catmull-Clark 一次细分后为何全变四边形、奇异点是什么
- [ ] 实现 QEM 简化的代价函数并说明贪心折叠流程
- [ ] 用 SDF 实现 min/max/smin 布尔与法线差分
- [ ] 写 sphere tracing 渲染两个融合球体（ShaderToy）
- [ ] 说明 BVH refit 与 rebuild 的取舍及 TLAS/BLAS 分层理由
- [ ] 说出资产导入管线从 glTF 到 GPU buffer 的 6 个步骤

---

# 扩展篇：关键算法代码

## A. de Casteljau 与三次 Bezier（10 行核心）

```cpp
// n+1 控制点, 参数 t: 层层 lerp, 数值稳定且可顺便给出切线
Vec3 bezier(std::vector<Vec3> p, float t) {
    for (int k = p.size() - 1; k > 0; --k)
        for (int i = 0; i < k; ++i)
            p[i] = p[i] + (p[i + 1] - p[i]) * t;
    return p[0];       // 倒数第二轮的两个点之差 = 一阶导方向(切线)
}
```
等价 Bernstein 展开更适合 SIMD；de Casteljau 的价值是**几何直觉与导数免费**。

## B. QEM 简化核心（边折叠版）

```cpp
struct QEM {
    Mat4 q = 0;                                  // 累计平面误差二次型
    float cost(const Vec3 &v) { return dot(v, q * v); }  // vᵀQv
};
// 初始化: 每顶点 Q = Σ相邻面 (p·pᵀ), p = (a,b,c,d) 面方程(单位法线)
// 循环:
//   1) 堆取最小代价边: cost = v̄ᵀ(Qᵢ+Qⱼ)v̄, v̄=(Qᵢ+Qⱼ)⁻¹·(0,0,0,1)最优坍缩点
//      (退化时取边中点; 用法线/边界约束防塌穿)
//   2) 坍缩 i,j → v̄: 更新拓扑, Qᵢ += Qⱼ, 更新邻边代价
//   3) 达到目标面数停止
```
防退化三件套：边界边锁死（或加虚拟垂直平面惩罚）、体积保持修正、坍缩后翻面检测（法线点积变负则拒绝）。

## C. SDF 布尔与平滑混合

```cpp
float sdSphere(Vec3 p, float r) { return length(p) - r; }
float sdBox(Vec3 b, Vec3 p) {                                   // 精确盒 SDF
    Vec3 q = abs(p) - b;
    return length(max(q, 0)) + min(max(q.x, max(q.y, q.z)), 0);
}
float opUnion(float a, float b) { return min(a, b); }
float smin(float a, float b, float k) {                         // 多项式平滑并
    float h = clamp(0.5f + 0.5f * (b - a) / k, 0, 1);
    return mix(b, a, h) - k * h * (1 - h);
}
Vec3 sdfNormal(Vec3 p) {                                        // 四点差分(tetrahedron)
    const float e = 1e-3f;
    return normalize(Vec3(sdf(p + Vec3(e,-e,-e)) - sdf(p + Vec3(-e, e, e)),
                          sdf(p + Vec3(-e,e,-e)) - sdf(p + Vec3( e,-e, e)),
                          sdf(p + Vec3(-e,-e,e)) - sdf(p + Vec3( e, e,-e))));
}
```
注意：smin 后的场**不再是精确距离**（步长偏保守）→ sphere tracing 时把步长再乘 0.8 保险。

## D. Sphere Tracing 主循环

```cpp
float march(Vec3 ro, Vec3 rd) {
    float t = 0;
    for (int i = 0; i < 128; ++i) {
        float d = sdf(ro + rd * t);       // d = 到最近曲面的安全距离
        if (d < 1e-4f * t) return t;      // 命中(按距离放大 ε 防停不下来)
        t += d;                           // 沿光线安全推进
        if (t > FAR) break;
    }
    return -1;
}
```
软阴影/AO 免费：march 过程中 `min(d / t)` 即可近似——ShaderToy 技巧的源头。

## E. 顶点缓存重排（Forsyth 算法要点）

```
1) FIFO 顶点 cache (默认 32) 模拟
2) 评分 = f(cache 位置) + f(剩余引用次数) + f(最近展开的三角度)
3) 贪心展开最高分三角形; 每步更新受影响顶点分
→ ACMR(每三角形平均顶点取数) 从 ~3 降到 ~0.6-0.8
```
验收指标：**ACMR**（average cache miss ratio）——用 `meshoptimizer` 库一行调用即可对比你手写版的质量。

## F. 习题与解答

**Q1：Catmull-Clark 一次细分后，非四边形面去哪了？**
A：每个 N 边形面生成一个度为 N 的新面点，一次细分后每个原 N 边形被分成 N 个四边形 → 网格全四边形化；度≠4 的点成为**奇异点**（极限曲率不连续点），是建模时布线的核心约束。

**Q2：法线贴图和真位移的轮廓差异如何解释？**
A：法线贴图只改 shading normal（光照响应），silhouette（轮廓）仍是低模折线；真位移改几何位置。近景特写时"轮廓锯齿 + 表面细节"的矛盾必然暴露——所以角色特写用 pre-tessellated 高模。

**Q3：BVH 遍历为何用显式栈而非递归？**
A：GPU/迭代实现无硬件栈保证（Metal shader 栈极小/性能差）；显式 `int stack[32]` 数组 + while 循环是标准写法；栈深 log₂(n) 量级，32 够用（爆栈=建树退化，加断言）。

**Q4：为什么 meshlet 顶点数选 64~128？**
A：上限受 mesh shader 输出槽位/共享内存约束；下限要保证簇内顶点复用率（TV ratio）与剔除粒度平衡——簇太大剔除浪费、太小 draw 开销占优。Nanite 用 128 顶点簇 + 层级聚合。
