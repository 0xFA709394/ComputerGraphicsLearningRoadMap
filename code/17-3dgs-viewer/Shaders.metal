// 17-3dgs-viewer: 3D Gaussian Splatting 最小查看器(docs/22 第 1~2 周 / docs/27 案例 D 的 MVD)
// 链路: 合成场景 → 真实 .ply 往返 → bitonic 排序(ulong: key<<32|index, 排索引不排负载)
//      → gather 重建有序实例缓冲 → instanced billboard + alpha 混合(远→近)

#include <metal_stdlib>
using namespace metal;

struct Splat {
    float4 pos;          // xyz
    float4 colorAlpha;   // rgb + alpha
    float4 pad0;         // scale.xyz + pad(EWA 用)
    float4 pad1;         // quaternion (w,x,y,z)
};

// ---- Pass 1: 每帧生成排序键(ulong: 32bit 单调键 << 32 | 原 index) ----
kernel void makeKeys(device const Splat *splats [[buffer(0)]],
                     device ulong *keys [[buffer(1)]],
                     constant float3 &camPos [[buffer(2)]],
                     uint gid [[thread_position_in_grid]]) {
    float3 p = splats[gid].pos.xyz;
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
    float4 clip = u.viewProj * float4(s.pos.xyz, 1);
    VOut o;
    o.pos = clip;
    // ---- EWA splatting 核心(docs/27 案例 D 练习 1 的落地) ----
    // 1) 3D 协方差 Σ = R·S·Sᵀ·Rᵀ (S = scale 对角)
    float qw = s.pad1.x, qx = s.pad1.y, qy = s.pad1.z, qz = s.pad1.w;
    // 四元数 → 旋转矩阵(列)
    float3 r0 = float3(1-2*(qy*qy+qz*qz), 2*(qx*qy+qw*qz), 2*(qx*qz-qw*qy));
    float3 r1 = float3(2*(qx*qy-qw*qz), 1-2*(qx*qx+qz*qz), 2*(qy*qz+qw*qx));
    float3 r2 = float3(2*(qx*qz+qw*qy), 2*(qy*qz-qw*qx), 1-2*(qx*qx+qy*qy));
    float3 sc = s.pad0.xyz;
    // M = R·S 的三列
    float3 m0 = r0 * sc.x, m1 = r1 * sc.y, m2 = r2 * sc.z;
    // Σ = M·Mᵀ (对称)
    float sxx = dot(m0,m0), sxy = dot(m0,m1), sxz = dot(m0,m2);
    float syy = dot(m1,m1), syz = dot(m1,m2), szz = dot(m2,m2);
    // 2) 投影雅可比 J(视空间→NDC, 小角近似: 只取 x/y 缩放与透视除数)
    float3 pv = s.pos.xyz - u.camPos.xyz;
    float z = max(dot(pv, normalize(float3(-u.camPos.x, -u.camPos.y, -u.camPos.z))), 0.2);
    float f = u.misc.w * 0.5;                       // 焦距(像素)
    float jx = f / z, jy = f / z;
    // 3) 2D 协方差 C = J·W·Σ·Wᵀ·Jᵀ (W=视变换, 简化为恒等+深度缩放)
    float cxx = jx*jx*sxx, cxy = jx*jy*sxy, cyy = jy*jy*syy;
    cxx += 0.3; cyy += 0.3;                         // 低通核(docs/22 §EWA)
    // 4) 特征分解 → 椭圆半轴与角度
    float tr = cxx + cyy, det = cxx*cyy - cxy*cxy;
    float disc = sqrt(max(tr*tr/4 - det, 0.0));
    float l1 = tr/2 + disc, l2 = max(tr/2 - disc, 0.1);
    float ang = atan2(2*cxy, cxx - cyy) * 0.5;      // 主轴方向
    float aPx = clamp(sqrt(l1), 1.5, 80.0);
    float bPx = clamp(sqrt(l2), 1.0, 80.0);
    // 5) 四角按椭圆旋转/缩放
    float ca = cos(ang), sa = sin(ang);
    float2 c[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 e = c[vid];
    float2 local = float2(e.x * aPx * ca - e.y * bPx * sa, e.x * aPx * sa + e.y * bPx * ca);
    // NDC 偏移必须在透视除法之后加(先除 w 再偏移, 否则偏移被 w 缩成亚像素——踩坑实录)
    float2 ndc = clip.xy / clip.w;
    o.pos = float4(ndc + local / float2(u.misc.w * 1.5, u.misc.w), clip.z / clip.w, 1.0);
    o.corner = e;
    o.colorAlpha = s.colorAlpha;
    o.radiusPx = aPx;
    return o;
}
fragment float4 splatFrag(VOut in [[stage_in]]) {
    float d2 = dot(in.corner, in.corner);
    if (d2 > 1) discard_fragment();
    float a = in.colorAlpha.a * exp(-4.0 * d2);        // 高斯核 α 衰减
    return float4(in.colorAlpha.rgb * a, a);           // premultiplied
}
