# 15 · 2D 渲染与 Core Animation 的图形学本质

> iOS 老兵的主场变现章：把 20 年 UI 经验**翻译**成图形学语言。读完你会发现 CALayer 树就是一张合成图（scene graph），Render Server 就是一个系统级 frame graph——熟悉的锚点让 GPU 知识立刻可用。

---

## 1. 立即模式 vs 保留模式（渲染架构第一刀）

| | 保留模式 | 立即模式 |
|---|---|---|
| 代表 | UIKit/Core Animation、浏览器、Flutter | 游戏引擎、imgui、自研渲染器 |
| 数据 | **layer 树持久化**，系统负责合成 | 每帧全量重录命令 |
| 状态 | 声明式（改属性，系统算差量）| 命令式（你自己维护场景）|
| 优势 | 局部更新/动画外置/省电 | 完全控制/特殊效果 |

- `CALayer ≈ 一张纹理 + 4×4 变换 + 混合参数 + 裁剪/遮罩描述`——它就是你手写渲染器里的一个 **sprite draw**。
- 你做 Metal 渲染器时的"场景树"与 CA 的 layer 树同构：**两者都是"变换层级 + 可绘制叶"**。

## 2. Render Server：系统级 Frame Graph

- **Core Animation 的渲染在独立进程**（render server，历史上是 backboardd）：App 只提交 layer 树变更，GPU 合成命令由它编码。
- 每帧流程：`CATransaction.commit()`（runloop 末尾隐式提交）→ 打包 layer 变化 → Render Server 合成 → 与 display 同步上屏。
- **为什么主线程卡死时动画照样流畅**：隐式动画（position/transform 等）的插值发生在 Render Server 侧——App 只上交了起止值与 timing 函数。图形学表述：**状态插值外包给了合成器，渲染器（你的 App）只出关键帧**。
- presentation layer vs model layer：前者是"服务端当前插值状态"的查询接口——调试动画跳变的必备工具。

## 3. 常用属性的图形学本质对照表

| CA 属性 | 图形学本质 | 章节 |
|---|---|---|
| transform / CATransform3D | 4×4 仿射/投影矩阵；**m34 = 透视项**（非零才近大远小）| 01 |
| anchorPoint | 变换局部原点 = 矩阵链 `T(anchor)·M·T(−anchor)` | 01 |
| opacity | 混合因子（premultiplied 合成）| 02 |
| cornerRadius + masksToBounds | 片元级形状裁剪（历史实现代价见 §4）| 02 |
| mask | 逐像素模板/alpha 相乘 | 02 |
| shadow | **离屏合成的模糊**：shadowPath 给定形状轮廓可免alpha 分析 | 09 |
| shouldRasterize | "烘焙成纹理缓存"——一次离屏换多次复用 | 07 |
| contents (CGImage) | 一张纹理（GPU 常驻/按需上传）| 04 |
| CAEmitterLayer | GPU 粒子系统的系统封装 | 07/14 |

把每行读成"哦，就是我写过的那个 pass/参数"，这一章就完成了它的翻译任务。

## 4. 离屏渲染与合成成本（性能直觉的总复习）

- **离屏渲染的本质**：合成器无法在单 pass 顺序流水线完成（需要中间纹理/多次采样同一内容）——与你 Metal 里"多一个 RenderPass = tile 写回"完全同源（07 章）。
- 典型触发：mask、多图层阴影（无 shadowPath）、圆角+裁剪叠加（部分场景现代 iOS 已优化，用 Instruments 确认而非背诵）、`shouldRasterize` 本身（首次）。
- **Color Blended Layers（绿/红）**：红色 = 该区域半透明需混合下层 = **UI 界的 overdraw 计数器**；优化手法全透明/blendedLayers。
- `drawsAsynchronously` / AsyncDisplayKit 思路：**把纹理生产（布局+光栅化）移到工作线程，主线程只提交纹理**——正是你自研渲染器"CPU 编码多线程化"的 UI 版。
- 功耗视角：合成层级深度 ≈ 带宽倍数；ProMotion 下静态内容自动降频，动态 layer 树深度直接进耗电账本。

## 5. Metal 与 CA 的互通（你第 4 阶段的日常）

```cpp
// MTKView/CAMetalLayer 的关键配置与语义
layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;   // 输出色彩空间由 CA 层管理
layer.wantsExtendedDynamicRange = YES;               // EDR: >1.0 值直通显示(09章)
layer.maximumDrawableCount = 3;                      // 2=省内存多等待, 3=流畅多内存
// drawable = 系统纹理池轮转; presentDrawable 与 vsync 对齐(帧节奏=07章)
```
- 你的 Metal 输出最终**仍经 Render Server 与 UI 合成**——所以 EDR/色彩管理/色彩空间协商都发生在 layer 级；调试"画面与系统 UI 亮度不一致"先查这里。
- 与 UI 同帧混排的时序：`CAMetalLayer` 的 drawable 在提交后进入合成队列，与 CA 事务的 commit 时机耦合——偶发掉帧的隐性来源。

## 6. 文字渲染速成（2D 渲染的最后堡垒）

- 管线：`字体文件(glyph 轮廓) → shaping(把字符序列→字形序列+定位, HarfBuzz/CoreText) → 光栅化 → 纹理图集缓存 → 图元提交`。
- glyph 光栅化三种：**CPU 位图缓存**（抗锯齿灰度/次像素 RGB，系统 UI 标配）；**SDF 文字**（Valve 2007，任意缩放+描边/阴影，游戏 HUD 主流）；**GPU 直接矢量光栅化**（Pathfinder 类，笔画展开/扫描线，大字号动态缩放最优）。
- 纹理图集 = 04 章图集技术：glyph 按字体/字号/样式分桶入 LRU 图集，命中即免光栅化。
- 10 年内你会发现：自己写游戏 UI 框架时 80% 的难度在文字（shaping/双向排版/emoji），不在画矩形。

## 7. 自绘 UI 的架构启示（游戏内 UI）

- 立即模式（imgui）：每帧重建顶点列表——**状态即函数返回值**，工具 UI 神器。
- 保留模式（UMG/自研）：控件树 + 脏标记 + 合批渲染（同图集九宫格/文本分桶合批）。
- 核心渲染问题就三个：**图集合批（draw 数 <10）、文字缓存（§6）、裁剪嵌套（scissor 栈）**——全部映射到 02/04/07 章。
- SwiftUI `Canvas`/`graphicsEffect` 的可编程着色（RuntimeShader 思想）= 官方把 fragment shader 递给 UI 层的通道——你的两套知识在产品层合流。

## 8. 自测清单

- [ ] 解释"主线程阻塞动画仍流畅"的渲染架构原因（Render Server 插值）
- [ ] 用矩阵链写出 anchorPoint 语义并验证旋转缩放行为
- [ ] 说明 mask 触发离屏渲染的管线原因，及 shadowPath 的优化原理
- [ ] 把 Color Blended Layers 映射为 overdraw 术语并给出优化清单
- [ ] 画出 Metal drawable 进入屏幕合成的完整时序（含 EDR/色彩空间协商）
- [ ] 设计一个游戏内 UI 渲染器的合批策略（图集/文字/裁剪三件事）

---

## 结语（全书）

至此 15 章闭环：**数学(01)→管线(02)→光照(03)→纹理(04)→几何(05)→光追(06)→GPU(07)→动画(08)→色彩(09)→工程(10)→进阶(11)→方向(12)→速查(13)→物理(14)→2D/CA(15)**。你的 iOS 经验不是需要卸下的包袱，而是第 15 章这样的"翻译接口"——每一章都能找到一个你熟悉的锚点。开始写代码吧：第一个里程碑永远是 **Hello Triangle**。
