# 14 · 迷你帧图（声明式 pass 组织 + 拓扑排序 + 死 pass 剔除 + RT 池化）

**培训体系的收官件**：18 章蓝图 M2（frame graph + 资源管理）的最小可信实现。载荷是一条 HDR bloom 后处理链（场景 → 亮部提取 → 分离高斯 ×2 → 合成），三球 + 条纹地面，首帧打印图编译结果与池统计。

## 运行

```bash
./build.sh
./framegraph     # 首帧 stdout: "帧图编译: scene → bright → blurH → blurV → composite"
                 # 第二帧: "RT 池: 命中 N / 新建 M"(跨帧零新建 = 池化在工作)
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **声明式 pass**：只说"我读什么写什么、怎么画"，组织顺序交给图 | `FGPass` |
| **编译期拓扑排序**（Kahn 算法）：读先于写自动排出依赖序 | `compile()` |
| **死 pass 剔除**：从输出 pass 反向标记可达，没被读到的 pass 整体不执行 | 同上 |
| **渲染目标池**：按"格式+尺寸"内容寻址跨帧复用（名字不参与键）| `poolKey()` |
| **瞬时资源**：深度缓冲 loadAction=clear + storeAction=dontCare，用完即弃 | `execute()` |
| **backbuffer 特殊化**：drawable 每帧轮换不进池，用 customTarget 钩子注入 | `FGPass.customTarget` |
| 半分辨率 bloom 链（亮部软阈值 + 9-tap 分离高斯 + ACES 合成）| `Shaders.metal` |
| 图按帧重建（pass 集合可随状态增减——帧图的核心价值）| `draw()` |

**headless 验证**：编译序正确（shadowMap → scene → bright → blurH → blurV → composite）；第二帧起 RT 池零新建；三球清晰、阴影 pass 已入图。

## 与前作的关系

06（离屏 postfx）手写了五个 render pass 的串联——本例把同样的链路**交给图去组织**：加一个 pass 只需声明 + append，顺序、资源、复用全自动。这就是从"示例"到"引擎"的一步：07 的阴影、11 的 CSM、13 的 TAA 都是未来往这张图上挂的新节点。

## 观察点与练习

- 观察：改 `buildPostChain` 里 blur 迭代 ×2（再挂两组 blurH/blurV），编译输出自动变长；把 "bright" 从 composite 的 reads 里删掉——整条后处理链被死 pass 剔除，只剩 scene。
1. RT **别名**（aliasing）：bright/blurH/blurV 三个半分辨率 RT 生命周期不重叠，理论上可共用一块内存（真引擎按生命期重叠分析做内存复用，带宽/内存省一半）
2. 把 07 的 shadow pass 挂进图（writes: ["shadowMap"]，scene reads 它）
3. 把 13 的 TAA resolve 挂进图（历史 RT 是**跨帧资源**——池需要"persist"标记）
4. 异步 compute：把 blur 改 compute 内核放第二队列（图节点带队列标签）
5. 增量编译：本例每帧重建图；真引擎 diff 上一帧的图做增量（docs/18 M2 的完整形态）

## 体系终章

至此 14 个示例 + 26 章文档 + 周计划构成完整闭环：**概念（docs）→ 落地（code）→ 工程化（frame graph）**。往后就是把这张图越挂越满、把每个节点越写越深——那是学习者的旅途，不是脚手架的。
