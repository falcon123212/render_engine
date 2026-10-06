// vdbnorm : normalise des séquences VDB (caches Mantaflow, packs d'artistes,
// nuage Disney) vers le format de référence du banc :
//   - une image par fichier <prefixe>_<NNNN>.vdb ;
//   - grilles renommées : density, temperature, flame, velocity ;
//   - float32 (pas de demi-précision), compression Blosc.
// C'est la référence « OpenVDB + Blosc » des critères.
//
//   vdbnorm --list <fichier.vdb>
//   vdbnorm <dossier|fichier> -o <dossier> [--prefix smoke]
//           [--map src=dst ...] [--json stats.json]
//
// Sans --map, les noms courants sont reconnus (Mantaflow de Blender 5.0 :
// density, temperature, flame, velocity ; Houdini/EmberGen : heat, vel, v...).
// Les grilles vides et non reconnues (ex. « shadow » de Mantaflow) sont omises.

#include <openvdb/io/File.h>
#include <openvdb/openvdb.h>
#include <openvdb/tools/Statistics.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

namespace {

const std::map<std::string, std::string> kDefaultMap = {
    {"density", "density"}, {"smoke", "density"},
    {"heat", "temperature"}, {"temperature", "temperature"}, {"temp", "temperature"},
    {"flame", "flame"}, {"flames", "flame"}, {"fire", "flame"},
    {"velocity", "velocity"}, {"vel", "velocity"}, {"v", "velocity"},
};

long lastNumber(const fs::path& p)
{
    const std::string s = p.stem().string();
    size_t e = s.find_last_of("0123456789");
    if (e == std::string::npos) return -1;
    size_t b = e;
    while (b > 0 && std::isdigit(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::stol(s.substr(b, e - b + 1));
}

void listGrids(const fs::path& path)
{
    openvdb::io::File file(path.string());
    file.open(false);
    std::printf("%s (bibliothèque %s, format %u)\n", path.filename().string().c_str(),
                file.version().c_str(), file.fileVersion());
    for (auto it = file.beginName(); it != file.endName(); ++it) {
        const auto grid = file.readGrid(*it);
        const auto bbox = grid->evalActiveVoxelBoundingBox();
        const auto dim = bbox.dim();
        std::printf("  %-14s %-12s voxel %.4g  actifs %10llu  boîte %dx%dx%d  demi-précision %s\n",
                    it.gridName().c_str(), grid->valueType().c_str(),
                    grid->voxelSize()[0], (unsigned long long)grid->activeVoxelCount(),
                    dim.x(), dim.y(), dim.z(), grid->saveFloatAsHalf() ? "oui" : "non");
    }
    file.close();
}

struct GridStats
{
    std::string name;
    std::string type;
    unsigned long long active = 0;
    double minV = 0, maxV = 0;
};

void usage()
{
    std::fprintf(stderr,
        "usage : vdbnorm --list <fichier.vdb>\n"
        "        vdbnorm <dossier|fichier> -o <dossier> [--prefix seq] [--map src=dst ...]"
        " [--json stats.json]\n");
}

} // namespace

int main(int argc, char** argv)
{
    openvdb::initialize();
    fs::path input, outDir, jsonPath;
    std::string prefix = "frame";
    std::map<std::string, std::string> mapping;
    bool list = false;
    for (int i = 1; i < argc; ++i) {
        const std::string_view a = argv[i];
        if (a == "--list") list = true;
        else if (a == "-o" && i + 1 < argc) outDir = argv[++i];
        else if (a == "--prefix" && i + 1 < argc) prefix = argv[++i];
        else if (a == "--json" && i + 1 < argc) jsonPath = argv[++i];
        else if (a == "--map" && i + 1 < argc) {
            const std::string m = argv[++i];
            const size_t eq = m.find('=');
            if (eq == std::string::npos) { usage(); return 2; }
            mapping[m.substr(0, eq)] = m.substr(eq + 1);
        } else if (input.empty()) input = argv[i];
        else { usage(); return 2; }
    }
    if (input.empty() || (!list && outDir.empty())) {
        usage();
        return 2;
    }
    if (mapping.empty()) mapping = kDefaultMap;

    std::vector<fs::path> files;
    if (fs::is_directory(input)) {
        for (const auto& e : fs::directory_iterator(input))
            if (e.is_regular_file() && e.path().extension() == ".vdb") files.push_back(e.path());
        std::sort(files.begin(), files.end(), [](const fs::path& a, const fs::path& b) {
            const long na = lastNumber(a), nb = lastNumber(b);
            return na != nb ? na < nb : a < b;
        });
    } else {
        files.push_back(input);
    }
    if (files.empty()) {
        std::fprintf(stderr, "aucun .vdb dans %s\n", input.string().c_str());
        return 1;
    }
    if (list) {
        listGrids(files.front());
        return 0;
    }

    fs::create_directories(outDir);
    const auto t0 = std::chrono::steady_clock::now();
    unsigned long long inBytes = 0, outBytes = 0;
    std::ostringstream framesJson;
    for (size_t f = 0; f < files.size(); ++f) {
        openvdb::io::File in(files[f].string());
        in.open(false);
        openvdb::GridPtrVec out;
        std::vector<GridStats> stats;
        for (auto it = in.beginName(); it != in.endName(); ++it) {
            const auto found = mapping.find(it.gridName());
            if (found == mapping.end()) continue;
            openvdb::GridBase::Ptr grid = in.readGrid(*it);
            if (grid->activeVoxelCount() == 0) {
                continue; // ex. « flame » vide dans un cache de fumée
            }
            if (!grid->isType<openvdb::FloatGrid>() && !grid->isType<openvdb::Vec3SGrid>()) {
                std::fprintf(stderr, "  %s : grille '%s' de type %s ignorée\n",
                             files[f].filename().string().c_str(), it.gridName().c_str(),
                             grid->valueType().c_str());
                continue;
            }
            grid->setName(found->second);
            grid->setSaveFloatAsHalf(false);
            GridStats s{found->second, grid->valueType(), grid->activeVoxelCount()};
            if (auto fg = openvdb::gridPtrCast<openvdb::FloatGrid>(grid)) {
                const auto ex = openvdb::tools::extrema(fg->cbeginValueOn());
                s.minV = ex.min();
                s.maxV = ex.max();
            } else if (auto vg = openvdb::gridPtrCast<openvdb::Vec3SGrid>(grid)) {
                const auto ex = openvdb::tools::extrema(vg->cbeginValueOn());
                s.minV = ex.min();
                s.maxV = ex.max(); // normes min/max
            }
            stats.push_back(s);
            out.push_back(grid);
        }
        in.close();
        if (out.empty()) {
            std::fprintf(stderr, "%s : aucune grille reconnue (voir --list, --map)\n",
                         files[f].string().c_str());
            return 1;
        }
        char name[256];
        std::snprintf(name, sizeof(name), "%s_%04zu.vdb", prefix.c_str(), f + 1);
        const fs::path dst = outDir / name;
        openvdb::io::File file(dst.string());
        file.setCompression(openvdb::io::COMPRESS_BLOSC | openvdb::io::COMPRESS_ACTIVE_MASK);
        file.write(out);
        file.close();
        inBytes += fs::file_size(files[f]);
        outBytes += fs::file_size(dst);

        framesJson << (f ? ",\n" : "") << "    {\"frame\": " << f + 1 << ", \"bytes\": "
                   << fs::file_size(dst) << ", \"grids\": [";
        for (size_t g = 0; g < stats.size(); ++g) {
            framesJson << (g ? ", " : "") << "{\"name\": \"" << stats[g].name
                       << "\", \"type\": \"" << stats[g].type << "\", \"active\": "
                       << stats[g].active << ", \"min\": " << stats[g].minV
                       << ", \"max\": " << stats[g].maxV << "}";
        }
        framesJson << "]}";
        if (f == 0 || (f + 1) % 20 == 0 || f + 1 == files.size()) {
            std::printf("  %s :", name);
            for (const auto& s : stats) std::printf(" %s(%llu)", s.name.c_str(), s.active);
            std::printf("\n");
        }
    }
    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    if (!jsonPath.empty()) {
        std::ofstream(jsonPath) << "{\n  \"source\": \"" << fs::absolute(input).generic_string()
            << "\",\n  \"frames_count\": " << files.size() << ",\n  \"input_bytes\": " << inBytes
            << ",\n  \"output_bytes\": " << outBytes << ",\n  \"frames\": [\n"
            << framesJson.str() << "\n  ]\n}\n";
    }
    std::printf("%zu images : %.1f Mo -> %.1f Mo (float32 Blosc) en %.1f s\n", files.size(),
                inBytes / 1e6, outBytes / 1e6, secs);
    return 0;
}
