# 07 · Shadow Map（光源深度 pass + 斜率偏置 + 3×3 PCF）

对应 `docs/11 §1.1`（阴影映射基础）与 `docs/02`（两 pass 组织）。旋转球体向棋盘格地面投影，含斜率缩放偏置与手动 PCF。

## 运行

```bash
./build.sh
./shadow-map
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **depth-only PSO**（`fragmentFunction = nil`，无颜色附件）| `shadowPSO` 构造 |
| 光源正交投影（z∈[0,1]，自洽映射即可，y 无需翻转）| `ortho()` |
| 阴影图纹理（depth32Float，RT+shaderRead）| `shadowMap` |
| 世界→光源 NDC→[0,1] uv 的重投影采样 | `sceneFrag` |
| 斜率缩放 bias（`0.0015 + (1−NdotL)·k`）抗 acne | `shadowPCF` |
| 3×3 手动 PCF（最近邻采样+二值平均）| 同上 |
| 一 PSO 多物体（地面 quad 自建顶点 + 球体 MTKMesh）| `draw` 两个 draw call |

**开发实录踩坑**：depth-only PSO 用了 `[[stage_in]]` 却忘设 `vertexDescriptor` → PSO 创建静默失败、程序退出。教训：**所有 guard 失败都该打日志**（本 repo 其他示例已示范），以及"shadow pass 复用场景顶点布局"这个前提本身。

## 观察点与练习

- 观察：球影边缘 3×3 PCF 略软；掠射角地面无 acne 条纹（bias 生效）。
1. 把 bias 改 0（acne 条纹出现）再改 0.02（阴影脱体 Peter-panning）——docs/11 树 8 两条分支亲手复现
2. 阴影图分辨率 1024→256：边缘块状化；texel 数量与偏置联动
3. 升级 PCSS：blocker search 估半影（docs/11 扩展篇 A 三步全代码）
4. 硬件 compare sampler：`sampler(mag_filter::nearest, compare_func::less)` + `sample_compare` 重写 PCF（ fewer ALU）

## 通往 CSM

把本例 ortho 换成 4 级切分（`docs/11 §1.2`：λ 实用切分 + texel snapping），每级一张 1024 图——即 18 章蓝图 M3 的阴影里程碑。
