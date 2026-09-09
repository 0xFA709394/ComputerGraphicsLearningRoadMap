#include <metal_stdlib>
using namespace metal;

// 与 Swift 侧内存布局一一对应（vertex pulling 风格, 免去 vertex descriptor 管线配置）
struct Vertex {
    float3 pos;
    float4 color;
};
struct Uniforms {
    float4x4 mvp;
};

struct VOut {
    float4 pos [[position]];
    float4 color;
};

vertex VOut vertMain(uint vid [[vertex_id]],
                     device const Vertex *verts [[buffer(0)]],
                     constant Uniforms &u [[buffer(1)]])
{
    VOut o;
    o.pos   = u.mvp * float4(verts[vid].pos, 1.0);
    o.color = verts[vid].color;
    return o;
}

fragment float4 fragMain(VOut in [[stage_in]]) {
    return in.color;
}
