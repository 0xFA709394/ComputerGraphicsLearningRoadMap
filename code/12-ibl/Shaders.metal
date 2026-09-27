// 12-ibl: 基于图像的光照(split-sum 三件套)
// 对应 docs/03 §IBL split-sum 与 README 阶段 4 里程碑最后一块。
// 结构: 程序化 HDR 环境图(CPU 生成) → irradiance 卷积 + GGX 预滤波 + BRDF LUT(离屏一次性)
//      → 主 pass: 25 球 PBR 矩阵(metallic × roughness) + 环境背景

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 viewProj;
    float4 camPos;
    float4 sunDir;     // xyz 指向光源, w 强度
    float4 misc;       // x: time
};
struct ObjUniforms { float4x4 model; float4 mr; };   // mr: x=metallic, y=roughness

struct VIn {
    float3 pos [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

// 每个立方体面的基向量(dir = normalize(f + ndc.x*r + ndc.y*u)), CPU 与 shader 共用同一约定
struct FaceBasis { float4 r, u, f; };

// ============ 离屏卷积 pass(全屏三角形, 每面/每 mip 一次) ============
struct QuadOut {
    float4 pos [[position]];
    float2 uv;
};
vertex QuadOut quadVert(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
    QuadOut o;
    o.pos = float4(p[vid], 0.5, 1);
    o.uv = p[vid] * 0.5 + 0.5;         // ndc.y=+1(渲染目标第0行) ↔ uv.y=1, 与 CPU 上传约定一致
    return o;
}

// irradiance: 对 N 朝向的余弦半球做离散卷积(预计算, 不用重要性采样也可)
fragment float4 irradianceFS(QuadOut in [[stage_in]],
                             texturecube<float> env [[texture(0)]],
                             constant FaceBasis &fb [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    float2 ndc = in.uv * 2 - 1;
    float3 N = normalize(fb.f.xyz + ndc.x * fb.r.xyz + ndc.y * fb.u.xyz);
    float3 up = abs(N.y) < 0.999 ? float3(0,1,0) : float3(1,0,0);
    float3 rt = normalize(cross(up, N)), tp = cross(N, rt);
    float3 sum = 0;
    float count = 0;
    for (float phi = 0; phi < 6.2831853; phi += 0.045)
        for (float theta = 0; theta < 1.5707963; theta += 0.055) {
            float3 t = float3(sin(theta)*cos(phi), cos(theta), sin(theta)*sin(phi));
            float3 d = rt*t.x + N*t.y + tp*t.z;         // 半球内的世界方向
            sum += env.sample(s, d).rgb * (t.y * sin(theta));   // cosθ·sinθ 加权
            count += 1;
        }
    return float4(M_PI_F * sum / count, 1);        // 公式见 docs/03 §辐照度
}

static inline float3 ggxSample(float2 xi, float rough, float3 N) {
    float a = rough * rough;
    float phi = 2 * M_PI_F * xi.x;
    float ct = sqrt((1 - xi.y) / (1 + (a*a - 1) * xi.y));
    float st = sqrt(1 - ct * ct);
    float3 h = float3(st * cos(phi), ct, st * sin(phi));
    float3 up = abs(N.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
    float3 t = normalize(cross(up, N)), b = cross(N, t);
    return normalize(t * h.x + N * h.y + b * h.z);
}

// GGX 预滤波: 重要性采样 + 每样本能量权重(learnopengl split-sum 第一项), roughness 由 CPU 传入
fragment float4 prefilterFS(QuadOut in [[stage_in]],
                            texturecube<float> env [[texture(0)]],
                            constant FaceBasis &fb [[buffer(1)]],
                            constant float4 &params [[buffer(2)]]) {   // x: roughness
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    float2 ndc = in.uv * 2 - 1;
    float3 R = normalize(fb.f.xyz + ndc.x * fb.r.xyz + ndc.y * fb.u.xyz);
    float3 V = R;                                      // split-sum 近似: V=R
    float rough = params.x;
    float3 sum = 0; float wsum = 0;
    uint rngState = uint(in.uv.x * 997) ^ uint(in.uv.y * 131);
    for (int i = 0; i < 128; i++) {
        rngState = rngState * 747796405 + 2891336453;  // PCG 风格 hash
        float2 xi = float2(float(rngState >> 8 & 0xffff) / 65535.0,
                           float(rngState >> 24 & 0xffff) / 65535.0);
        float3 H = ggxSample(xi, rough, R);
        float3 L = normalize(2 * dot(V, H) * H - V);
        float NoL = dot(R, L);
        if (NoL > 0) {
            float NoH = max(dot(R, H), 1e-4);
            float HoV = max(dot(H, V), 1e-4);
            float D = rough*rough*rough*rough / (M_PI_F * pow(NoH*NoH*(rough*rough*rough*rough-1)+1, 2));
            float pdf = D * NoH / (4 * HoV) + 1e-4;
            float w = NoL / pdf;                       // 重要性采样权重(docs/06)
            sum += env.sample(s, L).rgb * w;
            wsum += w;
        }
    }
    return float4(sum / max(wsum, 1e-4), 1);
}

// BRDF LUT: 对 (NoV, roughness) 积分 Fresnel 尺度/偏移, R 通道=scale G 通道=bias
fragment float4 brdfLutFS(QuadOut in [[stage_in]]) {
    float NoV = in.uv.x;               // 注: 行0=+u, NoV 与 y 方向无关紧要(上下对称使用)
    float rough = 1 - in.uv.y;
    float3 V = float3(sqrt(1 - NoV*NoV), NoV, 0);
    float3 N = float3(0, 1, 0);
    float scale = 0, bias = 0;
    uint rngState = 12345;
    for (int i = 0; i < 256; i++) {
        rngState = rngState * 747796405 + 2891336453;
        float2 xi = float2(float(rngState >> 8 & 0xffff) / 65535.0,
                           float(rngState >> 24 & 0xffff) / 65535.0);
        float3 H = ggxSample(xi, rough, N);
        float3 L = normalize(2 * dot(V, H) * H - V);
        float NoL = dot(N, L), NoH = dot(N, H), HoV = dot(H, V);
        if (NoL > 0) {
            float F = 1 - pow(1 - HoV, 5);            // F0=1 时的 Fresnel 形状
            scale += NoL * F;
            bias += NoL * (1 - F);
            // 无遮挡项的简化积分(Smith 由 LUT 的经验平均吸收)
        }
    }
    return float4(scale / 256, bias / 256, 0, 1);
}

// ============ 背景: 相机所在大立方体内壁 ============
struct BgOut {
    float4 pos [[position]];
    float3 dir;
};
vertex BgOut bgVert(VIn in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                    constant ObjUniforms &obj [[buffer(2)]]) {
    BgOut o;
    float4 wp = obj.model * float4(in.pos * 60, 1);    // 放大到 ±60
    o.pos = u.viewProj * wp;
    o.dir = in.pos;
    return o;
}
fragment float4 bgFrag(BgOut in [[stage_in]], texturecube<float> env [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    return float4(env.sample(s, in.dir).rgb, 1);
}

// ============ 主场景: PBR + IBL ============
struct VOut {
    float4 pos [[position]];
    float3 world;
    float3 normal;
    float2 uv;
};
vertex VOut sceneVert(VIn in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                      constant ObjUniforms &obj [[buffer(2)]]) {
    VOut o;
    float4 wp = obj.model * float4(in.pos, 1);
    o.world = wp.xyz;
    o.normal = (obj.model * float4(in.normal, 0)).xyz;
    o.uv = in.uv;
    o.pos = u.viewProj * wp;
    return o;
}

static float3 aces(float3 x) {
    return clamp((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0, 1);
}

fragment float4 sceneFrag(VOut in [[stage_in]],
                          constant Uniforms &u [[buffer(1)]],
                          constant ObjUniforms &obj [[buffer(2)]],
                          texturecube<float> irradiance [[texture(0)]],
                          texturecube<float> prefiltered [[texture(1)]],
                          texture2d<float> brdfLut [[texture(2)]]) {
    constexpr sampler s(mag_filter::linear, mip_filter::linear);
    float metallic = obj.mr.x, rough = max(obj.mr.y, 0.05);
    float3 N = normalize(in.normal);
    float3 V = normalize(u.camPos.xyz - in.world);
    float3 R = reflect(-V, N);
    float3 albedo = float3(0.86, 0.10, 0.09);          // 统一红色系, 观察 IBL 梯度
    float3 F0 = mix(float3(0.04), albedo, metallic);

    // 直接光: 一盏方向光(与环境图太阳一致)
    float3 L = u.sunDir.xyz;
    float3 H = normalize(L + V);
    float NoL = saturate(dot(N, L));
    float D = rough*rough*rough*rough;
    float NoH2 = NoL > 0 ? dot(N,H)*dot(N,H) : 0.001;
    float dd = NoH2 * (D - 1) + 1;
    float dist = D / (M_PI_F * dd * dd);
    float k = (rough + 1) * (rough + 1) / 8;
    float NoV = max(dot(N, V), 1e-4);
    float gv = NoL / (NoL * (1 - k) + k) * NoV / (NoV * (1 - k) + k);
    float3 F = F0 + (1 - F0) * pow(1 - max(dot(H, V), 0.0), 5);
    float3 direct = (albedo * (1 - metallic) / M_PI_F + dist * gv * F) * NoL * u.sunDir.w;

    // IBL(split-sum): (kD·albedo·E_N) + prefiltered_R · (F0·scale + bias)
    float3 ks = F0 + (1 - F0) * pow(1 - NoV, 5);
    float3 kd = (1 - ks) * (1 - metallic);
    float3 E = irradiance.sample(s, N).rgb;
    float mip = rough * 4;                             // 预滤波 5 级 mip
    float3 pre = prefiltered.sample(s, R, level(mip)).rgb;
    float2 ab = brdfLut.sample(s, float2(NoV, 1 - rough)).rg;
    float3 indirect = kd * albedo * E + pre * (F0 * ab.x + ab.y);

    float3 col = (direct + indirect) * 1.0;
    return float4(pow(aces(col), 1 / 2.2), 1);         // ACES + gamma(docs/09)
}
