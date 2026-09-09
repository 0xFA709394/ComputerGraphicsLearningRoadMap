#include <metal_stdlib>
using namespace metal;

// ================= 场景 pass（输出线性 HDR, 无 tone map）=================
struct Uniforms {
    float4x4 viewProj;
    float4x4 model;
    float4   lightDir;
    float4   camPos;
    float4   misc;        // x = time
};

struct VIn {
    float3 pos    [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv     [[attribute(2)]];
};
struct VOut {
    float4 pos [[position]];
    float3 worldPos;
    float3 worldNormal;
    float2 uv;
};

vertex VOut vertMain(VIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    VOut o;
    float4 wp = u.model * float4(in.pos, 1.0);
    o.worldPos    = wp.xyz;
    o.worldNormal = (u.model * float4(in.normal, 0.0)).xyz;
    o.pos         = u.viewProj * wp;
    o.uv          = in.uv;
    return o;
}

fragment float4 sceneFrag(VOut in [[stage_in]],
                          constant Uniforms &u [[buffer(1)]],
                          texture2d<float> albedoTex [[texture(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear,
                          mip_filter::linear, address::repeat);
    float3 base = albedoTex.sample(smp, in.uv).rgb;

    float3 N = normalize(in.worldNormal);
    float3 L = normalize(-u.lightDir.xyz);
    float3 V = normalize(u.camPos.xyz - in.worldPos);
    float3 H = normalize(L + V);
    float ndl  = saturate(dot(N, L));
    float spec = powr(saturate(dot(N, H)), 48.0) * 2.5;   // >1 → bloom 目标

    // 移动发光带（保证画面存在 >1 的 HDR 区域）
    float f = fract(in.uv.x * 3.0 - u.misc.x * 0.25);
    float band = smoothstep(0.08, 0.0, abs(f - 0.5));

    float3 color = base * (0.12 + 0.88 * ndl)
                 + float3(spec)
                 + float3(0.30, 0.65, 1.0) * band * 5.0;
    return float4(color, 1.0);                            // 线性 HDR, 不做任何编码
}

// ================= 全屏三角形（3 顶点覆盖屏幕, docs/02 §10 复用技巧）=================
struct FSOut {
    float4 pos [[position]];
    float2 uv;
};

vertex FSOut fullscreenVert(uint vid [[vertex_id]]) {
    float2 uv  = float2((vid << 1) & 2, vid & 2);          // (0,0) (2,0) (0,2)
    FSOut o;
    o.pos = float4(uv * 2.0 - 1.0, 0.0, 1.0);             // 超出屏幕的三角形
    o.uv  = uv;
    return o;
}

// ---- 亮部提取（soft-knee 简化版: 阈值 1.0）----
fragment float4 brightFrag(FSOut in [[stage_in]],
                           texture2d<float> scene [[texture(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear);
    float3 c = scene.sample(smp, in.uv).rgb;
    float l = max(c.r, max(c.g, c.b));
    float w = max(0.0, l - 1.0) / (l + 1e-4);             // 越亮权重越接近 1
    return float4(c * w, 1.0);
}

// ---- 可分离高斯（9-tap, 方向由 uniform 注入 → H/V 两次调用）----
fragment float4 blurFrag(FSOut in [[stage_in]],
                         texture2d<float> src [[texture(0)]],
                         constant float2 &dir [[buffer(0)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear);
    const float w[5] = {0.227027, 0.194595, 0.121622, 0.054054, 0.016216};
    float3 c = src.sample(smp, in.uv).rgb * w[0];
    for (int i = 1; i < 5; ++i) {
        c += src.sample(smp, in.uv + dir * float(i)).rgb * w[i];
        c += src.sample(smp, in.uv - dir * float(i)).rgb * w[i];
    }
    return float4(c, 1.0);
}

// ---- 合成: scene + bloom → 曝光 → ACES → gamma（docs/09 §4/§5）----
float3 acesFitted(float3 x) {
    x *= 0.6;
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

fragment float4 compositeFrag(FSOut in [[stage_in]],
                              texture2d<float> scene [[texture(0)]],
                              texture2d<float> bloom [[texture(1)]])
{
    constexpr sampler smp(mag_filter::linear, min_filter::linear);
    float3 c = scene.sample(smp, in.uv).rgb
             + bloom.sample(smp, in.uv).rgb * 0.9;
    c = acesFitted(c * 1.15);
    c = powr(c, 1.0 / 2.2);
    return float4(c, 1.0);
}
