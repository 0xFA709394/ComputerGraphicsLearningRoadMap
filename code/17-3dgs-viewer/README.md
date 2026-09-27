# 17 · 3DGS 最小查看器（ply 往返 · GPU 排序 · instanced splat）

docs/22（3DGS 实操）第 1~2 周的参考实现，docs/27 案例 D 的 MVD 骨架。链路全通：**合成高斯场景 → 写真实 3DGS .ply（17 字段二进制）→ 读回 → 每帧 ulong(key<<32|index) bitonic 排序 → gather 重建远→近实例缓冲 → instanced billboard + premultiplied alpha 混合**。空格开关排序看混合序错乱。

## 运行

```bash
./build.sh
./splat      # 空格: 开关排序; scene.ply 由程序生成
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **3DGS ply 格式**：binary_little_endian、f_dc→颜色的 `(c-0.5)/0.2820948` 逆映射、opacity 的 sigmoid/logit 往返 | `writePLY/readPLY` |
| **排索引不排负载**：key 与原 index 打包进一个 ulong，比较/交换成本减半（16 号练习 3 的落地）| `makeKeys` |
| IEEE754 正数的位模式**保序映射**（float→uint 单调）| 同上 |
| **gather pass**：升序键倒序取 → 远→近的混合序（alpha 合成的正确性根基）| `gather` |
| instanced billboard：`[[instance_id]]` + 顶点着色器自生成四角，屏幕半径 ∝ scale/w | `splatVert` |
| premultiplied alpha 混合（one / oneMinusSourceAlpha）| PSO |
| SH 仅 DC 项、各向同性 scale 的**诚实简化**（真版差距见练习）| 全局 |

**headless 验证**：ply 往返 32768/32768；键单调违例 0/32767；圆环+螺旋+地面结构可见。
**开发实录踩坑**：reader 初版 stride 按 21 字段算（真实 3DGS 含 f_rest×45 时才是 62 字段），与 writer 的 17 字段不符 → 读回 26526 个错位 splats——**资产格式的读写两侧必须共享同一定义**（常量/代码生成），本仓库用"往返计数断言"兜底。

## 与真 3DGS viewer 的差距（练习路线，对照 docs/22 与 docs/27 案例 D）

1. **2D 协方差投影**：真版把 3D 高斯（scale+rot 四元数）投影成屏幕椭圆（EWA splatting）——本例的圆形 splat 是最大简化
2. f_rest 高阶 SH（视角相关颜色）
3. 键量化 uint16 + GPU radix（16 号练习 2）
4. 真实训练数据：`gsplat`/官方推理输出直接喂本 loader
5. ARKit 摆放 + EDR（docs/27 案例 D 第 7~10 周）
