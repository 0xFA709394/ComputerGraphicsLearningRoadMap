#include <metal_stdlib>
using namespace metal;

#define PI 3.14159265

// Swift 侧逐字段对齐（16B 对齐; lightPos/lightColor 各 3 个 float4 连续排布）
struct Uniforms {
    float4x4 viewProj;
    float4   camPos;
    float4   lightPos[3];
    float4   lightColor[3];
};

// 实例数据: 变换矩阵 + 材质参数（x=metallic, y=roughness）
struct InstanceData {
    float4x4 model;
    float4   matParams;
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
    float4 matParams;
};

vertex VOut vertMain(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]],
                     device const InstanceData *inst [[buffer(2)]],
                     uint iid [[instance_id]])
{
    VOut o;
    float4 wp = inst[iid].model * float4(in.pos, 1.0);
    o.worldPos    = wp.xyz;
    o.worldNormal = (inst[iid].model * float4(in.normal, 0.0)).xyz;  // 均匀缩放, 归一化即可
    o.pos         = u.viewProj * wp;
    o.matParams   = inst[iid].matParams;
    return o;
}

// ---- Cook-Torrance 各项（docs/03 §4, 扩展篇 A 同源）----
float D_GGX(float NdotH, float a2) {
    float d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}
float G_Smith(float NdotV, float NdotL, float k) {
    float gv = NdotV / (NdotV * (1.0 - k) + k);
    float gl = NdotL / (NdotL * (1.0 - k) + k);
    return gv * gl;
}

float3 acesFitted(float3 x) {
    x *= 0.6;
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 fragMain(VOut in [[stage_in]], constant Uniforms &u [[buffer(1)]])
{
    float metallic  = in.matParams.x;
    float roughness = in.matParams.y;
    float3 albedo   = float3(0.95, 0.72, 0.30);   // 金色 baseColor

    float3 N = normalize(in.worldNormal);
    float3 V = normalize(u.camPos.xyz - in.worldPos);
    float NdotV = max(dot(N, V), 1e-4);

    float3 F0 = mix(float3(0.04), albedo, metallic);   // metallic 工作流 (docs/03 §4.4)

    float a  = roughness * roughness, a2 = a * a;
    float k  = (roughness + 1.0) * (roughness + 1.0) / 8.0;

    float3 color = float3(0.0);
    for (int i = 0; i < 3; ++i) {
        float3 toL = u.lightPos[i].xyz - in.worldPos;
        float dist2 = dot(toL, toL);
        float3 L = toL * rsqrt(max(dist2, 1e-4));
        float NdotL = dot(N, L);
        if (NdotL <= 0.0) continue;

        float3 H = normalize(L + V);
        float NdotH = saturate(dot(N, H));
        float VdotH = saturate(dot(V, H));

        float3 F = F0 + (1.0 - F0) * powr(1.0 - VdotH, 5.0);
        float  D = D_GGX(NdotH, a2);
        float  G = G_Smith(NdotV, NdotL, k);

        float3 spec  = D * G * F / (4.0 * NdotV * NdotL + 1e-4);
        float3 diff  = (1.0 - metallic) * albedo / PI;
        float3 radiance = u.lightColor[i].rgb / (dist2 + 1.0);   // 1/d² + windowing

        color += (diff + spec) * radiance * NdotL;
    }

    // 廉价半球环境项（IBL 的 stand-in: 天空/地面渐变, docs/03 §5 的下一步是 split-sum）
    float3 irr = mix(float3(0.10, 0.08, 0.07), float3(0.24, 0.27, 0.32), N.y * 0.5 + 0.5);
    color += (1.0 - metallic) * albedo * irr + F0 * irr * 0.5;

    // 曝光 → ACES → gamma（docs/09 §4.2; 本例 RT 非 sRGB 格式, 由 shader 手动编码）
    color = acesFitted(color * 1.2);
    color = powr(color, 1.0 / 2.2);
    return float4(color, 1.0);
}
