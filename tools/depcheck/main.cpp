// depcheck : vérifie que chaque dépendance vcpkg se lie et fonctionne, par un
// petit aller-retour réel (compression, conversion, écriture/lecture).

#include <Alembic/AbcCoreOgawa/All.h>
#include <Alembic/AbcGeom/All.h>
#include <meshoptimizer.h>
#include <nanovdb/NanoVDB.h>
#include <nanovdb/tools/CreateNanoGrid.h>
#include <openvdb/io/Stream.h>
#include <openvdb/openvdb.h>
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

#include <cmath>
#include <cstdio>
#include <filesystem>
#include <sstream>
#include <vector>

namespace {

int g_failures = 0;

void report(bool ok, const char* what)
{
    std::printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    g_failures += ok ? 0 : 1;
}

void checkZstd()
{
    std::vector<int> src(1 << 18);
    for (size_t i = 0; i < src.size(); ++i) {
        src[i] = int(100.0 * std::sin(i * 0.01)); // petits entiers lisses
    }
    const size_t srcBytes = src.size() * sizeof(int);
    std::vector<char> dst(ZSTD_compressBound(srcBytes));
    const size_t csize = ZSTD_compress(dst.data(), dst.size(), src.data(), srcBytes, 3);
    std::vector<int> back(src.size());
    const size_t dsize = ZSTD_decompress(back.data(), srcBytes, dst.data(), csize);
    std::printf("      zstd %s : 1 Mo -> %zu octets (x%.1f)\n", ZSTD_versionString(),
                csize, double(srcBytes) / csize);
    report(!ZSTD_isError(csize) && dsize == srcBytes && back == src, "zstd aller-retour");
}

void checkMeshopt()
{
    const unsigned n = 100; // grille 100x100 sommets
    std::vector<unsigned> idx;
    for (unsigned y = 0; y + 1 < n; ++y) {
        for (unsigned x = 0; x + 1 < n; ++x) {
            const unsigned a = y * n + x, b = a + 1, c = a + n, d = c + 1;
            idx.insert(idx.end(), {a, b, c, b, d, c});
        }
    }
    const float before =
        meshopt_analyzeVertexCache(idx.data(), idx.size(), n * n, 16, 0, 0).acmr;
    std::vector<unsigned> opt(idx.size());
    meshopt_optimizeVertexCache(opt.data(), idx.data(), idx.size(), n * n);
    const float after =
        meshopt_analyzeVertexCache(opt.data(), opt.size(), n * n, 16, 0, 0).acmr;
    std::printf("      meshoptimizer %d : ACMR %.2f -> %.2f\n", MESHOPTIMIZER_VERSION,
                before, after);
    report(after <= before, "meshoptimizer optimisation du cache");
}

void checkZfp()
{
    const size_t n = 64;
    std::vector<float> field(n * n * n);
    for (size_t z = 0; z < n; ++z)
        for (size_t y = 0; y < n; ++y)
            for (size_t x = 0; x < n; ++x)
                field[(z * n + y) * n + x] =
                    std::sin(x * 0.1f) * std::cos(y * 0.13f) * std::sin(z * 0.07f + 1.f);
    const double tol = 1e-3;
    zfp_field* f = zfp_field_3d(field.data(), zfp_type_float, n, n, n);
    zfp_stream* zs = zfp_stream_open(nullptr);
    zfp_stream_set_accuracy(zs, tol);
    std::vector<unsigned char> buf(zfp_stream_maximum_size(zs, f));
    bitstream* bs = stream_open(buf.data(), buf.size());
    zfp_stream_set_bit_stream(zs, bs);
    zfp_stream_rewind(zs);
    const size_t csize = zfp_compress(zs, f);

    std::vector<float> back(field.size());
    zfp_field* g = zfp_field_3d(back.data(), zfp_type_float, n, n, n);
    zfp_stream_rewind(zs);
    const bool ok = zfp_decompress(zs, g) != 0;
    double maxErr = 0;
    for (size_t i = 0; i < field.size(); ++i)
        maxErr = std::max(maxErr, double(std::abs(field[i] - back[i])));
    std::printf("      zfp %s : 64^3 float, précision %.0e -> x%.1f, erreur max %.2e\n",
                ZFP_VERSION_STRING, tol, double(field.size() * 4) / csize, maxErr);
    report(ok && csize > 0 && maxErr <= tol, "zfp précision fixe");
    zfp_field_free(f);
    zfp_field_free(g);
    zfp_stream_close(zs);
    stream_close(bs);
}

void checkVdb()
{
    openvdb::initialize();
    auto grid = openvdb::FloatGrid::create(0.f);
    grid->setName("density");
    auto acc = grid->getAccessor();
    const int n = 64;
    for (int z = 0; z < n; ++z)
        for (int y = 0; y < n; ++y)
            for (int x = 0; x < n; ++x) {
                const float dx = x - 32.f, dy = y - 32.f, dz = z - 32.f;
                const float v = 1.f - std::sqrt(dx * dx + dy * dy + dz * dz) / 30.f;
                if (v > 0.f) acc.setValue(openvdb::Coord(x, y, z), v);
            }

    std::ostringstream os(std::ios_base::binary);
    openvdb::io::Stream stream(os);
    stream.setCompression(openvdb::io::COMPRESS_BLOSC);
    stream.write(openvdb::GridCPtrVec{grid});
    const size_t vdbBytes = os.str().size();
    std::printf("      OpenVDB %s : %zu voxels actifs, Blosc %zu octets\n",
                openvdb::getLibraryVersionString(),
                size_t(grid->activeVoxelCount()), vdbBytes);
    report(grid->activeVoxelCount() > 0 && vdbBytes > 0, "OpenVDB grille + écriture Blosc");

    auto fp32 = nanovdb::tools::createNanoGrid(*grid);
    auto fp8 = nanovdb::tools::createNanoGrid<openvdb::FloatGrid, nanovdb::Fp8>(*grid);
    const auto* nano = fp32.grid<float>();
    const float probe = nano ? nano->getAccessor().getValue(nanovdb::Coord(32, 32, 32)) : -1.f;
    std::printf("      NanoVDB %d.%d : float %zu octets, Fp8 %zu octets\n",
                NANOVDB_MAJOR_VERSION_NUMBER, NANOVDB_MINOR_VERSION_NUMBER,
                size_t(fp32.size()), size_t(fp8.size()));
    report(nano && std::abs(probe - 1.f) < 1e-6f && fp8.size() < fp32.size(),
           "NanoVDB conversion float et Fp8");
}

void checkAlembic()
{
    using namespace Alembic;
    const auto path = (std::filesystem::temp_directory_path() / "rdc_depcheck.abc").string();
    const std::vector<Imath::V3f> pts = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}};
    const std::vector<int32_t> indices = {0, 1, 2, 3}, counts = {4};
    {
        Abc::OArchive archive(AbcCoreOgawa::WriteArchive(), path);
        const uint32_t ts = archive.addTimeSampling(
            AbcCoreAbstract::TimeSampling(1.0 / 24.0, 0.0));
        AbcGeom::OPolyMesh mesh(archive.getTop(), "quad", ts);
        auto& schema = mesh.getSchema();
        schema.set(AbcGeom::OPolyMeshSchema::Sample(
            AbcGeom::V3fArraySample(pts), AbcGeom::Int32ArraySample(indices),
            AbcGeom::Int32ArraySample(counts)));
        std::vector<Imath::V3f> moved = pts;
        for (auto& p : moved) p.z += 0.5f;
        AbcGeom::OPolyMeshSchema::Sample s;
        s.setPositions(AbcGeom::P3fArraySample(moved));
        schema.set(s);
    }
    size_t samples = 0;
    {
        Abc::IArchive archive(AbcCoreOgawa::ReadArchive(), path);
        AbcGeom::IPolyMesh mesh(archive.getTop(), "quad");
        samples = mesh.getSchema().getNumSamples();
    }
    std::filesystem::remove(path);
    std::printf("      Alembic %s : %zu échantillons relus\n",
                AbcCoreAbstract::GetLibraryVersionShort().c_str(), samples);
    report(samples == 2, "Alembic Ogawa écriture + lecture");
}

} // namespace

int main()
{
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    checkZstd();
    checkMeshopt();
    checkZfp();
    checkVdb();
    checkAlembic();
    std::printf("\nRESULTAT : %s (%d échec(s))\n", g_failures ? "ECHEC" : "OK", g_failures);
    return g_failures ? 1 : 0;
}
