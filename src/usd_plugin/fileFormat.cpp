#include "fileFormat.h"

#include <pxr/base/tf/diagnostic.h>
#include <pxr/base/tf/registryManager.h>
#include <pxr/base/tf/staticTokens.h>
#include <pxr/base/tf/type.h>
#include <pxr/usd/ar/asset.h>
#include <pxr/usd/ar/resolvedPath.h>
#include <pxr/usd/ar/resolver.h>

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <memory>
#include <numbers>
#include <sstream>
#include <string_view>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(
    _tokens,
    ((Id, "rdc"))
    ((Version, "0.1"))
    ((Target, "usd"))
    ((Usda, "usda"))
);

TF_REGISTRY_FUNCTION(TfType)
{
    SDF_DEFINE_FILE_FORMAT(RdcFileFormat, SdfFileFormat);
}

namespace {

constexpr std::string_view kHelloMagic = "RDC-HELLO";

std::shared_ptr<ArAsset> _OpenAsset(const std::string& path)
{
    return ArGetResolver().OpenAsset(ArResolvedPath(path));
}

bool _ReadAll(const std::string& path, std::string* out)
{
    const std::shared_ptr<ArAsset> asset = _OpenAsset(path);
    if (!asset) {
        return false;
    }
    out->resize(asset->GetSize());
    return asset->Read(out->data(), out->size(), 0) == out->size();
}

struct _HelloParams
{
    int frames = 48;
    double fps = 24.0;
};

bool _ParseHello(const std::string& text, _HelloParams* params)
{
    std::istringstream in(text);
    std::string line;
    if (!std::getline(in, line) || line.rfind(kHelloMagic, 0) != 0) {
        return false;
    }
    while (std::getline(in, line)) {
        const size_t eq = line.find('=');
        if (eq == std::string::npos) {
            continue;
        }
        const std::string key = line.substr(0, eq);
        const std::string value = line.substr(eq + 1);
        if (key == "frames") {
            params->frames = std::clamp(std::stoi(value), 1, 100000);
        } else if (key == "fps") {
            params->fps = std::stod(value);
        }
    }
    return true;
}

// Cube de côté 2 posé sur le sol, qui s'écrase et s'étire à volume constant
// en avançant sur X. Même formule que tests/usd/test_hello_plugin.py.
void _CubePoints(int frame, double fps, double out[8][3])
{
    static const double base[8][3] = {
        {-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
        {-1, -1,  1}, {1, -1,  1}, {1, 1,  1}, {-1, 1,  1},
    };
    const double t = static_cast<double>(frame - 1);
    const double s = 1.0 + 0.3 * std::sin(2.0 * std::numbers::pi * t / fps);
    const double sxy = 1.0 / std::sqrt(s);
    for (int i = 0; i < 8; ++i) {
        out[i][0] = base[i][0] * sxy + 0.05 * t;
        out[i][1] = base[i][1] * sxy;
        out[i][2] = (base[i][2] + 1.0) * s;
    }
}

std::string _HelloToUsda(const _HelloParams& p)
{
    std::ostringstream o;
    o << std::setprecision(9);
    o << "#usda 1.0\n(\n"
      << "    defaultPrim = \"Cube\"\n"
      << "    metersPerUnit = 1\n"
      << "    upAxis = \"Z\"\n"
      << "    startTimeCode = 1\n"
      << "    endTimeCode = " << p.frames << "\n"
      << "    timeCodesPerSecond = " << p.fps << "\n"
      << ")\n\n"
      << "def Mesh \"Cube\"\n{\n"
      << "    int[] faceVertexCounts = [4, 4, 4, 4, 4, 4]\n"
      << "    int[] faceVertexIndices = [0, 3, 2, 1, 4, 5, 6, 7, 0, 1, 5, 4,"
         " 1, 2, 6, 5, 2, 3, 7, 6, 3, 0, 4, 7]\n"
      << "    uniform token subdivisionScheme = \"none\"\n";

    double pts[8][3];
    std::ostringstream points, extent;
    points << std::setprecision(9);
    extent << std::setprecision(9);
    for (int f = 1; f <= p.frames; ++f) {
        _CubePoints(f, p.fps, pts);
        double lo[3] = {1e300, 1e300, 1e300};
        double hi[3] = {-1e300, -1e300, -1e300};
        points << "        " << f << ": [";
        for (int i = 0; i < 8; ++i) {
            points << (i ? ", " : "") << "(" << pts[i][0] << ", "
                   << pts[i][1] << ", " << pts[i][2] << ")";
            for (int a = 0; a < 3; ++a) {
                lo[a] = std::min(lo[a], pts[i][a]);
                hi[a] = std::max(hi[a], pts[i][a]);
            }
        }
        points << "],\n";
        extent << "        " << f << ": [(" << lo[0] << ", " << lo[1] << ", "
               << lo[2] << "), (" << hi[0] << ", " << hi[1] << ", " << hi[2]
               << ")],\n";
    }
    o << "    point3f[] points.timeSamples = {\n" << points.str() << "    }\n"
      << "    float3[] extent.timeSamples = {\n" << extent.str() << "    }\n"
      << "}\n";
    return o.str();
}

} // namespace

RdcFileFormat::RdcFileFormat()
    : SdfFileFormat(_tokens->Id, _tokens->Version, _tokens->Target,
                    _tokens->Id.GetString())
{
}

RdcFileFormat::~RdcFileFormat() = default;

bool RdcFileFormat::CanRead(const std::string& file) const
{
    const std::shared_ptr<ArAsset> asset = _OpenAsset(file);
    if (!asset || asset->GetSize() < kHelloMagic.size()) {
        return false;
    }
    std::string head(kHelloMagic.size(), '\0');
    return asset->Read(head.data(), head.size(), 0) == head.size()
        && head == kHelloMagic;
}

bool RdcFileFormat::Read(SdfLayer* layer,
                         const std::string& resolvedPath,
                         bool /*metadataOnly*/) const
{
    std::string text;
    if (!_ReadAll(resolvedPath, &text)) {
        TF_RUNTIME_ERROR("rdc: impossible de lire '%s'", resolvedPath.c_str());
        return false;
    }
    _HelloParams params;
    if (!_ParseHello(text, &params)) {
        TF_RUNTIME_ERROR("rdc: '%s' n'est pas un fichier RDC-HELLO",
                         resolvedPath.c_str());
        return false;
    }

    // v0 : on délègue au lecteur usda, qui remplit les données de la couche.
    const SdfFileFormatConstPtr usda = SdfFileFormat::FindById(_tokens->Usda);
    if (!usda) {
        TF_CODING_ERROR("rdc: format usda introuvable");
        return false;
    }
    return usda->ReadFromString(layer, _HelloToUsda(params));
}

PXR_NAMESPACE_CLOSE_SCOPE
