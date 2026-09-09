#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 model;      // 仅旋转
    float4   lightDir;
    float4   camPos;
};

struct VIn {
    float3 pos    [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv     [[attribute(2)]];
};

struct VOut {
    float4 pos        [[position]];
    float3 worldPos;
    float3 worldNormal;
    float2 uv;
};

vertex VOut vertMain(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]])
{
    VOut o;
    float4 wp = u.model * float4(in.pos, 1.0);
    o.worldPos    = wp.xyz;
    o.worldNormal = (u.model * float4(in.normal, 0.0)).xyz;
    o.pos         = u.viewProj * wp;
    o.uv          = in.uv;
    return o;
}

// 采样器在 shader 内声明（与 API 侧 sampler 等价, 三线性 + repeat）
constexpr sampler smp(mag_filter::linear, min_filter::linear,
                      mip_filter::linear, address::repeat);

fragment float4 fragMain(VOut in [[stage_in]],
                         constant Uniforms &u [[buffer(1)]],
                         texture2d<float> albedoTex [[texture(0)]])
{
    // 半球对照实验（docs/04 §2）:
    //   uv.x < 0.5: 强制 mip0 采样 → 远处高频走样闪烁
    //   uv.x ≥ 0.5: 正常采样 → GPU 按 ρ=log2 选择 mip, 平稳
    float3 base;
    if (in.uv.x < 0.5) {
        base = albedoTex.sample(smp, in.uv, level(0.0)).rgb;
    } else {
        base = albedoTex.sample(smp, in.uv).rgb;
    }

    float3 N = normalize(in.worldNormal);
    float3 L = normalize(-u.lightDir.xyz);
    float3 V = normalize(u.camPos.xyz - in.worldPos);
    float3 H = normalize(L + V);
    float ndl  = saturate(dot(N, L));
    float spec = powr(saturate(dot(N, H)), 48.0) * 0.25;

    float3 color = base * (0.12 + 0.88 * ndl) + float3(spec);
    return float4(color, 1.0);
}
