// 19-gltf-loader: glTF 2.0 最小资产管线(生成→写→读→渲染往返)
// 对应 docs/10 §资产管线 与 docs/27 案例 A 第 3~4 周(MVD)。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float4 lightDir;     // 指向光源
    float4 misc;         // x: time
};
struct ObjUniforms { float4x4 model; float4 baseColor; };

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
};
struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
};
vertex VOut vert(VIn in [[stage_in]],
                 constant Uniforms &u [[buffer(1)]],
                 constant ObjUniforms &obj [[buffer(2)]]) {
    VOut o;
    float4 wp = obj.model * float4(in.pos, 1);
    o.world = wp.xyz;
    o.normal = (obj.model * float4(in.normal, 0)).xyz;
    o.pos = u.viewProj * wp;
    return o;
}
fragment float4 frag(VOut in [[stage_in]],
                     constant Uniforms &u [[buffer(1)]],
                     constant ObjUniforms &obj [[buffer(2)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(u.lightDir.xyz);
    float ndl = saturate(dot(N, L));
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 H = normalize(L + V);
    float spec = pow(saturate(dot(N, H)), 42) * 0.3;
    return float4(obj.baseColor.rgb * (0.15 + 0.9 * ndl) + spec, 1);
}
