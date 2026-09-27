// 08-compute-particles: compute 更新 + 点精灵渲染
// 对应 docs/07 §6/扩展篇 C（GPU 粒子系统）的简化单 pass 版

#include <metal_stdlib>
using namespace metal;

struct Particle { float4 pos; float4 vel; };   // 32B/粒子, w 分量留空(练习: half4 压缩)

struct SimParams {
    float4 attractor;   // xyz: 吸引子位置, w: 引力强度 G
    float4 sim;         // x: dt, y: drag, z: 重生半径, w: 时间(随机种子)
    float4 counts;      // x: 粒子数(越界 guard 用)
};

struct RenderUniforms {
    float4x4 viewProj;
    float4 misc;        // x: time, y: pointBase, z: speedScale
};

static inline float hash11(uint n, uint seed) {
    n = (n ^ seed) * 0x27d4eb2dU;
    n = (n ^ (n >> 15U)) * 0x85ebca6bU;
    n ^= n >> 16U;
    return float(n) * (1.0f / 4294967295.0f);
}

// ---- Pass 1: 物理更新, 每粒子一线程 ----
kernel void particleUpdate(
    device Particle *p        [[buffer(0)]],
    constant SimParams &sp    [[buffer(1)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= uint(sp.counts.x)) return;   // 网格按线程组向上取整, 越界线程必须返回

    Particle P = p[gid];
    float3 d = sp.attractor.xyz - P.pos.xyz;
    float r2 = dot(d, d) + 0.7;                       // 软化: 避免 r→0 时 1/r² 奇点
    float3 a = sp.attractor.w * d * (rsqrt(r2) / r2); // G·d/|d|³

    P.vel.xyz += a * sp.sim.x;                        // 半隐式欧拉: 先速度后位置
    P.vel.xyz *= exp(-sp.sim.y * sp.sim.x);           // 帧率无关阻尼(docs/07 扩展 C)
    P.pos.xyz += P.vel.xyz * sp.sim.x;

    bool dead = dot(P.pos.xyz, P.pos.xyz) > sp.sim.z * sp.sim.z
             || P.pos.x != P.pos.x;                   // NaN 兜底(docs/01 浮点陷阱)
    if (dead) {
        uint s = uint(sp.sim.w * 61.7) + gid;         // 时间作种子, 每帧重生位置不同
        float z  = 1 - 2 * hash11(gid,     s);        // 球面均匀采样(z,角度)法
        float r  = sqrt(max(0.0f, 1 - z * z));
        float an = 6.2831853f * hash11(gid + 1, s);
        float3 dir = float3(r * cos(an), r * sin(an), z);
        P.pos.xyz = sp.attractor.xyz + dir * (2.5f + 2.0f * hash11(gid + 2, s));
        float3 axis = select(float3(0, 1, 0), float3(1, 0, 0), abs(dir.y) > 0.9f);
        float3 tangent = normalize(cross(axis, dir));
        P.vel.xyz = tangent * (1.8f + 1.6f * hash11(gid + 3, s)) + dir * 0.3f;
    }
    p[gid] = P;
}

// ---- Pass 2: 点精灵渲染 ----
struct VOut {
    float4 pos [[position]];
    float  size [[point_size]];
    float  speed;
};

vertex VOut particleVert(
    device const Particle *p    [[buffer(0)]],
    constant RenderUniforms &u  [[buffer(1)]],
    uint vid [[vertex_id]])
{
    VOut o;
    o.pos = u.viewProj * float4(p[vid].pos.xyz, 1.0f);
    o.size = clamp(u.misc.y / max(o.pos.w, 0.1f), 1.0f, 9.0f)  // 1/w 透视衰减
           * (0.6f + 0.8f * hash11(vid, 7U));                  // 每粒子大小微差
    o.speed = length(p[vid].vel.xyz) * u.misc.z;
    return o;
}

fragment float4 particleFrag(
    VOut in [[stage_in]],
    float2 pc [[point_coord]])
{
    float2 c = pc * 2 - 1;
    float d2 = dot(c, c);
    if (d2 > 1) discard_fragment();
    float fall = exp(-3.5f * d2);                     // 高斯光斑, 比硬圆盘柔和
    float x = clamp(in.speed, 0.0f, 1.0f);            // 速度→颜色: 调试视图(docs/17)
    float3 col = mix(float3(0.10, 0.25, 0.85), float3(0.25, 0.85, 1.0), smoothstep(0.0f, 0.45f, x));
    col = mix(col, float3(1.0, 0.95, 0.82), smoothstep(0.45f, 1.0f, x));
    return float4(col * fall * 0.25f, 1.0f);          // 输出即"加色", 配 PSO additive
}
