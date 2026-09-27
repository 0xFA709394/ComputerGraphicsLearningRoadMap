# 18 · BVH 路径追踪器（SAH 构建 · 三角形网格 · 加速基准）

docs/06 §求交/加速结构的落地，docs/27 案例 B 第 1~2 周的参考实现。在 code/10 之上新增：**Möller–Trumbore 三角形求交、AABB、SAH 构建的 BVH、程序化三叶结网格（20480 三角）**，以及暴力 vs BVH 的加速基准（验收物）。

## 运行

```bash
./build.sh
./bvhpt            # 默认 480x360@96spp; stdout 打印基准
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **Möller–Trumbore** 三角形求交（u/v 重心坐标 + 行列式退化剔除） | `Triangle::hit` |
| **AABB slab 测试**（三轴区间求交，inv 预算） | `Aabb::hit` |
| **SAH 构建**：最宽轴 16 候选切分，cost = Σ(面积×数量) 最小化（docs/06 §SAH） | `subdivide` |
| 索引重排（`stable_partition`）+ 扁平节点数组（2N 预分配） | `build` |
| **递归遍历**：先测盒再下探，叶内逐三角（栈版是练习） | `traverse` |
| 程序化三叶结管道网格（Frenet 标架 + 环面细分） | `makeTrefoil` |
| **基准即验收**：20480 三角、2 万条射线，暴力 ~1s vs BVH 2.5ms | `main` |

**headless 验证**：加速 361~487×；Cornell Box + 金色三叶结 + 金属球成像正确（三叶结亮团居中、渗色正常）。
**开发实录踩坑**：NEE 的 `cosL` 又写反了一次（`dot(ln, wi)` 应为 `dot(ln, -wi)`）——**同一个坑在不同文件里踩两遍**，说明"踩坑实录必须连同修复一起复制到衍生代码"，人脑不可靠、文档才可靠。

## 练习路线（对照 docs/27 案例 B）

1. 遍历改显式栈（去递归）+ 最近子树先访（缓存友好）
2. SAH 加空间二分（全轴搜索而非最宽轴）
3. glTF/obj 网格输入（替换程序化三叶结）
4. BVH 节点压缩（8/16B 节点，指针-free）
5. embree 对标：同场景跑 Intel embree，差距即你的优化空间
