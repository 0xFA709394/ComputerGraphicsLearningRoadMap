# 01 · Hello Triangle（macOS 可运行）

对应 `docs/16-metal-quickstart.md` Step 0–1。**无 Xcode 工程**——两个源文件 + 一个构建脚本，适合理解最小管线。

## 运行

```bash
./build.sh
./hello-triangle      # 弹出 800×600 窗口, 彩色三角形
```

要求：macOS + Xcode Command Line Tools（`xcode-select --install`）。

## 文件

| 文件 | 职责 |
|---|---|
| `main.swift` | AppKit 窗口 + MTKView + Renderer（device/queue/PSO/帧循环）|
| `Shaders.metal` | 最简顶点/片元着色器（vertex_id 取硬编码顶点）|
| `build.sh` | metal→air→metallib + swiftc 链接 |

## 读懂后的练习（下一站 docs/16）

1. 顶点色改成随时间渐变（`frame` 号经 uniform 传入）
2. 加第二个三角形（vertexCount / buffer 两种做法各写一遍）
3. 加深度缓冲 + `depth32Float`（docs/16 Step 1）
4. 逐步升级到 MVP uniform → OBJ 加载 → PBR（docs/16 Step 2–5）
