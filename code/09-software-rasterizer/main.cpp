// 09-software-rasterizer: 单文件软光栅器(C++17, 零依赖)
// 对应 docs/02(光栅化/透视校正插值/z-buffer) 与 docs/11 §1.1(阴影映射) 的 CPU 实现。
// 构建: ./build.sh    运行: ./rasterizer [out.tga]    输出: 800x600 TGA(Preview 可开)
//
// 一帧两遍: 光源深度遍(shadow map) → 相机着色遍(Blinn-Phong + PCF 软阴影)。
// 全部概念在 CPU 逐像素完成——这就是 GPU 每帧替你做的事(docs/02 §1 的"心智模型")。

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <functional>
#include <vector>

static const int W = 800, H = 600;
static const int SMAP = 512;   // 阴影图分辨率

// ---------- 向量 / 矩阵(docs/01) ----------
struct Vec3 {
    float x{}, y{}, z{};
    Vec3 operator+(const Vec3& o) const { return {x + o.x, y + o.y, z + o.z}; }
    Vec3 operator-(const Vec3& o) const { return {x - o.x, y - o.y, z - o.z}; }
    Vec3 operator*(float s) const { return {x * s, y * s, z * s}; }
    Vec3 operator-() const { return {-x, -y, -z}; }
};
static float dot(const Vec3& a, const Vec3& b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static Vec3 cross(const Vec3& a, const Vec3& b) {
    return {a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x};
}
static float len(const Vec3& v) { return std::sqrt(dot(v, v)); }
static Vec3 norm(const Vec3& v) { return v * (1.0f / len(v)); }

struct Mat4 {                       // 行主序, 列向量约定: v' = M * v
    float m[4][4]{};
    static Mat4 identity() { Mat4 r; for (int i = 0; i < 4; i++) r.m[i][i] = 1; return r; }
};
static Vec3 xformPoint(const Mat4& M, const Vec3& p) {   // 齐次 w=1
    return {M.m[0][0]*p.x + M.m[0][1]*p.y + M.m[0][2]*p.z + M.m[0][3],
            M.m[1][0]*p.x + M.m[1][1]*p.y + M.m[1][2]*p.z + M.m[1][3],
            M.m[2][0]*p.x + M.m[2][1]*p.y + M.m[2][2]*p.z + M.m[2][3]};
}
static Vec3 xformDir(const Mat4& M, const Vec3& d) {     // w=0; 法线需逆转置, 本例仅旋转+等比缩放故可直接用
    return {M.m[0][0]*d.x + M.m[0][1]*d.y + M.m[0][2]*d.z,
            M.m[1][0]*d.x + M.m[1][1]*d.y + M.m[1][2]*d.z,
            M.m[2][0]*d.x + M.m[2][1]*d.y + M.m[2][2]*d.z};
}
static Mat4 mul(const Mat4& A, const Mat4& B) {
    Mat4 R{};
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
            for (int k = 0; k < 4; k++) R.m[r][c] += A.m[r][k] * B.m[k][c];
    return R;
}
static Mat4 perspective(float fovY, float aspect, float n, float f) {  // GL 约定 z∈[-1,1]
    float t = 1.0f / std::tan(fovY * 0.5f);
    Mat4 R{};
    R.m[0][0] = t / aspect; R.m[1][1] = t;
    R.m[2][2] = (f + n) / (n - f); R.m[2][3] = 2*f*n / (n - f);
    R.m[3][2] = -1;                                     // w_clip = -z_view
    return R;
}
static Mat4 ortho(float l, float r, float b, float t, float n, float f) {  // z∈[0,1]
    Mat4 R = Mat4::identity();
    R.m[0][0] = 2/(r-l); R.m[1][1] = 2/(t-b); R.m[2][2] = -1/(f-n);
    R.m[0][3] = -(r+l)/(r-l); R.m[1][3] = -(t+b)/(t-b); R.m[2][3] = -n/(f-n);
    return R;
}
static Mat4 lookAt(const Vec3& eye, const Vec3& target, const Vec3& up) {
    Vec3 fz = norm(target - eye), rx = norm(cross(fz, up)), uy = cross(rx, fz);
    Mat4 R{};
    R.m[0][0]=rx.x; R.m[0][1]=rx.y; R.m[0][2]=rx.z; R.m[0][3]=-dot(rx, eye);
    R.m[1][0]=uy.x; R.m[1][1]=uy.y; R.m[1][2]=uy.z; R.m[1][3]=-dot(uy, eye);
    R.m[2][0]=-fz.x; R.m[2][1]=-fz.y; R.m[2][2]=-fz.z; R.m[2][3]=dot(fz, eye);
    R.m[3][3]=1;
    return R;
}
static Mat4 rotationY(float a) {
    Mat4 R = Mat4::identity();
    float c = std::cos(a), s = std::sin(a);
    R.m[0][0]=c; R.m[0][2]=-s; R.m[2][0]=s; R.m[2][2]=c;
    return R;
}

// ---------- 图像 / 纹理 ----------
struct Image {
    int w{}, h{};
    std::vector<uint8_t> px;                            // BGR 交错
    void init(int w_, int h_) { w=w_; h=h_; px.assign(size_t(w)*h*3, 0); }
    void set(int x, int y, const Vec3& c) {             // 线性 rgb∈[0,1] → 8bit(gamma 见 README 练习)
        if (x<0||y<0||x>=w||y>=h) return;
        uint8_t* p = &px[(size_t(y)*w + x)*3];
        p[0]=uint8_t(std::clamp(c.z,0.f,1.f)*255+0.5f);
        p[1]=uint8_t(std::clamp(c.y,0.f,1.f)*255+0.5f);
        p[2]=uint8_t(std::clamp(c.x,0.f,1.f)*255+0.5f);
    }
    bool writeTGA(const char* path) {
        std::ofstream f(path, std::ios::binary);
        if (!f) return false;
        uint8_t head[18] = {0,0,2, 0,0,0,0,0, 0,0,0,0,
            uint8_t(w&255), uint8_t(w>>8), uint8_t(h&255), uint8_t(h>>8), 24, 0x20};
        f.write((char*)head, 18);
        f.write((char*)px.data(), px.size());
        return bool(f);
    }
};

// 过程式棋盘纹理(docs/04 §5: 免资产; nearest + repeat wrap)
struct Checker {
    Vec3 a{0.72f, 0.72f, 0.74f}, b{0.33f, 0.37f, 0.42f};
    Vec3 sample(float u, float v) const {
        u = u - std::floor(u); v = v - std::floor(v);
        return ((int(std::floor(u*8)) + int(std::floor(v*8))) & 1) ? b : a;
    }
};

// ---------- 网格 / 材质 ----------
struct Vertex { Vec3 pos, normal; float u{}, v{}; };
struct Mesh { std::vector<Vertex> verts; std::vector<std::array<int,3>> tris; };
struct Material { Vec3 albedo; bool checker{}; float ks{}, shin{}; };

static Mesh makeSphere(float radius, int lat, int lon) {  // 经纬球, 法线=归一化位置
    Mesh M;
    for (int i = 0; i <= lat; i++) {
        float th = float(M_PI)*i/lat, st = std::sin(th), ct = std::cos(th);
        for (int j = 0; j <= lon; j++) {
            float ph = 2*float(M_PI)*j/lon;
            Vec3 n{st*std::cos(ph), ct, st*std::sin(ph)};
            M.verts.push_back({n*radius, n, float(j)/lon, 1 - float(i)/lat});
        }
    }
    auto idx = [&](int i, int j) { return i*(lon+1) + j; };
    for (int i = 0; i < lat; i++)
        for (int j = 0; j < lon; j++) {
            M.tris.push_back({idx(i,j), idx(i+1,j), idx(i+1,j+1)});
            M.tris.push_back({idx(i,j), idx(i+1,j+1), idx(i,j+1)});
        }
    return M;
}
static Mesh makeGround(float S, float y, float R) {
    Mesh M;
    M.verts = {
        {{-S,y,-S},{0,1,0},0,0}, {{ S,y,-S},{0,1,0},R,0}, {{ S,y, S},{0,1,0},R,R},
        {{-S,y,-S},{0,1,0},0,0}, {{ S,y, S},{0,1,0},R,R}, {{-S,y, S},{0,1,0},0,R}};
    M.tris = {{0,1,2}, {3,4,5}};
    return M;
}

// ---------- 光栅化核心(docs/02 §3 的逐条落地) ----------
struct Varyings { Vec3 world, normal; float u, v; };      // 顶点→片元要插值的量

// 屏幕顶点: clip 之后的落点 + 插值辅助量
struct ScreenVtx { float sx, sy, z01, invW; Varyings vary; };

// 屏幕空间边函数(二倍符号面积): p 在 ab 左侧为正
static float edge(float ax, float ay, float bx, float by, float px, float py) {
    return (bx-ax)*(py-ay) - (by-ay)*(px-ax);
}

static int g_clippedTris = 0;   // 近裁剪面丢弃计数(正确实现应做三角形裁剪, docs/02 §2)

// 通用三角形光栅化: 对每个通过 z 测试的片元调用 frag(x, y, 插值后的 Varyings)
static void rasterize(const Mesh& M, const std::array<int,3>& tri, const Mat4& model,
                      const Mat4& vp, int tw, int th, bool orthoPass,
                      std::vector<float>& zbuf,
                      const std::function<void(int,int,const Varyings&)>& frag) {
    ScreenVtx s[3];
    for (int k = 0; k < 3; k++) {
        const Vertex& v = M.verts[tri[k]];
        Vec3 world = xformPoint(model, v.pos);
        Vec3 clip = xformPoint(vp, world);
        float w = vp.m[3][0]*world.x + vp.m[3][1]*world.y + vp.m[3][2]*world.z + vp.m[3][3];
        if (w < 0.05f) { g_clippedTris++; return; }      // 近平面后暴力丢弃
        s[k].vary = {world, norm(xformDir(model, v.normal)), v.u, v.v};
        s[k].invW = 1.0f / w;
        Vec3 ndc = clip * s[k].invW;                     // 透视除法(ortho 时 w=1, 自动退化)
        s[k].sx = (ndc.x + 1) * 0.5f * tw;
        s[k].sy = (1 - (ndc.y + 1) * 0.5f) * th;         // y 翻转: 图像原点左上
        s[k].z01 = orthoPass ? clip.z : ndc.z*0.5f + 0.5f;   // 光源遍 z 已在[0,1]
    }
    int x0 = std::max(0, (int)std::floor(std::min({s[0].sx, s[1].sx, s[2].sx})));
    int x1 = std::min(tw-1, (int)std::ceil(std::max({s[0].sx, s[1].sx, s[2].sx})));
    int y0 = std::max(0, (int)std::floor(std::min({s[0].sy, s[1].sy, s[2].sy})));
    int y1 = std::min(th-1, (int)std::ceil(std::max({s[0].sy, s[1].sy, s[2].sy})));
    float area = edge(s[0].sx,s[0].sy, s[1].sx,s[1].sy, s[2].sx,s[2].sy);
    if (std::fabs(area) < 1e-9f) return;
    float sign = area < 0 ? -1.f : 1.f;
    for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
            float px = x + 0.5f, py = y + 0.5f;
            float b0 = sign*edge(s[1].sx,s[1].sy, s[2].sx,s[2].sy, px,py);
            float b1 = sign*edge(s[2].sx,s[2].sy, s[0].sx,s[0].sy, px,py);
            float b2 = sign*edge(s[0].sx,s[0].sy, s[1].sx,s[1].sy, px,py);
            if (b0 < 0 || b1 < 0 || b2 < 0) continue;
            b0 = b0/area*sign; b1 = b1/area*sign; b2 = b2/area*sign;   // 归一化重心坐标
            // z 在屏幕空间线性插值是"对的"(docs/02 §3 特例)
            float z = b0*s[0].z01 + b1*s[1].z01 + b2*s[2].z01;
            size_t zi = size_t(y)*tw + x;
            if (z >= zbuf[zi]) continue;                  // z-buffer 测试
            zbuf[zi] = z;
            // 透视校正插值: 属性/w 线性组合, 再除以插值后的 1/w(docs/02 §3)
            float invW = b0*s[0].invW + b1*s[1].invW + b2*s[2].invW;
            float w0 = b0*s[0].invW, w1 = b1*s[1].invW, w2 = b2*s[2].invW;
            Varyings out;
            out.world  = { (w0*s[0].vary.world.x  + w1*s[1].vary.world.x  + w2*s[2].vary.world.x ) / invW,
                           (w0*s[0].vary.world.y  + w1*s[1].vary.world.y  + w2*s[2].vary.world.y ) / invW,
                           (w0*s[0].vary.world.z  + w1*s[1].vary.world.z  + w2*s[2].vary.world.z ) / invW };
            out.normal = { (w0*s[0].vary.normal.x + w1*s[1].vary.normal.x + w2*s[2].vary.normal.x) / invW,
                           (w0*s[0].vary.normal.y + w1*s[1].vary.normal.y + w2*s[2].vary.normal.y) / invW,
                           (w0*s[0].vary.normal.z + w1*s[1].vary.normal.z + w2*s[2].vary.normal.z) / invW };
            out.u = (w0*s[0].vary.u + w1*s[1].vary.u + w2*s[2].vary.u) / invW;
            out.v = (w0*s[0].vary.v + w1*s[1].vary.v + w2*s[2].vary.v) / invW;
            frag(x, y, out);
        }
}

// ---------- 场景 ----------
static const Vec3 LIGHT_DIR = norm({-0.5f, -1.0f, -0.35f});  // 光传播方向(与 07 示例一致)

int main(int argc, char** argv) {
    const char* outPath = argc > 1 ? argv[1] : "out.tga";
    Image img; img.init(W, H);
    std::vector<float> zbuf(size_t(W)*H, 1e30f);
    Checker checker;

    Mesh sphere = makeSphere(1.0f, 48, 64);
    Mesh ground = makeGround(3.5f, -1.4f, 7.0f);
    Mat4 sphereModel = rotationY(0.6f);
    Mat4 groundModel = Mat4::identity();
    Material sphereMat{{0.78f, 0.22f, 0.18f}, false, 0.5f, 64};
    Material groundMat{{}, true, 0.15f, 16};

    // ---- Pass 1: 光源深度遍 → 阴影图(docs/11 §1.1) ----
    Mat4 lightVP = mul(ortho(-5,5,-5,5,0.1f,30),
                       lookAt(LIGHT_DIR * -10.0f, {0,0,0}, {0,1,0}));
    std::vector<float> shadow(size_t(SMAP)*SMAP, 1e30f);
    auto depthFrag = [](int, int, const Varyings&) {};
    for (auto& t : sphere.tris) rasterize(sphere, t, sphereModel, lightVP, SMAP, SMAP, true, shadow, depthFrag);
    for (auto& t : ground.tris) rasterize(ground, t, groundModel, lightVP, SMAP, SMAP, true, shadow, depthFrag);

    // ---- Pass 2: 相机着色遍 ----
    Vec3 eye{2.2f, 1.6f, 4.2f};
    Mat4 camVP = mul(perspective(50.f*float(M_PI)/180, float(W)/H, 0.1f, 100),
                     lookAt(eye, {0,-0.4f,0}, {0,1,0}));
    Vec3 L = -LIGHT_DIR;                                  // 指向光源
    const Material* mat = &sphereMat;                     // immediate-mode 材质绑定(对应 draw 前的 setFragmentBytes)

    auto shade = [&](int x, int y, const Varyings& v) {
        Vec3 n = norm(v.normal);
        float ndl = std::max(0.f, dot(n, L));
        // 阴影测试: 重投影到光源 NDC + 斜率偏置 + 2x2 PCF(对照 07 示例)
        Vec3 lc = xformPoint(lightVP, v.world);
        float su = (lc.x + 1) * 0.5f, sv = (1 - (lc.y + 1)) * 0.5f;
        float bias = 0.0015f + (1 - ndl) * 0.004f;
        float lit = 0;
        for (int dy = -1; dy <= 0; dy++)
            for (int dx = -1; dx <= 0; dx++) {
                int tx = std::clamp(int(su*SMAP)+dx, 0, SMAP-1);
                int ty = std::clamp(int(sv*SMAP)+dy, 0, SMAP-1);
                lit += (lc.z - bias > shadow[size_t(ty)*SMAP+tx]) ? 0.f : 1.f;
            }
        lit *= 0.25f;
        // Blinn-Phong(docs/03 §2)
        Vec3 base = mat->checker ? checker.sample(v.u, v.v) : mat->albedo;
        Vec3 h = norm(L + norm(eye - v.world));
        float spec = mat->ks * std::pow(std::max(0.f, dot(n, h)), mat->shin);
        Vec3 c = base * (0.18f + 0.95f * ndl * lit) + Vec3{spec,spec,spec} * (ndl * lit);
        img.set(x, y, c);
    };
    mat = &groundMat;
    for (auto& t : ground.tris) rasterize(ground, t, groundModel, camVP, W, H, false, zbuf, shade);
    mat = &sphereMat;
    for (auto& t : sphere.tris) rasterize(sphere, t, sphereModel, camVP, W, H, false, zbuf, shade);

    if (!img.writeTGA(outPath)) { std::printf("写 %s 失败\n", outPath); return 1; }
    std::printf("已输出 %s (%dx%d), 阴影图 %dx%d, 近平面丢弃三角形 %d 个\n",
                outPath, W, H, SMAP, SMAP, g_clippedTris);
    return 0;
}
