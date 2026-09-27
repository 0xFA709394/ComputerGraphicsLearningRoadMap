# 19 · glTF 2.0 最小资产管线（生成 → 写 → 读 → 渲染往返）

docs/10 §资产管线（glTF/OBJ/USD）此前无代码——本例补上。docs/27 案例 A 第 3~4 周的 MVD。

## 运行

```bash
./build.sh
./gltf      # knot.gltf + knot.bin 由程序生成, stdout 打印往返计数
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **glTF 2.0 分体结构**：.gltf(JSON 场景图) + .bin(顶点数据) | `GlbWriter` |
| **bufferView/accessor 语义**：byteOffset 对齐、componentType(5123=u16/5126=f32)、target(34962/34963) | 同上 |
| 材质的 `pbrMetallicRoughness.baseColorFactor` 读到渲染 | `GlbLoader` → `frag` |
| **accessor 反解**：按 count×type×componentType 从 bin 切片读回 | `readAccessor` |
| 程序化环面结网格（18 号三叶结的 Swift 移植，7920 顶点/47520 索引） | `GlbMesh` |
| 交错顶点打包（pos3f|nrm3f 24B——16 号 SIMD3 对齐教训的纪律应用） | `Renderer.init` |

**headless 验证**：往返 47520/47520 索引；材质颜色贯通（暖色结像素断言）；成像正常。
**开发实录踩坑**：primitive 里的 accessor 编号写偏一位（indices:1/POSITION:2/NORMAL:3，实际 0/1/2）——JSON 数组下标手写时**与数组定义必须对照编号**；这正是 MTKMesh 崩坏后自写加载器的第一课：**资产格式的引用完整性要靠往返计数断言兜底**（同 17 号 ply 的教训）。

## 练习路线（对照 docs/27 案例 A 第 3~4 周）

1. GLB（二进制容器：12B 头 + JSON chunk + BIN chunk）
2. 多 mesh/多 node 的场景图（node 变换层级 = 15 号骨骼链的静止版）
3. KHR_materials_pbrSpecularGlossiness + baseColorTexture（贴图接入 04 号知识）
4. 接进 14 号帧图：glTF 节点 → frame graph 的 opaque pass
5. Draco/meshopt 压缩扩展（工业级加载器的分水岭）
