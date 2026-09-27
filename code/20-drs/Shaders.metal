// 20-drs: 动态分辨率缩放(帧时间反馈回路 + 滞回控制器 + 分档渲染)
// 对应 docs/07 §8.3 动态画质 / docs/09 §MetalFX 与 docs/27 案例 C 骨架。
// 空格: 切换合成负载, 观察 stdout 档位变化与画面软硬(放大器是 bilinear 占位)。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float4 misc;        // x: time, y: loadIter(合成 ALU 负载)
};
struct ObjUniforms { float4x4 model; float4 color; };

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
    float ndl = saturate(dot(N, normalize(float3(0.4, 0.85, 0.35))));
    // 合成 ALU 负载: 帧时间控制器的"假 GPU 压力"(空格开关)
    float x = 0.5;
    for (int i = 0; i < int(u.misc.y); i++) x = sqrt(x + 0.001);
    float3 base = obj.color.rgb;
    if (obj.color.a > 0.5 && in.world.y < 0.01) {
        base *= (fract(in.world.x * 1.2) < 0.5) ? 0.35 : 1.0;   // 细条纹: 低分辨率下看软化
    }
    return float4(base * (0.15 + 0.9 * ndl) + x * 0.0, 1);       // x 只耗 ALU 不改色
}

// 放大 pass: bilinear 占位(MetalFX 时间超分是 drop-in 替换, 见 README)
struct QuadOut { float4 pos [[position]]; float2 uv; };
vertex QuadOut upVert(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    QuadOut o;
    o.pos = float4(p[vid], 0.5, 1);
    o.uv = p[vid] * 0.5 + 0.5;
    return o;
}
fragment float4 upFrag(QuadOut in [[stage_in]], texture2d<float> lowRes [[texture(0)]],
                       constant float4 &scaleInfo [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float3 c = lowRes.sample(s, in.uv).rgb;
    // 分辨率标签: 右下角色块编码当前 scale(0.5..1.0 → 色相)
    float2 d = abs(in.uv - float2(0.93, 0.07));
    if (d.x < 0.035 && d.y < 0.05) {
        float t = (scaleInfo.x - 0.5) / 0.5;
        return float4(mix(float3(1,0.25,0.2), float3(0.2,0.9,0.35), t), 1);
    }
    return float4(c, 1);
}
