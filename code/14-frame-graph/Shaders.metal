// 14-frame-graph: 迷你帧图(声明式 pass 组织 + RT 池化)的载荷: HDR bloom 后处理链
// 对应 docs/18 蓝图 M2 与 docs/02 §pass 组织、docs/09 §后处理。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 lightVP;       // 阴影重投影(ortho, z∈[0,1])
    float4 camPos;
    float4 lightDir;        // xyz 光传播方向
    float4 misc;            // x: time, y: 纹理尺寸
    float4 texel;
};
struct ObjUniforms { float4x4 model; float4 color; };  // color.a>0.5 = 地面条纹

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

// ---- Pass 1: 场景(线性 HDR) ----
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
                          constant ObjUniforms &obj [[buffer(2)]],
                          depth2d<float> shadowMap [[texture(0)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(u.lightDir.xyz);                // 指向光源(Swift 侧已传指向量, 勿再取负)
    float3 base = obj.color.rgb;
    if (obj.color.a > 0.5 && in.world.y < 0.01) {
        base *= (fract(in.world.x * 1.5) < 0.5) ? 0.35 : 1.0;   // 条纹放粗, 降摩尔纹
    }
    float ndl = saturate(dot(N, L));
    // PCF 3x3 + 斜率偏置(07/11 同款; y 不翻转)
    float4 lc = u.lightVP * float4(in.world, 1);
    float2 suv = float2((lc.x + 1) * 0.5, (lc.y + 1) * 0.5);
    float bias = 0.0022 + (1 - ndl) * 0.004;
    float lit = 0;
    constexpr sampler sn(mag_filter::nearest, address::clamp_to_edge);
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            lit += (lc.z - bias > shadowMap.sample(sn, suv + float2(x, y) / 1024.0)) ? 0 : 1;
    lit /= 9;
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 64) * 1.5 * lit;   // bloom 源仍 >1
    return float4(base * (0.15 + 0.95 * ndl * lit) + spec, 1);
}

// ---- Pass 0: 光源深度(depth-only; 11 的教训: stage_in 需要 vertexDescriptor) ----
vertex float4 shadowVert(VIn in [[stage_in]],
                         constant Uniforms &u [[buffer(1)]],
                         constant ObjUniforms &obj [[buffer(2)]]) {
    return u.lightVP * (obj.model * float4(in.pos, 1));
}

// ---- 全屏三角形基座 ----
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

// ---- Pass 2: 亮部提取(luminance > 阈值, 软过渡) ----
fragment float4 brightFS(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                         constant float4 &params [[buffer(1)]]) {   // x: 阈值
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    float k = max(0.0, l - params.x) / max(l, 1e-4);       // 软阈值(docs/09 §bloom)
    return float4(c * k, 1);
}

// ---- Pass 3/4: 分离高斯 9-tap(方向由 params.xy 给出) ----
fragment float4 blurFS(QuadOut in [[stage_in]], texture2d<float> src [[texture(0)]],
                       constant float4 &params [[buffer(1)]]) {     // xy: 方向*texel
    constexpr sampler s(mag_filter::linear, address::clamp_to_edge);
    float w[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };
    float3 c = src.sample(s, in.uv).rgb * w[0];
    for (int i = 1; i < 5; i++) {
        c += src.sample(s, in.uv + params.xy * float(i)).rgb * w[i];
        c += src.sample(s, in.uv - params.xy * float(i)).rgb * w[i];
    }
    return float4(c, 1);
}

// ---- Pass 5: 合成 + ACES + gamma ----
fragment float4 compositeFS(QuadOut in [[stage_in]],
                            texture2d<float> scene [[texture(0)]],
                            texture2d<float> bloom [[texture(1)]],
                            constant float4 &params [[buffer(1)]]) { // x: bloom 强度
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    float3 x = scene.sample(s, in.uv).rgb + bloom.sample(s, in.uv).rgb * params.x;
    x = clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0, 1);
    return float4(pow(x, 1/2.2), 1);
}
