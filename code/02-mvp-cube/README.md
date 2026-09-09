# 02 · MVP Cube（顶点缓冲 + uniform + 深度）

对应 `docs/16-metal-quickstart.md` Step 2 与 `docs/01-math.md` 扩展篇 A/C 的矩阵落地。

## 运行

```bash
./build.sh
./mvp-cube       # 旋转的六色立方体
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| 顶点/索引缓冲 + `drawIndexedPrimitives` | `main.swift` draw |
| vertex pulling 式 shader（免 vertex descriptor）| `Shaders.metal` vertMain |
| Metal 透视矩阵（z∈[0,1]，y 翻转）与 lookAt | `perspective` / `lookAt` |
| 深度缓冲三件套：PSO 格式 + depthStencilPixelFormat + depth state | init |
| 每帧 uniform：`setVertexBytes` 直传 MVP | draw |

## 练习（对照 docs/16 Day2）

1. 把 `clearDepth` 改 0、`depthCompareFunction` 改 `.greater`（reversed-z 版），验证效果一致——理解 01 章深度方向
2. 打开背面剔除 `enc.setCullMode(.back)`，观察哪些面被剔掉，修正每面索引绕向直到正确（02 章绕向实战）
3. uniform 里再加一个 `float4x4 model`，shader 中输出生成法线着色的立方体（提示：面法线=顶点色通道复用）
4. 用键盘/鼠标改 eye，做一个 orbit 相机（01 章 lookAt 复用）
