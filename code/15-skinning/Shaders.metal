// 15-skinning: GPU 骨骼蒙皮(矩阵调色板 + 两骨骼线性混合 LBS)
// 对应 docs/08 §骨骼蒙皮推导。空格键: 开/关蒙皮(僵硬直臂 vs 挥动触手)。

#include <metal_stdlib>
using namespace metal;

constant int BONES = 6;

struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float4 misc;            // x: time, y: skinOn
};
/// 矩阵调色板: 平铺字段(Swift Array 是引用, setBytes 拷不到内容 —— 11 号踩坑)
struct Skin {
    float4x4 b0, b1, b2, b3, b4, b5;
};

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];     // y = 沿臂参数 [0,1] → 骨骼权重由此推导
};

struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
    float v;                // 供片元做颜色渐变
};

vertex VOut skinVert(VIn in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]],
                     constant Skin &sk [[buffer(2)]]) {
    float4x4 pal[BONES] = { sk.b0, sk.b1, sk.b2, sk.b3, sk.b4, sk.b5 };
    float3 p = in.pos, n = in.normal;
    if (u.misc.y > 0.5) {
        // 两骨骼线性混合(docs/08 §LBS): 权重由沿臂参数连续划分
        float f = in.uv.y * (BONES - 1);
        int i0 = min(int(f), BONES - 2);
        float w = f - float(i0);
        // 真实资产把 i0/w 存成顶点属性; 本例免资产, 用参数化网格现场推导
        float3 p0 = (pal[i0]     * float4(p, 1)).xyz;
        float3 p1 = (pal[i0 + 1] * float4(p, 1)).xyz;
        p = mix(p0, p1, w);
        n = normalize(mix((pal[i0]     * float4(n, 0)).xyz,
                          (pal[i0 + 1] * float4(n, 0)).xyz, w));
    }
    VOut o;
    float4 wp = float4(p, 1);
    o.world = wp.xyz;
    o.normal = n;
    o.v = in.uv.y;
    o.pos = u.viewProj * wp;
    return o;
}

fragment float4 skinFrag(VOut in [[stage_in]],
                         constant Uniforms &u [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(float3(0.45, 0.8, 0.35));
    float3 base = mix(float3(0.92, 0.35, 0.15), float3(0.98, 0.85, 0.30), in.v);  // 基部→尖端渐变
    float ndl = saturate(dot(N, L));
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 48) * 0.35;
    return float4(base * (0.18 + 0.85 * ndl) + spec, 1);
}

// 地面
vertex VOut groundVert(VIn in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    VOut o;
    o.world = in.pos;
    o.normal = in.normal;
    o.v = 0;
    o.pos = u.viewProj * float4(in.pos, 1);
    return o;
}
fragment float4 groundFrag(VOut in [[stage_in]]) {
    float s = fract(in.world.x * 0.8) < 0.5 ? 0.30 : 0.55;      // 淡条纹
    float s2 = fract(in.world.z * 0.8) < 0.5 ? 0.30 : 0.55;
    return float4(float3(0.5 * s + 0.5 * s2) * 0.55, 1);
}
