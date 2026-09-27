// 10-path-tracer: 单文件路径追踪器(C++17, 零依赖, 多线程)
// 对应 docs/06(渲染方程/蒙特卡洛/NEE)——阶段 3 验收第二张图: Cornell Box。
// 构建: ./build.sh    运行: ./pathtracer [宽 高 spp]    输出: out.tga
//
// 采样策略: 漫反射表面用 NEE(显式向光源发阴影光线) + 余弦加权间接散射;
//           只有来自相机/镜面反射的路径直接看到发光体(避免与 NEE 双重计数)。
//           这正是 docs/06 §"NEE+MIS" 的无权重简化版——理解它, MIS 只是再加一个系数。

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <thread>
#include <vector>

// ---------- 向量 ----------
struct Vec3 {
    float x{}, y{}, z{};
    Vec3 operator+(const Vec3& o) const { return {x+o.x, y+o.y, z+o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x-o.x, y-o.y, z-o.z}; }
    Vec3 operator*(const Vec3& o) const { return {x*o.x, y*o.y, z*o.z}; }   // hadamard
    Vec3 operator*(float s) const { return {x*s, y*s, z*s}; }
    Vec3 operator/(float s) const { return *this * (1/s); }
    Vec3 operator-() const { return {-x, -y, -z}; }
    Vec3& operator+=(const Vec3& o) { x+=o.x; y+=o.y; z+=o.z; return *this; }
};
static float dot(const Vec3& a, const Vec3& b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x};
}
static float len(const Vec3& v) { return std::sqrt(dot(v,v)); }
static Vec3 norm(const Vec3& v) { return v / len(v); }

// PCG32: 每线程独立种子, 统计质量优于 rand()
struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed) {}
    float u() {   // [0,1)
        uint64_t o = s * 6364136223846793005ULL + 1442695040888963407ULL;
        s = o;
        return float((o >> 33) & 0x7FFFFFFFull) / float(0x80000000);
    }
};

struct Ray { Vec3 o, d; };

// ---------- 材质(docs/03 辐射度学 + docs/06 采样) ----------
struct Material {
    enum Kind { Lambert, Metal, Dielectric, Light } kind;
    Vec3 albedo;
    float fuzz{}, ior{};
    Vec3 emit;                       // Light 专用
};

// ---------- 可求交对象 ----------
struct Hit { float t{}; Vec3 p, n; bool front{}; const Material* m{}; };

struct Sphere {
    Vec3 c; float r; const Material* m;
    bool hit(const Ray& ray, float tmin, float tmax, Hit& h) const {
        Vec3 oc = ray.o - c;
        float a = dot(ray.d, ray.d), hb = dot(oc, ray.d), cc = dot(oc,oc) - r*r;
        float disc = hb*hb - a*cc;
        if (disc < 0) return false;
        float sq = std::sqrt(disc);
        for (float t : { (-hb - sq)/a, (-hb + sq)/a })
            if (tmin < t && t < tmax) {
                h = {t, ray.o + ray.d*t, (ray.o + ray.d*t - c) / r, true, m};
                h.front = dot(ray.d, h.n) < 0;
                if (!h.front) h.n = -h.n;
                return true;
            }
        return false;
    }
};
// 轴对齐矩形(墙面/光源), 法线朝 -axisDir 的一侧发光
struct Rect {
    enum Axis { XY, YZ, XZ } axis;   // XY: 平面 z=k; YZ: 平面 x=k; XZ: 平面 y=k
    float a0, a1, b0, b1, k;         // 平面内 [a0,a1]x[b0,b1]
    const Material* m;
    // 把光线参数映射到平面内的 (a,b) 坐标: XY→(x,y), YZ→(y,z), XZ→(x,z)
    void map(const Ray& r, float& pa, float& da, float& pb, float& db,
             float& pn, float& dn, Vec3& n) const {
        if (axis == XY) { pa=r.o.x; da=r.d.x; pb=r.o.y; db=r.d.y; pn=r.o.z; dn=r.d.z; n={0,0,1}; }
        else if (axis == YZ) { pa=r.o.y; da=r.d.y; pb=r.o.z; db=r.d.z; pn=r.o.x; dn=r.d.x; n={1,0,0}; }
        else { pa=r.o.x; da=r.d.x; pb=r.o.z; db=r.d.z; pn=r.o.y; dn=r.d.y; n={0,1,0}; }
    }
    bool hit(const Ray& ray, float tmin, float tmax, Hit& h) const {
        float pa, da, pb, db, pn, dn; Vec3 n;
        map(ray, pa, da, pb, db, pn, dn, n);
        if (std::fabs(dn) < 1e-8f) return false;
        float t = (k - pn) / dn;
        if (!(tmin < t && t < tmax)) return false;
        float a = pa + da*t, b = pb + db*t;
        if (a < a0 || a > a1 || b < b0 || b > b1) return false;
        bool front = dot(ray.d, n) < 0;
        h = {t, ray.o + ray.d*t, front ? n : -n, front, m};
        return true;
    }
};

struct World {
    std::vector<Sphere> spheres;
    std::vector<Rect> rects;
    const Material* lightMat{};
    Rect lightRect{};                // NEE 专用: 面上均匀采样
    bool hit(const Ray& r, float tmin, float tmax, Hit& best) const {
        bool any = false;
        for (auto& s : spheres) { Hit h; if (s.hit(r, tmin, tmax, h) && h.t < best.t) { best = h; any = true; } }
        for (auto& q : rects)   { Hit h; if (q.hit(r, tmin, tmax, h) && h.t < best.t) { best = h; any = true; } }
        return any;
    }
};

// ---------- 采样工具 ----------
static Vec3 randomInUnitSphere(Rng& rng) {   // 拒绝采样
    for (;;) {
        Vec3 p{(rng.u()*2-1), (rng.u()*2-1), (rng.u()*2-1)};
        if (dot(p,p) < 1) return p;
    }
}
static Vec3 cosineHemisphere(Rng& rng, const Vec3& n) {   // pdf = cosθ/π(docs/06)
    float a = rng.u() * 2*float(M_PI), z = rng.u();
    float r = std::sqrt(1 - z);
    Vec3 t = std::fabs(n.x) > 0.9f ? Vec3{0,1,0} : Vec3{1,0,0};
    Vec3 bx = norm(cross(t, n)), bz = cross(n, bx);
    return norm(bx*(r*std::cos(a)) + bz*(r*std::sin(a)) + n*std::sqrt(z));
}
static Vec3 sampleLight(const World& w, Rng& rng, float& pdfA) {  // 光源面上均匀采样
    const Rect& L = w.lightRect;
    float a = L.a0 + rng.u()*(L.a1 - L.a0);
    float b = L.b0 + rng.u()*(L.b1 - L.b0);
    pdfA = 1.0f / ((L.a1-L.a0) * (L.b1-L.b0));
    return L.axis == Rect::XY ? Vec3{a, b, L.k} : L.axis == Rect::YZ ? Vec3{L.k, a, b} : Vec3{a, L.k, b};
}

// ---------- 散射 ----------
static bool scatter(const Material& m, const Ray& in, const Hit& h, Rng& rng,
                    Vec3& atten, Ray& out, bool& specular) {
    specular = false;
    if (m.kind == Material::Lambert) {
        out = {h.p, cosineHemisphere(rng, h.n)};
        atten = m.albedo;                                  // brdf*cos/pdf = albedo/π*cos/(cos/π)
        return true;
    }
    if (m.kind == Material::Metal) {
        Vec3 r = in.d - h.n*(2*dot(in.d, h.n));
        out = {h.p, norm(r + randomInUnitSphere(rng)*m.fuzz)};   // fuzz: 球内随机扰动
        specular = true;
        if (dot(out.d, h.n) <= 0) return false;
        atten = m.albedo;
        return true;
    }
    if (m.kind == Material::Dielectric) {
        specular = true;
        float ratio = h.front ? 1.f/m.ior : m.ior;
        Vec3 ud = norm(in.d);
        float ct = std::fmin(dot(-ud, h.n), 1.f);
        float st = std::sqrt(1 - ct*ct);
        bool reflect = ratio*st > 1.f;
        float f0 = (1-m.ior)/(1+m.ior); f0 *= f0;
        float fres = f0 + (1-f0)*std::pow(1-ct, 5);        // Schlick
        if (reflect || rng.u() < fres) {
            out = {h.p, ud - h.n*(2*dot(ud, h.n))};
        } else {                                            // 折射(Schlick 概率外的部分)
            Vec3 dPerp = (ud + h.n*ct) * ratio;
            Vec3 dPara = h.n * -std::sqrt(std::fabs(1 - dot(dPerp, dPerp)));
            out = {h.p, norm(dPerp + dPara)};
        }
        atten = {1,1,1};
        return true;
    }
    return false;                                           // 光源材质: 不散射
}

// NEE: 从命中点向光源面上采一点, 估计直接光照(docs/06 §直接光采样)
//   L_dir = Le · (albedo/π) · cosθ_surf · cosθ_light / d² / pdfA
// (pdfA 是面积 pdf; 面元 dA 对命中点的立体角 dω = cosθ_light·dA/d², 展开后即上式)
static Vec3 neeDirect(const World& w, const Hit& h, Rng& rng) {
    float pdfA;
    Vec3 lp = sampleLight(w, rng, pdfA);
    Vec3 toL = lp - h.p;
    float d2 = dot(toL, toL), dist = std::sqrt(d2);
    Vec3 wi = toL / dist;
    float cosS = dot(h.n, wi);
    if (cosS <= 0) return {};
    Vec3 ln{0, -1, 0};                     // 顶灯法线朝箱内
    float cosL = dot(ln, -wi);             // 与"光→命中点"方向的夹角(立体角换算)
    if (cosL <= 0) return {};
    Ray shadow = {h.p + h.n*1e-4f, wi};
    Hit tmp; tmp.t = dist - 2e-4f;
    if (w.hit(shadow, 1e-4f, dist - 2e-4f, tmp) && tmp.m->kind != Material::Light) return {};
    return w.lightMat->emit * h.m->albedo * (cosS * cosL / (d2 * pdfA)) / float(M_PI);
}

// ---------- 相机 ----------
struct Camera {
    Vec3 o, ll, hor, ver;
    Camera(Vec3 lookfrom, Vec3 lookat, float vfov, float aspect) {
        float th = vfov * float(M_PI)/180;
        float hh = std::tan(th/2);
        Vec3 w = norm(lookfrom - lookat), u = norm(cross(w, {0,1,0})), v = cross(u, w);
        hor = u * (2*hh*aspect); ver = v * (2*hh);
        ll = lookfrom - hor/2 - ver/2 - w;
        o = lookfrom;
    }
    Ray ray(float sx, float sy) const { return {o, norm(ll + hor*sx + ver*sy - o)}; }
};

// ---------- 主积分器 ----------
static Vec3 trace(const World& w, const Camera& cam, float sx, float sy, Rng& rng) {
    Ray ray = cam.ray(sx, sy);
    Vec3 throughput{1,1,1}, radiance{};
    bool specularBounce = true;      // 相机光线/镜面弹射可以直接看到光源
    for (int depth = 0; depth < 8; depth++) {
        Hit h; h.t = 1e30f;
        if (!w.hit(ray, 1e-4f, 1e30f, h)) break;
        if (h.m->kind == Material::Light) {
            if (specularBounce) radiance += throughput * h.m->emit;   // 漫反射来源的已被 NEE 计入
            break;
        }
        if (h.m->kind == Material::Lambert)
            radiance += throughput * neeDirect(w, h, rng);
        Vec3 atten; Ray out; bool spec;
        if (!scatter(*h.m, ray, h, rng, atten, out, spec)) break;
        throughput = throughput * atten;
        if (throughput.x + throughput.y + throughput.z < 1e-4f) break;   // 简易 Russian roulette
        specularBounce = spec;
        ray = out;
    }
    return radiance;
}

// ---------- Cornell Box ----------
struct MaterialStore {                               // 材质集中存放, 指针稳定
    Material white{Material::Lambert, {0.86f,0.86f,0.86f}},
              red{Material::Lambert, {0.70f,0.12f,0.10f}},
              green{Material::Lambert, {0.12f,0.55f,0.16f}},
              glass{Material::Dielectric, {1,1,1}, 0, 1.5f},
              mirror{Material::Metal, {0.88f,0.88f,0.92f}, 0.03f},
              light{Material::Light, {}, 0, 0, {15,15,15}};
};
static World buildCornell(const MaterialStore& M) {
    World w;
    w.rects = {
        {Rect::XZ, 0,1, 0,1, 0, &M.white},     // 地板 y=0
        {Rect::XZ, 0,1, 0,1, 1, &M.white},     // 天花板 y=1
        {Rect::XY, 0,1, 0,1, 1, &M.white},     // 后墙 z=1
        {Rect::YZ, 0,1, 0,1, 0, &M.red},       // 左墙 x=0 红
        {Rect::YZ, 0,1, 0,1, 1, &M.green},     // 右墙 x=1 绿
        {Rect::XZ, 0.32f,0.68f, 0.32f,0.68f, 0.999f, &M.light},   // 顶灯(略低于天花避免贴面)
    };
    w.spheres = {
        {{0.27f, 0.15f, 0.36f}, 0.15f, &M.glass},
        {{0.73f, 0.15f, 0.36f}, 0.15f, &M.mirror},
    };
    w.lightMat = &M.light;
    for (auto& r : w.rects)
        if (r.m == &M.light) w.lightRect = r;
    return w;
}

// ---------- TGA ----------
static bool writeTGA(const char* path, int w, int h, const std::vector<uint8_t>& px) {
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    uint8_t head[18] = {0,0,2, 0,0,0,0,0, 0,0,0,0,
        uint8_t(w&255), uint8_t(w>>8), uint8_t(h&255), uint8_t(h>>8), 24, 0x20};
    f.write((char*)head, 18);
    f.write((char*)px.data(), px.size());
    return bool(f);
}

int main(int argc, char** argv) {
    int W2 = argc > 1 ? std::atoi(argv[1]) : 480;
    int H2 = argc > 2 ? std::atoi(argv[2]) : 360;
    int spp = argc > 3 ? std::atoi(argv[3]) : 128;

    MaterialStore M;
    World world = buildCornell(M);
    Camera cam({0.5f, 0.5f, -1.7f}, {0.5f, 0.5f, 1.0f}, 38, float(W2)/H2);

    std::vector<Vec3> accum(size_t(W2)*H2);
    std::atomic<int> nextRow{0};
    int nThreads = int(std::thread::hardware_concurrency());
    std::vector<std::thread> pool;
    auto t0 = std::chrono::steady_clock::now();
    for (int tid = 0; tid < nThreads; tid++)
        pool.emplace_back([&, tid] {
            Rng rng(0x9E3779B97F4A7C15ULL ^ (uint64_t(tid+1)*0xBF58476D1CE4E5B9ULL));
            for (;;) {
                int y = nextRow.fetch_add(1);
                if (y >= H2) break;
                for (int x = 0; x < W2; x++) {
                    Vec3 c{};
                    for (int s = 0; s < spp; s++)
                        c += trace(world, cam,
                                   (x + rng.u())/W2, 1.0f - (y + rng.u())/H2, rng);
                    accum[size_t(y)*W2 + x] = c * (1.0f/spp);
                }
            }
        });
    for (auto& t : pool) t.join();
    double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-t0).count();

    std::vector<uint8_t> px(size_t(W2)*H2*3);
    for (size_t i = 0; i < accum.size(); i++) {
        Vec3 c = accum[i];
        // gamma 2 + 限幅(docs/06: 无 tone map 的诚实呈现; ACES 见 06 示例)
        px[i*3+0] = uint8_t(std::clamp(std::sqrt(c.z), 0.f, 1.f)*255);
        px[i*3+1] = uint8_t(std::clamp(std::sqrt(c.y), 0.f, 1.f)*255);
        px[i*3+2] = uint8_t(std::clamp(std::sqrt(c.x), 0.f, 1.f)*255);
    }
    if (!writeTGA("out.tga", W2, H2, px)) { std::printf("写 out.tga 失败\n"); return 1; }
    std::printf("Cornell Box: %dx%d, %dspp, %d 线程, %.0fms → out.tga\n",
                W2, H2, spp, nThreads, ms);
    return 0;
}
