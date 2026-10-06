// vdbref : mesure les références « volumes » du banc sur des grilles float.
//
//   vdbref <fichier.vdb|dossier> [--tol T | --tol-rel R] [--json sortie.json]
//
// Pour chaque grille float (somme sur les images d'un dossier) :
//   - OpenVDB float32 + Blosc (taille de la grille sérialisée seule) ;
//   - NanoVDB float, Fp16, Fp8, FpN (oracle à erreur absolue T), avec
//     l'erreur maximale mesurée sur les voxels actifs ;
//   - NanoVDB Fp8 + zstd -19 (ce que gagne un simple codage entropique) ;
//   - ZFP précision fixe T par feuille 8^3, topologie (origine + masque) en
//     sus, avec l'erreur maximale mesurée.
// T par défaut : demi-pas d'une quantification 8 bits de la plage de la
// grille (--tol-rel 0.5/255), soit l'erreur visée par une quantification Fp8.
// Les grilles vectorielles (vitesse) ne sont pas encore traitées.

#include <nanovdb/NanoVDB.h>
#include <nanovdb/tools/CreateNanoGrid.h>
#include <openvdb/io/Stream.h>
#include <openvdb/io/File.h>
#include <openvdb/openvdb.h>
#include <openvdb/tools/Statistics.h>
#include <zfp.h>
#include <zstd.h>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

struct Measure
{
    unsigned long long bytes = 0;
    double maxErr = 0;
};

using Results = std::map<std::string, Measure>; // méthode -> mesure

size_t zstdSize(const void* data, size_t n, int level)
{
    std::vector<char> out(ZSTD_compressBound(n));
    const size_t c = ZSTD_compress(out.data(), out.size(), data, n, level);
    return ZSTD_isError(c) ? n : c;
}

template<typename BuildT>
double maxErrNano(const nanovdb::NanoGrid<BuildT>* nano, const openvdb::FloatGrid& src)
{
    auto acc = nano->getAccessor();
    double e = 0;
    for (auto it = src.cbeginValueOn(); it; ++it) {
        const auto c = it.getCoord();
        const float v = acc.getValue(nanovdb::Coord(c.x(), c.y(), c.z()));
        e = std::max(e, double(std::abs(v - *it)));
    }
    return e;
}

void measureGrid(const openvdb::FloatGrid& grid, double tol, Results& r)
{
    // OpenVDB float32 + Blosc.
    {
        std::ostringstream os(std::ios_base::binary);
        openvdb::io::Stream stream(os);
        stream.setCompression(openvdb::io::COMPRESS_BLOSC | openvdb::io::COMPRESS_ACTIVE_MASK);
        auto copy = grid.deepCopy();
        copy->setSaveFloatAsHalf(false);
        stream.write(openvdb::GridCPtrVec{copy});
        r["openvdb_blosc"].bytes += os.str().size();
    }
    // NanoVDB.
    {
        auto h = nanovdb::tools::createNanoGrid(grid);
        r["nanovdb_float"].bytes += h.size();
    }
    {
        auto h = nanovdb::tools::createNanoGrid<openvdb::FloatGrid, nanovdb::Fp16>(grid);
        auto& m = r["nanovdb_fp16"];
        m.bytes += h.size();
        m.maxErr = std::max(m.maxErr, maxErrNano(h.grid<nanovdb::Fp16>(), grid));
    }
    {
        auto h = nanovdb::tools::createNanoGrid<openvdb::FloatGrid, nanovdb::Fp8>(grid);
        auto& m = r["nanovdb_fp8"];
        m.bytes += h.size();
        const double e = maxErrNano(h.grid<nanovdb::Fp8>(), grid);
        m.maxErr = std::max(m.maxErr, e);
        auto& z = r["nanovdb_fp8_zstd19"];
        z.bytes += zstdSize(h.data(), h.size(), 19);
        z.maxErr = std::max(z.maxErr, e);
    }
    {
        auto h = nanovdb::tools::createNanoGrid<openvdb::FloatGrid, nanovdb::FpN>(
            grid, nanovdb::tools::StatsMode::Default, nanovdb::CheckMode::Default, false, 0,
            nanovdb::tools::AbsDiff(float(tol)));
        auto& m = r["nanovdb_fpn"];
        m.bytes += h.size();
        m.maxErr = std::max(m.maxErr, maxErrNano(h.grid<nanovdb::FpN>(), grid));
    }
    // ZFP précision fixe par feuille 8^3 (+ origine 12 o et masque 64 o par feuille).
    {
        auto& m = r["zfp_leaf8"];
        float block[512], back[512];
        std::vector<unsigned char> buf;
        zfp_stream* zs = zfp_stream_open(nullptr);
        zfp_stream_set_accuracy(zs, tol);
        for (auto leaf = grid.tree().cbeginLeaf(); leaf; ++leaf) {
            for (int i = 0; i < 512; ++i) block[i] = leaf->getValue(i);
            zfp_field* f = zfp_field_3d(block, zfp_type_float, 8, 8, 8);
            buf.resize(zfp_stream_maximum_size(zs, f));
            bitstream* bs = stream_open(buf.data(), buf.size());
            zfp_stream_set_bit_stream(zs, bs);
            zfp_stream_rewind(zs);
            const size_t n = zfp_compress(zs, f);
            zfp_field* g = zfp_field_3d(back, zfp_type_float, 8, 8, 8);
            zfp_stream_rewind(zs);
            zfp_decompress(zs, g);
            for (auto v = leaf->cbeginValueOn(); v; ++v)
                m.maxErr = std::max(m.maxErr, double(std::abs(back[v.pos()] - *v)));
            m.bytes += n + 12 + 64;
            zfp_field_free(f);
            zfp_field_free(g);
            stream_close(bs);
        }
        zfp_stream_close(zs);
    }
}

} // namespace

int main(int argc, char** argv)
{
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    openvdb::initialize();
    fs::path input, jsonPath;
    double tolAbs = -1, tolRel = 0.5 / 255.0;
    for (int i = 1; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--tol" && i + 1 < argc) tolAbs = std::stod(argv[++i]);
        else if (a == "--tol-rel" && i + 1 < argc) tolRel = std::stod(argv[++i]);
        else if (a == "--json" && i + 1 < argc) jsonPath = argv[++i];
        else input = a;
    }
    if (input.empty()) {
        std::fprintf(stderr, "usage : vdbref <fichier.vdb|dossier> [--tol T | --tol-rel R]"
                             " [--json sortie.json]\n");
        return 2;
    }
    std::vector<fs::path> files;
    if (fs::is_directory(input)) {
        for (const auto& e : fs::directory_iterator(input))
            if (e.path().extension() == ".vdb") files.push_back(e.path());
        std::sort(files.begin(), files.end());
    } else {
        files.push_back(input);
    }

    const auto t0 = std::chrono::steady_clock::now();
    std::map<std::string, Results> perGrid;
    std::map<std::string, std::pair<double, unsigned long long>> info; // tol, voxels
    for (const auto& path : files) {
        openvdb::io::File file(path.string());
        file.open(false);
        for (auto it = file.beginName(); it != file.endName(); ++it) {
            auto grid = openvdb::gridPtrCast<openvdb::FloatGrid>(file.readGrid(*it));
            if (!grid) continue;
            double tol = tolAbs;
            if (tol <= 0) {
                const auto ex = openvdb::tools::extrema(grid->cbeginValueOn());
                tol = tolRel * std::max(1e-12, ex.max() - ex.min());
            }
            measureGrid(*grid, tol, perGrid[it.gridName()]);
            auto& in = info[it.gridName()];
            in.first = std::max(in.first, tol);
            in.second += grid->activeVoxelCount();
        }
        file.close();
    }
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    std::ostringstream js;
    js << "{\n  \"source\": \"" << fs::absolute(input).generic_string() << "\",\n  \"frames\": "
       << files.size() << ",\n  \"grids\": {";
    bool firstGrid = true;
    for (const auto& [name, res] : perGrid) {
        const auto base = double(res.at("openvdb_blosc").bytes);
        std::printf("\n%s : %zu image(s), %llu voxels actifs, tolérance %.3g\n", name.c_str(),
                    files.size(), info[name].second, info[name].first);
        std::printf("  %-20s %12s %10s %12s\n", "méthode", "octets", "vs Blosc", "erreur max");
        js << (firstGrid ? "" : ",") << "\n    \"" << name << "\": {\"tolerance\": "
           << info[name].first << ", \"active_voxels\": " << info[name].second
           << ", \"methods\": {";
        firstGrid = false;
        bool firstM = true;
        for (const auto& [m, v] : res) {
            std::printf("  %-20s %12llu %9.2fx %12.3g\n", m.c_str(), v.bytes, base / v.bytes, v.maxErr);
            js << (firstM ? "" : ", ") << "\"" << m << "\": {\"bytes\": " << v.bytes
               << ", \"max_error\": " << v.maxErr << "}";
            firstM = false;
        }
        js << "}}";
    }
    js << "\n  }\n}\n";
    if (!jsonPath.empty()) std::ofstream(jsonPath) << js.str();
    std::printf("\n(%.1f s)\n", secs);
    return 0;
}
