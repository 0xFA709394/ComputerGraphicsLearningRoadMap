// 17-3dgs-viewer: 3D Gaussian Splatting 最小查看器(docs/22 第 1~2 周 / docs/27 案例 D 的 MVD)
// 链路: 合成场景 → 真实 .ply 往返 → bitonic 排序(ulong: key<<32|index, 排索引不排负载)
//      → gather 重建有序实例缓冲 → instanced billboard + alpha 混合(远→近)

#include <metal_stdlib>
using namespace metal;

struct Splat {
    float4 posScale;     // xyz + 世界尺度
    float4 colorAlpha;   // rgb(SH DC 已解码) + alpha
};

// ---- Pass 1: 每帧生成排序键(ulong: 32bit 单调键 << 32 | 原 index) ----
kernel void makeKeys(device const Splat *splats [[buffer(0)]],
                     device ulong *keys [[buffer(1)]],
                     constant float3 &camPos [[buffer(2)]],
                     uint gid [[thread_position_in_grid]]) {
    float3 p = splats[gid].posScale.xyz;
    float d = length(p - camPos);                       // 距离键
    uint k = as_type<uint>(d);                          // IEEE754 单调映射(正数保序)
    keys[gid] = (ulong(k) << 32) | ulong(gid);
}

// ---- Pass 2: bitonic(与 16 号同构, ulong 全比较: 越大越远 → 升序 = 近在前) ----
kernel void bitonicUlong(device ulong *keys [[buffer(0)]],
                         constant uint2 &kj [[buffer(1)]],
                         uint gid [[thread_position_in_grid]]) {
    uint k = kj.x, j = kj.y;
    uint i = gid, l = i ^ j;
    if (l > i) {
        bool descending = (i & k) == 0;
        ulong a = keys[i], b = keys[l];
        bool swap = descending ? (a > b) : (a < b);
        if (swap) { keys[i] = b; keys[l] = a; }
    }
}

// ---- Pass 3: gather —— 按有序索引重建实例缓冲(降序遍历 = 远→近, 正确混合序) ----
kernel void gather(device const Splat *splats [[buffer(0)]],
                   device const ulong *keys [[buffer(1)]],
                   device Splat *sorted [[buffer(2)]],
                   constant uint &nTotal [[buffer(3)]],
                   uint gid [[thread_position_in_grid]]) {
    // 升序数组(近在前)从尾部倒序取 → sorted[0]=最远: alpha 混合要求的远→近序
    uint idx = uint(keys[nTotal - 1 - gid] & 0xFFFFFFFF);
    sorted[gid] = splats[idx];
}

// ---- Pass 4: instanced billboard 渲染 ----
struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float4 misc;        // x: time, y: N, z: sortedOn, w: viewportH
};
struct VOut {
    float4 pos [[position]];
    float2 corner;
    float4 colorAlpha;
    float radiusPx;
};
vertex VOut splatVert(uint vid [[vertex_id]],
                      uint iid [[instance_id]],
                      device const Splat *sorted [[buffer(0)]],
                      constant Uniforms &u [[buffer(1)]]) {
    Splat s = sorted[iid];
    float4 clip = u.viewProj * float4(s.posScale.xyz, 1);
    VOut o;
    o.pos = clip;
    // 屏幕空间半径 ≈ 世界尺度 × 投影缩放/w(docs/22 简化: 真版是 3D 协方差→2D 投影, 见 README 练习)
    float rPx = clamp(s.posScale.w / max(clip.w, 0.3) * u.misc.w * 0.35, 2.0, 60.0);
    float2 c[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    o.corner = c[vid];
    o.pos.xy += c[vid] * rPx / float2(u.misc.w * 1.5, u.misc.w);   // NDC 偏移(近似方形视口)
    o.colorAlpha = s.colorAlpha;
    o.radiusPx = rPx;
    return o;
}
fragment float4 splatFrag(VOut in [[stage_in]]) {
    float d2 = dot(in.corner, in.corner);
    if (d2 > 1) discard_fragment();
    float a = in.colorAlpha.a * exp(-4.0 * d2);        // 高斯核 α 衰减
    return float4(in.colorAlpha.rgb * a, a);           // premultiplied
}
