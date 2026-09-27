// 13-taa: 时序抗锯齿(Halton 抖动 + 历史累积 + 邻域包围盒 clamp)
// 对应 docs/11 §TAA 与 18 章蓝图 M3。空格键: 开/关 TAA 对比抖动闪烁。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;      // 已含本帧 subpixel 抖动
    float4 camPos;
    float4 misc;            // x: time, y: taaOn, z: 当前帧混合权重(首帧=1)
    float4 texel;           // xy: 1/分辨率
};
struct ObjUniforms { float4x4 model; float4 color; };

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

// ---- 场景: 细条纹地面(走样重灾区) + 球 ----
struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
};
vertex VOut sceneVert(VIn in [[stage_in]],
                      constant Uniforms &u [[buffer(1)]],
                      constant ObjUniforms &obj [[buffer(2)]]) {
    VOut o;
    float4 wp = obj.model * float4(in.pos, 1);
    o.world = wp.xyz;
    o.normal = (obj.model * float4(in.normal, 0)).xyz;
    o.pos = u.viewProj * wp;
    return o;
}
fragment float4 sceneFrag(VOut in [[stage_in]],
                          constant Uniforms &u [[buffer(1)]],
                          constant ObjUniforms &obj [[buffer(2)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(float3(0.4, 0.8, 0.45));
    float3 base = obj.color.rgb;
    if (obj.color.a > 0.5 && in.world.y < 0.01) {          // 地面条纹
        float s = fract(in.world.x * 3.0);
        base *= (s < 0.5) ? 0.35 : 1.0;                    // 0.33m 细条纹 → 高频走样源
    }
    float ndl = saturate(dot(N, L));
    return float4(base * (0.25 + 0.85 * ndl), 1);          // 线性 HDR 中间结果
}

// ---- TAA resolve: 历史 clamp 到当前邻域 AABB 后 10% 混合 ----
struct QuadOut {
    float4 pos [[position]];
    float2 uv;
};
vertex QuadOut quadVert(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    QuadOut o;
    o.pos = float4(p[vid], 0.5, 1);
    o.uv = p[vid] * 0.5 + 0.5;
    return o;
}
fragment float4 taaResolveFS(QuadOut in [[stage_in]],
                             texture2d<float> current [[texture(0)]],
                             texture2d<float> history [[texture(1)]],
                             constant Uniforms &u [[buffer(1)]]) {
    constexpr sampler sn(mag_filter::nearest, address::clamp_to_edge);
    float4 c = current.sample(sn, in.uv);
    if (u.misc.y < 0.5) return c;                          // TAA 关: 直通(画面=抖动闪烁)
    float4 h = history.sample(sn, in.uv);
    float4 mn = c, mx = c;                                 // 3x3 邻域包围盒(AABB clamp 变体)
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            float4 n = current.sample(sn, in.uv + float2(x, y) * u.texel.xy);
            mn = min(mn, n); mx = max(mx, n);
        }
    h = clamp(h, mn, mx);
    return mix(h, c, u.misc.z);                             // docs/11: 90% 历史 + 10% 当前(首帧 1.0)
}

// ---- 输出: ACES + gamma ----
fragment float4 blitFS(QuadOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, address::clamp_to_edge);
    float3 x = tex.sample(s, in.uv).rgb;
    x = clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0, 1);
    return float4(pow(x, 1/2.2), 1);
}
