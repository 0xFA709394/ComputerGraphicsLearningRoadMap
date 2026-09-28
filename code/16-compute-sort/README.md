# 16 · GPU Bitonic 排序（65536 键/帧 · 逐 pass 多 dispatch · 零 CPU 回读）

docs/07 §6 模式库「排序」条目的落地，同时是 **docs/27 进阶案例的公共深水区**：案例 D 的 3DGS 深度排序、案例 A 的透明排序都以它为原语。空格键开关排序（颜色乱序/名次渐变对照）。

## 运行

```bash
./build.sh
./computesort     # 空格: 开关排序
```

## 本例要点

| 知识点 | 位置 |
|---|---|
| **bitonic 排序网络**：O(log²N) 个固定 pass，无数据依赖、无原子、无锁——GPU 友好的本质 | `bitonicStep` |
| 比较交换配对：线程 i 处理 `(i, i^j)`，`l>i` 才动手 → 每对恰好一次，**in-place 安全** | 同上 |
| 方向位 `(i & k) == 0`：每 k 段交替升降，网络末端收敛为全序 | 同上 |
| **逐 pass 多 dispatch**：65536 元素 = 105 次 dispatch（log²16/2），全部编码进一个 command buffer，零 CPU 回读 | `draw()` 双重 while |
| 键 = 视线深（CPU 写 w；可并入首个 pass 作练习——带宽合并） | 同上 |
| **排序结果的可视化证明**：数组下标即名次 → 蓝→红→金渐变；旋转相机时颜色随深度流动 | `ptVert/ptFrag` |

**headless 验证**：回读缓冲断言**单调违例 0/65535**（完全有序）；lit 17.2% 点云带渐变。

## v2 · GPU radix 排序（练习 2 落地）

LSB radix：**16 pass × 4-bit nibble 全覆盖 64 位键**，每 pass 三 kernel：
`radixHist`（全局原子计数 16 bin）→ `radixScan`（单线程组串行前缀和，教学版）→ `radixScatter`（游标原子散射）。

**headless 基准**：32k 键违例 0/32767；radix 4.89ms vs bitonic 1.94ms——**教学版更慢**，原因正是工业差距所在：
全局原子在 16 bin 上争用（32768 线程打 16 个地址）而无 threadgroup 聚合；16 次 pass 的 dispatch 开销。
工业版（案例 D）：threadgroup 内聚合直方图 + 多桶扫描 + 一次性 uint16 键——把 4.89ms 打进 0.5ms 量级。

**v2 踩坑实录**：
1. **`thread_position_in_threadgroup` 是属性不是函数**——MSL 里只能 `uint ti [[thread_position_in_threadgroup]]` 作为参数传入，函数体内直接调用报 undeclared（独立最小文件单测抓出）。
2. **radix 排的是键缓冲不是数据缓冲**——初版把 SIMD4 点数据当 ulong 键排，违例一半。分离 `radixKeys/radixScratch` 后干净。
3. **`cb.waitUntilCompleted()` 前忘了 `cb.commit()` = 永久死等**——基准挂 9 分钟的元凶。

## 与 3DGS/透明的实战差距（练习路线）

1. 键量化：float32 → uint16（3DGS 工业做法，比较代价减半）
2. ~~bitonic → GPU radix~~ **已落地（v2）**；进阶：threadgroup 聚合直方图 + 多桶扫描（工业 3DGS 形态）
3. 排序值携带负载（3DGS 排的是索引而非数据——间接取 splat）
4. 分帧排序：相机慢转时隔帧重排（带宽减半的工程折中）
5. threadgroup 内存版本：组内排序 + 组间归并（docs/07 扩展 A 的树形归约思想）

## 体系位置

15 个基础示例之后的首个**进阶原语**：docs/27 四个案例中 A/D 直接引用、B 的 MLT 变异采样间接受益。它把「模式库伪码 → 可运行可验证实现」的仓库方法论延伸到了毕业后阶段。
