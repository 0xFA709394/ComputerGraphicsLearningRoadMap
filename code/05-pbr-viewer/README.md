# 05 · PBR Viewer（实例化参数矩阵 + GGX 三点光 + ACES）

对应 `docs/03` 全章与 `docs/16 Step 5`——起步示例的收官。7×5 球阵：横轴 metallic 0→1，纵轴 roughness 0→1，金色 baseColor，暖主光 + 冷补光 + 背后轮廓光。

## 运行

```bash
./build.sh
./pbr-viewer
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| 实例化绘制：`instance_id` + 实例 buffer（每球 metallic/roughness）| `vertMain` + `drawIndexedPrimitives(instanceCount:)` |
| 完整 Cook-Torrance：GGX D / Smith G / Schlick F（docs/03 §4）| `fragMain` |
| metallic 工作流 F0 与漫反射规则 | `F0 = mix(0.04, albedo, metallic)` |
| 三点光布置（key/fill/rim）与 1/d² 衰减+windowing | `Uniforms` 灯光数据 |
| ACES tone map + 手动 gamma（本例 RT 非 sRGB 格式）| `acesFitted` |

**观察点**（对照 docs/03 自测）：
- 顶行（roughness=0）高光锐利如镜面钉点；底行拖出宽光晕（GGX 重尾）
- 右列（metallic=1）无漫反射、高光呈金色；左列高光无色（电介质）
- 轮廓光勾勒出每球边缘——验证 `VdotH` 菲涅尔在掠射角增强

## 练习（通往 18 章毕业项目）

1. 材质参数改为每实例 `SIMD4(baseColor.rgb, roughness, metallic)`，给球阵上色棋盘（04 例纹理接入）
2. 灯光数据移入 `array<Light>` 常量缓冲 + 循环上限用 function constant 特化（docs/10 §3.1）
3. 预热下一步：给环境项换成真 IBL——prefiltered cube + BRDF LUT（docs/03 扩展篇 C 代码直接可抄）
4. 把 `half` 化本 shader（docs/07 §E 清单），对比 GPU 计数器

## macOS 26 适配注记

本机工具链上 `MDLAsset → MTKMesh` 转换出的**顶点位置全为 0**（手写四面体 OBJ 可复现，与 vertexDescriptor 传法无关），球体会静默消失。现改用 `makeSphereBuffers()` 过程化经纬球（布局 pos3f|normal3f|uv2f 与原流程一致，shader 不变）。原 Model I/O 加载流程见 git 历史（工具链修复后可还原）；完整排障过程见 `code/11-csm/README.md` 的踩坑实录。
