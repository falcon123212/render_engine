// Preparation d'une scene maillee pour le bench (format 3).
// Preparing a mesh scene for the bench (format 3).
//
//   poc_gpu_l3 prep <maillage.mesh> <scene.bin> [nombre de points]
//
// Entree : maillage produit par scenes_publiques/convertir.py (triangles en metres, z vers le haut, albedo par triangle).
// Etapes :
//   1. BVH (SAH par paniers) sur la geometrie statique ;
//   2. points de cache : grille de hachage spatiale (cellule de cote h + direction dominante de la normale), comme SHaRC ;
//      h est ajuste pour viser le nombre de points demande ;
//   3. placement automatique de 3 lampes (espaces libres, eloignes les uns des autres) et d'un objet mobile (cube) ;
//   4. 5 etats (lampes allumees / eteintes, cube deplace) et les voxels touches par chaque evenement ;
//   5. reference de qualite par etat : solution du meme systeme multi-rebonds que le cache (iterations de Jacobi a rayons
//      frais, 2 chaines independantes pour mesurer le bruit propre de la reference). Meme definition que la reference
//      Python des scenes en boites (sim3d.reference).
#include <unordered_map>
#include <chrono>
#include <numeric>

struct MeshIn { int nt = 0; std::vector<float> V; std::vector<float> alb; std::vector<uint8_t> ds; };

static MeshIn read_mesh(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "maillage %s introuvable\n", path); exit(1); }
    char magic[4]; MeshIn M;
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "MSH1", 4) != 0 || fread(&M.nt, 4, 1, f) != 1) { fprintf(stderr, "maillage %s : format inconnu\n", path); exit(1); }
    rd(f, M.V, 9 * (size_t)M.nt); rd(f, M.alb, M.nt); rd(f, M.ds, M.nt);
    fclose(f);
    return M;
}

struct HostRng {
    unsigned long long s;
    explicit HostRng(unsigned long long x) : s(mix64(x * 0x9E3779B97F4A7C15ull + 1)) {}
    float u() { s = mix64(s + 0x9E3779B97F4A7C15ull); return (float)(s >> 40) * (1.0f / 16777216.0f); }
};

// ------------------------------------------------------------------------------------------------ BVH
struct BvhNode { float lo[3]; int lf; float hi[3]; int cnt; };   // meme disposition que les 2 float4 lus par trace_bvh
static_assert(sizeof(BvhNode) == 32, "noeud BVH : 32 octets");

static void build_bvh(const MeshIn& M, std::vector<BvhNode>& nodes, std::vector<int>& order) {
    int n = M.nt;
    order.resize(n); std::iota(order.begin(), order.end(), 0);
    std::vector<float> cen(3 * (size_t)n), tlo(3 * (size_t)n), thi(3 * (size_t)n);
    for (int t = 0; t < n; ++t) for (int a = 0; a < 3; ++a) {
        float x0 = M.V[9 * (size_t)t + a], x1 = M.V[9 * (size_t)t + 3 + a], x2 = M.V[9 * (size_t)t + 6 + a];
        tlo[3 * (size_t)t + a] = std::min(x0, std::min(x1, x2)); thi[3 * (size_t)t + a] = std::max(x0, std::max(x1, x2));
        cen[3 * (size_t)t + a] = 0.5f * (tlo[3 * (size_t)t + a] + thi[3 * (size_t)t + a]);
    }
    nodes.clear(); nodes.reserve(2 * (size_t)n + 1); nodes.push_back(BvhNode{});
    struct Item { int node, start, count, depth; };
    std::vector<Item> st{{0, 0, n, 0}};
    const int NB = 16;
    auto area = [](const float* lo, const float* hi) {
        float d0 = hi[0] - lo[0], d1 = hi[1] - lo[1], d2 = hi[2] - lo[2];
        return d0 < 0 ? 0.f : 2.f * (d0 * d1 + d1 * d2 + d2 * d0);
    };
    while (!st.empty()) {
        Item it = st.back(); st.pop_back();
        BvhNode& nd = nodes[it.node];
        float clo[3] = {1e30f, 1e30f, 1e30f}, chi[3] = {-1e30f, -1e30f, -1e30f};
        for (int a = 0; a < 3; ++a) { nd.lo[a] = 1e30f; nd.hi[a] = -1e30f; }
        for (int k = it.start; k < it.start + it.count; ++k) {
            int t = order[k];
            for (int a = 0; a < 3; ++a) {
                nd.lo[a] = std::min(nd.lo[a], tlo[3 * (size_t)t + a]); nd.hi[a] = std::max(nd.hi[a], thi[3 * (size_t)t + a]);
                clo[a] = std::min(clo[a], cen[3 * (size_t)t + a]); chi[a] = std::max(chi[a], cen[3 * (size_t)t + a]);
            }
        }
        int ax = 0;
        for (int a = 1; a < 3; ++a) if (chi[a] - clo[a] > chi[ax] - clo[ax]) ax = a;
        float ext = chi[ax] - clo[ax];
        if (it.count <= 4 || it.depth >= 56 || ext < 1e-7f) {
            if (it.count <= 64 || it.depth >= 56) { nd.lf = it.start; nd.cnt = it.count; continue; }
        }
        int mid = -1;
        if (ext >= 1e-7f) {   // SAH par paniers
            int bc[NB] = {0}; float blo[NB][3], bhi[NB][3];
            for (int b = 0; b < NB; ++b) for (int a = 0; a < 3; ++a) { blo[b][a] = 1e30f; bhi[b][a] = -1e30f; }
            auto bin_of = [&](int t) { return std::min(NB - 1, (int)((cen[3 * (size_t)t + ax] - clo[ax]) / ext * NB)); };
            for (int k = it.start; k < it.start + it.count; ++k) {
                int t = order[k], b = bin_of(t); bc[b]++;
                for (int a = 0; a < 3; ++a) { blo[b][a] = std::min(blo[b][a], tlo[3 * (size_t)t + a]); bhi[b][a] = std::max(bhi[b][a], thi[3 * (size_t)t + a]); }
            }
            float best = 1e30f; int bs = -1;
            for (int s = 1; s < NB; ++s) {
                float l0[3] = {1e30f, 1e30f, 1e30f}, l1[3] = {-1e30f, -1e30f, -1e30f}, r0[3] = {1e30f, 1e30f, 1e30f}, r1[3] = {-1e30f, -1e30f, -1e30f};
                int nl = 0, nr = 0;
                for (int b = 0; b < s; ++b) { nl += bc[b]; for (int a = 0; a < 3; ++a) { l0[a] = std::min(l0[a], blo[b][a]); l1[a] = std::max(l1[a], bhi[b][a]); } }
                for (int b = s; b < NB; ++b) { nr += bc[b]; for (int a = 0; a < 3; ++a) { r0[a] = std::min(r0[a], blo[b][a]); r1[a] = std::max(r1[a], bhi[b][a]); } }
                if (!nl || !nr) continue;
                float c = nl * area(l0, l1) + nr * area(r0, r1);
                if (c < best) { best = c; bs = s; }
            }
            float leaf_cost = it.count * area(nd.lo, nd.hi);
            if (bs > 0 && !(it.count <= 4 && best >= leaf_cost)) {
                auto pm = std::partition(order.begin() + it.start, order.begin() + it.start + it.count, [&](int t) { return bin_of(t) < bs; });
                mid = (int)(pm - order.begin());
            } else if (it.count <= 4) { nd.lf = it.start; nd.cnt = it.count; continue; }
        }
        if (mid <= it.start || mid >= it.start + it.count) {   // repli : coupe a la mediane
            mid = it.start + it.count / 2;
            std::nth_element(order.begin() + it.start, order.begin() + mid, order.begin() + it.start + it.count,
                             [&](int a, int b) { return cen[3 * (size_t)a + ax] < cen[3 * (size_t)b + ax]; });
        }
        int left = (int)nodes.size();
        nodes.push_back(BvhNode{}); nodes.push_back(BvhNode{});
        BvhNode& nd2 = nodes[it.node];   // la reference a pu etre invalidee par push_back
        nd2.lf = left; nd2.cnt = 0;
        st.push_back({left, it.start, mid - it.start, it.depth + 1});
        st.push_back({left + 1, mid, it.start + it.count - mid, it.depth + 1});
    }
}

// ------------------------------------------------------------------------------------------- points de cache
struct CellRec { float p[3]; float d2; float n[3]; double asum, wsum; };

static void decode_key(unsigned long long k, int& cx, int& cy, int& cz, int& b) {
    k -= 1ull; b = (int)(k & 7ull); cz = (int)((k >> 3) & 0xFFFFFull); cy = (int)((k >> 23) & 0xFFFFFull); cx = (int)((k >> 43) & 0xFFFFFull);
}
static unsigned long long spread3(unsigned long long x) {   // 21 bits -> morton
    x &= 0x1fffffull;
    x = (x | x << 32) & 0x1f00000000ffffull; x = (x | x << 16) & 0x1f0000ff0000ffull; x = (x | x << 8) & 0x100f00f00f00f00full;
    x = (x | x << 4) & 0x10c30c30c30c30c3ull; x = (x | x << 2) & 0x1249249249249249ull;
    return x;
}

static void sample_cells(const MeshIn& M, float h, const float lo[3], std::unordered_map<unsigned long long, CellRec>& cells) {
    cells.clear();
    for (int t = 0; t < M.nt; ++t) {
        const float* v = &M.V[9 * (size_t)t];
        float e1[3] = {v[3] - v[0], v[4] - v[1], v[5] - v[2]}, e2[3] = {v[6] - v[0], v[7] - v[1], v[8] - v[2]};
        float cr[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        float l = sqrtf(cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2]);
        if (l < 1e-12f) continue;
        float ar = 0.5f * l, n[3] = {cr[0] / l, cr[1] / l, cr[2] / l};
        int ns = (int)std::min(1e6, std::max(1.0, std::ceil(ar / (h * h) * 4.0)));
        HostRng r(t);
        int sides = M.ds[t] ? 2 : 1;
        for (int k = 0; k < ns; ++k) {
            float a = 1.f / 3.f, b = 1.f / 3.f;
            if (k > 0) { a = r.u(); b = r.u(); if (a + b > 1.f) { a = 1.f - a; b = 1.f - b; } }
            float P[3] = {v[0] + e1[0] * a + e2[0] * b, v[1] + e1[1] * a + e2[1] * b, v[2] + e1[2] * a + e2[2] * b};
            int c[3]; float d2 = 0.f;
            for (int x = 0; x < 3; ++x) { c[x] = (int)floorf((P[x] - lo[x]) / h); float cc = lo[x] + (c[x] + 0.5f) * h; d2 += (P[x] - cc) * (P[x] - cc); }
            for (int sd = 0; sd < sides; ++sd) {
                float nn[3] = {sd ? -n[0] : n[0], sd ? -n[1] : n[1], sd ? -n[2] : n[2]};
                unsigned long long key = cell_key(c[0], c[1], c[2], normal_bucket(nn[0], nn[1], nn[2]));
                auto ins = cells.try_emplace(key, CellRec{{0, 0, 0}, 1e30f, {0, 0, 1}, 0.0, 0.0});
                CellRec& cr2 = ins.first->second;
                if (d2 < cr2.d2) { cr2.d2 = d2; for (int x = 0; x < 3; ++x) { cr2.p[x] = P[x]; cr2.n[x] = nn[x]; } }
                cr2.asum += (double)M.alb[t] * ar / ns; cr2.wsum += (double)ar / ns;
            }
        }
    }
}

// -------------------------------------------------------------------------------------------- noyaux de preparation
__global__ void k_probe(DevState s, const float* C, int nc, float diag, float* out) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= nc) return;
    f3 o = ld3(C, i);
    float clr = 1e30f, enc = 0.f, back = 0.f;
    const int ND = 64;
    for (int k = 0; k < ND; ++k) {   // directions de Fibonacci sur la sphere
        float z = 1.f - (2.f * k + 1.f) / ND, r = sqrtf(fmaxf(0.f, 1.f - z * z)), ph = 2.39996323f * k;
        f3 d = mk(r * cosf(ph), r * sinf(ph), z);
        float t = 1e30f; int q = -1;
        trace_bvh(o, d, s, t, q);
        if (q != -1) {
            clr = fminf(clr, t);
            if (t < diag) enc += 1.f;
            float4 n4 = __ldg(s.STN + (-2 - q));
            if (n4.x * d.x + n4.y * d.y + n4.z * d.z > 0.f && !(__float_as_int(n4.w) & 1)) back += 1.f;
        }
    }
    out[3 * i] = clr; out[3 * i + 1] = enc / ND; out[3 * i + 2] = back / ND;
}

// une iteration de Jacobi a rayons frais : Lout = moyenne de A(p) * (Edir(p) + Lin(p)) sur K rayons cosinus
__global__ void k_ref(DevState s, const float* Alb, const float* Lin, float* Lout, float* acc, float* closec, int Np,
                      uint32_t seed, int K, int accumulate, int count_close) {
    extern __shared__ float sh[];
    int* shq = (int*)(sh + 9 * s.nt);
    for (int j = threadIdx.x; j < 9 * s.nt; j += blockDim.x) sh[j] = s.T[j];
    for (int j = threadIdx.x; j < s.nt; j += blockDim.x) shq[j] = s.TQ[j];
    __syncthreads();
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= Np) return;
    uint32_t rs = hash32(seed ^ hash32(i + 1));
    f3 P = ld3(s.P, i), N = ld3(s.N, i), O = P + N * 1e-3f;
    float sum[NL];
    for (int l = 0; l < NL; ++l) sum[l] = 0.f;
    int close = 0;
    for (int r = 0; r < K; ++r) {
        f3 D = cosine_dir(N, rnd(rs), rnd(rs));
        float t; int q;
        bool hit = trace_full(O, D, sh, shq, s, t, q);
        if (hit && t < 0.02f) close++;
        f3 H = hit ? O + D * t : O;
        int pi;
        if (resolve_hit(s, hit, H, D, q, i, pi)) continue;
        float A = Alb[pi];
        for (int l = 0; l < NL; ++l) sum[l] += A * (s.Edir[NL * (size_t)pi + l] + Lin[NL * (size_t)pi + l]);
    }
    for (int l = 0; l < NL; ++l) {
        float v = sum[l] / K;
        Lout[NL * (size_t)i + l] = v;
        if (accumulate) acc[NL * (size_t)i + l] += v;
    }
    if (count_close) closec[i] += (float)close;
}

// ------------------------------------------------------------------------------------------------ ecriture (format 3)
struct MeshScene {
    float lo[3], ext[3], h;
    std::vector<float> ST, STN; std::vector<BvhNode> BN; std::vector<unsigned long long> HK; std::vector<int> HV;
    int npst = 0, nbox = 0, NR = 0;
    std::vector<float> L, A; std::vector<int> region;
    std::vector<float> Pst, Nst;                              // points statiques
    std::vector<std::vector<float>> inten;                    // par etat
    std::vector<int> boxpos;                                  // par etat : 0 = position A, 1 = position B
    float boxc[2][3], boxe;                                   // centres et demi-cote du cube
    int bnu;                                                  // points par cote d'une face du cube
    std::vector<std::vector<float>> ref, Pw; std::vector<std::vector<uint8_t>> valid;
};

static void box_quads(const float c[3], float e, std::vector<float>& Q) {
    // o, u, v, n (normale sortante) pour les 6 faces ; u x v suit n
    const float E = 2.f * e;
    float F[6][12] = {
        {c[0] + e, c[1] - e, c[2] - e, 0, E, 0, 0, 0, E, 1, 0, 0},
        {c[0] - e, c[1] - e, c[2] - e, 0, 0, E, 0, E, 0, -1, 0, 0},
        {c[0] - e, c[1] + e, c[2] - e, 0, 0, E, E, 0, 0, 0, 1, 0},
        {c[0] - e, c[1] - e, c[2] - e, E, 0, 0, 0, 0, E, 0, -1, 0},
        {c[0] - e, c[1] - e, c[2] + e, E, 0, 0, 0, E, 0, 0, 0, 1},
        {c[0] - e, c[1] - e, c[2] - e, 0, E, 0, E, 0, 0, 0, 0, -1}};
    Q.assign(&F[0][0], &F[0][0] + 72);
}

static void write_mesh_scene(const char* path, const MeshScene& m, bool with_ref) {
    FILE* f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "ecriture %s impossible\n", path); exit(1); }
    auto W = [&](const void* p, size_t n) { if (n && fwrite(p, 1, n, f) != n) { fprintf(stderr, "ecriture\n"); exit(1); } };
    const int NS = (int)m.inten.size(), Np = m.npst + m.nbox;
    int h[8] = {Np, 6, 12, NS, NL, m.NR, with_ref ? 1 : 0, 3};
    W(h, 32); W(m.lo, 12); W(m.ext, 12); W(&m.h, 4);
    int mm[4] = {(int)(m.ST.size() / 9), (int)m.BN.size(), (int)m.HK.size(), m.npst};
    W(mm, 16);
    W(m.ST.data(), m.ST.size() * 4); W(m.STN.data(), m.STN.size() * 4); W(m.BN.data(), m.BN.size() * sizeof(BvhNode));
    W(m.HK.data(), m.HK.size() * 8); W(m.HV.data(), m.HV.size() * 4);
    W(m.L.data(), m.L.size() * 4); W(m.A.data(), m.A.size() * 4); W(m.region.data(), m.region.size() * 4);
    for (int si = 0; si < NS; ++si) {
        std::vector<float> P(m.Pst), N(m.Nst), Q;
        box_quads(m.boxc[m.boxpos[si]], m.boxe, Q);
        std::vector<int> dims, off;
        for (int q = 0; q < 6; ++q) {
            dims.push_back(m.bnu); dims.push_back(m.bnu); off.push_back(m.npst + q * m.bnu * m.bnu);
            for (int iv = 0; iv < m.bnu; ++iv) for (int iu = 0; iu < m.bnu; ++iu) for (int x = 0; x < 3; ++x) {
                P.push_back(Q[12 * q + x] + Q[12 * q + 3 + x] * (iu + 0.5f) / m.bnu + Q[12 * q + 6 + x] * (iv + 0.5f) / m.bnu);
                N.push_back(Q[12 * q + 9 + x]);
            }
        }
        std::vector<float> T; std::vector<int> TQ;
        for (int q = 0; q < 6; ++q) {
            const float* o = &Q[12 * q]; const float* u = o + 3; const float* v = o + 6;
            for (int x = 0; x < 3; ++x) T.push_back(o[x]);
            for (int x = 0; x < 3; ++x) T.push_back(u[x]);
            for (int x = 0; x < 3; ++x) T.push_back(u[x] + v[x]);
            for (int x = 0; x < 3; ++x) T.push_back(o[x]);
            for (int x = 0; x < 3; ++x) T.push_back(u[x] + v[x]);
            for (int x = 0; x < 3; ++x) T.push_back(v[x]);
            TQ.push_back(q); TQ.push_back(q);
        }
        W(m.inten[si].data(), NL * 4); W(P.data(), P.size() * 4); W(N.data(), N.size() * 4); W(Q.data(), Q.size() * 4);
        W(dims.data(), dims.size() * 4); W(off.data(), off.size() * 4); W(T.data(), T.size() * 4); W(TQ.data(), TQ.size() * 4);
        if (with_ref) { W(m.ref[si].data(), Np * 4); W(m.valid[si].data(), Np); W(m.Pw[si].data(), (size_t)NL * Np * 4); }
    }
    for (int a = 0; a < NS; ++a) for (int b = 0; b < NS; ++b) {
        std::vector<int> occ;
        if (a != b && m.boxpos[a] != m.boxpos[b]) {
            for (int p = 0; p < 2; ++p) for (int i = 0; i < 12; ++i) for (int j = 0; j < 12; ++j) for (int k = 0; k < 12; ++k) {
                float x[3] = {m.boxc[p][0] - m.boxe + 2 * m.boxe * i / 11.f, m.boxc[p][1] - m.boxe + 2 * m.boxe * j / 11.f, m.boxc[p][2] - m.boxe + 2 * m.boxe * k / 11.f};
                occ.push_back(host_vox(x));
            }
            std::sort(occ.begin(), occ.end()); occ.erase(std::unique(occ.begin(), occ.end()), occ.end());
        }
        int no = (int)occ.size(); W(&no, 4); W(occ.data(), occ.size() * 4);
        for (int l = 0; l < NL; ++l) {
            std::vector<int> em;
            if (a != b && m.inten[a][l] == 0.f && m.inten[b][l] > 0.f) em.push_back(host_vox(&m.L[3 * l]));
            int ne = (int)em.size(); W(&ne, 4); W(em.data(), em.size() * 4);
        }
    }
    fclose(f);
}

static double secs_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
}

static int prep_mode(const char* in_path, const char* out_path, int target) {
    if (NL != 3) { fprintf(stderr, "prep : utiliser poc_gpu_l3 (scenes maillees a 3 lampes)\n"); return 1; }
    auto t0 = std::chrono::steady_clock::now();
    MeshIn M = read_mesh(in_path);
    fprintf(stderr, "[prep] %d triangles\n", M.nt);
    MeshScene m;
    float hi[3];
    for (int a = 0; a < 3; ++a) { m.lo[a] = 1e30f; hi[a] = -1e30f; }
    for (size_t k = 0; k < M.V.size(); ++k) { int a = k % 3; m.lo[a] = std::min(m.lo[a], M.V[k]); hi[a] = std::max(hi[a], M.V[k]); }
    float diag = sqrtf((hi[0] - m.lo[0]) * (hi[0] - m.lo[0]) + (hi[1] - m.lo[1]) * (hi[1] - m.lo[1]) + (hi[2] - m.lo[2]) * (hi[2] - m.lo[2]));
    for (int a = 0; a < 3; ++a) { float pad = 0.01f * diag + 0.05f; m.lo[a] -= pad; hi[a] += pad; m.ext[a] = hi[a] - m.lo[a]; }
    set_bounds(m.lo, m.ext);

    // 1. BVH
    std::vector<int> order;
    build_bvh(M, m.BN, order);
    m.ST.resize(9 * (size_t)M.nt); m.STN.resize(4 * (size_t)M.nt);
    for (int j = 0; j < M.nt; ++j) {
        const float* v = &M.V[9 * (size_t)order[j]];
        float* T = &m.ST[9 * (size_t)j];
        for (int x = 0; x < 3; ++x) { T[x] = v[x]; T[3 + x] = v[3 + x] - v[x]; T[6 + x] = v[6 + x] - v[x]; }
        float cr[3] = {T[4] * T[8] - T[5] * T[7], T[5] * T[6] - T[3] * T[8], T[3] * T[7] - T[4] * T[6]};
        float l = sqrtf(cr[0] * cr[0] + cr[1] * cr[1] + cr[2] * cr[2]); l = l > 0 ? l : 1.f;
        int fl = M.ds[order[j]] ? 1 : 0;
        m.STN[4 * (size_t)j] = cr[0] / l; m.STN[4 * (size_t)j + 1] = cr[1] / l; m.STN[4 * (size_t)j + 2] = cr[2] / l;
        memcpy(&m.STN[4 * (size_t)j + 3], &fl, 4);
    }
    fprintf(stderr, "[prep] BVH : %zu noeuds (%.1f s)\n", m.BN.size(), secs_since(t0));

    // 2. points de cache (h ajuste pour viser target points)
    double atot = 0;
    for (int t = 0; t < M.nt; ++t) {
        const float* v = &M.V[9 * (size_t)t];
        float e1[3] = {v[3] - v[0], v[4] - v[1], v[5] - v[2]}, e2[3] = {v[6] - v[0], v[7] - v[1], v[8] - v[2]};
        float cr[3] = {e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]};
        atot += 0.5 * sqrt((double)cr[0] * cr[0] + (double)cr[1] * cr[1] + (double)cr[2] * cr[2]) * (M.ds[t] ? 2 : 1);
    }
    std::unordered_map<unsigned long long, CellRec> cells;
    m.h = (float)sqrt(atot / target);
    for (int it = 0; it < 5; ++it) {
        sample_cells(M, m.h, m.lo, cells);
        double ratio = (double)cells.size() / target;
        fprintf(stderr, "[prep] cellule %.3f m -> %zu points\n", m.h, cells.size());
        if (fabs(ratio - 1.0) < 0.08 || it == 4) break;
        m.h *= (float)std::min(2.0, std::max(0.5, sqrt(ratio)));
    }
    std::vector<std::pair<unsigned long long, unsigned long long>> keys;   // (morton, cle)
    for (auto& kv : cells) {
        int cx, cy, cz, b; decode_key(kv.first, cx, cy, cz, b);
        keys.push_back({(spread3(cx) | spread3(cy) << 1 | spread3(cz) << 2) * 8 + b, kv.first});
    }
    std::sort(keys.begin(), keys.end());
    m.npst = (int)keys.size();
    size_t HS = 1024; while (HS < 2 * (size_t)m.npst) HS <<= 1;
    m.HK.assign(HS, 0ull); m.HV.assign(HS, -1);
    std::unordered_map<unsigned long long, int> zone;
    for (int i = 0; i < m.npst; ++i) {
        const CellRec& c = cells[keys[i].second];
        for (int x = 0; x < 3; ++x) { m.Pst.push_back(c.p[x]); m.Nst.push_back(c.n[x]); }
        m.A.push_back((float)(c.wsum > 0 ? c.asum / c.wsum : 0.5));
        unsigned long long k = keys[i].second;
        size_t hh = (size_t)mix64(k) & (HS - 1);
        while (m.HK[hh] != 0ull) hh = (hh + 1) & (HS - 1);
        m.HK[hh] = k; m.HV[hh] = i;
        int cx, cy, cz, b; decode_key(k, cx, cy, cz, b);   // zone de verification : 4 x 4 x 4 cellules, meme direction
        auto z = zone.try_emplace(cell_key(cx >> 2, cy >> 2, cz >> 2, b), (int)zone.size());
        m.region.push_back(z.first->second);
    }
    cells.clear();
    m.NR = (int)zone.size();
    fprintf(stderr, "[prep] %d points de cache, %d zones (%.1f s)\n", m.npst, m.NR, secs_since(t0));

    // 3. lampes et cube : points libres sondes par rayons
    DevState g{};
    g.ST = dput(m.ST); g.STN = (const float4*)dput(m.STN);
    { std::vector<float> bn(8 * m.BN.size()); memcpy(bn.data(), m.BN.data(), bn.size() * 4); g.BN = (const float4*)dput(bn); }
    const int NC = 16384;
    std::vector<float> C(3 * NC);
    { HostRng r(12345); for (int i = 0; i < NC; ++i) for (int a = 0; a < 3; ++a) C[3 * i + a] = m.lo[a] + m.ext[a] * (0.03f + 0.94f * r.u()); }
    float* dC = dput(C); float* dO = dalloc<float>(3 * NC);
    (k_probe<<<(NC + 127) / 128, 128>>>(g, dC, NC, diag, dO), DBG_K("k_probe"));
    std::vector<float> O(3 * NC); CK(cudaMemcpy(O.data(), dO, O.size() * 4, cudaMemcpyDeviceToHost));
    auto dist = [&](int a, const float* p) { float d = 0; for (int x = 0; x < 3; ++x) d += (C[3 * a + x] - p[x]) * (C[3 * a + x] - p[x]); return sqrtf(d); };
    std::vector<int> ok;
    float cmin = std::max(0.3f, 0.015f * diag), emin = 0.5f;
    for (int tries = 0; tries < 6 && ok.size() < 16; ++tries) {
        ok.clear();
        for (int i = 0; i < NC; ++i) if (O[3 * i] >= cmin && O[3 * i] < 1e29f && O[3 * i + 1] >= emin && O[3 * i + 2] <= 0.05f) ok.push_back(i);
        if (ok.size() < 16) { cmin *= 0.6f; emin = std::max(0.25f, emin - 0.1f); }
    }
    if (ok.size() < 3) { fprintf(stderr, "[prep] ERREUR : pas assez d'espace libre pour placer les lampes\n"); return 1; }
    // lampes a mi-hauteur (15 a 60 % de la hauteur de la scene), comme des lampes d'interieur ou des lampadaires
    std::vector<int> okL;
    for (int i : ok) { float zr = (C[3 * i + 2] - m.lo[2]) / m.ext[2]; if (zr >= 0.15f && zr <= 0.6f) okL.push_back(i); }
    if (okL.size() < 3) okL = ok;
    std::vector<int> Li;
    Li.push_back(*std::max_element(okL.begin(), okL.end(), [&](int a, int b) { return O[3 * a] < O[3 * b]; }));
    std::vector<float> cl; for (int i : okL) cl.push_back(O[3 * i]);
    std::nth_element(cl.begin(), cl.begin() + cl.size() / 2, cl.end());
    float cmed = cl[cl.size() / 2];
    while ((int)Li.size() < NL) {   // le plus loin des lampes deja placees, parmi les points les plus degages
        int best = -1; float bd = -1;
        for (int i : okL) {
            if (O[3 * i] < cmed) continue;
            float d = 1e30f; for (int j : Li) d = std::min(d, dist(i, &C[3 * j]));
            if (d > bd) { bd = d; best = i; }
        }
        Li.push_back(best);
    }
    for (int j : Li) for (int x = 0; x < 3; ++x) m.L.push_back(C[3 * j + x]);
    float b = std::min(2.5f, std::max(0.25f, 0.06f * diag));
    int ia = -1, ib = -1;
    for (int tries = 0; tries < 8 && (ia < 0 || ib < 0); ++tries, b *= 0.75f) {
        ia = ib = -1; float da = 1e30f, db = 1e30f;
        for (int i : ok) {
            if (O[3 * i] < 1.0f * b) continue;
            bool libre = true; for (int l = 0; l < NL; ++l) if (dist(i, &m.L[3 * l]) < 1.2f * b) libre = false;
            if (!libre) continue;
            float d0 = dist(i, &m.L[0]);
            if (d0 < da) { da = d0; ia = i; }
        }
        if (ia < 0) continue;
        for (int i : ok) {
            if (O[3 * i] < 1.0f * b || dist(i, &C[3 * ia]) < 2.f * b) continue;
            bool libre = true; for (int l = 0; l < NL; ++l) if (dist(i, &m.L[3 * l]) < 1.2f * b) libre = false;
            if (!libre) continue;
            float d1 = dist(i, &m.L[3]);
            if (d1 < db) { db = d1; ib = i; }
        }
        if (ia >= 0 && ib >= 0) break;
    }
    if (ia < 0 || ib < 0) { fprintf(stderr, "[prep] ERREUR : pas de place pour le cube mobile\n"); return 1; }
    m.boxe = 0.5f * b;
    for (int x = 0; x < 3; ++x) { m.boxc[0][x] = C[3 * ia + x]; m.boxc[1][x] = C[3 * ib + x]; }
    m.bnu = std::max(2, (int)std::lround(b / m.h));
    m.nbox = 6 * m.bnu * m.bnu;
    for (int k = 0; k < m.nbox; ++k) m.A.push_back(0.7f);
    {   // zones du cube : 4 x 4 points par zone et par face
        int tu = (m.bnu + 3) / 4;
        for (int q = 0; q < 6; ++q) for (int iv = 0; iv < m.bnu; ++iv) for (int iu = 0; iu < m.bnu; ++iu)
            m.region.push_back(m.NR + q * tu * tu + (iv / 4) * tu + iu / 4);
        m.NR += 6 * tu * tu;
    }
    // 4. etats : (lampes 0, 1, 2 ; position du cube)
    const float I[5][3] = {{1, 1, 0}, {0, 1, 0}, {1, 1, 0}, {1, 1, 1}, {0, 1, 0}};
    const int BP[5] = {0, 0, 1, 0, 1};
    for (int si = 0; si < 5; ++si) { m.inten.push_back(std::vector<float>(I[si], I[si] + 3)); m.boxpos.push_back(BP[si]); }
    fprintf(stderr, "[prep] lampes (%.2f %.2f %.2f) (%.2f %.2f %.2f) (%.2f %.2f %.2f), cube %.2f m (%.1f s)\n",
            m.L[0], m.L[1], m.L[2], m.L[3], m.L[4], m.L[5], m.L[6], m.L[7], m.L[8], b, secs_since(t0));
    write_mesh_scene(out_path, m, false);

    // 5. references (meme systeme que le cache, converge)
    Scene S = load(out_path);
    const int Np = S.Np;
    // iterations : Wm de chauffe (rebonds), puis blocs de TB iterations moyennees jusqu'a un bruit propre < cible
    int K = 32, Wm = 16, TB = 64, Tmax = 2048;
    double cible = 0.03;
    if (const char* e = getenv("PREP_BRUIT_CIBLE")) cible = atof(e);
    if (const char* e = getenv("PREP_ITER_MAX")) Tmax = std::max(TB, atoi(e));
    int B = 256, G = (Np + B - 1) / B;
    size_t shm = S.Nt * 10 * sizeof(float);
    float *Lin = dalloc<float>(NL * (size_t)Np), *Lout = dalloc<float>(NL * (size_t)Np), *closec = dalloc<float>(Np);
    float* acc[2] = {dalloc<float>(NL * (size_t)Np), dalloc<float>(NL * (size_t)Np)};
    {   // normalisation : eclairement direct moyen = 1 dans l'etat 0
        std::vector<float> Ed(NL * (size_t)Np);
        CK(cudaMemcpy(Ed.data(), S.st[0].Edir, Ed.size() * 4, cudaMemcpyDeviceToHost));
        double sm = 0; for (float x : Ed) sm += x;
        float cn = sm > 0 ? (float)(Np / sm) : 1.f;
        for (auto& v : m.inten) for (auto& x : v) x *= cn;
        fprintf(stderr, "[prep] facteur d'intensite %.4g\n", cn);
        // l'eclairement direct est lineaire en intensite : on recharge pour repartir des intensites normalisees
        write_mesh_scene(out_path, m, false);
    }
    S = load(out_path);
    std::vector<double> noise;
    double vfrac = 0;
    float* Lc2[2] = {dalloc<float>(NL * (size_t)Np), dalloc<float>(NL * (size_t)Np)};   // etat courant de chaque chaine
    std::vector<int> iters;
    for (int si = 0; si < S.NS; ++si) {
        CK(cudaMemset(closec, 0, Np * 4));
        std::vector<float> a0(NL * (size_t)Np), a1(NL * (size_t)Np), cc(Np), ref(Np), Pw(NL * (size_t)Np);
        std::vector<uint8_t> val(Np);
        for (int ch = 0; ch < 2; ++ch) { CK(cudaMemset(Lc2[ch], 0, NL * (size_t)Np * 4)); CK(cudaMemset(acc[ch], 0, NL * (size_t)Np * 4)); }
        int it_done = 0, T = 0; double nz = 1.0; int nv = 0;
        while (true) {
            int n_it = it_done == 0 ? Wm + TB : TB;
            for (int ch = 0; ch < 2; ++ch) {
                float* a = Lc2[ch];
                for (int k = 0; k < n_it; ++k) {
                    int it = it_done + k;
                    (k_ref<<<G, B, shm>>>(S.st[si], S.dA, a, Lout, acc[ch], closec, Np, (uint32_t)mix64(0x51ull + 7919ull * si + 104729ull * ch + 31ull * it), K, it >= Wm, ch == 0), DBG_K("k_ref"));
                    std::swap(a, Lout);
                }
                if (a != Lc2[ch]) { std::swap(Lout, a); CK(cudaMemcpy(Lc2[ch], Lout, NL * (size_t)Np * 4, cudaMemcpyDeviceToDevice)); }
            }
            it_done += n_it; T = it_done - Wm;
            CK(cudaMemcpy(a0.data(), acc[0], a0.size() * 4, cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(a1.data(), acc[1], a1.size() * 4, cudaMemcpyDeviceToHost));
            CK(cudaMemcpy(cc.data(), closec, Np * 4, cudaMemcpyDeviceToHost));
            double d2 = 0, rs = 0; nv = 0;
            for (int i = 0; i < Np; ++i) {
                float e0 = 0, e1 = 0;
                for (int l = 0; l < NL; ++l) {
                    float x0 = a0[NL * (size_t)i + l] / T, x1 = a1[NL * (size_t)i + l] / T;
                    Pw[NL * (size_t)i + l] = 0.5f * (x0 + x1); e0 += x0; e1 += x1;
                }
                ref[i] = 0.5f * (e0 + e1);
                val[i] = cc[i] / ((double)K * it_done) < 0.3;
                if (val[i]) { d2 += 0.25 * (e0 - e1) * (e0 - e1); rs += ref[i]; nv++; }
            }
            nz = nv && rs > 0 ? sqrt(d2 / nv) / (rs / nv) : 0.0;
            if (nz <= cible || T >= Tmax) break;
        }
        noise.push_back(nz); iters.push_back(T);
        vfrac += (double)nv / Np / S.NS;
        m.ref.push_back(ref); m.Pw.push_back(Pw); m.valid.push_back(val);
        fprintf(stderr, "[prep] reference etat %d : bruit propre %.2f %% apres %d iterations, %d points valides (%.1f s)\n", si, 100 * nz, T, nv, secs_since(t0));
    }
    write_mesh_scene(out_path, m, true);
    printf("{\"type\":\"prep\",\"triangles\":%d,\"np\":%d,\"cellule_m\":%.4f,\"zones\":%d,\"diag_m\":%.2f,\"cube_m\":%.2f,\"bvh_noeuds\":%zu,"
           "\"points_valides\":%.4f,\"bruit_ref\":[", M.nt, m.npst + m.nbox, m.h, m.NR, diag, b, m.BN.size(), vfrac);
    for (size_t k = 0; k < noise.size(); ++k) printf("%s%.5f", k ? "," : "", noise[k]);
    printf("],\"iterations_ref\":[");
    for (size_t k = 0; k < iters.size(); ++k) printf("%s%d", k ? "," : "", iters[k]);
    printf("],\"lampes\":[");
    for (int l = 0; l < NL; ++l) printf("%s[%.3f,%.3f,%.3f]", l ? "," : "", m.L[3 * l], m.L[3 * l + 1], m.L[3 * l + 2]);
    printf("],\"secondes\":%.1f}\n", secs_since(t0));
    return 0;
}
