# 09 · 软件光栅器（C++ 零依赖 · 透视校正 · z-buffer · 软阴影）

阶段 3 验收件之一（README 核心策略第 5 条）。对应 `docs/02`（光栅化管线逐概念）与 `docs/11 §1.1`（阴影映射）的 **CPU 实现**——绕过 GPU 直接操作像素，建立"像素从哪来"的心智模型。与 `code/07`（Metal shadow map）同一场景、同一算法，一个在 GPU 一个在 CPU，互为镜像。

## 运行

```bash
./build.sh
./rasterizer          # 输出 out.tga (800x600, Preview 直接打开)
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **透视投影矩阵**（GL 约定 z∈[-1,1]，视口阶段归一）| `perspective()` |
| 边函数（二倍符号面积）→ **重心坐标**插值 | `edge()` / `rasterize()` |
| **透视校正插值**：属性/w 线性组合再除以插值后的 1/w；z 是唯一可以屏幕空间线性插值的量 | `rasterize()` 中段 |
| **z-buffer**：逐像素深度测试，两遍共用同一算法 | `zbuf` / `shadow` |
| 近裁剪面：三角形任一顶点 w 过小即整块丢弃（正确做法是裁剪，见 docs/02 §2；计数 `g_clippedTris`）| `rasterize()` 开头 |
| **阴影映射两遍结构**：光源正交深度遍 → 相机遍重投影采样 + 斜率偏置 + 2×2 PCF | `main()` Pass 1/2 |
| 正交 pass 下 w≡1，透视校正数学**自然退化**为线性插值——统一光栅化核心，只有 clip→屏幕映射不同 | `orthoPass` 参数 |
| 过程式棋盘纹理（nearest + repeat wrap，免资产）| `Checker` |
| Blinn-Phong（ambient + diffuse + spec，材质结构体对应 GPU 的 bind 材质）| `shade` |

**开发实录踩坑**：`makeGround` 最初用聚合初始化 `Mesh M = {{6 个顶点}}`——只初始化了 `verts`，`tris` 静默为空，画面只剩球没有地面、无任何报错。教训：**聚合初始化的嵌套大括号数错 = 静默丢数据**，C++ 下"画面缺东西"先查数据再查算法；输出图像统计（亮像素占比）比肉眼更早暴露问题。

## 观察点与练习

- 观察：球下软阴影边缘 2~4 像素过渡；棋盘格远处格子透视收敛无"游动"（透视校正生效）；球面明暗连续无裂缝。
1. 把透视校正除法 `/invW` 去掉（直接线性插 u,v）：棋盘格在远处发生**纹理游动**——docs/02 §3 那张经典对比图亲手复现
2. z-buffer 换成"画家算法"（按三角形平均深度排序）：构造穿插三角形看排序错误
3. 背面剔除：用 `area` 的符号剔除与视点背离的三角形（先统一 makeSphere 的绕向），统计三角形量减半
4. 阴影图 512→128：阴影块状化；把 bias 改 0 复现 acne 条纹（docs/24 树 8）
5. 输出加 gamma 2.2（当前是线性直写，与 04 示例的 sRGB 议题对照）
6. 近平面裁剪：把相机推进球内，看整块三角形消失；实现真正的三角形-平面裁剪
7. 双线性采样：`Checker::sample` 改 bilinear + 生成 mipmap，远处摩尔纹对比
8. 加 SIMD：`rasterize` 内层循环用 Accelerate/NEON intrinsics（对应 README 阶段 3 的加分项）

## 与 07 的镜像关系

| 概念 | 07 (Metal) | 09 (CPU) |
|---|---|---|
| 深度测试 | `MTLDepthStencilState` | `zbuf` 数组 |
| 光栅化 | 硬件 | `edge()` 循环 |
| 顶点/片元 | vertex/fragment shader | `xformPoint` / `shade` |
| PCF | `sample_compare` 可选 | 手写 2×2 |

## 通往 10

光栅化回答"像素怎么画"；下一件 `code/10-path-tracer` 回答"颜色从哪来"——渲染方程 + 蒙特卡洛，阶段 3 验收的第二张图。
