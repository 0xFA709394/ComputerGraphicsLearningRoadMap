# 27 · 进阶方向案例：第 26 周之后的四个完整项目

> 每个案例 = 一个**作品集级项目**：真实场景定位 + 技术分解 + 周里程碑 + 验收物 + 面试故事线。
> 全部从仓库已有资产出发——你的 14 号帧图、10 号路径追踪器、12 号 IBL 就是起点，不是从零开始。

## 如何选

| | A 引擎渲染器 | B 离线渲染器 | C Apple 图形专家 | D 3DGS 神经渲染 |
|---|---|---|---|---|
| 起点资产 | code/14 帧图 + 11/12/13 | code/10 路径追踪 | code/08/12 + Instruments | docs/22 + code/05 |
| 周期 | 16 周 | 14 周 | 12 周 | 12 周 |
| 强度 | 高（工程量大） | 高（数学深） | 中（平台知识广） | 中（跨领域新） |
| 就业面 | 游戏引擎/大厂渲染组 | 影视/研究/工业仿真 | Apple 生态稀缺位 | CV+图形交叉热点 |
| 加分背景 | C++/架构经验 | 数学耐心 | iOS 多年经验（你） | 学习能力展示 |

**只选一个做完，比四个都半途而废值钱十倍。** 下面每个案例都标了"最小可演示版本"（MVD）——时间不够时砍到 MVD 也要出片。

---

## 案例 A：Aurora——基于帧图的小型引擎渲染器（方向 A）

**定位**：一个能加载 glTF 场景、跑完整 PBR+阴影+后处理链的**可交互渲染器**，相当于把 UE5 渲染模块的知识压缩成一人可完成的比例。面试一句话："我写了一个 frame graph 驱动的 PBR 引擎渲染器，支持 glTF、CSM、TAA、IBL 和异步 compute。"

**技术分解**（在 14 号帧图上挂节点）：

```
[glTF 加载] → [帧图 v2] → [shadowCSM×4] → [opaque PBR+IBL] → [TAA resolve]
   ↓              ↓                              ↓
[资源系统]    [瞬时/持久资源]                [半透明(排序)]
                                                    ↓
              [bloom] → [ACES] → [MetalFX 超分] → [屏幕]
```

**周里程碑**：

| 周 | 内容 | 验收物 |
|---|---|---|
| 1~2 | 帧图 v2：节点队列标签（graphic/compute）、异步 compute 通道、RT 生命期重叠分析 | 编译输出打印资源复用率 |
| 3~4 | glTF 2.0 加载（KHR_materials_pbrSpecularGlossiness 之外的 core + skin）| DamagedHelmet 正确显示 |
| 5~6 | PBR 材质系统（uber shader + permutation 缓存）| 材质面板调参实时生效 |
| 7~8 | 把 11 号 CSM 挂图（4 级）+ 12 号 IBL（场景探针） | 室内外场景阴影/环境光正确 |
| 9~10 | 把 13 号 TAA 挂图 + 速度缓冲重投影（相机可动） | 移动相机无鬼影 |
| 11~12 | 半透明（OIT 或排序）+ 剪影 pass + MetalFX | Sponza 全场景 60fps |
| 13~14 | 性能专项：Instruments 归因 → bindless/argument buffer/实例化 | 一页性能报告（counter 证据链） |
| 15~16 | 打磨 + 演示模式 + README（架构图） | **3 分钟演示视频** |

**MVD（最小可演示）**：周 1~8——glTF + PBR + CSM 已是完整作品。
**关键深水区**：glTF 蒙皮（15 号的调色板直接复用）、TAA 重投影的速度缓冲、uber shader 的 permutation 爆炸管理。
**对应文档**：18 章（蓝图）、10 章（shader 工程）、07 章（bindless/性能）。

---

## 案例 B：Lumen-less 但 Honest——教学级离线渲染器（方向 B）

**定位**：把 10 号路径追踪器升级为**双向 + MLT + 体渲染**的物理正确渲染器，对标 Mitsuba 2 的教学定位。面试一句话："我的离线渲染器实现了 BDPT+MIS 和单向 MLT，渲染了 XXX 场景并和 Mitsuba 参考图做了 RMSD 对比。"

**技术分解**（在 10 号上生长）：

```
[BVH(SAH)] → [BDPT 双向路径] → [MIS 权重] → [MLT 变异采样]
     ↓                                ↓
[三角形网格(obj/glTF)]         [体渲染(homogeneous→heterogeneous)]
                                      ↓
              [GBuffer 辅助降噪(SVGF 思想)] → [EXR 输出 + RMSD 对比工具]
```

**周里程碑**：

| 周 | 内容 | 验收物 |
|---|---|---|
| 1~2 | BVH：SAH 构建 + 遍历（10 号暴力遍历直接换） | 10 万三角场景加速 100× 基准图 |
| 3~4 | 三角形网格 + 法线插值 + obj/glTF 输入 | Cornell Box 加_mesh 变体 |
| 5~7 | **BDPT**：双向路径生成 + MIS 权重（docs/06 §MIS 落地） | 同 spp 下噪声对比图（BDPT vs NEE） |
| 8~9 | 单向 MLT：变异策略 + 复用链 | 焦散场景（pool、glass caustics） |
| 10~11 | 体渲染：homogeneous 参与介质 → 单散射 | 体积光柱图 |
| 12 | OpenEXR 输出 + 与 Mitsuba 参考的 RMSD 脚本 | **误差数字**（物理正确的证明） |
| 13~14 | 文档：设计文档 + 每个估计器的推导笔记 | GitHub README（学术味） |

**MVD**：周 1~7（BVH + 网格 + BDPT/MIS）已超越绝大多数求职作品。
**关键深水区**：MIS 权重的幂次选择、MLT 的变异接受率调参、BDPT 的策略组合爆炸（限 S=2 起步）。
**对应文档**：06 章（全部）、01 章（蒙特卡洛）、03 章（BSDF 理论）。

---

## 案例 C：Metal 光影——Apple 平台图形专家方案包（方向 C）

**定位**：不做单一程序，做一个 **iOS 端"画质+性能"完整方案**：Metal 延迟光照 + MetalFX 超分 + 动态分辨率 + 热降级，配 Instruments 证据链。这是 Apple 生态里最稀缺的岗位画像。面试一句话："我做了一套 iOS 上的 MetalFX+DRS+热感知动态画质管线，A17 上功耗降低 X% 帧率提升 Y%，全部有 Instruments 数据。"

**技术分解**：

```
[TBDR 延迟光照(G-buffer 在 tile 显存)] → [MetalFX 时间超分]
        ↓                                      ↓
[DRS 动态分辨率]                    [CADisplayLink 帧调度]
        ↓                                      ↓
[thermalState 感知三档画质] ← [Instruments: GPU counter 时间线]
```

**周里程碑**：

| 周 | 内容 | 验收物 |
|---|---|---|
| 1~2 | iOS 移植 12 号 IBL（TBDR imageblock 版 G-buffer） | 真机跑通 + 帧捕获截图 |
| 3~4 | MetalFX 接入（时间超分，历史帧喂法） | 开/关对比视频 + 锐度分析 |
| 5~6 | DRS：GPU 帧时间反馈 → 渲染比例抖动 | 帧率曲线图 |
| 7~8 | thermalState 三档画质（降级路径设计） | 烤机 30 分钟帧率-温度曲线 |
| 9~10 | Instruments 专项：Metal System Trace 定位瓶颈并优化一轮 | **前后对比数据表** |
| 11~12 | ProMotion 自适应 + 低电量模式适配 + 总结报告 | 一页性能工程报告 |

**MVD**：周 1~6（MetalFX+DRS 已是完整特性）。
**关键深水区**：MetalFX 的历史帧与 TAA 的交互（13 号知识直接迁移）、TBDR 上 G-buffer 用 imageblock 显存而非中间 RT（07 章 §5 的主场）。
**对应文档**：07 章（TBDR）、09 章（EDR/MetalFX）、02 章（pass 组织）。

---

## 案例 D：Splat Studio——iOS 3DGS 查看与编辑器（方向 D）

**定位**：把 docs/22 的四周入门升级为**产品级 3DGS 移动查看器**：compute 排序、EDR 高亮、AR 摆放、体积压缩。站在 CV×图形的交叉热点上。面试一句话："我做了 iOS 上的 3DGS 渲染器，compute 排序 + 量化压缩，百万级 splat 30fps。"

**技术分解**：

```
[.ply → 量化压缩(SH 降阶+半精度)] → [compute: 每帧深度排序(radix)]
        ↓                                   ↓
[mipmap 式 LOD(距离衰减 SH 阶数)]      [点精灵/instanced quad 光栅化]
                                             ↓
              [EDR bloom 高亮] → [ARKit 平面检测摆放] → [截屏分享]
```

**周里程碑**：

| 周 | 内容 | 验收物 |
|---|---|---|
| 1~2 | docs/22 的 viewer 强化：instanced quad + 05 号的 PBR 混合 shading | 10 万 splat 60fps |
| 3~4 | compute 深度排序（08 号的粒子 compute 直接改造：位置→key 归约排序） | 旋转无闪烁 |
| 5~6 | 量化压缩：SH 系数降阶 + half + 分块 LOD | 内存减 60% 数据 |
| 7~8 | EDR 高光 + 简单曝光控制（09 章） | 高亮场景不发灰 |
| 9~10 | ARKit 摆放（平面检测 + 手势缩放旋转） | 真机 AR 演示视频 |
| 11~12 | 性能：排序带宽优化（分帧排序/桶排序）+ 总结 | 百万 splat 30fps 截图 |

**MVD**：周 1~4（排序查看器已可用）。
**关键深水区**：排序带宽（每帧百万 key 的 GPU 排序是带宽怪兽——分帧/桶排序是标准解）、SH 降阶的视觉损失控制。
**对应文档**：22 章（实操）、07 章（compute 模式库）、09 章（EDR）。

---

## 通用收尾动作（四个案例共用）

1. **仓库工程化**：CI（GitHub Actions 跑 build-all）、README 架构图、代码注释密度对齐本仓库风格。
2. **写作一篇**：把项目中最深的一个点写成博客（MLT 调参/MetalFX 历史帧/3DGS 排序带宽）——技术写作是图形学职位的硬通货。
3. **面试故事线**（STAR 压缩到 90 秒）：场景→你在已有基础上加了什么→最深的一个技术决策→量化结果。
4. **回哺本仓库**：踩坑实录按 16 章速查表格式提交——你的下一个人会感谢你。
