# 08 · 动画系统

> 从关键帧插值到 GPU 蒙皮再到 IK。iOS 开发者优势：ARKit 的 BlendShape 人脸、CADisplayLink 驱动模型、Core Animation 曲线直觉全部可以对接。

---

## 1. 关键帧与插值

- Keyframe = (时间, 值[, 切线])；采样 = 相邻两帧插值。
- 插值模式：constant / linear / bezier / hermite；wrap 模式：clamp / repeat / pingpong（repeat 相位衔接要 C¹）。
- **Easing 函数族**（ease-in/out/back/elastic…）= 时间域重映射；与 UIKit `UIView.animate(curve:)` 一一对应——你早已在用动画数学。
- 工程要点：动画时间轴统一（秒，浮点）；tick 与渲染解耦（fixed timestep + 插值）。

---

## 2. 骨骼动画（核心）

### 2.1 概念模型
- **Skeleton**：骨骼树（joint 层级）；**bind pose**：建模时骨架姿态。
- 每顶点绑定若干关节 + 权重（通常≤4）。
- 变换链：局部关节矩阵沿树连乘 → 当前世界姿态 `Cᵢ`；皮肤顶点：
  ```
  v' = Σᵢ wᵢ · (Cᵢ · Bᵢ⁻¹) · v
  Bᵢ = bind pose 世界矩阵（**inverse bind matrix 预计算**）
  ```
  ——这一行是骨骼动画的全部，务必能推导（"把顶点搬回绑定空间再搬到现在姿态"）。

### 2.2 LBS 的缺陷与改进
- **LBS（线性混合蒙皮）**：矩阵线性混合 → 关节处体积塌缩（糖果纸效应）。
- **DQS（对偶四元数）**：旋转严格刚体 → 鼓包问题；权重/混合策略决定取舍。
- 生产折中：加"twist 骨骼"手工分解扭转、 corrective morph（修正混合形状）。

### 2.3 GPU 蒙皮两条路线
1. **VS 内蒙皮**：每帧上传关节矩阵调色板（`float4×4 × N`）；简单，双倍顶点变换成本（阴影 pass 重复算）。
2. **Compute 预蒙皮**：compute kernel 把网格蒙皮到 ping-pong vertex buffer → 所有 pass 共享——引擎主流（代价：额外带宽与内存）。
- Apple 上 `simd_float4x3`（3 行）省 1/4 带宽；矩阵用 `half` 可行时再省。

### 2.4 动画数据与压缩
- Clip = 多轨道（关节×TRS×曲线）；采样在动画时间轴上插值。
- 压缩：量化（16bit/12bit）、关键帧稀疏化（误差阈值）、轨道裁剪（恒定通道砍掉）；误差度量（关节位置/角度误差）。
- 开源参考：**ozz-animation**（Gabriel Cuer，运行时库，代码极整洁，读源码学架构首选）；glTF animation/Skin 规范。

---

## 3. 混合与状态机

### 3.1 混合技术
- **Cross-fade**：两 clip 归一化时间对齐后按权重混合（linear/smoothstep 权重曲线）。
- **叠加混合（additive）**：`base + (clip − reference pose)`——呼吸/后坐力/受伤叠加层。
- **Blend mask**：分骨骼混合（上半身开枪 + 下半身跑）。
- **1D/2D Blend Space**：参数域（速度×方向）内多 clip 混合——移动系统标准做法。
- 旋转混合必须用四元数 nlerp/slerp（01 章）。

### 3.2 状态机与图
- 状态 + 转移条件（开始/结束时间、相位、参数阈值）→ **Anim Graph**（节点化混合图）。
- 高阶：**Motion Matching**（每帧在动画库中搜索与目标速度/轨迹最匹配的帧段，免状态机设计；概念级）。
- 分层架构：Locomotion 层 / 全身动作层 / IK 层 / 物理层。

---

## 4. IK（反向动力学）

- **Two-bone IK（解析法）**：肘/膝两骨骼链——余弦定理求中间关节角 + 极向量（pole vector）定平面朝向；O(1)、稳定、游戏主力。
- **CCD**：迭代地把末端朝目标旋转（关节优先远端）。
- **FABRIK**：前后向可达性迭代，收敛快姿态自然。
- **Jacobian 方法**：线性系统求解速度级 IK（学术/影视级）。
- 应用：脚部贴地（foot IK + 地面法线对齐）、手扶栏杆、头部 look-at、VR 手臂。

---

## 5. BlendShape / Morph Target

- 顶点级增量：`v' = v + Σ wᵢ·Δvᵢ`；权重驱动表情/口型/肌肉滑动。
- **ARKit 52 blendshape 人脸标准**（iOS 开发者直接变现的知识）；Vision 的面部关键点 → blendshape 权重。
- GPU 实现：morph 数据放纹理（顶点拉取）或 buffer；权重 uniform 数组；多个 morph 叠加时顶点带宽注意。

---

## 6. 程序动画与物理

- **弹簧-阻尼**： critically damped spring 数值积分（半隐式欧拉）——相机跟随/布娃娃软约束/UI 弹性全套适用。
- **Verlet 积分链**：次级运动（尾巴/飘带/毛发链），距离约束迭代。
- **Ragdoll**：物理引擎约束体 + 动画骨骼双向映射（死时物理接管，起身 blend 回动画）。
- 风场/噪声驱动顶点位移（与第 4 章程序噪声打通）。

---

## 7. 系统架构（引擎视角）

- 求值管线：采样（clip curves）→ 混合（graph 拓扑序）→ 姿态求解（FK）→ 蒙皮（GPU）→ IK 后处理。
- **多线程求值**：动画 job 化（每角色一 job，依赖图调度）；写优于读的 SoA 姿态缓冲。
- Retargeting：骨骼映射（不同骨架比例/命名差异，MoCap → 角色骨架）；简化方案：局部空间对齐 + 比例缩放。
- 调试可视化：骨骼渲染、权重热图、混合权重实时曲线、帧冻结单步。

---

## 8. 自测清单

- [ ] 推导蒙皮公式并解释 inverse bind matrix 存在的理由
- [ ] 解释 LBS 糖果纸缺陷及 DQS 的取舍
- [ ] 实现 two-bone IK（余弦定理+极向量）用于脚贴地
- [ ] 搭一个 1D blend space（idle→walk→run）
- [ ] 用 ARKit blendshape 数据驱动一个 Morph Target 模型
- [ ] 设计 compute 预蒙皮管线并说明与 VS 蒙皮的带宽权衡

---

# 扩展篇：蒙皮与 IK 完整实现

## A. 蒙皮矩阵链（把公式翻译成代码）

```cpp
// 离线一次:
for (joint j : skeleton)
    invBind[j] = inverse(worldBindPose(j));       // 预计算, 常驻显存

// 每帧 (compute, 每关节 1 线程):
simd_float4x4 skinned[JOINTS];
for (uint j = 0; j < jointCount; ++j)
    skinned[j] = worldPose[j] * invBind[j];       // 蒙皮矩阵 = C·B⁻¹

// 每顶点 (VS 或 compute):
simd_float3 v = 0;
simd_float3 n = 0;
for (int k = 0; k < 4; ++k) {
    simd_float4x4 M = skinned[indices[k]];
    v += weights[k] * (M * float4(position, 1)).xyz;
    n += weights[k] * (normalMatrix(M) * float4(normal, 0)).xyz;  // 法线用逆转置!
}
```
注意：权重需归一化（`w /= (w0+w1+w2+w3)`，DCC 导出常不保证）；法线用逆转置或接受近似（M 的旋转部分正交时直接乘）。

## B. Two-Bone IK（解析解，脚贴地/手抓握的标准件）

```cpp
// a=肩/髋, b=肘/膝, c=腕/踝, 目标 t, 极向量 pole
bool solveTwoBoneIK(Vec3 &a, Vec3 &b, Vec3 &c, const Vec3 &t, const Vec3 &pole,
                    float l1, float l2)
{
    float d = clamp(length(t - a), fabs(l1 - l2) + 1e-4f, l1 + l2 - 1e-4f);
    // 1) 余弦定理求肘部内角
    float cosInner = (l1*l1 + l2*l2 - d*d) / (2*l1*l2);        // 远端角
    float cosShoulder = (l1*l1 + d*d - l2*l2) / (2*l1*d);      // 近端角
    // 2) 在 a→t 平面内旋转近端骨骼到肩角
    Vec3 axisDt = normalize(t - a);
    Vec3 axisBend = normalize(cross(axisDt, pole));            // 弯曲平面法线
    Vec3 dirUpper = axisDt * cosShoulder + cross(axisBend, axisDt) * sinShoulder...
    // 3) 膝/肘方向与 pole 对齐 (在弯曲平面内旋转至指向 pole)
    ...  // 全程 O(1), 无迭代, 游戏实时标准
}
```
工程细节：膝盖极向量 = 髋-踝连线前方向；落地检测失败时（目标超腿长）钳制到最长伸展 + 抬根骨骼（hip displacement）。

## C. Compute 预蒙皮 kernel（Metal）

```cpp
kernel void skinMesh(const device float3 *inPos  [[buffer(0)]],
                     const device float3 *inNrm  [[buffer(1)]],
                     const device UByte4   *jidx [[buffer(2)]],
                     const device float4   *jw   [[buffer(3)]],
                     constant simd_float4x4 *palette [[buffer(4)]],
                     device float3 *outPos [[buffer(5)]],       // ping-pong buffer
                     device float3 *outNrm [[buffer(6)]],
                     uint vid [[thread_position_in_threadgroup]],  // + instance offset
                     uint gid [[thread_position_in_grid]])
{
    float4 w = jw[gid]; float s = 1.0f / (w.x + w.y + w.z + w.w);
    simd_float4x4 M = palette[jidx[gid].x] * (w.x * s)
                    + palette[jidx[gid].y] * (w.y * s)
                    + palette[jidx[gid].z] * (w.z * s)
                    + palette[jidx[gid].w] * (w.w * s);        // LBS 矩阵先混合!
    outPos[gid] = (M * float4(inPos[gid], 1)).xyz;
    outNrm[gid] = simd_normalize((simd_float3x3(M) * inNrm[gid]));  // 近似: 正交旋转部分
}
```
矩阵先混合再做一次矩阵乘 = **每顶点 1 次乘矩阵**（先乘后混合要 4 次）——LBS 线性性的直接红利。

## D. 批判性数据（自测用）

| 场景 | VS 蒙皮 | Compute 预蒙皮 |
|---|---|---|
| 单 pass（主相机） | 胜（零额外带宽） | 多一次写回 |
| 主相机+阴影+反射 3 pass | 3×重复计算 | 1×计算 3×读（大概率胜） |
| 精度 | 每次重算 | 需 fp32 中间格 |

经验阈值：pass 数 ≥2 或顶点数 >10 万时预蒙皮开始占优——用你的真机数据验证一次。

## E. 习题与解答

**Q1：LBS 的"糖果纸"从矩阵混合角度怎么解释？**
A：两个刚性变换矩阵线性插值 ≠ 刚性变换（旋转子阵失去正交性 → 出现缩放/剪切分量）；关节 180° 折叠时内凹侧被非线性压缩。DQS 对四元数做插值保刚性，但等长骨骼关节外凸。

**Q2：动画混合为什么必须 slerp/nlerp 而不能欧拉角 lerp？**
A：欧拉角 lerp 路径依赖旋转顺序（非测地线）、分量间耦合导致中间姿态歪斜；四元数 nlerp 近似测地线（等角速度近似）且计算廉价——动画系统默认 nlerp+slerp 兜底。

**Q3：蒙皮为什么"矩阵先混合再乘顶点"能省 4 倍？**
A：LBS 公式 `ΣwᵢMᵢv = (ΣwᵢMᵢ)v`——分配律把 4 次矩阵×向量缩成 1 次（4 顶点权重混合仅增加矩阵加法）。这是"数学恒等式换性能"的最经典案例。

**Q4：foot IK 为什么通常在动画混合之后执行？**
A：IK 是**位姿后处理**（在最终姿态上做约束求解）；放在混合前会被后续混合/叠加层破坏。管线顺序：采样 → 混合 → IK/物理修正 → 蒙皮 → 渲染。
