# 03 · OBJ Viewer（Model I/O + stage_in + Blinn-Phong）

对应 `docs/16-metal-quickstart.md` Step 3 与 `docs/10 §4.2`（资产管线）。加载 `assets/sphere.obj`（脚本生成的 UV 球，693 顶点/1280 三角形），Blinn-Phong 光照 + 程序化 UV 棋盘。

## 运行

```bash
./build.sh
./obj-viewer      # 旋转的棋盘球
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| MDLAsset 加载 + **MTKMeshBufferAllocator** | `main.swift` §1 |
| MTLVertexDescriptor ↔ MDL 描述符转换（pos/normal/uv, stride 32）| §2 |
| `[[stage_in]]` + `[[attribute(n)]]` 声明式顶点输入 | `Shaders.metal` |
| 世界空间法线/位置 varying、Blinn-Phong | `fragMain` |
| UV 可视化（透视校正插值直观检验）| `checkerboard` |

## 开发实录踩坑（本文件真实调试过程，价值高于代码）

1. **`MTKMesh 转换失败`**——`MDLAsset(url:)` 默认分配器不产生 `MTLBuffer`；必须 `MDLAsset(url:vertexDescriptor:bufferAllocator: MTKMeshBufferAllocator(device:))`。16 章 Step 3 的头号坑。
2. `pd.vertexDescriptors[0]` 不存在——正确属性是单数 `pd.vertexDescriptor`。
3. MSL struct 内 `float3` 有 16 字节对齐——想用 vertex pulling 手写 struct 对齐 32 字节布局会踩坑，所以本例走标准 `[[stage_in]]` 路线（对比 02 例的 pulling 风格，两种都该会）。

## 练习（对照 docs/16 Day3）

1. 换你自己的 OBJ（Blender 导出，Y-up、仅三角面），处理"模型消失/绕向"两件事
2. 把棋盘换成真纹理：`MTKTextureLoader` + `SRGB` 选项 + shader `texture2d` 采样（Step 4）
3. 加第二个光源与 rim light（17 章 §1）
4. 用 `mesh.boundingBox` 自动缩放/居中任意模型到视锥内

## macOS 26 适配注记

本机工具链上 `MDLAsset → MTKMesh` 转换出的**顶点位置全为 0**（手写四面体 OBJ 可复现，与 vertexDescriptor 传法无关），球体会静默消失。现改用 `makeSphereBuffers()` 过程化经纬球（布局 pos3f|normal3f|uv2f 与原流程一致，shader 不变）。原 Model I/O 加载流程见 git 历史（工具链修复后可还原）；完整排障过程见 `code/11-csm/README.md` 的踩坑实录。
