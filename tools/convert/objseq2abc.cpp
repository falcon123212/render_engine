// objseq2abc : convertit une séquence d'OBJ à topologie fixe (une image par
// fichier, ex. Vlasic et al. 2008) en un Alembic Ogawa « positions seules ».
//
//   objseq2abc <dossier> -o <sortie.abc> [--fps 30] [--name mesh] [--json stats.json]
//
// - Fichiers triés par numéro dans le nom (mesh_0002.obj avant mesh_0010.obj).
// - Topologie lue sur la première image, puis vérifiée sur chaque image.
// - L'Alembic utilise l'ordre horaire des faces : l'ordre OBJ (anti-horaire)
//   est inversé, comme le font les exporteurs Maya/Blender.
// - Le contenu écrit (topologie une fois + positions par image, ni normales
//   ni UV) sert de référence « Alembic Ogawa brut » équitable pour le banc.

#include <Alembic/AbcCoreOgawa/All.h>
#include <Alembic/AbcGeom/All.h>

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>

namespace fs = std::filesystem;

namespace {

struct ObjFrame
{
    std::vector<Imath::V3f> points;
    std::vector<int32_t> counts;
    std::vector<int32_t> indices;
};

const char* skipSpaces(const char* p, const char* end)
{
    while (p < end && (*p == ' ' || *p == '\t')) ++p;
    return p;
}

bool parseObj(const fs::path& path, ObjFrame* out, std::string* err)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        *err = "ouverture impossible";
        return false;
    }
    const std::string text((std::istreambuf_iterator<char>(in)), {});
    out->points.clear();
    out->counts.clear();
    out->indices.clear();

    const char* p = text.data();
    const char* end = p + text.size();
    while (p < end) {
        const char* eol = static_cast<const char*>(std::memchr(p, '\n', end - p));
        if (!eol) eol = end;
        if (eol - p > 2 && p[0] == 'v' && (p[1] == ' ' || p[1] == '\t')) {
            float xyz[3];
            const char* q = p + 2;
            for (float& c : xyz) {
                q = skipSpaces(q, eol);
                const auto r = std::from_chars(q, eol, c);
                if (r.ec != std::errc()) {
                    *err = "sommet illisible";
                    return false;
                }
                q = r.ptr;
            }
            out->points.emplace_back(xyz[0], xyz[1], xyz[2]);
        } else if (eol - p > 2 && p[0] == 'f' && (p[1] == ' ' || p[1] == '\t')) {
            const char* q = p + 2;
            int32_t n = 0;
            const size_t first = out->indices.size();
            while ((q = skipSpaces(q, eol)) < eol && *q != '\r') {
                long idx = 0;
                const auto r = std::from_chars(q, eol, idx);
                if (r.ec != std::errc()) {
                    *err = "face illisible";
                    return false;
                }
                q = r.ptr;
                while (q < eol && *q != ' ' && *q != '\t' && *q != '\r') ++q; // /vt/vn
                // Indices OBJ : base 1, négatifs relatifs à la fin.
                const long resolved = idx > 0 ? idx - 1 : long(out->points.size()) + idx;
                out->indices.push_back(int32_t(resolved));
                ++n;
            }
            std::reverse(out->indices.begin() + first, out->indices.end());
            out->counts.push_back(n);
        }
        p = eol + 1;
    }
    for (int32_t i : out->indices) {
        if (i < 0 || size_t(i) >= out->points.size()) {
            *err = "indice de face hors limites";
            return false;
        }
    }
    return !out->points.empty();
}

// Tri naturel : compare les derniers nombres trouvés dans les noms.
long lastNumber(const fs::path& p)
{
    const std::string s = p.stem().string();
    size_t e = s.find_last_of("0123456789");
    if (e == std::string::npos) return -1;
    size_t b = e;
    while (b > 0 && std::isdigit(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::stol(s.substr(b, e - b + 1));
}

void usage()
{
    std::fprintf(stderr,
        "usage : objseq2abc <dossier> -o <sortie.abc> [--fps 30] [--name mesh]"
        " [--json stats.json]\n");
}

} // namespace

int main(int argc, char** argv)
{
    fs::path inDir, outPath, jsonPath;
    double fps = 30.0;
    std::string name = "mesh";
    for (int i = 1; i < argc; ++i) {
        const std::string_view a = argv[i];
        if (a == "-o" && i + 1 < argc) outPath = argv[++i];
        else if (a == "--fps" && i + 1 < argc) fps = std::stod(argv[++i]);
        else if (a == "--name" && i + 1 < argc) name = argv[++i];
        else if (a == "--json" && i + 1 < argc) jsonPath = argv[++i];
        else if (inDir.empty()) inDir = argv[i];
        else { usage(); return 2; }
    }
    if (inDir.empty() || outPath.empty()) {
        usage();
        return 2;
    }

    std::vector<fs::path> files;
    for (const auto& e : fs::recursive_directory_iterator(inDir)) {
        if (e.is_regular_file() && e.path().extension() == ".obj") files.push_back(e.path());
    }
    std::sort(files.begin(), files.end(), [](const fs::path& a, const fs::path& b) {
        const long na = lastNumber(a), nb = lastNumber(b);
        return na != nb ? na < nb : a < b;
    });
    if (files.empty()) {
        std::fprintf(stderr, "aucun .obj dans %s\n", inDir.string().c_str());
        return 1;
    }

    const auto t0 = std::chrono::steady_clock::now();
    using namespace Alembic;
    Imath::Box3f bounds;
    ObjFrame first, frame;
    std::string err;
    {
        fs::create_directories(outPath.parent_path().empty() ? "." : outPath.parent_path());
        Abc::OArchive archive(AbcCoreOgawa::WriteArchive(), outPath.string());
        const uint32_t ts = archive.addTimeSampling(
            AbcCoreAbstract::TimeSampling(1.0 / fps, 0.0));
        AbcGeom::OPolyMesh mesh(archive.getTop(), name, ts);
        auto& schema = mesh.getSchema();

        for (size_t f = 0; f < files.size(); ++f) {
            ObjFrame& cur = f == 0 ? first : frame;
            if (!parseObj(files[f], &cur, &err)) {
                std::fprintf(stderr, "%s : %s\n", files[f].string().c_str(), err.c_str());
                return 1;
            }
            if (f > 0 && (cur.points.size() != first.points.size()
                          || cur.counts != first.counts || cur.indices != first.indices)) {
                std::fprintf(stderr, "%s : topologie différente de la première image\n",
                             files[f].string().c_str());
                return 1;
            }
            for (const auto& pt : cur.points) bounds.extendBy(pt);
            Imath::Box3d fb;
            for (const auto& pt : cur.points) fb.extendBy(Imath::V3d(pt));
            if (f == 0) {
                schema.set(AbcGeom::OPolyMeshSchema::Sample(
                    AbcGeom::V3fArraySample(cur.points),
                    AbcGeom::Int32ArraySample(first.indices),
                    AbcGeom::Int32ArraySample(first.counts)));
            } else {
                AbcGeom::OPolyMeshSchema::Sample s;
                s.setPositions(AbcGeom::P3fArraySample(cur.points));
                s.setSelfBounds(fb);
                schema.set(s);
            }
        }
    }

    const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    size_t tris = 0;
    for (int32_t c : first.counts) tris += size_t(std::max(0, c - 2));
    const Imath::V3f size = bounds.size();
    const double diag = std::sqrt(double(size.x) * size.x + double(size.y) * size.y
                                  + double(size.z) * size.z);
    const auto abcBytes = fs::file_size(outPath);

    std::ostringstream js;
    js << "{\n"
       << "  \"source\": \"" << fs::absolute(inDir).generic_string() << "\",\n"
       << "  \"abc\": \"" << fs::absolute(outPath).generic_string() << "\",\n"
       << "  \"frames\": " << files.size() << ",\n"
       << "  \"fps\": " << fps << ",\n"
       << "  \"vertices\": " << first.points.size() << ",\n"
       << "  \"faces\": " << first.counts.size() << ",\n"
       << "  \"triangles\": " << tris << ",\n"
       << "  \"bbox_min\": [" << bounds.min.x << ", " << bounds.min.y << ", " << bounds.min.z << "],\n"
       << "  \"bbox_max\": [" << bounds.max.x << ", " << bounds.max.y << ", " << bounds.max.z << "],\n"
       << "  \"bbox_diagonal\": " << diag << ",\n"
       << "  \"raw_position_bytes_per_frame\": " << first.points.size() * 12 << ",\n"
       << "  \"abc_bytes\": " << abcBytes << "\n"
       << "}\n";
    if (!jsonPath.empty()) std::ofstream(jsonPath) << js.str();
    std::printf("%s : %zu images, %zu sommets, %zu faces, diag %.3f, %.1f Mo (%.1f s)\n",
                outPath.filename().string().c_str(), files.size(), first.points.size(),
                first.counts.size(), diag, abcBytes / 1e6, secs);
    return 0;
}
