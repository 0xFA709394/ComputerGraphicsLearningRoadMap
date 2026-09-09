#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos   [[position]];
    float4 color;
};

vertex VOut vertMain(uint vid [[vertex_id]]) {
    const float4 verts[3] = {
        float4(-0.7, -0.6, 0.0, 1),
        float4( 0.7, -0.6, 0.0, 1),
        float4( 0.0,  0.7, 0.0, 1)
    };
    VOut o;
    o.pos = verts[vid];
    // 位置映射成顶点色: (-0.7..0.7) -> (0..1)
    o.color = float4(float2(verts[vid].xy + float2(0.5, 0.35)), 0.5, 1.0);
    return o;
}

fragment float4 fragMain(VOut in [[stage_in]]) {
    return in.color;
}
