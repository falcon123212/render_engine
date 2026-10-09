// Bench CUDA du cache a dependances - Windows et Linux (CUDA >= 12.8 pour les RTX 50).
// POC GPU : cache de lumiere a dependances (v3) vs accumulation classique, sur RTX.
//   poc_gpu timing  <scene.bin>
//   poc_gpu quality <scene.bin> <nseeds> <budget1,budget2,...>
//   poc_gpu scenf   <scene.bin> <nseeds> <scenarios.txt> [budget des baselines]
//   poc_gpu prep    <maillage.mesh> <scene.bin> [points]     (scenes publiques : voir prep_mesh.cuh)
// Scenes : format 2 = boites (exportees par Python), format 3 = maillages (BVH + grille de hachage des points de cache).
// BENCH_RAYONS=r : r rayons par point et par image, historiques en images (scenes publiques : 8).
// Sortie : lignes JSON sur stdout.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <cstdarg>
#include <map>
#include <cstdlib>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <psapi.h>
#pragma comment(lib, "psapi.lib")
static double cpu_seconds() {   // temps CPU du processus (utilisateur + noyau)
    FILETIME c, e, k, u; GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
    auto t = [](FILETIME f) { return (double)(((uint64_t)f.dwHighDateTime << 32) | f.dwLowDateTime) * 1e-7; };
    return t(k) + t(u);
}
static double ram_mb() { PROCESS_MEMORY_COUNTERS pc; GetProcessMemoryInfo(GetCurrentProcess(), &pc, sizeof(pc)); return pc.PeakWorkingSetSize / 1048576.0; }
static uint64_t now_ms() { return GetTickCount64(); }
#else   // Linux
#include <sys/resource.h>
#include <time.h>
static double cpu_seconds() {
    struct rusage u; getrusage(RUSAGE_SELF, &u);
    return u.ru_utime.tv_sec + u.ru_utime.tv_usec * 1e-6 + u.ru_stime.tv_sec + u.ru_stime.tv_usec * 1e-6;
}
static double ram_mb() { struct rusage u; getrusage(RUSAGE_SELF, &u); return u.ru_maxrss / 1024.0; }   // ko sous Linux
static uint64_t now_ms() { timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000ull + (uint64_t)(t.tv_nsec / 1000000); }
#endif
static double vram_used_mb() { size_t f, t; cudaMemGetInfo(&f, &t); return (t - f) / 1048576.0; }

#define CK(x) do { cudaError_t e_ = (x); if (e_ != cudaSuccess) { \
    fprintf(stderr, "CUDA %s @ %s:%d\n", cudaGetErrorString(e_), __FILE__, __LINE__); exit(1); } } while (0)

// ---------------------------------------------------------------------------------------------------------------
// Traces de debogage / debug traces
//  - NVTX (NVIDIA Tools Extension, livree avec le CUDA Toolkit) : plages nommees visibles dans Nsight Systems
//    (nsys profile --trace=cuda,nvtx ...). Toujours actives, cout negligeable.
//  - BENCH_DEBUG=1 : trace de chaque etape sur stderr + verification SYNCHRONE de chaque lancement de noyau
//    (cudaGetLastError + cudaDeviceSynchronize) : la premiere erreur GPU est attribuee au bon noyau.
//    BENCH_DEBUG=2 : trace aussi chaque appel de noyau (tres verbeux).
// ---------------------------------------------------------------------------------------------------------------
#if defined(__has_include)
#if __has_include(<nvtx3/nvToolsExt.h>)
#include <nvtx3/nvToolsExt.h>
#define HAVE_NVTX 1
#endif
#endif
#ifndef HAVE_NVTX
static inline int nvtxRangePushA(const char*) { return 0; }
static inline int nvtxRangePop() { return 0; }
static inline void nvtxMarkA(const char*) {}
#endif
static int g_debug = 0;
// BENCH_RAYONS : rayons par point de cache et par image (1 par defaut ; scenes publiques : 4, voir run_cuda.sh).
// Multiplie le budget de TOUTES les methodes : les comparaisons a temps egal sont inchangees.
static float g_rays = 1.f;
static std::map<std::string, long long>& kcount() { static std::map<std::string, long long> m; return m; }
static void DBG(const char* fmt, ...) {
    if (!g_debug) return;
    va_list a; va_start(a, fmt);
    fprintf(stderr, "[trace] "); vfprintf(stderr, fmt, a); fprintf(stderr, "\n"); fflush(stderr);
    va_end(a);
}
static void DBG_K(const char* name) {   // appele apres chaque lancement de noyau
    if (!g_debug) return;
    long long n = ++kcount()[name];
    cudaError_t e1 = cudaGetLastError();
    cudaError_t e2 = cudaDeviceSynchronize();
    if (e1 != cudaSuccess || e2 != cudaSuccess) {
        fprintf(stderr, "[trace] ERREUR GPU dans le noyau %s (appel %lld) : lancement = %s, execution = %s\n",
                name, n, cudaGetErrorString(e1), cudaGetErrorString(e2));
        fflush(stderr);
        exit(2);
    }
    if (n == 1 || g_debug >= 2) DBG("noyau %-20s appel %lld ok", name, n);
}
static void DBG_SUMMARY() {
    if (!g_debug) return;
    long long t = 0;
    for (auto& kv : kcount()) { DBG("bilan : %-20s %lld appels", kv.first.c_str(), kv.second); t += kv.second; }
    DBG("bilan : %lld lancements de noyaux verifies, aucune erreur", t);
}
struct NvtxScope { explicit NvtxScope(const char* n) { nvtxRangePushA(n); } ~NvtxScope() { nvtxRangePop(); } };

#ifndef GX
#define GX 16
#define GY 8
#define GZ 6
#endif
constexpr int VX = GX, VY = GY, VZ = GZ, NV = VX * VY * VZ, NW = NV / 32;   // grille de transit (compile-time)
static_assert(NV % 128 == 0, "masque multiple de 128 bits");
constexpr int FX = 16, FY = 8, FZ = 6;   // grille fine des voxels d'evenement exportes par Python
#ifndef NLIGHTS
#define NLIGHTS 3
#endif
constexpr int NL = NLIGHTS;
constexpr float X1 = 8.f, Y1 = 4.f, Z1 = 3.f;   // bornes des scenes en boites (format 2)
// Bornes de la grille de transit : (0,0,0)-(8,4,3) pour les scenes en boites, boite englobante pour les maillages (format 3)
__constant__ float c_lo[3] = {0.f, 0.f, 0.f};
__constant__ float c_ext[3] = {X1, Y1, Z1};
static float g_lo[3] = {0.f, 0.f, 0.f}, g_ext[3] = {X1, Y1, Z1};
constexpr int VERIF_FRAMES = 4;

// ------------------------------------------------------------------ outils device
struct f3 { float x, y, z; };
__device__ __forceinline__ f3 mk(float x, float y, float z) { return {x, y, z}; }
__device__ __forceinline__ f3 operator+(f3 a, f3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
__device__ __forceinline__ f3 operator-(f3 a, f3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
__device__ __forceinline__ f3 operator*(f3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
__device__ __forceinline__ float dot(f3 a, f3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
__device__ __forceinline__ f3 cross(f3 a, f3 b) { return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }
__device__ __forceinline__ f3 ld3(const float* p, int i) { return {p[3 * i], p[3 * i + 1], p[3 * i + 2]}; }

__device__ __forceinline__ uint32_t hash32(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; x ^= x >> 16; return x;
}
__device__ __forceinline__ float rnd(uint32_t& s) {
    s = s * 747796405u + 2891336453u;
    uint32_t w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    w = (w >> 22u) ^ w;
    return (w >> 8) * (1.0f / 16777216.0f);
}

__device__ __forceinline__ int vox_of(f3 p) {
    int i = min(max(int((p.x - c_lo[0]) / c_ext[0] * VX), 0), VX - 1);
    int j = min(max(int((p.y - c_lo[1]) / c_ext[1] * VY), 0), VY - 1);
    int k = min(max(int((p.z - c_lo[2]) / c_ext[2] * VZ), 0), VZ - 1);
    return (k * VY + j) * VX + i;
}
// parcours DDA (Amanatides-Woo) : uniquement les voxels traverses ; masque en memoire partagee
__device__ __forceinline__ void dda_seg(f3 a, f3 b, uint32_t* sm, int stride) {
    const float sx = VX / c_ext[0], sy = VY / c_ext[1], sz = VZ / c_ext[2];
    float ax = (a.x - c_lo[0]) * sx, ay = (a.y - c_lo[1]) * sy, az = (a.z - c_lo[2]) * sz;
    float bx = (b.x - c_lo[0]) * sx, by = (b.y - c_lo[1]) * sy, bz = (b.z - c_lo[2]) * sz;
    int ix = min(max(int(ax), 0), VX - 1), iy = min(max(int(ay), 0), VY - 1), iz = min(max(int(az), 0), VZ - 1);
    int ex = min(max(int(bx), 0), VX - 1), ey = min(max(int(by), 0), VY - 1), ez = min(max(int(bz), 0), VZ - 1);
    float dx = bx - ax, dy = by - ay, dz = bz - az;
    int stx = dx > 0 ? 1 : -1, sty = dy > 0 ? 1 : -1, stz = dz > 0 ? 1 : -1;
    float tdx = dx != 0 ? fabsf(1.f / dx) : 1e30f, tdy = dy != 0 ? fabsf(1.f / dy) : 1e30f, tdz = dz != 0 ? fabsf(1.f / dz) : 1e30f;
    float tmx = dx != 0 ? ((dx > 0 ? (ix + 1 - ax) : (ax - ix)) * tdx) : 1e30f;
    float tmy = dy != 0 ? ((dy > 0 ? (iy + 1 - ay) : (ay - iy)) * tdy) : 1e30f;
    float tmz = dz != 0 ? ((dz > 0 ? (iz + 1 - az) : (az - iz)) * tdz) : 1e30f;
    for (int g = 0; g < VX + VY + VZ; ++g) {
        int v = (iz * VY + iy) * VX + ix;
        sm[(v >> 5) * stride] |= 1u << (v & 31);
        if (ix == ex && iy == ey && iz == ez) break;
        if (tmx < tmy && tmx < tmz) { ix += stx; tmx += tdx; if (ix < 0 || ix >= VX) break; }
        else if (tmy < tmz) { iy += sty; tmy += tdy; if (iy < 0 || iy >= VY) break; }
        else { iz += stz; tmz += tdz; if (iz < 0 || iz >= VZ) break; }
    }
}

__device__ __forceinline__ void set_bit_reg(uint32_t (&m)[NW], int v) {
    uint32_t bit = 1u << (v & 31); int w0 = v >> 5;
#pragma unroll
    for (int w = 0; w < NW; ++w) m[w] |= (w == w0) ? bit : 0u;
}
__device__ __forceinline__ void dda_reg(f3 a, f3 b, uint32_t (&m)[NW]) {
    const float sx = VX / c_ext[0], sy = VY / c_ext[1], sz = VZ / c_ext[2];
    float ax = (a.x - c_lo[0]) * sx, ay = (a.y - c_lo[1]) * sy, az = (a.z - c_lo[2]) * sz;
    float bx = (b.x - c_lo[0]) * sx, by = (b.y - c_lo[1]) * sy, bz = (b.z - c_lo[2]) * sz;
    int ix = min(max(int(ax), 0), VX - 1), iy = min(max(int(ay), 0), VY - 1), iz = min(max(int(az), 0), VZ - 1);
    int ex = min(max(int(bx), 0), VX - 1), ey = min(max(int(by), 0), VY - 1), ez = min(max(int(bz), 0), VZ - 1);
    float dx = bx - ax, dy = by - ay, dz = bz - az;
    int stx = dx > 0 ? 1 : -1, sty = dy > 0 ? 1 : -1, stz = dz > 0 ? 1 : -1;
    float tdx = dx != 0 ? fabsf(1.f / dx) : 1e30f, tdy = dy != 0 ? fabsf(1.f / dy) : 1e30f, tdz = dz != 0 ? fabsf(1.f / dz) : 1e30f;
    float tmx = dx != 0 ? ((dx > 0 ? (ix + 1 - ax) : (ax - ix)) * tdx) : 1e30f;
    float tmy = dy != 0 ? ((dy > 0 ? (iy + 1 - ay) : (ay - iy)) * tdy) : 1e30f;
    float tmz = dz != 0 ? ((dz > 0 ? (iz + 1 - az) : (az - iz)) * tdz) : 1e30f;
    for (int g = 0; g < VX + VY + VZ; ++g) {
        set_bit_reg(m, (iz * VY + iy) * VX + ix);
        if (ix == ex && iy == ey && iz == ez) break;
        if (tmx < tmy && tmx < tmz) { ix += stx; tmx += tdx; if (ix < 0 || ix >= VX) break; }
        else if (tmy < tmz) { iy += sty; tmy += tdy; if (iy < 0 || iy >= VY) break; }
        else { iz += stz; tmz += tdz; if (iz < 0 || iz >= VZ) break; }
    }
}

__device__ __forceinline__ void rast_seg(f3 a, f3 b, uint32_t* m) {
    for (int s = 0; s < 20; ++s) {
        int v = vox_of(a + (b - a) * (s / 19.f));
        m[v >> 5] |= 1u << (v & 31);
    }
}

// triangles en memoire partagee
__device__ bool trace(f3 o, f3 d, const float* T, const int* TQ, int nt, float& tmin, int& q) {
    tmin = __int_as_float(0x7f800000); q = -1;
    for (int j = 0; j < nt; ++j) {
        f3 v0 = mk(T[9 * j], T[9 * j + 1], T[9 * j + 2]);
        f3 e1 = mk(T[9 * j + 3], T[9 * j + 4], T[9 * j + 5]);
        f3 e2 = mk(T[9 * j + 6], T[9 * j + 7], T[9 * j + 8]);
        f3 p = cross(d, e2);
        float det = dot(e1, p);
        if (fabsf(det) <= 1e-9f) continue;
        float inv = 1.f / det;
        f3 tv = o - v0;
        float u = dot(tv, p) * inv;
        if (u < 0.f) continue;
        f3 qv = cross(tv, e1);
        float v = dot(d, qv) * inv;
        if (v < 0.f || u + v > 1.f) continue;
        float t = dot(e2, qv) * inv;
        if (t > 1e-4f && t < tmin) { tmin = t; q = TQ[j]; }
    }
    return q >= 0;
}

struct DevState {
    float *P, *N, *Q, *T, *Edir, *ref, *Pw;
    int *dims, *off, *TQ;
    uint32_t* SV;
    uint8_t* valid;
    float inten[NL];
    int nt;
    // Maillages (format 3) : geometrie statique dans un BVH, points de cache retrouves par table de hachage spatiale
    const float* ST;                  // triangles statiques : v0, e1, e2 (9 flottants)
    const float4* STN;                // normale geometrique + drapeaux (w : bit 0 = double face)
    const float4* BN;                 // noeuds du BVH (2 float4 : bmin + gauche/premier, bmax + nombre)
    const unsigned long long* HK;     // cles de la table de hachage (0 = vide)
    const int* HV;                    // point de cache associe
    unsigned hmask;                   // taille de la table - 1
    float hcell;                      // taille d'une cellule de cache (m)
};

__device__ __forceinline__ int point_index(f3 H, int q, const DevState& s) {
    f3 o = ld3(s.Q + 12 * q, 0), u = ld3(s.Q + 12 * q, 1), v = ld3(s.Q + 12 * q, 2);
    f3 d = H - o;
    float a = dot(d, u) / dot(u, u), b = dot(d, v) / dot(v, v);
    int nu = s.dims[2 * q], nv = s.dims[2 * q + 1];
    int iu = min(max(int(a * nu), 0), nu - 1), iv = min(max(int(b * nv), 0), nv - 1);
    return s.off[q] + iv * nu + iu;
}

// ---------------------------------------------------------------- maillages (format 3)
// Cle d'une cellule de cache : cellule de cote hcell + direction dominante de la normale (6 seaux), comme la grille de
// hachage de SHaRC. Partagee hote / GPU.
__host__ __device__ __forceinline__ int normal_bucket(float nx, float ny, float nz) {
    float ax = fabsf(nx), ay = fabsf(ny), az = fabsf(nz);
    if (ax >= ay && ax >= az) return nx > 0.f ? 0 : 1;
    if (ay >= az) return ny > 0.f ? 2 : 3;
    return nz > 0.f ? 4 : 5;
}
__host__ __device__ __forceinline__ unsigned long long cell_key(int cx, int cy, int cz, int b) {
    return ((((unsigned long long)(cx & 0xFFFFF) << 20 | (unsigned long long)(cy & 0xFFFFF)) << 20 | (unsigned long long)(cz & 0xFFFFF)) << 3 | (unsigned long long)b) + 1ull;
}
__host__ __device__ __forceinline__ unsigned long long mix64(unsigned long long x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ull; x ^= x >> 27; x *= 0x94d049bb133111ebull; x ^= x >> 31; return x;
}
__device__ __forceinline__ int hash_find(const DevState& s, unsigned long long key) {
    unsigned h = (unsigned)mix64(key) & s.hmask;
    for (int probe = 0; probe < 64; ++probe) {
        unsigned long long k = __ldg(s.HK + h);
        if (k == key) return __ldg(s.HV + h);
        if (k == 0ull) return -1;
        h = (h + 1) & s.hmask;
    }
    return -1;
}
// point de cache d'un impact H sur une surface de normale n (cote touche) ; -1 si aucun (rare : cellule non echantillonnee)
__device__ int hash_point(const DevState& s, f3 H, f3 n) {
    int b = normal_bucket(n.x, n.y, n.z);
    float ih = 1.f / s.hcell;
    int cx = (int)floorf((H.x - c_lo[0]) * ih), cy = (int)floorf((H.y - c_lo[1]) * ih), cz = (int)floorf((H.z - c_lo[2]) * ih);
    int p = hash_find(s, cell_key(cx, cy, cz, b));
    if (p >= 0) return p;
    for (int d = 0; d < 27; ++d) {   // voisins (impact au bord d'une cellule)
        int dz = d / 9 - 1, dy = (d / 3) % 3 - 1, dx = d % 3 - 1;
        if (dx == 0 && dy == 0 && dz == 0) continue;
        p = hash_find(s, cell_key(cx + dx, cy + dy, cz + dz, b));
        if (p >= 0) return p;
    }
    return -1;
}
__device__ __forceinline__ float aabb_enter(float4 a, float4 b, f3 o, f3 inv, float tmax) {
    float tx1 = (a.x - o.x) * inv.x, tx2 = (b.x - o.x) * inv.x;
    float ty1 = (a.y - o.y) * inv.y, ty2 = (b.y - o.y) * inv.y;
    float tz1 = (a.z - o.z) * inv.z, tz2 = (b.z - o.z) * inv.z;
    float tn = fmaxf(fmaxf(fminf(tx1, tx2), fminf(ty1, ty2)), fmaxf(fminf(tz1, tz2), 0.f));
    float tf = fminf(fminf(fmaxf(tx1, tx2), fmaxf(ty1, ty2)), fminf(fmaxf(tz1, tz2), tmax));
    return tn <= tf ? tn : 1e30f;
}
// parcours du BVH statique (pile, enfant le plus proche d'abord) ; q = -2 - indice du triangle statique touche
__device__ void trace_bvh(f3 o, f3 d, const DevState& s, float& tmin, int& q) {
    f3 inv = mk(fabsf(d.x) > 1e-12f ? 1.f / d.x : copysignf(1e30f, d.x),
                fabsf(d.y) > 1e-12f ? 1.f / d.y : copysignf(1e30f, d.y),
                fabsf(d.z) > 1e-12f ? 1.f / d.z : copysignf(1e30f, d.z));
    int stack[64]; int sp = 0, node = 0;
    while (true) {
        float4 a = __ldg(s.BN + 2 * node), b = __ldg(s.BN + 2 * node + 1);
        int lf = __float_as_int(a.w), cnt = __float_as_int(b.w);
        if (cnt > 0) {
            for (int j = lf; j < lf + cnt; ++j) {
                const float* T = s.ST + 9 * (size_t)j;
                f3 v0 = mk(__ldg(T), __ldg(T + 1), __ldg(T + 2));
                f3 e1 = mk(__ldg(T + 3), __ldg(T + 4), __ldg(T + 5));
                f3 e2 = mk(__ldg(T + 6), __ldg(T + 7), __ldg(T + 8));
                f3 p = cross(d, e2);
                float det = dot(e1, p);
                if (fabsf(det) <= 1e-12f) continue;
                float iv = 1.f / det;
                f3 tv = o - v0;
                float u = dot(tv, p) * iv;
                if (u < 0.f || u > 1.f) continue;
                f3 qv = cross(tv, e1);
                float v = dot(d, qv) * iv;
                if (v < 0.f || u + v > 1.f) continue;
                float t = dot(e2, qv) * iv;
                if (t > 1e-4f && t < tmin) { tmin = t; q = -2 - j; }
            }
        } else {
            float4 la = __ldg(s.BN + 2 * lf), lb = __ldg(s.BN + 2 * lf + 1);
            float4 ra = __ldg(s.BN + 2 * lf + 2), rb = __ldg(s.BN + 2 * lf + 3);
            float tl = aabb_enter(la, lb, o, inv, tmin), tr = aabb_enter(ra, rb, o, inv, tmin);
            int first = lf, second = lf + 1;
            if (tr < tl) { float x = tl; tl = tr; tr = x; first = lf + 1; second = lf; }
            if (tl < 1e30f) {
                if (tr < 1e30f && sp < 64) stack[sp++] = second;
                node = first; continue;
            }
        }
        if (sp == 0) break;
        node = stack[--sp];
    }
}
// rayon complet : triangles dynamiques (memoire partagee) puis BVH statique s'il existe
__device__ __forceinline__ bool trace_full(f3 o, f3 d, const float* T, const int* TQ, const DevState& s, float& tmin, int& q) {
    bool h = trace(o, d, T, TQ, s.nt, tmin, q);
    if (s.BN) { trace_bvh(o, d, s, tmin, q); h = q != -1; }
    return h;
}
// point de cache touche (pi) ; renvoie vrai si l'impact ne compte pas (rien touche, face arriere, cellule absente)
__device__ __forceinline__ bool resolve_hit(const DevState& s, bool hit, f3 H, f3 D, int q, int i, int& pi) {
    if (!hit) { pi = i; return true; }
    if (q >= 0) { pi = point_index(H, q, s); return dot(ld3(s.Q + 12 * q, 3), D) > 0.f; }
    float4 n4 = __ldg(s.STN + (-2 - q));
    f3 n = mk(n4.x, n4.y, n4.z);
    if (dot(n, D) > 0.f) {
        if (!(__float_as_int(n4.w) & 1)) { pi = i; return true; }   // face arriere d'une surface simple face
        n = n * -1.f;
    }
    pi = hash_point(s, H, n);
    if (pi < 0) { pi = i; return true; }
    return false;
}

__device__ __forceinline__ f3 cosine_dir(f3 N, float u1, float u2) {
    float r = sqrtf(u1), phi = 6.28318530718f * u2;
    f3 a = fabsf(N.x) > 0.9f ? mk(0, 1, 0) : mk(1, 0, 0);
    f3 T = cross(N, a); T = T * rsqrtf(dot(T, T));
    f3 B = cross(N, T);
    return T * (r * cosf(phi)) + B * (r * sinf(phi)) + N * sqrtf(fmaxf(0.f, 1.f - u1));
}

// ------------------------------------------------------------- construction d'etat
__global__ void k_build(DevState s, const float* L, int Np) {
    extern __shared__ float sh[];
    int* shq = (int*)(sh + 9 * s.nt);
    for (int j = threadIdx.x; j < 9 * s.nt; j += blockDim.x) sh[j] = s.T[j];
    for (int j = threadIdx.x; j < s.nt; j += blockDim.x) shq[j] = s.TQ[j];
    __syncthreads();
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    f3 P = ld3(s.P, i), N = ld3(s.N, i), O = P + N * 1e-3f;
    uint32_t m[NW] = {0};
    for (int l = 0; l < NL; ++l) {
        f3 d = ld3(L, l) - P;
        float r = sqrtf(dot(d, d));
        f3 D = d * (1.f / r);
        float c = dot(N, D), t; int q;
        trace_full(O, D, sh, shq, s, t, q);
        bool vis = t >= r - 1e-3f;
        float rr = fmaxf(r, 0.05f);
        s.Edir[NL * i + l] = s.inten[l] * fmaxf(c, 0.f) / (rr * rr) * (vis ? 1.f : 0.f);
        rast_seg(O, O + D * fminf(t, r), m);
    }
    for (int w = 0; w < NW; ++w) s.SV[(size_t)NW * i + w] = m[w];
}

// ----------------------------------------------------------------- noyaux de frame
struct Cache {
    float *Lc, *Lc2, *m, *n, *c0;
    int* kk;
    uint8_t* pending;
    uint32_t *cur, *prev;
    float* rstat;       // 4 * NR : somme ecart, somme ecart^2, somme ref, compte
    float* dstat;       // 3 * NR : DDGI par zone : somme nouvelles mesures, somme cache, compte
    uint8_t* stale;     // v4-A : bit l = memoire dormante de la lampe l perimee pour ce point
    float* snap;        // v5 : instantanes de la lumiere par etat (KSNAP x Np x NL)
    float* neq;         // v5-B : equations normales par zone (NEQ par zone)
    float* coef;        // v5-B : coefficients de projection par zone (KSNAP par zone)
    float* age;         // v4-C : frames depuis la derniere reinitialisation
    float* sumpr;       // [2] : courant / suivant
    int* npend;         // [2]
    double* err;        // [3]
};

struct Params {
    int Np, NR, mode;   // mode 0 = classique, 1 = allocation adaptative (v3 / oracle)
    float budget, nmax;
    uint32_t seed, frame;
    int pend_left, deps;
    int resp_mask; float nmax_resp;                  // SHaRC "responsive lighting" (bit l = lampe dynamique)
    int ddgi; float ddgi_h, ddgi_thr; int ddgi_clamp; // DDGI : hysteresis + seuils
    int dormant;        // v4-A : bit l = lampe l en sommeil (canal gele, exclu du rendu)
    int ramp;           // v4-C : plafond d'historique apres reinitialisation
    int proj_left, projK; int slot[6];   // v5-B : fenetre de projection et instantanes utilises
    float rays;         // rayons par point et par image (BENCH_RAYONS)
};
constexpr int KSNAP = 6, NEQ = 28;      // 6 instantanes max ; 21 (matrice) + 6 (second membre) + 1 (compte)
constexpr int PROJ_FRAMES = 4;

// Un thread par point de cache : ses k rayons, la mise a jour de son masque de dependances (sans atomique).
__device__ __forceinline__ float est_of(const Cache& c, int i, int dormant) {
    float e = 0.f;
    for (int l = 0; l < NL; ++l) if (!((dormant >> l) & 1)) e += c.Lc[NL * i + l];
    return e;
}

template <bool DEPS>
__global__ void k_trace2(DevState s, Cache c, Params p, const int* region, const float* Alb) {
    extern __shared__ float sh[];
    int* shq = (int*)(sh + 9 * s.nt);
    for (int j = threadIdx.x; j < 9 * s.nt; j += blockDim.x) sh[j] = s.T[j];
    for (int j = threadIdx.x; j < s.nt; j += blockDim.x) shq[j] = s.TQ[j];
    __syncthreads();
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= p.Np) return;
    uint32_t rs = hash32(p.seed * 0x9E3779B9u ^ hash32(p.frame * 0x85EBCA6Bu ^ hash32(i + 1)));
    int k;
    bool pend = p.pend_left > 0 && c.pending[i];
    if (p.mode == 0) {
        float kb = floorf(p.budget);
        k = int(kb) + (rnd(rs) < p.budget - kb ? 1 : 0);
    } else {
        float pr = 1.f / (c.n[i] + 1.f);
        float rrest = float(p.Np - c.npend[0]);
        float e = rrest * (0.5f / p.Np + 0.5f * pr / c.sumpr[0]) * p.rays;
        float eb = floorf(e);
        k = (pend ? 1 : 0) + int(eb) + (rnd(rs) < e - eb ? 1 : 0);
    }
    f3 P = ld3(s.P, i), N = ld3(s.N, i), O = P + N * 1e-3f;
    float acc[NL] = {0, 0, 0};
    uint32_t m[NW];                                    // masque en registres (indices statiques uniquement)
#pragma unroll
    for (int w = 0; w < NW; ++w) m[w] = 0;
    float c0 = pend ? c.c0[i] : 0.f;
    int rg = pend ? region[i] : 0;
    float sd = 0.f, sq = 0.f;
    for (int r = 0; r < k; ++r) {
        f3 D = cosine_dir(N, rnd(rs), rnd(rs));
        float t; int q;
        bool hit = trace_full(O, D, sh, shq, s, t, q);
        f3 H = hit ? O + D * t : O;
        int pi;
        bool back = resolve_hit(s, hit, H, D, q, i, pi);
        float val = 0.f;
        if (!back) {
            float A = Alb[pi];
            for (int l = 0; l < NL; ++l) {
                float lc = ((p.dormant >> l) & 1) ? 0.f : c.Lc[NL * pi + l];
                float v = A * (s.Edir[NL * pi + l] + lc);                   // multi-rebonds via le cache
                acc[l] += v;
                val += v;
            }
        }
        if (DEPS) {
            int src = back ? i : pi;                              // rayons d'ombre deja lances au point touche
            const uint4* sv = (const uint4*)(s.SV + (size_t)NW * src);   // 96 octets contigus : 6 lectures de 16 o
#pragma unroll
            for (int w = 0; w < NW / 4; ++w) {
                uint4 x = __ldg(sv + w);
                m[4 * w] |= x.x; m[4 * w + 1] |= x.y; m[4 * w + 2] |= x.z; m[4 * w + 3] |= x.w;
            }
            dda_reg(O, H, m);
        }
        if (pend) { float dv = val - c0; sd += dv; sq += dv * dv; }
    }
    if (pend && k > 0) {
        atomicAdd(&c.rstat[4 * rg + 0], sd);
        atomicAdd(&c.rstat[4 * rg + 1], sq);
        atomicAdd(&c.rstat[4 * rg + 2], c0 * k);
        atomicAdd(&c.rstat[4 * rg + 3], float(k));
    }
    if (p.proj_left > 0 && k > 0) {
        // v5-B : E_ind(i) ~ sum_a coef_a(zone) * T_a(i), T_a = instantane a (lampes actives), moindres carres par zone
        float T[KSNAP];
        for (int a = 0; a < p.projK; ++a) {
            const float* sp = c.snap + ((size_t)p.slot[a] * p.Np + i) * NL;
            float t = 0.f;
            for (int l = 0; l < NL; ++l) if (!((p.dormant >> l) & 1)) t += sp[l];
            T[a] = t;
        }
        float sv = 0.f; for (int l = 0; l < NL; ++l) sv += acc[l];
        float* q = c.neq + (size_t)region[i] * NEQ;
        int ix = 0;
        for (int a = 0; a < p.projK; ++a) for (int b = a; b < p.projK; ++b) atomicAdd(&q[ix++], k * T[a] * T[b]);
        for (int a = 0; a < p.projK; ++a) atomicAdd(&q[21 + a], sv * T[a]);
        atomicAdd(&q[27], float(k));
    }
    c.kk[i] = k;
    float ik = k > 0 ? 1.f / k : 0.f;
    for (int l = 0; l < NL; ++l) c.m[NL * i + l] = acc[l] * ik;
    if (p.ddgi && k > 0) {
        int rgd = region[i];
        float sa = 0.f; for (int l = 0; l < NL; ++l) sa += acc[l];
        atomicAdd(&c.dstat[3 * rgd + 0], sa * ik);
        atomicAdd(&c.dstat[3 * rgd + 1], est_of(c, i, p.dormant));
        atomicAdd(&c.dstat[3 * rgd + 2], 1.f);
    }
    if (DEPS && k > 0)
#pragma unroll
        for (int w = 0; w < NW; ++w) {
            uint32_t old = c.cur[(size_t)w * p.Np + i];
            if ((old | m[w]) != old) c.cur[(size_t)w * p.Np + i] = old | m[w];   // ecriture seulement si nouveaux bits
        }
}

__global__ void k_decide(Cache c, Params p, const int* region) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= p.Np) return;
    if (!c.pending[i]) return;
    const float* r4 = c.rstat + 4 * region[i];
    float cnt = r4[3];
    bool done = false;
    if (cnt >= 8.f) {
        float mean = r4[0] / cnt;
        float se = sqrtf(fmaxf(r4[1] / cnt - mean * mean, 0.f) / cnt);
        float base = r4[2] / cnt;
        float rel = mean / base;
        if (fabsf(mean) > 2.f * se && fabsf(rel) > 0.03f) {
            float tgt = fminf(fmaxf(0.5f / fabsf(rel), 1.f) * p.rays, p.nmax);
            c.n[i] = fminf(c.n[i], tgt);
            c.pending[i] = 0;
            done = true;
        }
    }
    if (!done) {
        if (p.pend_left <= 1) c.pending[i] = 0;          // fin de fenetre : on garde l'historique
        else atomicAdd(&c.npend[1], 1);
    }
}

__device__ __forceinline__ float warp_sum(float v) {
    for (int o = 16; o > 0; o >>= 1) v += __shfl_down_sync(0xffffffffu, v, o);
    return v;
}

__global__ void k_update(Cache c, Params p, const int* region) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float pr = 0.f;
    if (i < p.Np) {
        int k = c.kk[i];
        float n = c.n[i], nn = n + k;
        float nmx = p.nmax;
        if (p.ramp) { float a = c.age[i]; nmx = fminf(p.nmax, (4.f + 0.5f * a) * p.rays); c.age[i] = fminf(a + 1.f, 1e4f); }
        float alpha = k > 0 ? fminf(k / fminf(fmaxf(nn, 1.f), nmx), 1.f) : 0.f;
        if (p.ddgi) {
            // DDGI (ProbeBlendingCS) : ecart mesure par zone (equivalent d'une sonde a nombreux rayons)
            const float* d3 = c.dstat + 3 * region[i];
            float scale = 1.f;
            float h = p.ddgi_h;
            if (d3[2] > 0.f) {
                float mn = d3[0] / d3[2], mc = d3[1] / d3[2];
                float rel = fabsf(mn - mc) / fmaxf(mc, 1e-3f);
                if (rel > p.ddgi_thr) h = fmaxf(0.f, h - 0.75f);          // grand changement : hysteresis reduite
                if (p.ddgi_clamp && rel > 0.10f) scale = 0.25f;           // grand saut de luminosite : pas borne
            }
            float w = k > 0 ? (1.f - h) * scale : 0.f;
            for (int l = 0; l < NL; ++l) {
                float a = c.Lc[NL * i + l];
                c.Lc2[NL * i + l] = ((p.dormant >> l) & 1) ? a : a + w * (c.m[NL * i + l] - a);
            }
        } else {
            float alpha_r = k > 0 ? fminf(k / fminf(fmaxf(nn, 1.f), p.nmax_resp), 1.f) : 0.f;
            for (int l = 0; l < NL; ++l) {
                float a = c.Lc[NL * i + l];
                float al = ((p.resp_mask >> l) & 1) ? alpha_r : alpha;     // SHaRC : lampes "responsive"
                if ((p.dormant >> l) & 1) al = 0.f;                        // v4-A : canal en sommeil gele
                c.Lc2[NL * i + l] = a + al * (c.m[NL * i + l] - a);
            }
        }
        n = fminf(nn, nmx);
        c.n[i] = n;
        pr = 1.f / (n + 1.f);
    }
    pr = warp_sum(pr);
    if ((threadIdx.x & 31) == 0) atomicAdd(&c.sumpr[1], pr);
}

__global__ void k_sumpr(Cache c, int Np) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    float pr = i < Np ? 1.f / (c.n[i] + 1.f) : 0.f;
    pr = warp_sum(pr);
    if ((threadIdx.x & 31) == 0) atomicAdd(&c.sumpr[0], pr);
}

// v5-A : etat deja vu restaure -> confiance haute, mais verifie (v3)
__global__ void k_restored(Cache c, int Np, float nmax, int dormant, int verify) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    c.n[i] = nmax; c.age[i] = 1e4f; c.pending[i] = 0;
    if (verify) { c.pending[i] = 1; c.c0[i] = est_of(c, i, dormant); atomicAdd(&c.npend[1], 1); }
}

// v5-B : cellules recemment invalidees -> combinaison des instantanes ajustee par zone, puis verifiee
__global__ void k_proj_apply(Cache c, Params p, const int* region) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= p.Np) return;
    if (c.n[i] >= 16.f) return;
    const float* cf = c.coef + (size_t)region[i] * KSNAP;
    if (isnan(cf[0])) return;
    for (int l = 0; l < NL; ++l) {
        if ((p.dormant >> l) & 1) continue;
        float v = 0.f;
        for (int a = 0; a < p.projK; ++a) v += cf[a] * c.snap[((size_t)p.slot[a] * p.Np + i) * NL + l];
        c.Lc[NL * i + l] = fmaxf(v, 0.f);
    }
    c.n[i] = 8.f * p.rays; c.age[i] = 8.f;
    c.pending[i] = 1; c.c0[i] = est_of(c, i, p.dormant);
    atomicAdd(&c.npend[1], 1);
}

__global__ void k_rescale(Cache c, int Np, int l, float ratio) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < Np) c.Lc[NL * i + l] *= ratio;
}

__global__ void k_touched(Cache c, int Np, const int* V, int nv, int kind, int dormant) {
    // kind 0 : emetteur apparu -> reset ; kind 1 : occulteur -> verification (v3)
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    bool t = false;
    for (int j = 0; j < nv && !t; ++j) {
        int v = V[j];
        size_t o = (size_t)(v >> 5) * Np + i;
        t = ((c.cur[o] | c.prev[o]) >> (v & 31)) & 1u;
    }
    if (!t) return;
    if (kind == 0) { c.n[i] = 0.f; c.age[i] = 0.f; }
    else if (kind == 1) {
        c.pending[i] = 1;
        c.c0[i] = est_of(c, i, dormant);
        atomicAdd(&c.npend[1], 1);
    }
    if (kind >= 1 && dormant) c.stale[i] |= (uint8_t)dormant;   // v4-A : memoire dormante perimee ici
}

// v4-A : reveil d'une lampe. Memoire valide : restauree (deja remise a l'echelle). Perimee : canal remis a zero.
__global__ void k_wake(Cache c, int Np, int l, int verify, int dormant) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    if ((c.stale[i] >> l) & 1) {
        if (verify) {   // v4-A2 : la memoire sert de point de depart, la verification decide
            c.pending[i] = 1;
            c.c0[i] = est_of(c, i, dormant);
            atomicAdd(&c.npend[1], 1);
        } else { c.Lc[NL * i + l] = 0.f; c.n[i] = 0.f; c.age[i] = 0.f; }
        c.stale[i] &= (uint8_t)~(1u << l);
    }
}

__global__ void k_oracle(Cache c, int Np, const float* rold, const float* rnew) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    float rel = fabsf(rnew[i] - rold[i]) / (rold[i] + 1e-2f);
    c.n[i] *= 1.f - fminf(fmaxf(4.f * rel, 0.f), 1.f);
}

__global__ void k_error(Cache c, int Np, const float* ref, const uint8_t* valid, int dormant) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    double d2 = 0, rs = 0, cnt = 0;
    if (i < Np && valid[i]) {
        float e = est_of(c, i, dormant) - ref[i];
        d2 = double(e) * e; rs = ref[i]; cnt = 1;
    }
    for (int o = 16; o > 0; o >>= 1) {
        d2 += __shfl_down_sync(0xffffffffu, d2, o);
        rs += __shfl_down_sync(0xffffffffu, rs, o);
        cnt += __shfl_down_sync(0xffffffffu, cnt, o);
    }
    if ((threadIdx.x & 31) == 0) { atomicAdd(&c.err[0], d2); atomicAdd(&c.err[1], rs); atomicAdd(&c.err[2], cnt); }
}

__global__ void k_accum_est(Cache c, int Np, float* sum, float* sq, int dormant) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    float e = est_of(c, i, dormant);
    sum[i] += e; sq[i] += e * e;
}

// ------------------------------------------------------------------------ hote
template <class T> T* dalloc(size_t n) { T* p; CK(cudaMalloc(&p, n * sizeof(T) + 16)); return p; }
template <class T> T* dput(const std::vector<T>& v) { T* p = dalloc<T>(v.size()); CK(cudaMemcpy(p, v.data(), v.size() * sizeof(T), cudaMemcpyHostToDevice)); return p; }

static void set_bounds(const float lo[3], const float ext[3]) {
    for (int a = 0; a < 3; ++a) { g_lo[a] = lo[a]; g_ext[a] = ext[a]; }
    CK(cudaMemcpyToSymbol(c_lo, g_lo, sizeof g_lo)); CK(cudaMemcpyToSymbol(c_ext, g_ext, sizeof g_ext));
}
static int host_vox(const float* p) {   // voxel de la grille de transit (bornes courantes)
    int i = std::min(std::max(int((p[0] - g_lo[0]) / g_ext[0] * VX), 0), VX - 1);
    int j = std::min(std::max(int((p[1] - g_lo[1]) / g_ext[1] * VY), 0), VY - 1);
    int k = std::min(std::max(int((p[2] - g_lo[2]) / g_ext[2] * VZ), 0), VZ - 1);
    return (k * VY + j) * VX + i;
}

static std::vector<int> to_grid(const std::vector<int>& fine) {
    std::vector<char> mark(NV, 0);
    for (int v : fine) {
        int i = v % FX, j = (v / FX) % FY, k = v / (FX * FY);
        float x0 = i * X1 / FX, x1 = (i + 1) * X1 / FX, y0 = j * Y1 / FY, y1 = (j + 1) * Y1 / FY;
        float z0 = k * Z1 / FZ, z1 = (k + 1) * Z1 / FZ;
        int a0 = std::min(int(x0 / X1 * VX + 1e-4f), VX - 1), a1 = std::min(int(x1 / X1 * VX - 1e-4f), VX - 1);
        int b0 = std::min(int(y0 / Y1 * VY + 1e-4f), VY - 1), b1 = std::min(int(y1 / Y1 * VY - 1e-4f), VY - 1);
        int c0 = std::min(int(z0 / Z1 * VZ + 1e-4f), VZ - 1), c1 = std::min(int(z1 / Z1 * VZ - 1e-4f), VZ - 1);
        for (int a = a0; a <= a1; ++a) for (int b = b0; b <= b1; ++b) for (int cc = c0; cc <= c1; ++cc)
            mark[(cc * VY + b) * VX + a] = 1;
    }
    std::vector<int> out;
    for (int v = 0; v < NV; ++v) if (mark[v]) out.push_back(v);
    return out;
}

struct Scene {
    int Np, Nq, Nt, NS, nl, NR, has_ref, fmt = 2;
    std::vector<int> hdims, hoff;
    std::vector<float> L, A;
    std::vector<int> region;
    std::vector<DevState> st;
    std::vector<std::vector<float>> inten;
    std::vector<std::vector<int>> occ, em;
    float *dL, *dA; int* dRegion;
    int nst = 0, nnodes = 0, npst = 0; float hcell = 0.f;   // format 3
};

template <class T> void rd(FILE* f, std::vector<T>& v, size_t n) { v.resize(n); if (n && fread(v.data(), sizeof(T), n, f) != n) { fprintf(stderr, "lecture\n"); exit(1); } }

Scene load(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fichier %s\n", path); exit(1); }
    int h[8]; fread(h, 4, 8, f);
    if (h[4] != NL) { fprintf(stderr, "scene a %d lampes, programme compile pour %d (-DNLIGHTS)\n", h[4], NL); exit(1); }
    if (h[7] != 2 && h[7] != 3) { fprintf(stderr, "format de scene %d non supporte (reexporter)\n", h[7]); exit(1); }
    Scene S; S.Np = h[0]; S.Nq = h[1]; S.Nt = h[2]; S.NS = h[3]; S.nl = h[4]; S.NR = h[5]; S.has_ref = h[6]; S.fmt = h[7];
    // format 3 (maillage) : bornes, geometrie statique + BVH, table de hachage des points de cache
    const float *dST = nullptr; const float4 *dSTN = nullptr, *dBN = nullptr; const unsigned long long* dHK = nullptr; const int* dHV = nullptr;
    unsigned hmask = 0; float hcell = 0.f;
    if (S.fmt == 3) {
        float lo[3], ext[3]; int m[4];
        if (fread(lo, 4, 3, f) != 3 || fread(ext, 4, 3, f) != 3 || fread(&hcell, 4, 1, f) != 1 || fread(m, 4, 4, f) != 4) { fprintf(stderr, "lecture\n"); exit(1); }
        std::vector<float> ST, STN, BN; std::vector<unsigned long long> HK; std::vector<int> HV;
        rd(f, ST, 9 * (size_t)m[0]); rd(f, STN, 4 * (size_t)m[0]); rd(f, BN, 8 * (size_t)m[1]); rd(f, HK, (size_t)m[2]); rd(f, HV, (size_t)m[2]);
        dST = dput(ST); dSTN = (const float4*)dput(STN); dBN = (const float4*)dput(BN); dHK = dput(HK); dHV = dput(HV);
        hmask = (unsigned)m[2] - 1;
        S.nst = m[0]; S.nnodes = m[1]; S.npst = m[3]; S.hcell = hcell;
        set_bounds(lo, ext);
    }
    rd(f, S.L, 3 * NL); rd(f, S.A, S.Np); rd(f, S.region, S.Np);
    for (int s = 0; s < S.NS; ++s) {
        std::vector<float> in, P, N, Q, T, ref, Pw; std::vector<int> dims, off, TQ; std::vector<uint8_t> valid;
        rd(f, in, NL); rd(f, P, 3 * S.Np); rd(f, N, 3 * S.Np); rd(f, Q, 12 * S.Nq); rd(f, dims, 2 * S.Nq); rd(f, off, S.Nq);
        rd(f, T, 9 * S.Nt); rd(f, TQ, S.Nt);
        DevState d{};
        if (S.has_ref) { rd(f, ref, S.Np); rd(f, valid, S.Np); rd(f, Pw, (size_t)NL * S.Np); d.ref = dput(ref); d.valid = dput(valid); d.Pw = dput(Pw); }
        d.P = dput(P); d.N = dput(N); d.Q = dput(Q); d.T = dput(T); d.dims = dput(dims); d.off = dput(off); d.TQ = dput(TQ);
        d.Edir = dalloc<float>(NL * (size_t)S.Np); d.SV = dalloc<uint32_t>(NW * (size_t)S.Np);
        for (int l = 0; l < NL; ++l) d.inten[l] = in[l];
        d.nt = S.Nt;
        d.ST = dST; d.STN = dSTN; d.BN = dBN; d.HK = dHK; d.HV = dHV; d.hmask = hmask; d.hcell = hcell;
        if (S.hdims.empty()) { S.hdims = dims; S.hoff = off; }
        S.st.push_back(d); S.inten.push_back(in);
    }
    for (int e = 0; e < S.NS * S.NS; ++e) {
        int no; fread(&no, 4, 1, f);
        std::vector<int> o; rd(f, o, no); S.occ.push_back(S.fmt == 3 ? o : to_grid(o));   // format 3 : deja sur la grille de transit
        for (int l = 0; l < NL; ++l) {             // voxel de chaque lampe qui s'allume
            int ne; fread(&ne, 4, 1, f);
            std::vector<int> m; rd(f, m, ne); S.em.push_back(S.fmt == 3 ? m : to_grid(m));
        }
    }
    fclose(f);
    S.dL = dput(S.L); S.dA = dput(S.A); S.dRegion = dput(S.region);
    int B = 256, G = (S.Np + B - 1) / B;
    size_t shm = S.Nt * 10 * sizeof(float);
    for (auto& d : S.st) (k_build<<<G, B, shm>>>(d, S.dL, S.Np), DBG_K("k_build"));
    CK(cudaDeviceSynchronize());
    return S;
}

struct Method { std::string name; int mode; float nmax, budget; bool deps, verify, oracle; int track_every = 1; bool rescale = false;
                int resp_mask = 0; float nmax_resp = 8.f; bool ddgi = false; float ddgi_h = 0.97f, ddgi_thr = 0.25f; bool ddgi_clamp = true;
                bool memory = false, ramp = false, wake_verify = false, snaps = false, proj = false, snap_verify = false; };

struct Timers { double trace = 0, decide = 0, update = 0, swap = 0, event = 0; int frames = 0, events = 0; };

struct Runner {
    Scene& S; Cache c; int B = 256, G;
    std::vector<int*> dOcc, dEm;
    Runner(Scene& s) : S(s) {
        size_t Np = S.Np;
        c.Lc = dalloc<float>(NL * Np); c.Lc2 = dalloc<float>(NL * Np); c.m = dalloc<float>(NL * Np);
        c.n = dalloc<float>(Np); c.c0 = dalloc<float>(Np); c.kk = dalloc<int>(Np); c.pending = dalloc<uint8_t>(Np);
        c.cur = dalloc<uint32_t>(NW * Np); c.prev = dalloc<uint32_t>(NW * Np);
        c.stale = dalloc<uint8_t>(Np); c.age = dalloc<float>(Np);
        c.snap = dalloc<float>((size_t)KSNAP * Np * NL); c.neq = dalloc<float>((size_t)S.NR * NEQ); c.coef = dalloc<float>((size_t)S.NR * KSNAP);
        c.rstat = dalloc<float>(4 * S.NR); c.dstat = dalloc<float>(3 * S.NR); c.sumpr = dalloc<float>(2); c.npend = dalloc<int>(2); c.err = dalloc<double>(3);
        G = (S.Np + B - 1) / B;
        for (int e = 0; e < S.NS * S.NS; ++e) dOcc.push_back(dput(S.occ[e].empty() ? std::vector<int>{0} : S.occ[e]));
        for (size_t e = 0; e < S.em.size(); ++e) dEm.push_back(dput(S.em[e].empty() ? std::vector<int>{0} : S.em[e]));
    }
    // seq : indice d'etat par frame. Renvoie l'erreur par frame (si ref et want_err).
    float *rec_sum = nullptr, *rec_sq = nullptr; int rec_f0 = 0, rec_nf = 0;
    std::vector<float> run(const Method& M, const std::vector<int>& seq, uint32_t seed, bool want_err, Timers* tm) {
        NvtxScope nvtx_run(M.name.c_str());
        DBG("run : methode \"%s\", graine %u, %zu images", M.name.c_str(), seed, seq.size());
        size_t Np = S.Np;
        int s0 = seq[0];
        // demarrage a chaud
        if (S.has_ref) CK(cudaMemcpy(c.Lc, S.st[s0].Pw, NL * Np * 4, cudaMemcpyDeviceToDevice));
        else CK(cudaMemset(c.Lc, 0, NL * Np * 4));
        const float nmax = M.nmax * g_rays;   // historique plafonne en images (x rayons par point)
        std::vector<float> nm(Np, nmax); CK(cudaMemcpy(c.n, nm.data(), Np * 4, cudaMemcpyHostToDevice));
        CK(cudaMemset(c.pending, 0, Np)); CK(cudaMemset(c.cur, 0, NW * Np * 4)); CK(cudaMemset(c.prev, 0, NW * Np * 4));
        CK(cudaMemset(c.stale, 0, Np));
        { std::vector<float> ag(Np, 1e4f); CK(cudaMemcpy(c.age, ag.data(), Np * 4, cudaMemcpyHostToDevice)); }
        int dormant = 0; float ilearn[NL] = {0, 0, 0};
        float sp[2] = {float(Np) / (nmax + 1.f), 0.f}; CK(cudaMemcpy(c.sumpr, sp, 8, cudaMemcpyHostToDevice));
        int z2[2] = {0, 0}; CK(cudaMemcpy(c.npend, z2, 8, cudaMemcpyHostToDevice));
        Params p{S.Np, S.NR, M.mode, M.budget, M.nmax, seed, 0, 0, M.deps,
                 M.resp_mask, M.nmax_resp, M.ddgi ? 1 : 0, M.ddgi_h, M.ddgi_thr, M.ddgi_clamp ? 1 : 0, 0, M.ramp ? 1 : 0};
        p.rays = g_rays; p.budget = M.budget * g_rays; p.nmax = nmax; p.nmax_resp = M.nmax_resp * g_rays;
        cudaEvent_t ev[6]; for (auto& e : ev) cudaEventCreate(&e);
        size_t shm = S.Nt * 10 * sizeof(float);
        std::vector<float> errs;
        int pend_left = 0;
        int nslots = 0, slot_state[KSNAP], slot_next = 0, last_event_f = 0, proj_left = 0;
        for (int k = 0; k < KSNAP; ++k) slot_state[k] = -1;
        for (size_t f = 0; f < seq.size(); ++f) {
            int si = seq[f];
            DevState& st = S.st[si];
            p.frame = (uint32_t)f;
            // ---- evenement signale par le moteur
            if (f > 0 && seq[f - 1] != si) {
                int e = seq[f - 1];
                int pe = e * S.NS + si;   // paire d'etats (e -> si)
                NvtxScope nvtx_ev("evenement");
                if (g_debug >= 2 || f < 400) DBG("  image %zu : evenement, etat %d -> %d", f, e, si);
                if (tm) cudaEventRecord(ev[4]);
                if (M.snaps && (int)f - last_event_f >= 20) {   // v5 : instantane de l'etat qu'on quitte
                    int k = -1;
                    for (int a = 0; a < nslots; ++a) if (slot_state[a] == e) k = a;
                    if (k < 0) { if (nslots < KSNAP) k = nslots++; else { k = slot_next; slot_next = (slot_next + 1) % KSNAP; } }
                    slot_state[k] = e;
                    CK(cudaMemcpy(c.snap + (size_t)k * Np * NL, c.Lc, (size_t)Np * NL * 4, cudaMemcpyDeviceToDevice));
                }
                if (M.oracle && S.has_ref) (k_oracle<<<G, B>>>(c, S.Np, S.st[e].ref, st.ref), DBG_K("k_oracle"));
                if (M.rescale && !M.deps) {   // classique renforce : stockage par lampe + mise a l'echelle (technique connue)
                    for (int l = 0; l < NL; ++l) {
                        float a = S.inten[e][l], b = S.inten[si][l];
                        if (a == b) continue;
                        if (M.memory && a > 0 && b == 0) { dormant |= 1 << l; ilearn[l] = a; }          // memoire naive
                        else if (M.memory && a == 0 && b > 0 && ((dormant >> l) & 1)) {                 // restauree telle quelle
                            (k_rescale<<<G, B>>>(c, S.Np, l, b / ilearn[l]), DBG_K("k_rescale")); dormant &= ~(1 << l);
                        } else if (a > 0) (k_rescale<<<G, B>>>(c, S.Np, l, b / a), DBG_K("k_rescale"));
                    }
                }
                if (M.deps) {
                    int woke = 0;
                    for (int l = 0; l < NL; ++l) {
                        float a = S.inten[e][l], b = S.inten[si][l];
                        if (a == b) continue;
                        if (M.memory && a > 0 && b == 0) {            // v4-A : mise en sommeil (pas d'effacement)
                            dormant |= 1 << l; ilearn[l] = a;
                        } else if (M.memory && a == 0 && b > 0 && ((dormant >> l) & 1)) {   // v4-A : reveil
                            (k_rescale<<<G, B>>>(c, S.Np, l, b / ilearn[l]), DBG_K("k_rescale"));
                            dormant &= ~(1 << l); woke |= 1 << l;
                            if (M.wake_verify) {
                                CK(cudaMemset(c.npend, 0, 8));
                                CK(cudaMemset(c.rstat, 0, 4 * S.NR * 4));
                                (k_wake<<<G, B>>>(c, S.Np, l, 1, dormant), DBG_K("k_wake"));
                                CK(cudaMemcpy(c.npend, c.npend + 1, 4, cudaMemcpyDeviceToDevice));
                                pend_left = VERIF_FRAMES;
                            } else (k_wake<<<G, B>>>(c, S.Np, l, 0, dormant), DBG_K("k_wake"));
                        } else if (a > 0) (k_rescale<<<G, B>>>(c, S.Np, l, b / a), DBG_K("k_rescale"));    // linearite
                    }
                    for (int l = 0; l < NL; ++l) {        // lampe neuve (sans memoire) : cellules concernees reinitialisees
                        int ix = pe * NL + l;
                        if (!S.em[ix].empty() && !((woke >> l) & 1)) (k_touched<<<G, B>>>(c, S.Np, dEm[ix], (int)S.em[ix].size(), 0, dormant), DBG_K("k_touched"));
                    }
                    if (!S.occ[pe].empty()) {
                        if (M.verify) {
                            CK(cudaMemset(c.npend, 0, 8));
                            CK(cudaMemset(c.rstat, 0, 4 * S.NR * 4));
                            (k_touched<<<G, B>>>(c, S.Np, dOcc[pe], (int)S.occ[pe].size(), 1, dormant), DBG_K("k_touched"));
                            CK(cudaMemcpy(c.npend, c.npend + 1, 4, cudaMemcpyDeviceToDevice));
                            pend_left = VERIF_FRAMES;
                        } else if (dormant) (k_touched<<<G, B>>>(c, S.Np, dOcc[pe], (int)S.occ[pe].size(), 2, dormant), DBG_K("k_touched"));
                    }
                }
                if (M.snaps) {
                    int hit = -1;
                    for (int a = 0; a < nslots; ++a) if (slot_state[a] == si) hit = a;
                    if (hit >= 0) {                                   // v5-A : etat deja vu -> restaure puis verifie
                        CK(cudaMemcpy(c.Lc, c.snap + (size_t)hit * Np * NL, (size_t)Np * NL * 4, cudaMemcpyDeviceToDevice));
                        if (M.snap_verify) {
                            CK(cudaMemset(c.npend, 0, 8));
                            CK(cudaMemset(c.rstat, 0, 4 * S.NR * 4));
                            (k_restored<<<G, B>>>(c, S.Np, nmax, dormant, 1), DBG_K("k_restored"));
                            CK(cudaMemcpy(c.npend, c.npend + 1, 4, cudaMemcpyDeviceToDevice));
                            pend_left = VERIF_FRAMES;
                        } else {   // meme cle d'etat -> instantane valide par construction : pas de verification
                            (k_restored<<<G, B>>>(c, S.Np, nmax, dormant, 0), DBG_K("k_restored"));
                            CK(cudaMemset(c.npend, 0, 8));
                            pend_left = 0;
                        }
                        proj_left = 0;
                    } else if (M.proj && nslots >= 2) {               // v5-B : etat nouveau -> projection sur l'historique
                        p.projK = nslots;
                        for (int a = 0; a < nslots; ++a) p.slot[a] = a;
                        CK(cudaMemset(c.neq, 0, (size_t)S.NR * NEQ * 4));
                        proj_left = PROJ_FRAMES;
                    }
                }
                last_event_f = (int)f;
                if (M.mode == 1) {   // la repartition des rayons doit voir l'invalidation de CETTE frame
                    CK(cudaMemsetAsync(c.sumpr, 0, 4));
                    (k_sumpr<<<G, B>>>(c, S.Np), DBG_K("k_sumpr"));
                }
                if (tm) { cudaEventRecord(ev[5]); cudaEventSynchronize(ev[5]); float ms; cudaEventElapsedTime(&ms, ev[4], ev[5]); tm->event += ms; tm->events++; }
            }
            p.pend_left = pend_left;
            p.dormant = dormant;
            p.proj_left = proj_left;
            if (M.ddgi) CK(cudaMemsetAsync(c.dstat, 0, 3 * S.NR * 4));
            if (tm) cudaEventRecord(ev[0]);
            if (M.deps && f % 32 == 0) { std::swap(c.cur, c.prev); CK(cudaMemsetAsync(c.cur, 0, NW * Np * 4)); }
            if (tm) cudaEventRecord(ev[1]);
            bool track = M.deps && (f % M.track_every == 0);
            if (track) (k_trace2<true><<<G, B, shm>>>(st, c, p, S.dRegion, S.dA), DBG_K("k_trace2"));
            else (k_trace2<false><<<G, B, shm>>>(st, c, p, S.dRegion, S.dA), DBG_K("k_trace2"));
            if (tm) cudaEventRecord(ev[2]);
            if (pend_left > 0) {
                CK(cudaMemsetAsync(c.npend + 1, 0, 4));
                (k_decide<<<G, B>>>(c, p, S.dRegion), DBG_K("k_decide"));
                CK(cudaMemcpyAsync(c.npend, c.npend + 1, 4, cudaMemcpyDeviceToDevice));
                pend_left--;
            }
            if (tm) cudaEventRecord(ev[3]);
            CK(cudaMemsetAsync(c.sumpr + 1, 0, 4));
            (k_update<<<G, B>>>(c, p, S.dRegion), DBG_K("k_update"));
            CK(cudaMemcpyAsync(c.sumpr, c.sumpr + 1, 4, cudaMemcpyDeviceToDevice));
            std::swap(c.Lc, c.Lc2);
            if (proj_left > 0 && --proj_left == 0) {
                int K = p.projK;
                std::vector<float> q((size_t)S.NR * NEQ), cf((size_t)S.NR * KSNAP, NAN);
                CK(cudaMemcpy(q.data(), c.neq, q.size() * 4, cudaMemcpyDeviceToHost));
                for (int r = 0; r < S.NR; ++r) {
                    const float* Q = &q[(size_t)r * NEQ];
                    if (Q[27] < 24.f) continue;                        // pas assez de rayons dans la zone
                    double A[KSNAP][KSNAP + 1]; int ix = 0; double tr = 0;
                    for (int a = 0; a < K; ++a) for (int b = a; b < K; ++b) { A[a][b] = A[b][a] = Q[ix++]; }
                    for (int a = 0; a < K; ++a) { A[a][K] = Q[21 + a]; tr += A[a][a]; }
                    for (int a = 0; a < K; ++a) A[a][a] += 1e-3 * tr / K + 1e-9;   // regularisation
                    bool ok = true;
                    for (int a = 0; a < K && ok; ++a) {               // elimination de Gauss avec pivot
                        int pv = a; for (int b = a + 1; b < K; ++b) if (fabs(A[b][a]) > fabs(A[pv][a])) pv = b;
                        if (fabs(A[pv][a]) < 1e-12) { ok = false; break; }
                        for (int t = 0; t <= K; ++t) std::swap(A[a][t], A[pv][t]);
                        for (int b = 0; b < K; ++b) if (b != a) { double m = A[b][a] / A[a][a]; for (int t = a; t <= K; ++t) A[b][t] -= m * A[a][t]; }
                    }
                    if (!ok) continue;
                    bool sane = true; double x[KSNAP];
                    for (int a = 0; a < K; ++a) { x[a] = A[a][K] / A[a][a]; if (!std::isfinite(x[a]) || fabs(x[a]) > 4.0) sane = false; }
                    if (sane) for (int a = 0; a < K; ++a) cf[(size_t)r * KSNAP + a] = (float)x[a];
                }
                CK(cudaMemcpy(c.coef, cf.data(), cf.size() * 4, cudaMemcpyHostToDevice));
                CK(cudaMemset(c.npend, 0, 8));
                CK(cudaMemset(c.rstat, 0, 4 * S.NR * 4));
                (k_proj_apply<<<G, B>>>(c, p, S.dRegion), DBG_K("k_proj_apply"));
                CK(cudaMemcpy(c.npend, c.npend + 1, 4, cudaMemcpyDeviceToDevice));
                pend_left = VERIF_FRAMES;
            }
            if (tm) {
                cudaEvent_t e5 = ev[5]; cudaEventRecord(e5); cudaEventSynchronize(e5);
                float a, b, d, u;
                cudaEventElapsedTime(&a, ev[0], ev[1]); cudaEventElapsedTime(&b, ev[1], ev[2]);
                cudaEventElapsedTime(&d, ev[2], ev[3]); cudaEventElapsedTime(&u, ev[3], e5);
                tm->swap += a; tm->trace += b; tm->decide += d; tm->update += u; tm->frames++;
            }
            if (rec_sum && (int)f >= rec_f0 && (int)f < rec_f0 + rec_nf)
                (k_accum_est<<<G, B>>>(c, S.Np, rec_sum + (size_t)(f - rec_f0) * S.Np, rec_sq + (size_t)(f - rec_f0) * S.Np, dormant), DBG_K("k_accum_est"));
            if (want_err && S.has_ref) {
                CK(cudaMemset(c.err, 0, 24));
                (k_error<<<G, B>>>(c, S.Np, st.ref, st.valid, dormant), DBG_K("k_error"));
                double h[3]; CK(cudaMemcpy(h, c.err, 24, cudaMemcpyDeviceToHost));
                errs.push_back(float(sqrt(h[0] / h[2]) / (h[1] / h[2])));
            }
        }
        CK(cudaGetLastError());
        DBG("run termine : \"%s\"", M.name.c_str());
        for (auto& e : ev) cudaEventDestroy(e);
        return errs;
    }
};

static std::vector<Method> methods_quality(const std::vector<float>& budgets) {
    std::vector<Method> M;
    char nm[128];
    for (float b : budgets) {
        for (int N : {8, 16, 32}) {
            snprintf(nm, 128, "Accumulation N=%d, %.2fx rayons", N, b);
            M.push_back({nm, 0, float(N), b, false, false, false});
            snprintf(nm, 128, "Accumulation+parlampe N=%d, %.2fx rayons", N, b);
            Method r{nm, 0, float(N), b, false, false, false}; r.rescale = true; M.push_back(r);
        }
        // SHaRC fidele : accumulation plafonnee + lampe changeante en mode "responsive" (+ par lampe)
        for (int N : {16, 32, 64}) for (int R : {4, 8}) {
            snprintf(nm, 128, "SHaRC N=%d resp=%d, %.2fx rayons", N, R, b);
            Method r{nm, 0, float(N), b, false, false, false}; r.resp_mask = 1; r.nmax_resp = float(R); r.rescale = true; M.push_back(r);
        }
        // DDGI fidele : hysteresis + seuil d'irradiance (+ borne de luminosite), avec ou sans stockage par lampe
        for (float h : {0.9f, 0.97f}) for (float t : {0.25f, 0.5f, 1.0f}) for (int cl : {0, 1}) for (int pl : {0, 1}) {
            snprintf(nm, 128, "DDGI%s h=%.2f seuil=%.2f borne=%d, %.2fx rayons", pl ? "+parlampe" : "", h, t, cl, b);
            Method r{nm, 0, 64.f, b, false, false, false}; r.ddgi = true; r.ddgi_h = h; r.ddgi_thr = t; r.ddgi_clamp = cl; r.rescale = pl;
            M.push_back(r);
        }
    }
    M.push_back({"Cache a dependances v3", 1, 64.f, 1.f, true, true, false, 1});
    M.push_back({"Cache a dependances v3, suivi 1/4", 1, 64.f, 1.f, true, true, false, 4});
    M.push_back({"Oracle", 1, 64.f, 1.f, false, false, true});
    return M;
}

// =========================================================================================
// Mode "taa" : accumulateur temporel ecran (substitut de DLSS/FSR) avec ou sans masque reactif.
// Entree : 1 echantillon par pixel, non biaise, de la vraie lumiere indirecte (path tracing + NEE).
// =========================================================================================
struct Taa {
    float *x, *H, *H2, *mu, *sg;
    int* nb;               // 9 voisins par pixel (grille du quad), -1 si absent
    int* react;            // compte a rebours du masque reactif
    uint8_t* pend;         // masque en attente de verification
    uint32_t *cur, *prev;  // masques de dependances (SoA, NW mots)
    float* rs;             // 3 * NR : verification / detection par zone
    double* err;
};

template <bool DEPS>
__global__ void k_taa_pt(DevState s, Taa t, int Np, uint32_t seed, uint32_t frame, const float* Alb) {
    extern __shared__ float sh[];
    int* shq = (int*)(sh + 9 * s.nt);
    for (int j = threadIdx.x; j < 9 * s.nt; j += blockDim.x) sh[j] = s.T[j];
    for (int j = threadIdx.x; j < s.nt; j += blockDim.x) shq[j] = s.TQ[j];
    __syncthreads();
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    uint32_t rs = hash32(seed * 0x9E3779B9u ^ hash32(frame * 0x85EBCA6Bu ^ hash32(i + 7)));
    f3 P = ld3(s.P, i), N = ld3(s.N, i), O = P + N * 1e-3f;
    f3 D = cosine_dir(N, rnd(rs), rnd(rs));
    float tt; int q;
    bool hit = trace(O, D, sh, shq, s.nt, tt, q);
    f3 H = hit ? O + D * tt : O;
    bool back = !hit || dot(ld3(s.Q + 12 * q, 3), D) > 0.f;
    int pi = hit ? point_index(H, q, s) : i;
    float v = 0.f;
    if (!back) {   // radiance au point touche = albedo * (direct + indirect exact) : estimateur non biaise a 1 spp
        float ed = 0.f; for (int l = 0; l < NL; ++l) ed += s.Edir[NL * pi + l];
        v = Alb[pi] * (ed + s.ref[pi]);
    }
    t.x[i] = v;
    if (DEPS) {
        uint32_t m[NW];
#pragma unroll
        for (int w = 0; w < NW; ++w) m[w] = 0;
        const uint4* sv = (const uint4*)(s.SV + (size_t)NW * (back ? i : pi));
#pragma unroll
        for (int w = 0; w < NW / 4; ++w) { uint4 a = __ldg(sv + w); m[4 * w] |= a.x; m[4 * w + 1] |= a.y; m[4 * w + 2] |= a.z; m[4 * w + 3] |= a.w; }
        dda_reg(O, H, m);
#pragma unroll
        for (int w = 0; w < NW; ++w) { uint32_t o = t.cur[(size_t)w * Np + i]; if ((o | m[w]) != o) t.cur[(size_t)w * Np + i] = o | m[w]; }
    }
}

__global__ void k_taa_stats(Taa t, int Np) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    float s1 = 0.f, s2 = 0.f; int n = 0;
    for (int k = 0; k < 9; ++k) { int j = t.nb[9 * i + k]; if (j < 0) continue; float v = t.x[j]; s1 += v; s2 += v * v; n++; }
    float mu = s1 / n;
    t.mu[i] = mu; t.sg[i] = sqrtf(fmaxf(s2 / n - mu * mu, 0.f));
}

// detection aveugle par zone (sans information du moteur) : moyenne de l'image courante vs historique
__global__ void k_taa_zone_acc(Taa t, int Np, const int* region, int only_pending) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    if (only_pending && !t.pend[i]) return;
    float d = t.x[i] - t.H[i];
    int r = region[i];
    atomicAdd(&t.rs[3 * r], d); atomicAdd(&t.rs[3 * r + 1], d * d); atomicAdd(&t.rs[3 * r + 2], t.H[i]);
}
__global__ void k_taa_zone_decide(Taa t, int Np, const int* region, const float* cnt, int only_pending, int rf, int clear_pending) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    if (only_pending && !t.pend[i]) return;
    int r = region[i];
    float n = cnt[r];
    if (n >= 8.f) {
        float m = t.rs[3 * r] / n, se = sqrtf(fmaxf(t.rs[3 * r + 1] / n - m * m, 0.f) / n), base = t.rs[3 * r + 2] / n;
        if (fabsf(m) > 2.f * se && fabsf(m) > 0.05f * fmaxf(base, 1e-3f)) t.react[i] = rf;
    }
    if (clear_pending) t.pend[i] = 0;
}
__global__ void k_count_zone(int Np, const int* region, const uint8_t* pend, int only_pending, float* cnt) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    if (only_pending && !pend[i]) return;
    atomicAdd(&cnt[region[i]], 1.f);
}

// masque de dependances : pixels dont les chemins passent par un voxel modifie
__global__ void k_taa_touch(Taa t, int Np, const int* V, int nv, int rf, int to_pending) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    bool hit = false;
    for (int j = 0; j < nv && !hit; ++j) {
        int v = V[j]; size_t o = (size_t)(v >> 5) * Np + i;
        hit = ((t.cur[o] | t.prev[o]) >> (v & 31)) & 1u;
    }
    if (!hit) return;
    if (to_pending) t.pend[i] = 1; else t.react[i] = rf;
}
__global__ void k_taa_oracle(Taa t, int Np, const float* rold, const float* rnew, int rf) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    if (fabsf(rnew[i] - rold[i]) / (rold[i] + 1e-2f) > 0.10f) t.react[i] = rf;
}

__global__ void k_taa_update(Taa t, int Np, float alpha, float alpha_r, float gamma) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    float h = t.H[i];
    if (gamma > 0.f) { float lo = t.mu[i] - gamma * t.sg[i], hi = t.mu[i] + gamma * t.sg[i]; h = fminf(fmaxf(h, lo), hi); }   // bornage par la variance du voisinage
    float a = alpha, target = t.x[i];
    if (t.react[i] > 0) { a = alpha_r; t.react[i]--; target = t.mu[i]; }   // historique rejete : repli spatial (voisinage 3x3), comme un debruiteur
    t.H2[i] = h + a * (target - h);
}
__global__ void k_taa_err(Taa t, int Np, const float* ref, const uint8_t* valid) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    double d2 = 0, rs = 0, cnt = 0;
    if (i < Np && valid[i]) { double e = t.H[i] - ref[i]; d2 = e * e; rs = ref[i]; cnt = 1; }
    for (int o = 16; o > 0; o >>= 1) { d2 += __shfl_down_sync(0xffffffffu, d2, o); rs += __shfl_down_sync(0xffffffffu, rs, o); cnt += __shfl_down_sync(0xffffffffu, cnt, o); }
    if ((threadIdx.x & 31) == 0) { atomicAdd(&t.err[0], d2); atomicAdd(&t.err[1], rs); atomicAdd(&t.err[2], cnt); }
}

struct TaaMethod { std::string name; float alpha, gamma; int mask; };   // mask : 0 aucun, 1 aveugle, 2 dependances, 3 dependances verifie, 4 oracle
static int host_vox_fine(const float* p) {
    int i = std::min(std::max(int(p[0] / X1 * 16), 0), 15), j = std::min(std::max(int(p[1] / Y1 * 8), 0), 7), k = std::min(std::max(int(p[2] / Z1 * 6), 0), 5);
    return (k * 8 + j) * 16 + i;
}

static void run_taa_mode(Scene& S, const char* scen_file, int nseeds) {
    // scenarios
    struct Scen { std::string name; std::vector<std::pair<int, int>> parts; };
    std::vector<Scen> SC;
    FILE* sf = fopen(scen_file, "r"); char line[512];
    while (sf && fgets(line, sizeof line, sf)) {
        std::string L(line); while (!L.empty() && (L.back() == '\n' || L.back() == '\r')) L.pop_back();
        if (L.empty() || L[0] == '#') continue;
        size_t sc = L.find(';'); Scen x; x.name = L.substr(0, sc); std::string rest = L.substr(sc + 1); size_t pos = 0;
        while (pos < rest.size()) { size_t cm = rest.find(',', pos); if (cm == std::string::npos) cm = rest.size();
            std::string tok = rest.substr(pos, cm - pos); size_t co = tok.find(':');
            x.parts.push_back({atoi(tok.substr(0, co).c_str()), atoi(tok.substr(co + 1).c_str())}); pos = cm + 1; }
        SC.push_back(x);
    }
    if (sf) fclose(sf);
    size_t Np = S.Np; int B = 256, G = (S.Np + B - 1) / B;
    // voisinage 3x3 sur la grille de chaque quad
    std::vector<int> nb(9 * Np, -1);
    for (int q = 0; q < S.Nq; ++q) {
        int nu = S.hdims[2 * q], nv = S.hdims[2 * q + 1], o = S.hoff[q];
        for (int iv = 0; iv < nv; ++iv) for (int iu = 0; iu < nu; ++iu) {
            int i = o + iv * nu + iu, k = 0;
            for (int dv = -1; dv <= 1; ++dv) for (int du = -1; du <= 1; ++du) {
                int a = iu + du, b = iv + dv;
                nb[9 * (size_t)i + k++] = (a >= 0 && a < nu && b >= 0 && b < nv) ? o + b * nu + a : -1;
            }
        }
    }
    Taa t;
    t.x = dalloc<float>(Np); t.H = dalloc<float>(Np); t.H2 = dalloc<float>(Np); t.mu = dalloc<float>(Np); t.sg = dalloc<float>(Np);
    t.nb = dput(nb); t.react = dalloc<int>(Np); t.pend = dalloc<uint8_t>(Np);
    t.cur = dalloc<uint32_t>(NW * Np); t.prev = dalloc<uint32_t>(NW * Np); t.rs = dalloc<float>(3 * S.NR); t.err = dalloc<double>(3);
    float* cnt = dalloc<float>(S.NR);
    // voxels modifies par evenement : occulteurs + voxel de chaque lampe dont l'intensite change (allumage OU extinction)
    std::vector<int*> dV(S.NS * S.NS, nullptr); std::vector<int> nV(S.NS * S.NS, 0);
    for (int a = 0; a < S.NS; ++a) for (int b = 0; b < S.NS; ++b) {
        if (a == b) continue;
        std::vector<int> fine;
        for (int l = 0; l < NL; ++l) if (S.inten[a][l] != S.inten[b][l]) fine.push_back(host_vox_fine(&S.L[3 * l]));
        std::vector<int> v = to_grid(fine);
        for (int x : S.occ[a * S.NS + b]) v.push_back(x);
        std::sort(v.begin(), v.end()); v.erase(std::unique(v.begin(), v.end()), v.end());
        nV[a * S.NS + b] = (int)v.size(); dV[a * S.NS + b] = dput(v.empty() ? std::vector<int>{0} : v);
    }
    std::vector<TaaMethod> M;
    for (float a : {0.05f, 0.1f, 0.2f}) {
        char nm[96]; snprintf(nm, 96, "TAA borne alpha=%.2f", a); M.push_back({nm, a, 1.f, 0});
    }
    M.push_back({"TAA simple alpha=0.10 (sans bornage)", 0.1f, 0.f, 0});
    M.push_back({"TAA + detection aveugle", 0.1f, 1.f, 1});
    M.push_back({"TAA + masque dependances", 0.1f, 1.f, 2});
    M.push_back({"TAA + masque dependances verifie", 0.1f, 1.f, 3});
    M.push_back({"TAA + masque oracle", 0.1f, 1.f, 4});
    const float ALPHA_R = 0.5f; const int RF = 4;
    size_t shm = S.Nt * 10 * sizeof(float);
    for (auto& sc : SC) {
        std::vector<int> seq;
        for (auto& pr : sc.parts) for (int k = 0; k < pr.second; ++k) seq.push_back(pr.first);
        int last = (int)seq.size() - sc.parts.back().second;
        for (auto& m : M) {
            double pre = 0, post = 0; std::vector<double> curve(seq.size(), 0.0);
            bool deps = m.mask == 2 || m.mask == 3;
            for (int sd = 0; sd < nseeds; ++sd) {
                CK(cudaMemcpy(t.H, S.st[seq[0]].ref, Np * 4, cudaMemcpyDeviceToDevice));   // historique converge
                CK(cudaMemset(t.react, 0, Np * 4)); CK(cudaMemset(t.pend, 0, Np));
                CK(cudaMemset(t.cur, 0, NW * Np * 4)); CK(cudaMemset(t.prev, 0, NW * Np * 4));
                int verify_left = 0;
                for (size_t f = 0; f < seq.size(); ++f) {
                    int si = seq[f]; DevState& st = S.st[si];
                    if (deps && f % 32 == 0) { std::swap(t.cur, t.prev); CK(cudaMemset(t.cur, 0, NW * Np * 4)); }
                    if (deps) (k_taa_pt<true><<<G, B, shm>>>(st, t, S.Np, 5000 + sd, (uint32_t)f, S.dA), DBG_K("k_taa_pt"));
                    else (k_taa_pt<false><<<G, B, shm>>>(st, t, S.Np, 5000 + sd, (uint32_t)f, S.dA), DBG_K("k_taa_pt"));
                    if (f > 0 && seq[f - 1] != si) {
                        int pe = seq[f - 1] * S.NS + si;
                        if (m.mask == 2) (k_taa_touch<<<G, B>>>(t, S.Np, dV[pe], nV[pe], RF, 0), DBG_K("k_taa_touch"));
                        if (m.mask == 3) { (k_taa_touch<<<G, B>>>(t, S.Np, dV[pe], nV[pe], RF, 1), DBG_K("k_taa_touch")); verify_left = 2; CK(cudaMemset(t.rs, 0, 3 * S.NR * 4)); CK(cudaMemset(cnt, 0, S.NR * 4)); }
                        if (m.mask == 4) (k_taa_oracle<<<G, B>>>(t, S.Np, S.st[seq[f - 1]].ref, st.ref, RF), DBG_K("k_taa_oracle"));
                    }
                    if (m.mask == 1) {   // detection aveugle a chaque image
                        CK(cudaMemset(t.rs, 0, 3 * S.NR * 4)); CK(cudaMemset(cnt, 0, S.NR * 4));
                        (k_taa_zone_acc<<<G, B>>>(t, S.Np, S.dRegion, 0), DBG_K("k_taa_zone_acc")); (k_count_zone<<<G, B>>>(S.Np, S.dRegion, t.pend, 0, cnt), DBG_K("k_count_zone"));
                        (k_taa_zone_decide<<<G, B>>>(t, S.Np, S.dRegion, cnt, 0, RF, 0), DBG_K("k_taa_zone_decide"));
                    }
                    if (m.mask == 3 && verify_left > 0) {   // verification : changement reel sur les pixels signales ?
                        (k_taa_zone_acc<<<G, B>>>(t, S.Np, S.dRegion, 1), DBG_K("k_taa_zone_acc"));
                        (k_count_zone<<<G, B>>>(S.Np, S.dRegion, t.pend, 1, cnt), DBG_K("k_count_zone"));   // compte cumule sur les images de verification
                        if (--verify_left == 0) {
                            (k_taa_zone_decide<<<G, B>>>(t, S.Np, S.dRegion, cnt, 1, RF, 1), DBG_K("k_taa_zone_decide"));
                        }
                    }
                    (k_taa_stats<<<G, B>>>(t, S.Np), DBG_K("k_taa_stats"));
                    (k_taa_update<<<G, B>>>(t, S.Np, m.alpha, ALPHA_R, m.gamma), DBG_K("k_taa_update"));
                    std::swap(t.H, t.H2);
                    CK(cudaMemset(t.err, 0, 24));
                    (k_taa_err<<<G, B>>>(t, S.Np, st.ref, st.valid), DBG_K("k_taa_err"));
                    double h[3]; CK(cudaMemcpy(h, t.err, 24, cudaMemcpyDeviceToHost));
                    double e = sqrt(h[0] / h[2]) / (h[1] / h[2]);
                    curve[f] += e / nseeds;
                    if ((int)f >= last - 20 && (int)f < last) pre += e / 20.0 / nseeds;
                    if ((int)f >= last && (int)f < last + 30) post += e / 30.0 / nseeds;
                }
            }
            printf("{\"type\":\"taa\",\"scen\":\"%s\",\"name\":\"%s\",\"pre\":%.5f,\"post\":%.5f,\"last\":%d,\"curve\":[", sc.name.c_str(), m.name.c_str(), pre, post, last);
            for (size_t f = 0; f < curve.size(); ++f) printf("%s%.5f", f ? "," : "", curve[f]);
            printf("]}\n"); fflush(stdout);
        }
    }
}

#include "prep_mesh.cuh"

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage\n"); return 1; }
    std::string mode = argv[1];
    if (const char* d = getenv("BENCH_DEBUG")) g_debug = atoi(d);
    if (const char* r = getenv("BENCH_RAYONS")) g_rays = std::max(0.25f, (float)atof(r));
    if (g_debug) {
        int drv = 0, rt = 0, dev = 0; cudaDriverGetVersion(&drv); cudaRuntimeGetVersion(&rt); cudaGetDevice(&dev);
        cudaDeviceProp pr; cudaGetDeviceProperties(&pr, dev);
        DBG("mode %s, scene %s, BENCH_DEBUG=%d, NVTX %s", argv[1], argv[2], g_debug,
#ifdef HAVE_NVTX
            "actif");
#else
            "absent (en-tete nvtx3 introuvable)");
#endif
        DBG("GPU %s, architecture %d.%d, %d SM, %.0f Mo, pilote CUDA %d, runtime CUDA %d, masque %d bits, %d lampes",
            pr.name, pr.major, pr.minor, pr.multiProcessorCount, pr.totalGlobalMem / 1048576.0, drv, rt, NV, NL);
    }
    NvtxScope nvtx_main(argv[1]);
    if (mode == "prep") {   // poc_gpu prep <maillage.mesh> <scene.bin> [points] : scene maillee -> scene du bench
        if (argc < 4) { fprintf(stderr, "usage : prep <maillage.mesh> <scene.bin> [nombre de points]\n"); return 1; }
        return prep_mode(argv[2], argv[3], argc > 4 ? atoi(argv[4]) : 300000);
    }
    if (mode == "res") CK(cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync));   // attente passive : CPU = vrai travail hote
    CK(cudaFree(0));
    double v0 = vram_used_mb(), r0 = ram_mb();
    Scene S = load(argv[2]);
    double v1 = vram_used_mb();
    Runner R(S);
    double v2 = vram_used_mb();
    cudaDeviceProp prop; cudaGetDeviceProperties(&prop, 0);
    if (g_rays == 1.f)
        printf("{\"type\":\"scene\",\"np\":%d,\"nt\":%d,\"gpu\":\"%s\",\"mask_bits\":%d}\n", S.Np, S.Nt, prop.name, NV);
    else
        printf("{\"type\":\"scene\",\"np\":%d,\"nt\":%d,\"gpu\":\"%s\",\"mask_bits\":%d,\"rayons_par_point\":%.2f,\"triangles_statiques\":%d}\n",
               S.Np, S.Nt, prop.name, NV, g_rays, S.nst);
    if (mode == "res") {
        printf("{\"type\":\"vram\",\"contexte_mb\":%.1f,\"scene_mb\":%.1f,\"cache_tous_buffers_mb\":%.1f,\"ram_pic_mb\":%.1f,\"ram_debut_mb\":%.1f}\n",
               v0, v1 - v0, v2 - v1, ram_mb(), r0);
        std::vector<int> seq;
        for (int s = 0; s < S.NS; ++s) for (int f = 0; f < 60; ++f) seq.push_back(s);
        std::vector<Method> M;
        M.push_back({"Classique", 0, 16.f, 1.f, false, false, false});
        { Method r{"SHaRC responsive", 0, 64.f, 1.f, false, false, false}; r.resp_mask = 1; r.rescale = true; M.push_back(r); }
        M.push_back({"v3", 1, 64.f, 1.f, true, true, false, 4});
        { Method r{"v4-A2C", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; M.push_back(r); }
        for (auto& m : M) {
            R.run(m, seq, 5, false, nullptr); CK(cudaDeviceSynchronize());
            double c0 = cpu_seconds();
            auto t0 = now_ms();
            int reps = 3;
            for (int k = 0; k < reps; ++k) R.run(m, seq, 9 + k, false, nullptr);
            CK(cudaDeviceSynchronize());
            double c1 = cpu_seconds(); auto t1 = now_ms();
            int frames = reps * (int)seq.size();
            printf("{\"type\":\"cpu\",\"name\":\"%s\",\"cpu_ms_par_frame\":%.4f,\"mur_ms_par_frame\":%.4f}\n",
                   m.name.c_str(), (c1 - c0) * 1000.0 / frames, double(t1 - t0) / frames);
            fflush(stdout);
        }
    } else if (mode == "timing") {
        // sequence 5 etats x 60 frames, 2 passes (la 1re sert de chauffe)
        std::vector<int> seq;
        for (int s = 0; s < S.NS; ++s) for (int f = 0; f < 60; ++f) seq.push_back(s);
        std::vector<Method> M = {
            {"Classique 1.0x", 0, 16.f, 1.f, false, false, false},
            {"Classique 2.0x", 0, 16.f, 2.f, false, false, false},
            [] { Method r{"SHaRC responsive 1.0x", 0, 32.f, 1.f, false, false, false}; r.resp_mask = 1; r.rescale = true; return r; }(),
            [] { Method r{"DDGI 1.0x", 0, 64.f, 1.f, false, false, false}; r.ddgi = true; r.rescale = true; return r; }(),
            {"v3 sans suivi", 1, 64.f, 1.f, false, true, false},
            {"v3 complet", 1, 64.f, 1.f, true, true, false, 1},
            {"v3 suivi 1 frame sur 2", 1, 64.f, 1.f, true, true, false, 2},
            {"v3 suivi 1 frame sur 4", 1, 64.f, 1.f, true, true, false, 4},
            [] { Method r{"v4-A2C suivi 1/4", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; return r; }(),
        };
        for (auto& m : M) {
            Timers warm; R.run(m, seq, 7, false, &warm);
            Timers t;
            for (int rep = 0; rep < 3; ++rep) R.run(m, seq, 11 + rep, false, &t);
            printf("{\"type\":\"timing\",\"name\":\"%s\",\"trace\":%.5f,\"decide\":%.5f,\"update\":%.5f,\"swap\":%.5f,\"event\":%.5f}\n",
                   m.name.c_str(), t.trace / t.frames, t.decide / t.frames, t.update / t.frames, t.swap / t.frames,
                   t.events ? t.event / t.events : 0.0);
            fflush(stdout);
        }
    } else if (mode == "taa") {
        if (S.fmt == 3) { fprintf(stderr, "mode taa non supporte sur les scenes maillees\n"); return 1; }
        run_taa_mode(S, argv[4], atoi(argv[3]));
    } else if (mode == "scenf") {
        int nseeds = atoi(argv[3]);
        FILE* sf = fopen(argv[4], "r");
        if (!sf) { fprintf(stderr, "fichier de scenarios %s\n", argv[4]); return 1; }
        struct Scen { std::string name; std::vector<std::pair<int, int>> parts; };
        std::vector<Scen> SC;
        char line[512];
        while (fgets(line, sizeof line, sf)) {
            std::string L(line);
            while (!L.empty() && (L.back() == '\n' || L.back() == '\r')) L.pop_back();
            if (L.empty() || L[0] == '#') continue;
            size_t sc = L.find(';');
            Scen x; x.name = L.substr(0, sc);
            std::string rest = L.substr(sc + 1);
            size_t pos = 0;
            while (pos < rest.size()) {
                size_t comma = rest.find(',', pos); if (comma == std::string::npos) comma = rest.size();
                std::string tok = rest.substr(pos, comma - pos);
                size_t colon = tok.find(':');
                x.parts.push_back({atoi(tok.substr(0, colon).c_str()), atoi(tok.substr(colon + 1).c_str())});
                pos = comma + 1;
            }
            SC.push_back(x);
        }
        fclose(sf);
        int dyn = 0;   // lampes dont l'intensite change entre etats -> "responsive" pour SHaRC
        for (int s2 = 1; s2 < S.NS; ++s2) for (int l = 0; l < NL; ++l) if (S.inten[s2][l] != S.inten[0][l]) dyn |= 1 << l;
        // budget des baselines a temps GPU egal : 1,57x (SHaRC) / 1,53x (accumulation) calibres sur RTX 4060 pour les scenes
        // en boites ; argument optionnel = budget mesure sur CETTE scene (scenes maillees : cout du BVH different)
        float bS = 1.57f, bA = 1.53f;
        if (argc > 5) bS = bA = (float)atof(argv[5]);
        char nm[128];
        auto nmf = [&](const char* fmt, float b) { snprintf(nm, sizeof nm, fmt, b); return std::string(nm); };
        std::vector<Method> M;
        { Method r{nmf("SHaRC N=64 resp=8, %.2fx", bS), 0, 64.f, bS, false, false, false}; r.resp_mask = dyn; r.nmax_resp = 8.f; r.rescale = true; M.push_back(r); }
        { Method r{nmf("SHaRC + memoire naive, %.2fx", bS), 0, 64.f, bS, false, false, false}; r.resp_mask = dyn; r.nmax_resp = 8.f; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{nmf("Accumulation+parlampe N=32, %.2fx", bA), 0, 32.f, bA, false, false, false}; r.rescale = true; M.push_back(r); }
        { Method r{nmf("Accum+parlampe + memoire naive N=32, %.2fx", bA), 0, 32.f, bA, false, false, false}; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{nmf("Accum+parlampe + memoire naive N=64, %.2fx", bA), 0, 64.f, bA, false, false, false}; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{nmf("SHaRC + memoire + instantanes, %.2fx", bS), 0, 64.f, bS, false, false, false}; r.resp_mask = dyn; r.nmax_resp = 8.f; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        { Method r{nmf("Accum + memoire + instantanes N=32, %.2fx", bA), 0, 32.f, bA, false, false, false}; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        { Method r{nmf("Accum + memoire + instantanes N=64, %.2fx", bA), 0, 64.f, bA, false, false, false}; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        M.push_back({"Oracle", 1, 64.f, 1.f, false, false, true});
        M.push_back({"v3", 1, 64.f, 1.f, true, true, false, 4});
        { Method r{"v4-A2C memoire verifiee+rampe", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; M.push_back(r); }
        { Method r{"v5-A instantanes verifies", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; r.snap_verify = true; M.push_back(r); }
        { Method r{"v5-A instantanes", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; M.push_back(r); }
        { Method r{"v5-AB instantanes+projection", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; r.proj = true; M.push_back(r); }
        for (auto& sc : SC) {
            std::vector<int> seq;
            for (auto& pr : sc.parts) for (int k = 0; k < pr.second; ++k) seq.push_back(pr.first);
            int last = (int)seq.size() - sc.parts.back().second;
            for (auto& m : M) {
                double pre = 0, post = 0;
                std::vector<double> curve(seq.size(), 0.0);
                for (int sd = 0; sd < nseeds; ++sd) {
                    auto er = R.run(m, seq, 3000 + sd, true, nullptr);
                    for (int f = last - 20; f < last; ++f) pre += er[f] / 20.0 / nseeds;
                    for (int f = last; f < last + 30; ++f) post += er[f] / 30.0 / nseeds;
                    for (size_t f = 0; f < seq.size(); ++f) curve[f] += er[f] / nseeds;
                }
                printf("{\"type\":\"scen\",\"scen\":\"%s\",\"name\":\"%s\",\"pre\":%.5f,\"post\":%.5f,\"last\":%d,\"curve\":[", sc.name.c_str(), m.name.c_str(), pre, post, last);
                for (size_t f = 0; f < curve.size(); ++f) printf("%s%.5f", f ? "," : "", curve[f]);
                printf("]}\n");
                fflush(stdout);
            }
        }
    } else if (mode == "scen") {
        // scenarios aller-retour : erreur moyenne 30 frames apres le DERNIER evenement
        int nseeds = atoi(argv[3]);
        struct Scen { const char* name; std::vector<std::pair<int, int>> parts; };   // (etat, nb frames)
        std::vector<Scen> SC = {
            {"R1 allumee-eteinte-rallumee", {{0, 50}, {1, 30}, {0, 50}}},
            {"R2 allumee-eteinte-porte-rallumee", {{0, 40}, {1, 20}, {2, 20}, {3, 50}}},
            {"R3 porte ouverte-fermee-rouverte", {{0, 50}, {3, 30}, {0, 50}}},
            {"I1 lampe eteinte", {{0, 50}, {1, 50}}},
            {"I2 porte", {{1, 50}, {2, 50}}},
            {"I3 lampe allumee 1re fois", {{2, 50}, {3, 50}}},
            {"I4 boite", {{3, 50}, {4, 50}}},
        };
        std::vector<Method> M;
        { Method r{"SHaRC N=64 resp=8, 1.57x", 0, 64.f, 1.57f, false, false, false}; r.resp_mask = 1; r.nmax_resp = 8.f; r.rescale = true; M.push_back(r); }
        { Method r{"Accumulation+parlampe N=32, 1.53x", 0, 32.f, 1.53f, false, false, false}; r.rescale = true; M.push_back(r); }
        { Method r{"SHaRC + memoire naive, 1.57x", 0, 64.f, 1.57f, false, false, false}; r.resp_mask = 1; r.nmax_resp = 8.f; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{"Accum+parlampe + memoire naive N=32, 1.53x", 0, 32.f, 1.53f, false, false, false}; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{"Accum+parlampe + memoire naive N=64, 1.53x", 0, 64.f, 1.53f, false, false, false}; r.rescale = true; r.memory = true; M.push_back(r); }
        { Method r{"SHaRC + memoire + instantanes, 1.57x", 0, 64.f, 1.57f, false, false, false}; r.resp_mask = 1; r.nmax_resp = 8.f; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        { Method r{"Accum + memoire + instantanes N=32, 1.53x", 0, 32.f, 1.53f, false, false, false}; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        { Method r{"Accum + memoire + instantanes N=64, 1.53x", 0, 64.f, 1.53f, false, false, false}; r.rescale = true; r.memory = true; r.snaps = true; M.push_back(r); }
        M.push_back({"Oracle", 1, 64.f, 1.f, false, false, true});
        M.push_back({"v3", 1, 64.f, 1.f, true, true, false, 4});
        { Method r{"v4-A memoire", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; M.push_back(r); }
        { Method r{"v4-C rampe", 1, 64.f, 1.f, true, true, false, 4}; r.ramp = true; M.push_back(r); }
        { Method r{"v4-AC memoire+rampe", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.ramp = true; M.push_back(r); }
        { Method r{"v4-A2 memoire verifiee", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; M.push_back(r); }
        { Method r{"v4-A2C memoire verifiee+rampe", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; M.push_back(r); }
        { Method r{"v5-A instantanes verifies", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; r.snap_verify = true; M.push_back(r); }
        { Method r{"v5-A instantanes", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; M.push_back(r); }
        { Method r{"v5-AB instantanes+projection", 1, 64.f, 1.f, true, true, false, 4}; r.memory = true; r.wake_verify = true; r.ramp = true; r.snaps = true; r.proj = true; M.push_back(r); }
        for (auto& sc : SC) {
            std::vector<int> seq;
            for (auto& pr : sc.parts) for (int k = 0; k < pr.second; ++k) seq.push_back(pr.first);
            int last = (int)seq.size() - sc.parts.back().second;
            for (auto& m : M) {
                double pre = 0, post = 0;
                std::vector<double> curve(seq.size(), 0.0);
                for (int sd = 0; sd < nseeds; ++sd) {
                    auto er = R.run(m, seq, 2000 + sd, true, nullptr);
                    for (int f = last - 20; f < last; ++f) pre += er[f] / 20.0 / nseeds;
                    for (int f = last; f < last + 30; ++f) post += er[f] / 30.0 / nseeds;
                    for (size_t f = 0; f < seq.size(); ++f) curve[f] += er[f] / nseeds;
                }
                printf("{\"type\":\"scen\",\"scen\":\"%s\",\"name\":\"%s\",\"pre\":%.5f,\"post\":%.5f,\"last\":%d,\"curve\":[", sc.name, m.name.c_str(), pre, post, last);
                for (size_t f = 0; f < curve.size(); ++f) printf("%s%.5f", f ? "," : "", curve[f]);
                printf("]}\n");
                fflush(stdout);
            }
        }
    } else if (mode == "recon") {
        // poc_gpu recon scene.bin nseeds : courbes par graine + decomposition biais / variance par categorie
        int nseeds = atoi(argv[3]);
        const int F0 = 45, NF = 55;
        std::vector<Method> M;
        M.push_back({"Cache a dependances v3, suivi 1/4", 1, 64.f, 1.f, true, true, false, 4});
        { Method r{"SHaRC N=64 resp=8, 1.52x", 0, 64.f, 1.52f, false, false, false}; r.resp_mask = 1; r.nmax_resp = 8.f; r.rescale = true; M.push_back(r); }
        { Method r{"Accumulation+parlampe N=32, 1.51x", 0, 32.f, 1.51f, false, false, false}; r.rescale = true; M.push_back(r); }
        M.push_back({"Oracle", 1, 64.f, 1.f, false, false, true});
        size_t Np = S.Np;
        float *dsum = dalloc<float>(NF * Np), *dsq = dalloc<float>(NF * Np);
        std::vector<float> hsum(NF * Np), hsq(NF * Np);
        for (auto& m : M) for (int e = 0; e < S.NS - 1; ++e) {
            std::vector<int> seq(100, e); for (int f = 50; f < 100; ++f) seq[f] = e + 1;
            CK(cudaMemset(dsum, 0, NF * Np * 4)); CK(cudaMemset(dsq, 0, NF * Np * 4));
            R.rec_sum = dsum; R.rec_sq = dsq; R.rec_f0 = F0; R.rec_nf = NF;
            printf("{\"type\":\"recon_seeds\",\"name\":\"%s\",\"event\":%d,\"curves\":[", m.name.c_str(), e);
            for (int sd = 0; sd < nseeds; ++sd) {
                auto er = R.run(m, seq, 1000 + sd, true, nullptr);
                printf("%s[", sd ? "," : "");
                for (int f = 0; f < 100; ++f) printf("%s%.5f", f ? "," : "", er[f]);
                printf("]");
            }
            printf("]}\n");
            R.rec_sum = nullptr;
            CK(cudaMemcpy(hsum.data(), dsum, NF * Np * 4, cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(hsq.data(), dsq, NF * Np * 4, cudaMemcpyDeviceToHost));
            std::vector<float> rold(Np), rnew(Np); std::vector<uint8_t> val(Np);
            CK(cudaMemcpy(rold.data(), S.st[e].ref, Np * 4, cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(rnew.data(), S.st[e + 1].ref, Np * 4, cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(val.data(), S.st[e + 1].valid, Np, cudaMemcpyDeviceToHost));
            // categories : changement relatif de la reference > 20 %, 5-20 %, < 5 %
            double mref = 0; int nv = 0;
            std::vector<int> cat(Np, -1);
            for (size_t i = 0; i < Np; ++i) if (val[i]) {
                double rel = fabs(rnew[i] - rold[i]) / (rold[i] + 1e-2);
                cat[i] = rel > 0.2 ? 0 : (rel > 0.05 ? 1 : 2); mref += rnew[i]; nv++;
            }
            mref /= nv;
            printf("{\"type\":\"recon_bv\",\"name\":\"%s\",\"event\":%d,\"f0\":%d,\"mref\":%.6f,\"cats\":[", m.name.c_str(), e, F0, mref);
            for (int k = 0; k < 3; ++k) {
                int cnt = 0; for (size_t i = 0; i < Np; ++i) cnt += cat[i] == k;
                printf("%s{\"n\":%d,\"bias2\":[", k ? "," : "", cnt);
                std::vector<double> var(NF);
                for (int f = 0; f < NF; ++f) {
                    double b2 = 0, v = 0;
                    for (size_t i = 0; i < Np; ++i) if (cat[i] == k) {
                        double mu = hsum[f * Np + i] / nseeds;
                        double vv = hsq[f * Np + i] / nseeds - mu * mu;
                        b2 += (mu - rnew[i]) * (mu - rnew[i]); v += vv > 0 ? vv : 0;
                    }
                    printf("%s%.6e", f ? "," : "", cnt ? b2 / cnt : 0.0); var[f] = cnt ? v / cnt : 0.0;
                }
                printf("],\"var\":[");
                for (int f = 0; f < NF; ++f) printf("%s%.6e", f ? "," : "", var[f]);
                printf("]}");
            }
            printf("]}\n");
            fflush(stdout);
        }
    } else if (mode == "quality") {
        int nseeds = atoi(argv[3]);
        std::vector<float> budgets;
        for (char* tok = strtok(argv[4], ","); tok; tok = strtok(nullptr, ",")) budgets.push_back((float)atof(tok));
        for (auto& m : methods_quality(budgets)) {
            for (int e = 0; e < S.NS - 1; ++e) {
                std::vector<int> seq(100, e); for (int f = 50; f < 100; ++f) seq[f] = e + 1;
                double pre = 0, post = 0;
                std::vector<double> curve(100, 0.0);
                for (int sd = 0; sd < nseeds; ++sd) {
                    auto er = R.run(m, seq, 1000 + sd, true, nullptr);
                    for (int f = 30; f < 50; ++f) pre += er[f] / 20.0 / nseeds;
                    for (int f = 50; f < 80; ++f) post += er[f] / 30.0 / nseeds;
                    for (int f = 0; f < 100; ++f) curve[f] += er[f] / nseeds;
                }
                printf("{\"type\":\"quality\",\"name\":\"%s\",\"budget\":%.3f,\"event\":%d,\"pre\":%.5f,\"post\":%.5f}\n",
                       m.name.c_str(), m.budget, e, pre, post);
            }
            fflush(stdout);
        }
    }
    DBG_SUMMARY();
    return 0;
}
