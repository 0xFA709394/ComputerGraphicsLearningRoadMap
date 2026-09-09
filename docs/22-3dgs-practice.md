# 22 · 3DGS 实操手册：从手机采集到 iOS Viewer

> 方向 D 的完整落地路径。4 周里程碑制：采集训练 → 最简 viewer → 完整渲染 → 优化+AR。学完你手里会有一个别人很难快速复刻的作品（12 章作品集 P3 的施工图）。

---

## 1. 原理五分钟回顾（详版见 11 章 §8）

- 场景 = 数十万~百万个 **3D 高斯**（位置 μ、协方差 Σ、不透明度 α、球谐系数 SH 表征视角相关颜色）。
- 渲染 = 投影为 2D 椭圆（Σ' = J·W·Σ·Wᵀ·Jᵀ）→ **splat** 成 quad → 深度排序 → 前后 α 混合。
- 训练 = 可微光栅化 + 梯度下降：SfM 位姿已知，优化每个高斯的参数；自适应致密化/剪枝。
- 为什么快：**显式表达 + 光栅化管线**（NeRF 是隐式 MLP + 每像素射线 MC 积分）。

## 2. 生态地图（2024~2026 现状）

| 环节 | 工具 |
|---|---|
| 采集 | 手机环绕视频（自己拍，无需 App）；Polycam/Luma/Scaniverse 可代劳采集+重建 |
| SfM | **COLMAP**（特征提取→匹配→增量重建出相机位姿+稀疏点）|
| 训练 | 原版 graphdeco-inria/gaussian-splatting；**nerfstudio `splatfacto`**（工程化推荐）|
| 查看 | Web（antimatter15/splat）；**iOS：Apple 官方示例 + 开源 splat viewer** |
| 压缩 | 自研格式（量化/剪枝）、.spz（压缩生态在收敛中）|

## 3. iPhone 采集纪律（决定质量上限）

- **环绕 + 俯仰**两个 8 字轨迹，重叠率 60~80%；每 1~2 秒一帧（视频抽帧）。
- 表面要求：**纹理丰富、哑光**；纯色墙/镜面/玻璃/移动物体=失败重灾区。
- 光照均匀（阴天/室内恒定光）；关闭 HDR 与人像模式。
- 反例自查：训练图有鬼影/雾状 floaters → 采集重叠不足或反光。

## 4. 训练流水线（Mac 实操）

```bash
# 1) COLMAP（Apple Silicon 可用 homebrew/mamba 版；无 CUDA 也能 SfM）
colmap feature_extractor --database_path db.db --ImageReader.camera_model OPENCV
colmap exhaustive_matcher --database_path db.db
colmap mapper --database_path db.db --image_path images/ --output_path sparse/

# 2) nerfstudio 训练（Apple Silicon MPS 支持）
ns-process-data images --data images/ --output-dir data/proc
ns-train splatfacto --data data/proc          # ~10-30 分钟(取决于帧数)

# 3) 导出 ply: outputs/.../splats/0/...ply
```
参数要点：分辨率 `--pipeline.model.cull-alpha_thresh` 控 floaters；迭代默认 30k；输出 ply 每 100w splats ≈ 250MB（viewer 前先压缩/抽稀到 10~30w）。

## 5. .ply 字段速查（viewer 加载必读）

```
x y z                          位置
nx ny nz                       (可忽略)
f_dc_0..2                      SH 直流项(基础颜色)
f_rest_0..44                   SH 高频项(45=3色×15系数, 视角相关)
opacity                        不透明度(需 sigmoid)
scale_0..2                     尺度(需 exp)
rot_0..3                       旋转四元数(归一化)
```
**预处理一次性完成**（sigmoid/exp/颜色空间 SH→RGB），运行时零转换。

## 6. iOS Viewer 实现要点（Metal）

### 6.1 数据布局
```
SoA 多 buffer: pos(float3)|opacity-f_dc(RGBA8 打包)|scale-rot|SH 高频
100w splats ≈ 60~120MB——注意低端机内存档位与 mmap 加载
```

### 6.2 排序（性能主战场）
- CPU 排序：每帧按视深 `std::sort` —— 30w splats 约 3~5ms（A15），移动端可接受的下限。
- GPU tile 级排序：16×16 像素 tile 分桶 → 深度位压缩 → **基数排序**（07 章模式库）→ indirect draw 按序发射。100w@60fps 的正解（对照 Apple 官方实现）。

### 6.3 Splat 着色（核心 shader 骨架）
```cpp
// vertex: 每高斯一个 4 顶点 quad 实例
// 1) 世界→裁剪: c = VP * float4(pos,1); 若 c.w <= 近平面边界 → 剔除(膨胀)
// 2) 2D 协方差: cov2d = J W Σ Wᵀ Jᵀ (3 个独立分量 a,b,c)
// 3) 特征分解得椭圆两轴 -> 顶点沿轴外扩(留 3σ 截断)
out.offset = axisMajor * corner.x + axisMinor * corner.y;   // 传给片元

// fragment: 二次高斯衰减 α
float r2 = dot(offset, offset);
float alpha = min(0.99, opacity * exp(-0.5 * r2));
if (alpha < 1.0/255.0) discard;
return float4(shColor(viewDir) * alpha, alpha);   // premultiplied 输出
```
混合：back-to-front + `One, OneMinusSrcAlpha`（premultiplied——02/09 章知识闭环）。

### 6.4 质量与性能清单
- [ ] SH degree 0→3 分级加载（近高远低）
- [ ] 3σ 截断 + 屏幕尺寸钳制（近处巨 splat 撕裂）
- [ ] tile 内 early-z 剔除（被不透明 AR 深度遮挡的 splat 跳过）
- [ ] MetalFX 上采样（半分辨率 splat 再重建）
- [ ] 基准：A15 上 30w@60fps（CPU 排序）/ 100w@60fps（GPU 排序）

## 7. AR 放置（作品集最后一环）

- ARKit `ARWorldTrackingConfiguration` + LiDAR 场景深度：**真实物体遮挡 splat**（深度 pass 前置，21 章题 6 同款）。
- 锚定：`ARAnchor` 挂 viewer 世界原点；光照：`AREnvironmentProbe` 只影响虚拟底座，splat 自带真实感。
- 拍一个 15 秒演示视频：绕着虚拟"全息雕像"走动、被真实桌子遮挡——这是简历上最直观的一页。

## 8. 面试讲点（自备答案）

- 为什么 3DGS 比 NeRF 快三个量级？（显式 vs 隐式；光栅 vs MC）
- 3DGS 的三大失败场景？（镜面反射、稀疏视角、动态物体）与补救（Mip-Splatting 抗走样、致密化策略、4DGS）
- 为什么必须排序而 mesh 不用？（α 混合不可交换——02 章闭环）
- 压缩思路？（量化/剪枝/SH 截断/码率-质量曲线）

## 9. 四周里程碑

```
W1  采集+COLMAP+训练出第一只 ply；Web viewer 验证质量
W2  最简 Metal viewer（CPU 排序, SH degree0, 无优化）→ 30w@30fps
W3  完整 SH + GPU tile 排序 → 60fps 达标
W4  压缩加载 + AR 放置 + 演示视频 + 博客《我把雕像装进了 iPhone》
```
