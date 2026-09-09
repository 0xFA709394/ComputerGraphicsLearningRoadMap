#include <metal_stdlib>
using namespace metal;

// 光源与相机（lightVP 为正交投影, docs/11 §1.1 两遍阴影）
struct Uniforms {
    float4x4 viewProj;    // 主相机
    float4x4 lightVP;     // 光源 view * ortho (z∈[0,1])
    float4   lightDir;    // 光传播方向
    float4   camPos;
    float4   misc;        // x=time
};
struct ObjUniforms { float4x4 model; };

struct VIn {
    float3 pos    [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv     [[attribute(2)]];
};

// ================= Pass 1: 光源深度（depth-only PSO, 无片元着色器）=================
vertex float4 shadowVert(VIn in [[stage_in]],
                         constant Uniforms &u [[buffer(1)]],
                         constant ObjUniforms &o [[buffer(2)]]) {
    return u.lightVP * o.model * float4(in.pos, 1.0);
}

// ================= Pass 2: 场景 + PCF 阴影 =================
struct VOut {
    float4 pos [[position]];
    float3 worldPos;
    float3 worldNormal;
    float2 uv;
};

vertex VOut vertMain(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]],
                     constant ObjUniforms &o [[buffer(2)]]) {
    VOut v;
    float4 wp = o.model * float4(in.pos, 1.0);
    v.worldPos    = wp.xyz;
    v.worldNormal = (o.model * float4(in.normal, 0.0)).xyz;
    v.pos         = u.viewProj * wp;
    v.uv          = in.uv;
    return v;
}

// 3×3 PCF（docs/11 §1.1; 最近邻采样 + 手动比较, 二值结果平均）
float shadowPCF(texture2d<float> shadowMap, sampler smp, float3 suv, float NdotL) {
    if (suv.x < 0 || suv.x > 1 || suv.y < 0 || suv.y > 1) return 1.0;   // 视锥外无阴影
    // 斜率缩放偏置: 掠射角加深, 抑制 acne (docs/11 §1.1)
    float bias = 0.0015 + (1.0 - NdotL) * 0.002;
    float2 texel = 1.0 / float2(shadowMap.get_width(), shadowMap.get_height());
    float shadow = 0.0;
    for (int y = -1; y <= 1; ++y)
    for (int x = -1; x <= 1; ++x) {
        float d = shadowMap.sample(smp, suv.xy + float2(x, y) * texel).r;
        shadow += (suv.z - bias > d) ? 0.0 : 1.0;
    }
    return shadow / 9.0;
}

float3 acesFitted(float3 x) {
    x *= 0.6;
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 sceneFrag(VOut in [[stage_in]],
                          constant Uniforms &u [[buffer(1)]],
                          texture2d<float>   albedoTex  [[texture(0)]],
                          texture2d<float>   shadowMap  [[texture(1)]])
{
    constexpr sampler texSmp(mag_filter::linear, min_filter::linear,
                             mip_filter::linear, address::repeat);
    constexpr sampler shSmp(mag_filter::nearest, min_filter::nearest);  // 深度采样禁插值

    float3 base = albedoTex.sample(texSmp, in.uv).rgb;
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(-u.lightDir.xyz);
    float3 V = normalize(u.camPos.xyz - in.worldPos);
    float3 H = normalize(L + V);
    float NdotL = saturate(dot(N, L));

    // 世界 → 光源裁剪 → NDC → [0,1] uv/depth（正交投影 w=1）
    float4 lc = u.lightVP * float4(in.worldPos, 1.0);
    float3 suv = float3(lc.xy * 0.5 + 0.5, lc.z);
    float shadow = shadowPCF(shadowMap, shSmp, suv, NdotL);

    float spec = powr(saturate(dot(N, H)), 48.0) * 0.6;
    float3 color = base * (0.15 + 0.85 * NdotL * shadow)
                 + float3(spec * shadow)
                 + base * 0.08;                       // 极简环境项
    color = acesFitted(color * 1.1);
    color = powr(color, 1.0 / 2.2);
    return float4(color, 1.0);
}
