// 11-csm: 级联阴影贴图(4 级, 2D array 深度纹理)
// 对应 docs/11 §1.2: λ 切分 + texel snapping + 按视深选级 + 逐级 PCF

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4x4 lightVP[4];
    float4 splits;      // x/y/z = 级 0/1/2 的远平面(视深), w = 级联调试着色开关
    float4 lightDir;    // 光传播方向
    float4 camPos;
    float4 misc;        // x = time
};
struct ObjUniforms { float4x4 model; };
struct CascadeMat { float4x4 lightVP; };   // 每级阴影 pass 单独传

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

// ---- 阴影 pass 顶点(每级一遍, 无片元) ----
vertex float4 shadowVert(VIn in [[stage_in]],
                         constant CascadeMat &cm [[buffer(1)]],
                         constant ObjUniforms &obj [[buffer(2)]]) {
    return cm.lightVP * (obj.model * float4(in.pos, 1));
}

// ---- 场景 pass ----
struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
    float2 uv;
    float viewDepth;    // 透视 w = -z_view, 用于选级
};

vertex VOut sceneVert(VIn in [[stage_in]],
                      constant Uniforms &u [[buffer(1)]],
                      constant ObjUniforms &obj [[buffer(2)]]) {
    VOut o;
    float4 wp = obj.model * float4(in.pos, 1);
    o.world = wp.xyz;
    o.normal = (obj.model * float4(in.normal, 0)).xyz;   // 仅旋转/等比缩放, 免逆转置
    o.uv = in.uv;
    float4 cp = u.viewProj * wp;
    o.pos = cp;
    o.viewDepth = cp.w;
    return o;
}

// 3x3 PCF: 逐级采样(depth2d_array, 手动比较), 偏置随级数放大(纹素世界尺寸变大)
static float shadowPCF(depth2d_array<float> sm, float2 uv, float d,
                       uint cascade, float ndl) {
    constexpr sampler s(mag_filter::nearest, address::clamp_to_edge);
    float bias = (0.0008 + (1 - ndl) * 0.0025) * (1 + float(cascade) * 1.5);
    float lit = 0;
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++)
            lit += (d - bias > sm.sample(s, uv + float2(x, y) / 1024.0, cascade)) ? 0 : 1;
    return lit / 9;
}

fragment float4 sceneFrag(VOut in [[stage_in]],
                          constant Uniforms &u [[buffer(1)]],
                          texture2d<float> albedo [[texture(0)]],
                          depth2d_array<float> sm [[texture(1)]]) {
    float3 N = normalize(in.normal);
    float3 L = -u.lightDir.xyz;
    float ndl = saturate(dot(N, L));

    // 按视深选级(docs/11 §1.2): 近处用 0 级(高分屏), 远处用 3 级
    float vd = in.viewDepth;
    uint c = vd < u.splits.x ? 0 : vd < u.splits.y ? 1 : vd < u.splits.z ? 2 : 3;

    // 重投影到所选级的光源 NDC; ortho w=1。
    // y 不翻转(踩坑: 光栅化写入与采样走同一套 ndc→纹理行映射, 翻转会让近级错采镜像位置→大片错阴影)
    float4 lc = u.lightVP[c] * float4(in.world, 1);
    float2 suv = float2((lc.x + 1) * 0.5, (lc.y + 1) * 0.5);
    float lit = shadowPCF(sm, suv, lc.z, c, ndl);

    float3 base = albedo.sample(sampler(mag_filter::linear, mip_filter::linear), in.uv).rgb;
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 48) * 0.25;
    float3 col = base * (0.18 + 0.9 * ndl * lit) + spec * ndl * lit;

    // 级联调试视图(空格切换): 每级一个色调, 看切分边界与物体归属
    if (u.splits.w > 0.5) {
        float3 tint[4] = { float3(1, 0.35, 0.35), float3(0.4, 1, 0.45),
                           float3(0.45, 0.6, 1), float3(1, 0.9, 0.3) };
        col = mix(col, tint[c] * (0.4 + 0.6 * lit), 0.55);
    }
    return float4(col, 1);
}
