// 21-sdf-raymarch: 全片元着色器的 SDF 球体追踪(ShaderToy 复刻的 Metal 版)
// 对应 docs/05 §SDF/ray-marching 与 README 实战清单第 1 项。零网格: 几何全部由距离函数定义。

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4 camPos;
    float4 misc;        // x: time, y: aspect
};

// ---- SDF 原语(docs/05 §隐式表面) ----
static float sdSphere(float3 p, float r) { return length(p) - r; }
static float sdBox(float3 p, float3 b, float r) {          // 圆角盒
    float3 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}
static float sdTorus(float3 p, float2 t) {
    float2 q = float2(length(p.xz) - t.x, p.y);
    return length(q) - t.y;
}
static float sdPlane(float3 p, float h) { return p.y - h; }
/// 光滑最小(多项式变体): k 控制融合半径——SDF 布尔的"抗锯齿"
static float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// ---- 场景: 地面 + 旋转圆角盒 + 光滑融合的球/环 ----
static float map(float3 p, float t) {
    float d = sdPlane(p, -0.9);
    float3 q = p - float3(0.0, 0.35, 0.0);
    float c = cos(t * 0.5), s = sin(t * 0.5);
    q.xz = float2(q.x * c - q.z * s, q.x * s + q.z * c);       // 绕 Y 旋转
    d = min(d, sdBox(q, float3(0.55, 0.55, 0.55), 0.12));
    float sph = sdSphere(p - float3(1.5, 0.15, 0.6), 0.55);
    float tor = sdTorus(p - float3(-1.6, 0.0, 0.7) , float2(0.55, 0.2));
    d = smin(d, smin(sph, tor, 0.8), 0.7);                     // 光滑融合成有机体
    return d;
}

/// 球体追踪(docs/05 §ray-marching): 步长 = 当前距离 → 指数收敛且不穿面
static float march(float3 ro, float3 rd, float t, float maxD) {
    float d = 0.0;
    for (int i = 0; i < 96; i++) {
        float3 p = ro + rd * d;
        float s = map(p, t);
        if (s < 1e-4) return d;
        d += s;
        if (d > maxD) break;
    }
    return -1.0;
}
/// SDF 软阴影: 朝光源 march, 半影 ∝ min(s / k·步进) —— docs/11 §其他提到的距离场阴影
static float softShadow(float3 ro, float3 rd, float t) {
    float res = 1.0, d = 0.02;
    for (int i = 0; i < 48; i++) {
        float s = map(ro + rd * d, t);
        res = min(res, s / (0.15 * d));                        // k=0.15: 半影硬度
        d += clamp(s, 0.02, 0.4);
        if (res < 1e-3 || d > 6.0) break;
    }
    return clamp(res, 0.0, 1.0);
}
/// 法线: 距离场梯度(中心差分) —— 不存顶点法线的代价
static float3 calcNormal(float3 p, float t) {
    float2 e = float2(1e-3, 0.0);
    return normalize(float3(
        map(p + e.xyy, t) - map(p - e.xyy, t),
        map(p + e.yxy, t) - map(p - e.yxy, t),
        map(p + e.yyx, t) - map(p - e.yyx, t)));
}
/// 简易 AO: 命点周围距离场采样 —— SDF 免费 AO
static float calcAO(float3 p, float3 n, float t) {
    float occ = 0.0, sca = 1.0;
    for (int i = 0; i < 5; i++) {
        float h = 0.02 + 0.12 * float(i) / 4.0;
        occ += (h - map(p + n * h, t)) * sca;
        sca *= 0.85;
    }
    return clamp(1.0 - 2.5 * occ, 0.0, 1.0);
}

struct QuadOut { float4 pos [[position]]; float2 uv; };
vertex QuadOut vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    QuadOut o;
    o.pos = float4(p[vid], 0.5, 1);
    o.uv = p[vid];
    return o;
}

fragment float4 fs(QuadOut in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
    float t = u.misc.x;
    // 相机(轨道)
    float ang = t * 0.2;
    float3 ro = float3(cos(ang) * 4.2, 1.6, sin(ang) * 4.2);
    float3 fwd = normalize(-ro), right = normalize(cross(fwd, float3(0,1,0))), up = cross(right, fwd);
    float2 ndc = in.uv;
    float3 rd = normalize(fwd * 1.6 + right * ndc.x * u.misc.y + up * ndc.y);

    float d = march(ro, rd, t, 20.0);
    float3 sky = mix(float3(0.55, 0.72, 0.95), float3(0.12, 0.2, 0.42), ndc.y * 0.5 + 0.5);
    if (d < 0.0) return float4(sky, 1);

    float3 p = ro + rd * d;
    float3 n = calcNormal(p, t);
    float3 L = normalize(float3(0.5, 0.8, -0.35));

    // 地面棋盘(命中且 y≈-0.9 → 按世界坐标上色)
    float3 base = float3(0.82, 0.4, 0.25);
    if (p.y < -0.88) {
        float2 c = floor(p.xz * 1.2);
        base = (c.x + c.y) < 0.0 ? float3(0.24, 0.26, 0.32) : float3(0.72, 0.73, 0.76);
    }
    float ndl = max(dot(n, L), 0.0);
    float shadow = softShadow(p + n * 1e-3, L, t);
    float ao = calcAO(p, n, t);
    float3 col = base * (0.18 * ao + 0.9 * ndl * shadow * ao);
    // 天空反弹的假 GI + 距离雾
    col += float3(0.25, 0.35, 0.5) * max(dot(n, -rd), 0.0) * 0.25 * ao;
    col = mix(col, sky, smoothstep(8.0, 18.0, d));
    col = pow(col, 1 / 2.2);                                   // gamma
    return float4(col, 1);
}
