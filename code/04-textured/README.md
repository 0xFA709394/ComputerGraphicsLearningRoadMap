# 04 · Textured（纹理 + sRGB + mipmap 半球对照）

对应 `docs/16-metal-quickstart.md` Step 4、`docs/04 §2`（过滤与 mipmap）、`docs/09 §3`（sRGB 纪律）。

## 运行

```bash
./build.sh
./textured     # 球体右半平滑(mip 自动)、左半远处闪烁(强制 mip0)
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| `MTKTextureLoader` + `.SRGB` 选项（采样时硬件解码到线性）| `main.swift` §2 |
| `.generateMipmaps`（加载后自动建 mip 链）| 同上 |
| shader 内声明 `constexpr sampler`（三线性+repeat）| `Shaders.metal` |
| `level(0)` 强制 mip vs 自动选级——半屏对照实验 | `fragMain` |

**观察点**：把窗口缩小到原来 1/4——左半（`level(0)`）高频棋盘开始严重闪烁走样，右半（自动 mip）只是变模糊：这就是 Nyquist 与 mipmap 的关系（04 章 §1–2），一图胜千言。

## 练习

1. 把 `.SRGB: true` 改成 `false` 跑一次——左亮右暗对比消失、整体"发灰"，亲手复现 09 章排障表第 1 行
2. 把采样器 `mip_filter::linear` 去掉（即不用三线性）→ mip 级间跳变线出现在球面上
3. `MTLTexture.write` 自己填一张渐变纹理（无文件创建纹理的路径）
4. 加 `texture2d<float> albedoTex [[texture(1)]]` 第二张细节纹理，近距离叠加（04 章 §5.4 detail）

## macOS 26 适配注记

本机工具链上 `MDLAsset → MTKMesh` 转换出的**顶点位置全为 0**（手写四面体 OBJ 可复现，与 vertexDescriptor 传法无关），球体会静默消失。现改用 `makeSphereBuffers()` 过程化经纬球（布局 pos3f|normal3f|uv2f 与原流程一致，shader 不变）。原 Model I/O 加载流程见 git 历史（工具链修复后可还原）；完整排障过程见 `code/11-csm/README.md` 的踩坑实录。
