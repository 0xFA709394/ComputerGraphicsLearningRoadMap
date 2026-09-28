// 16-compute-sort: GPU bitonic 排序(docs/07 §6 模式库「排序」的落地)
// 案例需求方: 3DGS 深度排序(D)/透明排序(A)。要点: 排序网络 = 无数据依赖的
// 固定 pass 序列, 每个 pass 一次 compute dispatch, 全程零 CPU 回读。

#include <metal_stdlib>
using namespace metal;

// 点数据: xyz 位置, w = 排序键(视深)
kernel void bitonicStep(device float4 *data [[buffer(0)]],
                        constant uint2 &kj [[buffer(1)]],
                        uint gid [[thread_position_in_grid]]) {
    uint k = kj.x, j = kj.y;
    uint i = gid;
    uint l = i ^ j;                 // 本 pass 的配对元素
    if (l > i) {                    // 每对只处理一次(l<i 的线程直接空转)
        bool descending = (i & k) == 0;   // 网络方向: 每 k 段交替升降
        float4 a = data[i], b = data[l];
        bool swap = descending ? (a.w > b.w) : (a.w < b.w);
        if (swap) { data[i] = b; data[l] = a; }
    }
}

// ---- GPU radix 排序(LSB, 4-bit × 8 pass; docs/27 案例 D 的工业正主) ----
// pass p: 1) 直方图(全局原子, 16 bin) 2) 前缀和(单线程组) 3) 散射(游标原子)
// 键内含负载(索引在低 32 位), 非稳定排序不影响正确性。
kernel void radixHist(device const ulong *keys [[buffer(0)]],
                      device atomic_uint *hist [[buffer(1)]],
                      constant uint &shift [[buffer(2)]],
                      uint gid [[thread_position_in_grid]]) {
    uint digit = uint(keys[gid] >> shift) & 0xF;
    atomic_fetch_add_explicit(&hist[digit], 1, memory_order_relaxed);
}
kernel void radixScan(device uint *hist [[buffer(0)]],      // 16 bin: 就地前缀和(含 0)
                      threadgroup uint *tg [[threadgroup(0)]],
                      uint ti [[thread_position_in_threadgroup]]) {
    if (ti < 16) tg[ti] = hist[ti];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (ti == 0) {                                          // 16 元素串行 scan(教学版)
        uint sum = 0;
        for (int i = 0; i < 16; i++) { uint v = tg[i]; tg[i] = sum; sum += v; }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (ti < 16) hist[ti] = tg[ti];
}
kernel void radixScatter(device const ulong *keysIn [[buffer(0)]],
                         device ulong *keysOut [[buffer(1)]],
                         device atomic_uint *cursor [[buffer(2)]],   // 16 bin 游标(从 scan 偏移起)
                         constant uint &shift [[buffer(3)]],
                         uint gid [[thread_position_in_grid]]) {
    uint digit = uint(keysIn[gid] >> shift) & 0xF;
    uint pos = atomic_fetch_add_explicit(&cursor[digit], 1, memory_order_relaxed);
    keysOut[pos] = keysIn[gid];
}
kernel void clearBins(device atomic_uint *bins [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid < 16) atomic_store_explicit(&bins[gid], 0, memory_order_relaxed);
}

// ---- 渲染: 点精灵, 颜色 = 排序后的名次(rank) → 深度扫过时颜色流动 = 排序的可视化证明 ----
struct Uniforms {
    float4x4 viewProj;
    float4 misc;        // x: time, y: N, z: sortedOn
};
struct VOut {
    float4 pos [[position]];
    float size [[point_size]];
    float rank;
};
vertex VOut ptVert(device const float4 *data [[buffer(0)]],
                   constant Uniforms &u [[buffer(1)]],
                   uint vid [[vertex_id]]) {
    VOut o;
    float4 p = data[vid];                    // 排序后: 数组下标即名次
    o.pos = u.viewProj * float4(p.xyz, 1);
    o.size = clamp(30.0 / max(o.pos.w, 0.5), 2.0, 10.0);
    o.rank = u.misc.z > 0.5 ? float(vid) / u.misc.y : float(vid) / u.misc.y;
    return o;                                // 关排序时 rank=原始下标(乱色) 作对照
}
fragment float4 ptFrag(VOut in [[stage_in]], float2 pc [[point_coord]]) {
    float2 c = pc * 2 - 1;
    if (dot(c, c) > 1) discard_fragment();
    float fall = exp(-3.0 * dot(c, c));
    float r = in.rank;
    float3 col = mix(float3(0.15, 0.35, 0.95), float3(0.95, 0.25, 0.30), smoothstep(0.0, 0.6, r));
    col = mix(col, float3(1.0, 0.85, 0.3), smoothstep(0.6, 1.0, r));   // 蓝→红→金 名次渐变
    return float4(col * fall * 0.6, 1);
}
