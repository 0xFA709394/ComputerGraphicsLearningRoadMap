#include <metal_stdlib>
using namespace metal;

// 与 Swift 侧 Uniforms 逐字段对齐（16 字节对齐）
struct Uniforms {
    float4x4 viewProj;   // 相机 VP
    float4x4 model;      // 仅旋转 → 法线可直接用其 3x3（含缩放时须用逆转置, 见 docs/01 §2.4）
    float4   lightDir;   // 光的传播方向（指向地面）
    float4   camPos;     // 世界空间相机位置
};

struct VIn {
    float3 pos    [[attribute(0)]];   // MTKMesh 顶点描述符: pos/normal/uv
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

// UV 棋盘（程序化"纹理"——可视化 UV 与透视校正插值, docs/04 §5.1）
float3 checkerboard(float2 uv) {
    float2 c = floor(uv * 8.0);
    float k = fmod(c.x + c.y, 2.0);
    return mix(float3(0.92, 0.25, 0.21), float3(0.96, 0.96, 0.96), k);
}

fragment float4 fragMain(VOut in [[stage_in]],
                         constant Uniforms &u [[buffer(1)]])
{
    float3 N = normalize(in.worldNormal);
    float3 L = normalize(-u.lightDir.xyz);          // 指向光源
    float3 V = normalize(u.camPos.xyz - in.worldPos);
    float3 H = normalize(L + V);                    // Blinn-Phong (docs/03 §3)

    float  ndl   = saturate(dot(N, L));
    float  spec  = powr(saturate(dot(N, H)), 48.0) * 0.35;
    float3 base  = checkerboard(in.uv);

    float3 color = base * (0.12 + 0.88 * ndl)       // ambient + Lambert 漫反射
                 + float3(spec);                    // 高光
    return float4(color, 1.0);
}
