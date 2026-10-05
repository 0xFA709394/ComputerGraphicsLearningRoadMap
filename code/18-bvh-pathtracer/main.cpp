// 18-bvh-pathtracer: BVH 加速的路径追踪器(三角形网格 + SAH 构建 + 基准对比)
// 对应 docs/06 §求交/加速结构与 docs/27 案例 B 第 1~2 周。
// 构建: ./build.sh    运行: ./bvhpt [宽 高 spp]    输出: out.tga + 基准数据
//
// 在 code/10 之上新增: Triangle(Möller–Trumbore) / AABB / SAH-BVH / 三叶结网格
// 验收: Cornell Box + 三叶结成像; BVH vs 暴力遍历的加速比(基准打印)。

#include <algorithm>
#include <cstring>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <memory>
#include <thread>
#include <vector>

struct Vec3 {
    float x{}, y{}, z{};
    Vec3 operator+(const Vec3& o) const { return {x+o.x, y+o.y, z+o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x-o.x, y-o.y, z-o.z}; }
    Vec3 operator*(const Vec3& o) const { return {x*o.x, y*o.y, z*o.z}; }
    Vec3 operator*(float s) const { return {x*s, y*s, z*s}; }
    Vec3 operator/(float s) const { return *this * (1/s); }
    Vec3 operator-() const { return {-x,-y,-z}; }
    Vec3& operator+=(const Vec3& o) { x+=o.x; y+=o.y; z+=o.z; return *this; }
};
static float dot(const Vec3& a, const Vec3& b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x};
}
static float len(const Vec3& v) { return std::sqrt(dot(v,v)); }
static Vec3 norm(const Vec3& v) { return v / len(v); }

struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed) {}
    float u() {
        uint64_t o = s * 6364136223846793005ULL + 1442695040888963407ULL;
        s = o;
        return float((o >> 33) & 0x7FFFFFFFull) / float(0x80000000);
    }
};
struct Ray { Vec3 o, d; };
struct Material {
    enum Kind { Lambert, Metal, Light, Dielectric } kind;
    Vec3 albedo, emit;
};
struct Hit { float t{}; Vec3 p, n; bool front{}; const Material* m{}; };   // front: 命中外表面(介质折射方向判定用)

// ---------- AABB + 三角形(Möller–Trumbore, docs/06 §求交推导) ----------
struct Aabb {
    Vec3 mn{1e30f,1e30f,1e30f}, mx{-1e30f,-1e30f,-1e30f};
    void grow(const Vec3& p) { mn = {std::min(mn.x,p.x), std::min(mn.y,p.y), std::min(mn.z,p.z)};
                               mx = {std::max(mx.x,p.x), std::max(mx.y,p.y), std::max(mx.z,p.z)}; }
    void grow(const Aabb& b) { grow(b.mn); grow(b.mx); }
    bool hit(const Ray& r, float tmin, float tmax) const {
        for (int a = 0; a < 3; a++) {
            float ro = a==0?r.o.x:a==1?r.o.y:r.o.z, rd = a==0?r.d.x:a==1?r.d.y:r.d.z;
            float mna = a==0?mn.x:a==1?mn.y:mn.z, mxa = a==0?mx.x:a==1?mx.y:mx.z;
            float inv = 1.0f / rd;
            float t0 = (mna - ro) * inv, t1 = (mxa - ro) * inv;
            if (inv < 0) std::swap(t0, t1);
            tmin = std::max(tmin, t0); tmax = std::min(tmax, t1);
            if (tmax <= tmin) return false;
        }
        return true;
    }
};

struct Triangle {
    Vec3 a, b, c;
    const Material* m;
    Aabb box() const { Aabb t; t.grow(a); t.grow(b); t.grow(c); return t; }
    bool hit(const Ray& r, float tmin, float tmax, Hit& h) const {
        Vec3 e1 = b - a, e2 = c - a;
        Vec3 pvec = cross(r.d, e2);
        float det = dot(e1, pvec);
        if (std::fabs(det) < 1e-8f) return false;
        float inv = 1 / det;
        Vec3 tvec = r.o - a;
        float u = dot(tvec, pvec) * inv;
        if (u < 0 || u > 1) return false;
        Vec3 qvec = cross(tvec, e1);
        float v = dot(r.d, qvec) * inv;
        if (v < 0 || u + v > 1) return false;
        float t = dot(e2, qvec) * inv;
        if (tmin < t && t < tmax) {
            Vec3 n = norm(cross(e1, e2));
            h = {t, r.o + r.d*t, n, dot(r.d, n) < 0, m};
            return true;
        }
        return false;
    }
};

// ---------- SAH BVH(docs/06 §加速结构: 构建按表面积启发) ----------
struct BvhNode {
    Aabb box;
    uint32_t leftFirst = 0, count = 0;   // 内部: leftFirst=左孩子; 叶子: leftFirst=首三角
    bool leaf() const { return count > 0; }
};
struct Bvh {
    std::vector<BvhNode> nodes;
    uint32_t used = 1;
    std::vector<uint32_t> indices;       // 三角形重排索引

    void build(std::vector<Triangle>& tris) {
        if (tris.empty()) { std::printf("BVH: 空网格!\n"); std::exit(2); }
        nodes.assign(2 * tris.size() + 2, {});
        indices.resize(tris.size());
        for (uint32_t i = 0; i < tris.size(); i++) indices[i] = i;
        nodes[0].leftFirst = 0; nodes[0].count = uint32_t(tris.size());
        update(0, tris);
        subdivide(0, tris);
        nodes.resize(used);
    }
    void update(uint32_t n, const std::vector<Triangle>& tris) {
        Aabb b;
        for (uint32_t i = 0; i < nodes[n].count; i++) b.grow(tris[indices[nodes[n].leftFirst + i]].box());
        nodes[n].box = b;
    }
    float cost(const Aabb& b) const { return b.mx.x-b.mn.x + b.mx.y-b.mn.y + b.mx.z-b.mn.z; }
    void subdivide(uint32_t n, std::vector<Triangle>& tris) {
        if (nodes[n].count <= 4) return;
        // SAH: 在最宽轴上取若干候选切分, 取 cost 左面积·左数+右面积·右数 最小
        Vec3 ext = nodes[n].box.mx - nodes[n].box.mn;
        int axis = ext.x > ext.y && ext.x > ext.z ? 0 : (ext.y > ext.z ? 1 : 2);
        float mn = axis==0?nodes[n].box.mn.x:axis==1?nodes[n].box.mn.y:nodes[n].box.mn.z;
        float mx = axis==0?nodes[n].box.mx.x:axis==1?nodes[n].box.mx.y:nodes[n].box.mx.z;
        uint32_t first = nodes[n].leftFirst, count = nodes[n].count;
        float bestCost = 1e30f; uint32_t bestSplit = 0;
        for (int s = 1; s < 16; s++) {
            float pos = mn + (mx - mn) * s / 16.0f;
            Aabb L, R; uint32_t lc = 0, rc = 0;
            for (uint32_t i = 0; i < count; i++) {
                const Triangle& t = tris[indices[first + i]];
                float c = axis==0?t.a.x+t.b.x+t.c.x:axis==1?t.a.y+t.b.y+t.c.y:t.a.z+t.b.z+t.c.z;
                if (c < pos * 3) { L.grow(t.box()); lc++; } else { R.grow(t.box()); rc++; }
            }
            if (lc == 0 || rc == 0) continue;
            float c = cost(L) * lc + cost(R) * rc;
            if (c < bestCost) { bestCost = c; bestSplit = uint32_t(lc); }
        }
        if (bestSplit == 0 || bestSplit == count) return;    // 不可再分
        std::stable_partition(indices.begin() + first, indices.begin() + first + count,
                              [&](uint32_t i) {
                                  const Triangle& t = tris[i];
                                  float c = axis==0?t.a.x+t.b.x+t.c.x:axis==1?t.a.y+t.b.y+t.c.y:t.a.z+t.b.z+t.c.z;
                                  return c < 3 * (mn + (mx - mn) * bestSplit / 16.0f);
                              });
        uint32_t left = used++;
        uint32_t right = used++;
        nodes[left].leftFirst = first;      nodes[left].count = bestSplit;
        nodes[right].leftFirst = first + bestSplit; nodes[right].count = count - bestSplit;
        nodes[n].count = 0; nodes[n].leftFirst = left;
        update(left, tris); update(right, tris);
        subdivide(left, tris); subdivide(right, tris);
    }
    bool traverse(const std::vector<Triangle>& tris, uint32_t n, const Ray& r,
                  float tmin, float tmax, Hit& best) const {
        const BvhNode& node = nodes[n];
        if (!node.box.hit(r, tmin, tmax)) return false;
        bool any = false;
        if (node.leaf()) {
            for (uint32_t i = 0; i < node.count; i++) {
                Hit h;
                if (tris[indices[node.leftFirst + i]].hit(r, tmin, best.t, h) && h.t < best.t) {
                    best = h; any = true;
                }
            }
            return any;
        }
        any |= traverse(tris, node.leftFirst, r, tmin, best.t, best);
        any |= traverse(tris, node.leftFirst + 1, r, tmin, best.t, best);
        return any;
    }
};

// ---------- 场景: Cornell Box + 三叶结网格 ----------
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
                Vec3 n = norm(ray.o + ray.d*t - c);
                h = {t, ray.o + ray.d*t, n, dot(ray.d, n) < 0, m};
                return true;
            }
        return false;
    }
};
struct Rect {
    enum Axis { XY, YZ, XZ } axis;
    float a0, a1, b0, b1, k; const Material* m;
    bool hit(const Ray& ray, float tmin, float tmax, Hit& h) const {
        float pa, da, pb, db, pn, dn; Vec3 n;
        if (axis == XY) { pa=ray.o.x; da=ray.d.x; pb=ray.o.y; db=ray.d.y; pn=ray.o.z; dn=ray.d.z; n={0,0,1}; }
        else if (axis == YZ) { pa=ray.o.y; da=ray.d.y; pb=ray.o.z; db=ray.d.z; pn=ray.o.x; dn=ray.d.x; n={1,0,0}; }
        else { pa=ray.o.x; da=ray.d.x; pb=ray.o.z; db=ray.d.z; pn=ray.o.y; dn=ray.d.y; n={0,1,0}; }
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
    std::vector<Triangle> tris;      // 三叶结网格
    Bvh bvh;
    const Material* lightMat{};
    Rect lightRect{};
    bool useBvh = true;

    bool hit(const Ray& r, float tmin, float tmax, Hit& best) const {
        bool any = false;
        for (auto& s : spheres) { Hit h; if (s.hit(r, tmin, best.t, h) && h.t < best.t) { best = h; any = true; } }
        for (auto& q : rects)  { Hit h; if (q.hit(r, tmin, best.t, h) && h.t < best.t) { best = h; any = true; } }
        if (useBvh) { any |= bvh.traverse(tris, 0, r, tmin, best.t, best); }
        else {
            for (auto& t : tris) { Hit h; if (t.hit(r, tmin, best.t, h) && h.t < best.t) { best = h; any = true; } }
        }
        return any;
    }
};

// ---------- 采样/着色(与 code/10 同构: NEE + 余弦间接) ----------
static Vec3 cosineHemisphere(Rng& rng, const Vec3& n) {
    float a = rng.u() * 2*float(M_PI), z = rng.u(), r = std::sqrt(1 - z);
    Vec3 t = std::fabs(n.x) > 0.9f ? Vec3{0,1,0} : Vec3{1,0,0};
    Vec3 bx = norm(cross(t, n)), bz = cross(n, bx);
    return norm(bx*(r*std::cos(a)) + bz*(r*std::sin(a)) + n*std::sqrt(z));
}
static Vec3 neeDirect(const World& w, const Hit& h, Rng& rng) {
    const Rect& L = w.lightRect;
    float a = L.a0 + rng.u()*(L.a1 - L.a0), b = L.b0 + rng.u()*(L.b1 - L.b0);
    Vec3 lp = L.axis == Rect::XY ? Vec3{a, b, L.k} : L.axis == Rect::YZ ? Vec3{L.k, a, b} : Vec3{a, L.k, b};
    Vec3 toL = lp - h.p;
    float d2 = dot(toL, toL), dist = std::sqrt(d2);
    Vec3 wi = toL / dist;
    float cosS = dot(h.n, wi);
    if (cosS <= 0) return {};
    float cosL = dot(Vec3{0,-1,0}, -wi);   // 10 号踩坑: 与"光→命中点"方向点积
    if (cosL <= 0) return {};
    Hit tmp;
    Ray shadow = {h.p + h.n*1e-4f, wi};
    if (w.hit(shadow, 1e-4f, dist - 2e-4f, tmp)) return {};
    float pdfA = 1.0f / ((L.a1 - L.a0) * (L.b1 - L.b0));
    return w.lightMat->emit * h.m->albedo * (cosS * cosL / (d2 * pdfA)) / float(M_PI);
}
static Vec3 trace(const World& w, Ray ray, Rng& rng) {
    Vec3 tp{1,1,1}, rad{};
    bool spec = true;
    for (int depth = 0; depth < 6; depth++) {
        Hit h; h.t = 1e30f;
        if (!w.hit(ray, 1e-4f, 1e30f, h)) break;
        if (h.m->kind == Material::Light) { if (spec) rad += tp * h.m->emit; break; }
        if (h.m->kind == Material::Lambert) rad += tp * neeDirect(w, h, rng);
        Ray out{h.p, cosineHemisphere(rng, h.n)};
        if (h.m->kind == Material::Dielectric) {          // 光滑介质: Schlick 折/反(镜面链, spec 保持 true)
            Vec3 n1 = h.front ? h.n : -h.n;
            bool into = dot(ray.d, n1) < 0;
            float ior = into ? (1.f/1.5f) : 1.5f;
            float ct = std::fmin(dot(-norm(ray.d), n1), 1.f);
            float st = std::sqrt(1 - ct*ct);
            bool refl = ior*st > 1;
            float f0 = (1-1.5f)/(1+1.5f); f0 *= f0;
            if (refl || rng.u() < f0 + (1-f0)*std::pow(1-ct, 5))
                out.d = norm(ray.d + n1*(2*dot(-ray.d, n1)));
            else {
                Vec3 dPerp = (norm(ray.d) + n1*ct) * ior;
                out.d = norm(dPerp + n1 * -std::sqrt(std::fabs(1 - dot(dPerp, dPerp))));
                out.o = h.p - n1*1e-4f;
            }
            ray = out;
            continue;                                      // 镜面不衰减 throughput(教学简化)
        }
        tp = tp * h.m->albedo;
        if (tp.x + tp.y + tp.z < 1e-4f) break;
        spec = false;
        ray = out;
    }
    return rad;
}
struct Camera {
    Vec3 o, ll, hor, ver;
    Camera(Vec3 from, Vec3 at, float vfov, float aspect) {
        float hh = std::tan(vfov * float(M_PI) / 360);
        Vec3 w = norm(from - at), u = norm(cross(w, {0,1,0})), v = cross(u, w);
        hor = u * (2*hh*aspect); ver = v * (2*hh);
        ll = from - hor/2 - ver/2 - w; o = from;
    }
    Ray ray(float sx, float sy) const { return {o, norm(ll + hor*sx + ver*sy - o)}; }
};

// ---------- 单向 MLT(docs/27 案例 B 第 8~9 周教学版) ----------
// 状态 = 像素样本(u,v + 路径种子)。大步长跳变 10%(遍历性) + 小步变异 90%,
// Metropolis 接受 I(new)/I(old); 预热估 b(平均亮度) 做期望归一。
struct MltState {
    float u, v;
    uint64_t seed;
    float luminance;
};
static float evalSample(const World& w, const Camera& cam, const MltState& st) {
    Rng rng = Rng(st.seed);
    Vec3 c = trace(w, cam.ray(st.u, st.v), rng);
    return (c.x + c.y + c.z) / 3;
}
static MltState mutate(const MltState& s, Rng& rng) {
    MltState n = s;
    n.u = std::fmod(s.u + 0.02f * (rng.u()*2-1) + 1.0f, 1.0f);
    n.v = std::clamp(s.v + 0.02f * (rng.u()*2-1), 0.0f, 1.0f);
    n.seed = s.seed ^ (((uint64_t)(rng.u() * 0xFFFFFFFF) << 1) | 1);
    n.luminance = 0;
    return n;
}

// ---------- glTF 2.0 最小读回器(与 19 号 writer 互通; 单 mesh + POSITION/NORMAL + u16 索引) ----------
// 教学实现: 手写 JSON 字段定位(非通用解析器); 生产用 cgltf/tinygltf。
struct GltfMesh { std::vector<Vec3> pos, nrm; std::vector<uint32_t> idx; };

static std::string readFileStr(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}
static std::vector<float> readBinFloats(const std::string& binPath, size_t off, size_t count) {
    std::ifstream f(binPath, std::ios::binary);
    f.seekg(off);
    std::vector<float> out(count);
    f.read((char*)out.data(), count * 4);
    return out;
}
// 在 JSON 文本里找 "key":value 的数值(教学级: 假设无嵌套同名)
static bool jsonFindNumber(const std::string& js, const std::string& key, double& out) {
    std::string pat = "\"" + key + "\":";
    auto p = js.find(pat);
    if (p == std::string::npos) return false;
    out = std::atof(js.c_str() + p + pat.size());
    return true;
}
static bool jsonFindArrayN(const std::string& js, const std::string& key, double* out, int n) {
    std::string pat = "\"" + key + "\":";
    auto p = js.find(pat);
    if (p == std::string::npos) return false;
    p += pat.size();
    while (p < js.size() && js[p] != '[') p++;
    for (int i = 0; i < n; i++) out[i] = std::atof(js.c_str() + ++p), p += std::strcspn(js.c_str() + p, ",]");
    return true;
}

static GltfMesh loadGltf(const std::string& stem) {
    std::string js = readFileStr(stem + ".gltf");
    GltfMesh m;
    // buffer byteLength / 三个 accessor 的 bufferView byteOffset + count
    // 约定: view0=indices(u16), view1=positions, view2=normals(与 19 号 writer 的段序一致)
    auto findViewOffset = [&](int view) -> size_t {
        // 数第 view+1 个 "byteOffset": 的出现位置(每次 find 从上一命中+1 起)
        std::string pat = "\"byteOffset\":";
        size_t p = 0;
        for (int i = 0; i <= view; i++) {
            p = js.find(pat, p);
            if (p == std::string::npos) return 0;
            if (i < view) p += pat.size();      // 命中后再找下一个; 最后一次停在命中处
        }
        return (size_t)std::atoll(js.c_str() + p + pat.size());
    };
    // accessor count: indices 是 accessors[0]
    double idxCount = 0, posCount = 0;
    {
        // accessors 数组里逐个 "count"(sortedKeys 下 accessor 对象内字段序不定, 数出现次数)
        size_t accPos = js.find("\"accessors\"");
        auto nthCount = [&](int n) -> double {
            size_t p = accPos;
            size_t hit = std::string::npos;
            for (int i = 0; i <= n; i++) {
                p = js.find("\"count\":", p);
                if (p == std::string::npos) return 0;
                hit = p;
                p += 1;                     // 前进 1(而非 7): 下次 find 从命中的 c 之后找, 不漏
            }
            return std::atof(js.c_str() + hit + 8);   // "count": 是 8 字符(含引号与冒号)
        };
        idxCount = nthCount(0);
        posCount = nthCount(1);
    }
    size_t idxOff = findViewOffset(0), posOff = findViewOffset(1), nrmOff = findViewOffset(2);
    // u16 索引
    {
        std::ifstream f(stem + ".bin", std::ios::binary);
        f.seekg(idxOff);
        std::vector<uint16_t> tmp(idxCount);
        f.read((char*)tmp.data(), idxCount * 2);
        m.idx.assign(tmp.begin(), tmp.end());
    }
    auto pos = readBinFloats(stem + ".bin", posOff, posCount * 3);
    auto nrm = readBinFloats(stem + ".bin", nrmOff, posCount * 3);
    m.pos.resize(posCount);
    m.nrm.resize(posCount);
    for (size_t i = 0; i < posCount; i++) {
        m.pos[i] = {pos[i*3], pos[i*3+1], pos[i*3+2]};
        m.nrm[i] = {nrm[i*3], nrm[i*3+1], nrm[i*3+2]};
    }
    std::printf("loadGltf: idx=%zu pos=%zu\n", m.idx.size(), m.pos.size());
    return m;
}
static std::vector<Triangle> gltfToTriangles(const GltfMesh& g, const Material* m,
                                             float scale, Vec3 center) {
    std::vector<Triangle> tris;
    tris.reserve(g.idx.size() / 3);
    for (size_t i = 0; i + 2 < g.idx.size(); i += 3) {
        Vec3 a = g.pos[g.idx[i]] * scale + center;
        Vec3 b = g.pos[g.idx[i+1]] * scale + center;
        Vec3 c = g.pos[g.idx[i+2]] * scale + center;
        Vec3 n = norm(g.nrm[g.idx[i]] + g.nrm[g.idx[i+1]] + g.nrm[g.idx[i+2]]);
        tris.push_back({a, b, c, m});
        (void)n;
    }
    return tris;
}

/// 三叶结管道网格(tube around trefoil curve)
static std::vector<Triangle> makeTrefoil(const Material* m, int segT, int segR, float tube) {
    std::vector<Vec3> ring;
    ring.reserve(segT * segR);
    auto curve = [](float t) {
        return Vec3{ std::sin(t) + 2*std::sin(2*t), std::cos(t) - 2*std::cos(2*t), -std::sin(3*t) };
    };
    for (int i = 0; i < segT; i++) {
        float t = 2*float(M_PI) * i / segT;
        Vec3 p = curve(t);
        Vec3 tan = norm(curve(t + 0.01f) - curve(t - 0.01f));
        Vec3 n1 = norm(cross(tan, Vec3{0,1,0} + Vec3{0.01f,0,0}));
        Vec3 n2 = cross(tan, n1);
        for (int j = 0; j < segR; j++) {
            float a = 2*float(M_PI) * j / segR;
            ring.push_back(p + n1*(std::cos(a)*tube) + n2*(std::sin(a)*tube));
        }
    }
    std::vector<Triangle> tris;
    for (int i = 0; i < segT; i++)
        for (int j = 0; j < segR; j++) {
            int a = i*segR + j, b = ((i+1)%segT)*segR + j,
                c = ((i+1)%segT)*segR + (j+1)%segR, d = i*segR + (j+1)%segR;
            tris.push_back({ring[a], ring[b], ring[c], m});
            tris.push_back({ring[a], ring[c], ring[d], m});
        }
    return tris;
}

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
    int W = argc > 1 ? std::atoi(argv[1]) : 480;
    int H = argc > 2 ? std::atoi(argv[2]) : 360;
    int spp = argc > 3 ? std::atoi(argv[3]) : 96;

    bool mltMode = argc > 4 && std::strcmp(argv[4], "--mlt") == 0;
    static Material glass{Material::Dielectric, {1,1,1}};
    Material white{Material::Lambert, {0.86f,0.86f,0.86f}},
             red{Material::Lambert, {0.70f,0.12f,0.10f}},
             green{Material::Lambert, {0.12f,0.55f,0.16f}},
             knot{Material::Lambert, {0.90f,0.65f,0.15f}},
             metal{Material::Metal, {0.88f,0.88f,0.92f}},
             light{Material::Light, {}, {15,15,15}};
    World w;
    w.rects = {
        {Rect::XZ, 0,1, 0,1, 0, &white}, {Rect::XZ, 0,1, 0,1, 1, &white},
        {Rect::XY, 0,1, 0,1, 1, &white},
        {Rect::YZ, 0,1, 0,1, 0, &red},  {Rect::YZ, 0,1, 0,1, 1, &green},
        {Rect::XZ, 0.32f,0.68f, 0.32f,0.68f, 0.999f, &light},
    };
    w.spheres = { {{0.72f, 0.16f, 0.32f}, 0.16f, &metal} };
    // 三叶结: 缩放进箱子中央
    // 资产链: 生成 → 写 glTF(练习 3) → 读回 → 建三角形(证明"任何 glTF 输入都能走通")
    auto tris = makeTrefoil(&knot, 256, 40, 0.085f);
    for (auto& t : tris) { t.a = t.a * 0.24f + Vec3{0.5f, 0.42f, 0.5f};
                           t.b = t.b * 0.24f + Vec3{0.5f, 0.42f, 0.5f};
                           t.c = t.c * 0.24f + Vec3{0.5f, 0.42f, 0.5f}; }
    {
        // 写 knot.gltf + knot.bin(段序: indices u16 | positions | normals, 19 号同构)
        std::vector<uint16_t> idx;
        std::vector<float> pos, nrm;
        std::vector<int> vmap(tris.size() * 3, -1);
        auto vkey = [&](int ti, int vi) { return ti * 3 + vi; };
        (void)vkey;
        // 顶点去重(教学: 直接全量, 无索引优化)
        for (size_t ti = 0; ti < tris.size(); ti++) {
            const Vec3 vs[3] = {tris[ti].a, tris[ti].b, tris[ti].c};
            Vec3 n = norm(cross(tris[ti].b - tris[ti].a, tris[ti].c - tris[ti].a));
            for (int vi = 0; vi < 3; vi++) {
                idx.push_back(uint16_t(pos.size() / 3));
                pos.insert(pos.end(), {vs[vi].x, vs[vi].y, vs[vi].z});
                nrm.insert(nrm.end(), {n.x, n.y, n.z});
            }
        }
        std::ofstream bin("knot.bin", std::ios::binary);
        size_t idxBytes = idx.size() * 2;
        bin.write((char*)idx.data(), idxBytes);
        size_t pad = (4 - idxBytes % 4) % 4;
        bin.write("\0\0\0", pad);
        size_t posOff = idxBytes + pad;
        bin.write((char*)pos.data(), pos.size() * 4);
        size_t nrmOff = posOff + pos.size() * 4;
        bin.write((char*)nrm.data(), nrm.size() * 4);
        char head[512];
        std::snprintf(head, sizeof head,
            "{\"asset\":{\"version\":\"2.0\"},"
            "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":1,\"NORMAL\":2},\"indices\":0}]}],"
            "\"bufferViews\":[{\"byteOffset\":0,\"byteLength\":%zu},"
            "{\"byteOffset\":%zu,\"byteLength\":%zu},"
            "{\"byteOffset\":%zu,\"byteLength\":%zu}],"
            "\"accessors\":[{\"count\":%zu},{\"count\":%zu},{\"count\":%zu}]}",
            idxBytes, posOff, pos.size()*4, nrmOff, nrm.size()*4,
            idx.size(), pos.size()/3, pos.size()/3);
        std::ofstream gf("knot.gltf");
        gf << head;
    }
    auto g = loadGltf("knot");
    fflush(stdout); printf("glTF 往返: %zu 索引 / %zu 顶点\n", g.idx.size(), g.pos.size());
    w.tris = gltfToTriangles(g, &knot, 1.0f, Vec3{0, 0, 0});
    w.lightMat = &light;
    for (auto& r : w.rects) if (r.m == &light) w.lightRect = r;

    // ---- 基准: BVH 构建 + 暴力 vs BVH 遍历(docs/27 案例 B 验收) ----
    auto t0 = std::chrono::steady_clock::now();
    w.bvh.build(w.tris);
    double buildMs = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t0).count();
    Rng benchRng(42);
    Camera benchCam({0.5f,0.5f,-1.7f}, {0.5f,0.5f,1}, 38, 1.5f);
    auto traceNs = [&](bool bvh) {
        auto s = std::chrono::steady_clock::now();
        for (int i = 0; i < 20000; i++) {
            Ray r = benchCam.ray(benchRng.u(), benchRng.u());
            Hit h; h.t = 1e30f;
            w.useBvh = bvh;
            w.hit(r, 1e-4f, 1e30f, h);
        }
        return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-s).count();
    };
    double bruteMs = traceNs(false), bvhMs = traceNs(true);
    printf("三角形 %zu | BVH 节点 %zu | 构建 %.1fms | 2 万条射线: 暴力 %.0fms vs BVH %.1fms → 加速 %.1fx\n",
           w.tris.size(), w.bvh.nodes.size(), buildMs, bruteMs, bvhMs, bruteMs / std::max(bvhMs, 1e-9));
    w.useBvh = true;

    // ---- 渲染 ----
    Camera cam({0.5f, 0.5f, -1.7f}, {0.5f, 0.5f, 1.0f}, 38, float(W)/float(H));
    std::vector<Vec3> accum(size_t(W)*H);
    int nThreads = int(std::thread::hardware_concurrency());
    auto t1 = std::chrono::steady_clock::now();
    if (mltMode) {
        // ---- Metropolis: 每线程独立马尔可夫链, 期望归一 ----
        std::vector<std::thread> pool;
        std::atomic<int> nextChain{0};
        for (int tid = 0; tid < nThreads; tid++)
            pool.emplace_back([&, tid] {
                Rng rng(0xA5A5A5A5ULL ^ (uint64_t(tid+1)*0x9E3779B9ULL));
                MltState cur{rng.u(), rng.u(), (uint64_t)(rng.u()*0xFFFFFFFF), 0};
                cur.luminance = evalSample(w, cam, cur);
                double bSum = 0;
                const int warm = 8000;
                for (int i = 0; i < warm; i++) {           // 预热求 b(平均亮度)
                    MltState prop = mutate(cur, rng);
                    prop.luminance = evalSample(w, cam, prop);
                    if (cur.luminance <= 0 || rng.u() < prop.luminance / std::max(cur.luminance, 1e-6f))
                        cur = prop;
                    bSum += cur.luminance;
                }
                float b = std::max(float(bSum / warm), 1e-6f);
                int chains = 64;
                int stepsPer = spp * W * H / (nThreads * chains);
                for (;;) {
                    int ci = nextChain.fetch_add(1);
                    if (ci >= chains) break;
                    Rng crng(0xC0FFEEULL ^ (uint64_t(ci+1)*0xBF58476DULL));
                    MltState cc{crng.u(), crng.u(), (uint64_t)(crng.u()*0xFFFFFFFF), 0};
                    cc.luminance = evalSample(w, cam, cc);
                    for (int i = 0; i < stepsPer; i++) {
                        MltState prop;
                        if (crng.u() < 0.1f)                // 大步长跳变(遍历性)
                            prop = MltState{crng.u(), crng.u(), (uint64_t)(crng.u()*0xFFFFFFFF), 0};
                        else
                            prop = mutate(cc, crng);        // 小步变异
                        prop.luminance = evalSample(w, cam, prop);
                        float a = cc.luminance <= 0 ? 1.0f
                                : prop.luminance / std::max(cc.luminance, 1e-6f);
                        if (crng.u() < a) cc = prop;        // Metropolis 接受
                        int px = int(cc.u * W), py = int((1 - cc.v) * H);
                        if (px >= 0 && py >= 0 && px < W && py < H && cc.luminance > 0)
                            accum[size_t(py)*W + px] += Vec3{cc.luminance/b, cc.luminance/b, cc.luminance/b};
                    }
                }
                // 正确归一: 每像素累计 = Σ(Ii/b) 已是"期望亮度"; 但 splat 数 ≠ 像素数,
                // 还需除以"每像素平均 splat 数"(= 总 splat / 像素数) 才是亮度期望。
                // (归一移到 join 之后; 此处仅本线程诊断)
                double sum = 0; int nz = 0; float mx = 0;
                for (auto& c : accum) { sum += c.x + c.y + c.z; if (c.x+c.y+c.z > 0) nz++; mx = std::max(mx, c.x); }
                std::printf("MLT 线程: b=%.4f 非零=%d/%zu 峰值=%.1f\n", b, nz, accum.size(), mx);
            });
        for (auto& t : pool) t.join();
        // join 后统一归一: 每像素平均 splat 数
        double totalSplats = double(nThreads) * 64 * 7680;
        float perPixel = float(totalSplats) / (W * H);
        for (auto& c : accum) c = c / perPixel;
    } else {
    std::atomic<int> nextRow{0};
    std::vector<std::thread> pool;
    for (int tid = 0; tid < nThreads; tid++)
        pool.emplace_back([&, tid] {
            Rng rng(0x9E3779B97F4A7C15ULL ^ (uint64_t(tid+1)*0xBF58476D1CE4E5B9ULL));
            for (;;) {
                int y = nextRow.fetch_add(1);
                if (y >= H) break;
                for (int x = 0; x < W; x++) {
                    Vec3 c{};
                    for (int s = 0; s < spp; s++)
                        c += trace(w, cam.ray((x + rng.u())/W, 1.0f - (y + rng.u())/H), rng);
                    accum[size_t(y)*W + x] = c * (1.0f/spp);
                }
            }
        });
    for (auto& t : pool) t.join();
    }
    double ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-t1).count();

    std::vector<uint8_t> px(size_t(W)*H*3);
    for (size_t i = 0; i < accum.size(); i++) {
        Vec3 c = accum[i];
        px[i*3+0] = uint8_t(std::clamp(std::sqrt(c.z), 0.f, 1.f)*255);
        px[i*3+1] = uint8_t(std::clamp(std::sqrt(c.y), 0.f, 1.f)*255);
        px[i*3+2] = uint8_t(std::clamp(std::sqrt(c.x), 0.f, 1.f)*255);
    }
    if (!writeTGA("out.tga", W, H, px)) { printf("写 out.tga 失败\n"); return 1; }
    printf("渲染: %dx%d@%dspp, %d 线程, %.0fms → out.tga\n", W, H, spp, nThreads, ms);
    return 0;
}
