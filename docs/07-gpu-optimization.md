# 07 · GPU 架构与性能优化

> 参考实现：[code/08-compute-particles](../code/08-compute-particles/)（compute 每粒子一线程 + additive 点精灵）

> 资深工程师的价值区：理解硬件行为，让优化从"玄学调参"变成"瓶颈驱动工程"。本章以 Apple Silicon（TBDR）为主线——这是 iOS 开发者的主场优势。

---

## 1. CPU vs GPU 的设计哲学

- CPU：延迟导向（大缓存/乱序/分支预测）跑串行逻辑；GPU：**吞吐导向**——用数万线程的并行掩盖访存与指令延迟。
- GPU 逻辑流水线：顶点/片元数据 → 分布在 SM/CORE（Apple 术语 core）上以 **SIMT** 执行。
- 结论先行：GPU 优化三问——**算力(ALU)用了多少？带宽用了多少？并行度(occupancy)够不够掩盖延迟？**

---

## 2. SIMT 执行模型

- **simdgroup（Apple）/ subgroup（Vulkan）/ wavefront（AMD）**：锁步执行的最小单位，Apple GPU 为 **32 线程**。
- 分支发散（divergence）：同一 simdgroup 内走不同分支 → 两边都执行（掩码关闭各自 lane）→ 有效算力减半或更差；reconvergence 点。
- simdgroup 内通信原语（性能利器）：`simd_shuffle`、`simd_ballot`、`simd_reduce`——归约/扫描免去走显存。
- quad（2×2）是光栅化的最小调度单位（第 2 章）：quad 内发散直接影响纹理采样合法性。

---

## 3. 内存层级与带宽

### 3.1 层级（由快到慢）
1. 寄存器（每线程；用量决定占用率）
2. **threadgroup memory**（片上共享内存，KB 级；配合 barrier）
3. 纹理/L1 缓存 → L2 → 显存（统一内存 UMA on Apple）
- **带宽是移动 GPU 的第一瓶颈**：桌面独显 500~1000+ GB/s，手机 30~70 GB/s 量级，差一个数量级。

### 3.2 访存合并（coalescing）
- simdgroup 内线程访问**连续地址** → 合并为宽事务；随机访问 = 每线程一次事务 = 带宽×N。
- 数据布局对策：SoA（compute 友好）vs AoS（图形顶点友好）；粒子系统属性分 buffer。
- 纹理缓存行为：2D 局部性；swizzle 地址重排（ Morton/Z-order ）减少 cache miss（引擎自己做 render target swizzle）。

---

## 4. Occupancy 与延迟隐藏

- Occupancy = 活跃线程 / SM 最大线程；受寄存器用量与 threadgroup 大小限制（Metal 可查 `maxThreadsPerThreadgroup` / 寄存器 spills 警告）。
- 规则：**高延迟任务（纹理采样、显存读）需要高占用率掩盖；纯 ALU kernel 低占用也可跑满**——不要盲目最大化 occupancy。
- Threadgroup sizing：优选 simdgroup 倍数（32 的倍数，常见 64/128）；2D dispatch 尺寸匹配 tile 形状。

---

## 5. TBDR：Apple GPU 的架构本质（主场知识）

### 5.1 IMR vs TBDR
- 桌面 IMR（立即模式）：每个 draw 立即访问全屏 framebuffer（VRAM 巨带宽）。
- **TBDR（Tile-Based Deferred Rendering）**：两阶段——
  1. **Binning**：先跑一遍顶点（只有位置），把三角形按 tile（如 32×32 像素）分桶；
  2. **逐 tile 光栅化**：tile 内所有三角形一次性处理完（HSR 隐藏面消除后只着色可见片元），中间结果驻留**片上 tile 显存**，pass 结束才写回。
- **收益**：帧缓冲读放大消失 → 带宽骤减；MSAA 在 tile 内多采样近免费；**HSR**（隐藏面消除，PowerVR 遗产）让被遮挡片元根本不着色 → 不透明物体顺序不再影响着色负载（但仍有 binning 成本，排序依旧好习惯）。

### 5.2 可编程 tile 内存（Apple 独家武器）
- **imageblock**：pass 内每像素的片上自定义内存（GBuffer 延迟光照不回显存！Deferred Shading 在 TBDR 上"免费"化的正道）。
- **tile shader**（tile 后/前钩子）：tile 级计算（如 tile 光照列表、SSR 局部预积分）。
- **Raster Order Groups**（A11+）：同一像素的片元按光栅顺序执行 → **可编程混合/OIT**，解决透明排序。
- **memoryless RT**：深度/模板只在 tile 存在，不占显存带宽与内存——MSAA 深度标配。

### 5.3 RenderPass 纪律
- 越少 pass 越少 tile 写回 → 合并 pass、避免中间 RT；
- `loadAction`/`storeAction` 精确设置（DontCare 能省则省）；
- 避免在 pass 中途切换 framebuffer 的"feedback loop"反模式。

---

## 6. Compute Shader 模式库（通用并行原语）

- **归约（求和/最大）**：树形两阶段（组内 simdgroup shuffle + atomics/二阶段 buffer）。
- **扫描（前缀和）**：Hillis-Steele（inclusive, log 步）/ Blelloch（work-efficient）——粒子死活索引、实例剔除计数的基础。
- **直方图**：threadgroup 私有 + 合并（避免全局原子热点）。
- **转置/分块矩阵乘**：经典 tiling（threadgroup memory 复用）——通用教程级。
- **排序**：bitonic（GPU 友好）/ radix（引擎主流）；透明粒子排序。
- **同步语义**：`threadgroup_barrier`、device scope fence、memory barrier（acquire/release 语义，正确性关键）；原子操作性能陷阱（热点地址）。

---

## 7. 图形侧优化清单（按收益排序）

### 7.1 Draw call 与 CPU
- 合批（同材质网格合并）、**实例化**、**indirect draw**（GPU-driven 剔除后直接画）、argument buffers 减少绑定切换。
- PSO 缓存与预热；避免帧中创建资源；编码多线程（每线程 command buffer）。

### 7.2 Overdraw 与不透明排序
- near→far 排序（IMR early-z 受益；TBDR 上 HSR 已兜底但仍降 binning 压力）。
- 粒子/植被 = overdraw 重灾区：降分辨率粒子层、alpha test 优先于 blend、纹理 mip 预算。

### 7.3 顶点带宽
- 顶点格式压缩（half 位置、八面体法线、UNORM 颜色）；顶点缓存重排；meshlet 提高复用。
- 大量小三角形（像素面积<4）= 光栅化黑洞 → LOD 控制屏幕误差。

### 7.4 Shader 层
- **half 优先**（Apple fp16 满速率，ALU 密集 shader 常见 1.5~2× 提升）；mad 友好写法；避免每像素 sin/pow（LUT 化）；常量折叠；分支整理（uniform 分支免费，divergent 分支昂贵）。
- 纹理采样次数与格式（ASTC）；采样器状态复用。
- 特殊函数单元（SFU：rsqrt/rcp/log）吞吐低——归一化 3 次 rsqrt 的堆积就值得优化。

---

## 8. 性能分析方法论（Xcode 工具链实战）

### 8.1 工具
- **Xcode GPU Debugger**：帧捕获 → 逐 draw 检查管线状态/资源/shader 变量；GPU timing per pass。
- **Instruments · Metal System Trace**：编码/提交/执行时间线（CPU bound vs GPU bound 一眼定位）。
- GPU Counters（Xcode 调试仪表）：**ALU 利用率、纹理缓存命中率、带宽、tile 利用率、occupancy**——瓶颈归因的核心证据。
- `os_signpost` 自定义区间；Metal GPU 队列时间（`MTLCommandBuffer` GPU 时间回调）。

### 8.2 方法论（工程化）
1. 预算制：60fps=16.6ms、120fps=8.3ms；按子系统分配 ms 预算。
2. 测量 → 归因（counters）→ 假设 → 修改 → 复测 → 记录（防止玄学回退）。
3. 三类瓶颈速判：CPU 提交（Metal System Trace 空隙）/ GPU 前端（binning/顶点）/ GPU 后端（着色/带宽）。
4. 常见移动端元凶：中间 RT 滥用、sRGB 手动转换、fp32 万能 shader、透明粒子无排序、深度 pass 缺失 memoryless。

### 8.3 动态画质
- 热状态（`NSProcessInfo.thermalState`）与电量监控 → 动态分辨率缩放（DRS）+ MetalFX 超分 → 帧率-画质-功耗三角。
- ProMotion 自适应帧率 + `CADisplayLink` 帧调度。

---

## 9. 同步与多队列（Explicit API 深水区）

- Hazard 类型：WAR/WAW/RAW；解决工具：`MTLFence`/`MTLEvent`（资源级）、屏障（pass 内 UAV）、信号量（CPU-GPU）。
- Async compute：图形队列 + 计算队列并行（阴影/粒子与主 pass 重叠）——桌面收益大，TBDR 上要防 tile 打架。
- 三缓冲与 ring allocator：每帧资源槽位轮转，CPU 跑前 GPU 收尾，消灭气泡。

---

## 10. 自测清单

- [ ] 画出 TBDR 两阶段流程并解释 HSR 为何免除不透明 overdraw
- [ ] 解释 imageblock 如何让 deferred 在移动端翻身
- [ ] 用 GPU counters 定位一个 ALU bound 与一个带宽 bound 的 shader
- [ ] 实现归约与前缀和 compute kernel（simdgroup 优化版）
- [ ] 把一个 fp32 PBR shader 改造为 half 并测量收益
- [ ] 说明 RenderPass load/store 配置错误如何吃掉带宽（用计数器验证）

---

# 扩展篇：核心 Compute Kernel 实现（MSL）

## A. 树形归约（simdgroup 优化版）

```cpp
kernel void reduceSum(const device float *in  [[buffer(0)]],
                      device float       *out [[buffer(1)]],
                      uint gid  [[thread_position_in_grid]],
                      uint lid  [[thread_position_in_threadgroup]],
                      uint sgid [[simdgroup_index_in_threadgroup]],
                      uint lane [[thread_index_in_simdgroup]],
                      uint nsg  [[simdgroups_per_threadgroup]],
                      uint lsize[[threads_per_threadgroup]],
                      uint group[[threadgroup_position_in_grid]])
{
    // 约定: threadgroup = 256 线程 = 8 个 simdgroup × 32 lane
    threadgroup float scratch[8];
    float v = (gid < totalCount) ? in[gid] : 0.0f;

    // 1) 组内 32 lane 归约: simd_sum 一条指令搞定 5 步蝶形
    v = simd_sum(v);
    if (lane == 0) scratch[sgid] = v;                 // 每组 1 个代表值
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // 2) 组间 8 个值归约 (第一个 simdgroup 干活)
    if (sgid == 0) {
        v = (lane < nsg) ? scratch[lane] : 0.0f;
        v = simd_sum(v);
        if (lane == 0) out[group] = v;                // 每 threadgroup 输出 1 值
    }
}
// 大数组: 两遍调度 (kernel1 归约到 N/256, kernel2 再归约)
// 归约是 "reduce→scan→histogram" 三件套的地基, 必须写到肌肉记忆
```
要点：`simd_sum/simd_min/simd_max` 是**免费**的 warp 级原语（专用指令），替代它 = 5 次 shuffle + 5 次加法 + barrier。

## B. 前缀和（Hillis-Steele 组内扫描 + 组间衔接）

```cpp
kernel void blockScan(const device uint *in  [[buffer(0)]],
                      device uint       *out [[buffer(1)]],
                      device uint       *blockSums [[buffer(2)]],   // 供第二遍
                      uint lid   [[thread_position_in_threadgroup]],
                      uint lsize [[threads_per_threadgroup]])
{
    threadgroup uint temp[256];
    temp[lid] = in[gridId];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Hillis-Steele: log2(256)=8 轮倍增
    for (uint d = 1; d < lsize; d <<= 1) {
        uint t = (lid >= d) ? temp[lid - d] : 0;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        temp[lid] += t;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    out[gridId] = temp[lid];
    if (lid == lsize - 1) blockSums[group] = temp[lid];
    // 3) 第三遍: 各组加上前组累计 (scan(blockSums) 后广播) —— 经典三遍结构
}
```
用途：粒子存活索引压缩、光源 tile 计数、间接 draw 的实例偏移——**GPU-driven 管线的螺丝钉**。

## C. GPU 粒子系统（发射→更新→压缩 完整结构）

```cpp
// 1) 更新: 每粒子一线程
kernel void particleUpdate(device Particle *p    [[buffer(0)]],
                           constant float &dt    [[buffer(1)]],
                           constant Params &par  [[buffer(2)]],
                           uint gid [[thread_position_in_grid]],
                           uint max [[threads_per_grid]])
{
    if (gid >= par.count || !p[gid].alive) return;
    Particle &P = p[gid];
    // 半隐式欧拉 + 简单重力/阻力/寿命
    P.vel += (par.gravity + P.force * P.invMass) * dt;
    P.vel *= exp(-par.drag * dt);               // 帧率无关阻尼
    P.pos += P.vel * dt;
    P.life -= dt;
    P.alive = P.life > 0;
}

// 2) 压缩: scan(alive) 得到紧凑下标 → 紧凑 buffer 供渲染 (无 dead lane)
//    deadCount 超阈值 → 3) 发射: 用 alive 索引池尾原子取号
device int *emitIndex [[buffer(3)]];
int slot = atomic_fetch_add_explicit(emitCount, 1, memory_order_relaxed);
if (slot < par.maxEmit) { initParticle(p[pool[slot]], rng(gid)); }
```
渲染端：`draw_indexed_primitives` 以压缩后 count 用 **indirect draw** 发起（GPU 自己决定画多少）——CPU 全程零同步，这就是"GPU-driven"的最小完整闭环。

## D. 性能实验记录模板（建立自己的数据资产）

```
| 变量 | 对照组 | 实验组 | 指标(ALU利用率/带宽/ms) | 结论 |
|-----|-------|-------|------------------------|------|
| fp16 | PBR fp32 | PBR half | 3.2ms→2.1ms, ALU 95%→78% | 该shader ALU-bound, half 收益 34% |
| tgrp | 64 | 128/256 | occupancy 75%→50%, ms 持平 | 内存延迟已被 64 级并行掩盖 |
```
每条实验 = 一次假设验证。半年积累 = 一份任何公司都缺的 Apple GPU 调优数据库。

## E. 半精度改造清单（Apple GPU 实战）

1. varying/纹理采样返回值 `half`（`texture2d<half>` + `sampler`，采样器输出硬件原生半精度）。
2. 颜色/光照中间量 `half3`；**位置/深度/矩阵乘法保留 float**（大坐标精度）。
3. `powr/saturate` 等 MSL 内建支持 half 重载；常量写成 `0.5h`。
4. 检查 Xcode "Shader Performance" 面板的寄存器/spill 警告；Occupancy 突降通常是寄存器暴涨。
5. 常见收益：纯光照 shader 20~40%；后处理（bloom/blur）30%+；已混合纹理带宽瓶颈的收益趋近 0（先看 counters 再动手）。

## F. 习题与解答

**Q1：一个 kernel 每次 32B/thread 随机访问显存，为何带宽利用率只有 ~25%？**
A：32 线程/lane 各自随机 32B → 无法合并成 128B cache line 事务，每事务有效载荷 32/128。修复：SoA 布局让相邻线程访问相邻地址；或先 staging 到 threadgroup memory 再按块处理。

**Q2：为什么纯 ALU kernel 低 occupancy 也能跑满？**
A：ALU 指令延迟 4~8 周期且无长依赖链时，编译器 ILP（指令级并行）+ 少量 warp 足以填满流水线；而内存/纹理采样延迟数百周期，必须靠切换更多 warp 隐藏。**先看瓶颈类型再调 occupancy**——盲目减寄存器反而伤性能。

**Q3：TBDR 上为什么"多个小 RenderPass"比"单个大 Pass"差？**
A：每 pass 边界强制 tile 写回+重新 load 显存（带宽×2）；且 binning 重复执行。合并 pass / 用 imageblock 在 tile 内完成中间数据传递，可把多 pass 的往返全部消灭（第 5 章）。

**Q4：Instruments 显示 GPU 时间 12ms 但 frames 掉到 40fps，瓶颈在哪？**
A：看 Metal System Trace 的编码/提交间隙——大概率 CPU 编码瓶颈（draw 太多/同步等待/验证层没关 Release 版）。GPU 12ms < 16.6ms 却掉帧 = 经典"CPU 限制帧率"证据。

**Q5：atomic 热点（全部线程原子加同一地址）的优化？**
A：threadgroup 内先局部归约（每 group 1 次全局原子，256×递减竞争）；或 per-simdgroup 私有计数 + 最后合并；极端场景用 scan 重构算法消灭原子。
