# 11 · CSM 级联阴影贴图（4 级 λ 切分 · texel snapping · 逐级 PCF）

`code/07`（单张阴影图）的升级，对应 `docs/11 §1.2` 与 18 章蓝图 M3 阴影里程碑。走廊场景：14 球两列延伸到 50 米外，近处阴影清晰、远处靠低分辨率级联兜底。**空格键切换级联调试着色**（红/绿/蓝/黄 = 级 0~3，看切分边界与物体归属）——本仓库第一个交互示例。

## 运行

```bash
./build.sh
./csm          # 空格: 级联调试
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **λ 实用切分** `cᵢ = λ·log + (1−λ)·uniform`（λ=0.8，near 0.1 / far 60 → 3.4 / 8.0 / 18.7）| `splitDistance()` |
| **视锥切片 AABB 拟合**：切片 8 角点变换到光空间取包围盒，正交箱只包住这一片 | 级联循环 |
| **texel snapping**：光空间平移量对齐纹素网格消抖动（docs/11 §1.2）| 同上 |
| **depth2DArray**：4 级共用一张 array 纹理；每级切片视图作深度附件 | `shadowMap` / `cascadeViews` |
| 片元按**视深（clip.w）选级**，重投影采样对应 slice | `sceneFrag` |
| 逐级 PCF，**偏置随级数放大**（纹素世界尺寸变大） | `shadowPCF` |
| 每级独立深度 pass（复用 depth-only PSO） | `draw` Pass 1 |

## 开发实录踩坑（本例五连，值得逐条复盘）

1. **ortho 的 z 约定混用**（最隐蔽）：07 的 `ortho()` 按"正距离约定"写（n/f 传正数、view.z 为负），本例把光空间 AABB 的 **view.z 负值边界**直接传进去——z 映射整体错位，重投影深度全图越界 → **满屏皆阴影**。CPU 侧用同一矩阵手算一点的 NDC 才定位。教训：**每种矩阵约定写死文档注释，跨示例复制先核对参数语义**。
2. **阴影图采样 y 翻转**：采样 `v=(1−y+1)/2` 镜像了写入位置，近级（球密集）错采成大片阴影、远级（图大部分为空）侥幸正确——"远对近错"正是镜像类 bug 的指纹。光栅化写入与采样走同一套 ndc→行映射，**y 不需要翻**。
3. **MTKMesh 顶点全零**（工具链回归）：本机 macOS 26 上 `MDLAsset→MTKMesh` 转换出的顶点位置**全为 0**（手写四面体 OBJ 复现，与 vertexDescriptor 传法无关）——球体静默消失。改为**过程化经纬球**自建 MTLBuffer。**此问题同时影响 03/04/05/07**（已同批修复）。
4. **巨型四边形整三角形消失**：±120 的地面 quad，部分顶点落在相机后/远平面外时整个三角形不渲染（底部天空直穿）。细分 8×8 瓦片解决——大地面的标准工程做法，还顺带提升 tile binning 局部性。
5. **Uniforms 里放 Swift Array**：`var lightVP: [simd_float4x4]` 是引用（8 字节指针），`setBytes` 只拷贝指针不拷矩阵，shader 读到垃圾——编译器警告"may contain an object reference"点破。固定长度数据传 GPU 必须**平铺成多个字段**。

另：macOS 26 SDK 把 `newTextureView(pixelFormat:...)` 改成 descriptor 形式（`levelRange/sliceRange`），`simd_float4x4(translate:/scale:)` 便利构造被移除——API 迁移成本真实存在。

## 观察点与练习

- 观察：空格切调试色——地面从近到远依次红→绿→蓝→黄，切分边界随远近非线性（λ=0.8 偏 log）；球影边缘近处锐利、远处 3×3 PCF 后显软。
1. λ 0.8 → 0.5 / 0.95：观察各级覆盖范围变化，理解 log/uniform 切分的权衡
2. 去掉 texel snapping + 让相机每帧平移 0.01：阴影边缘闪烁（shimmer）复现
3. 级数 4 → 2：远处阴影块状化加剧
4. **级间 blend**：切分边界两侧做 10% 过渡带混合（docs/11 §1.2 提到的接缝处理）
5. 把每级 PCF 半径按"texel 世界尺寸 × 光源尺寸"缩放 → PCSS 化
6. 阴影 pass 移到第二队列 async compute（docs/07 §9）：与主 pass 重叠
7. 静态场景缓存级联矩阵：texel snapping 后相机微动时矩阵不变 → 阴影图免更新

## 通往 Mini-Engine

CSM 是 18 章蓝图 M3 的阴影件。下一步：TAA（时序抗锯齿，M3 另一件）+ frame graph 把这些 pass 组织起来（M2）。
