#pragma once

#include <pxr/pxr.h>
#include <pxr/base/tf/declarePtrs.h>
#include <pxr/usd/sdf/fileFormat.h>

#include <string>

PXR_NAMESPACE_OPEN_SCOPE

TF_DECLARE_WEAK_AND_REF_PTRS(RdcFileFormat);

/// Format de fichier USD pour les caches .rdc.
///
/// v0 « hello » : le fichier est un texte minimal (« RDC-HELLO », puis des
/// lignes clé=valeur) et le plugin génère un cube animé. Il sert uniquement à
/// valider la chaîne plugin -> USD de Blender -> import -> rendu Cycles.
/// Le vrai lecteur (SdfAbstractData, décodage à la demande) arrive en phase 2.
class RdcFileFormat : public SdfFileFormat
{
public:
    bool CanRead(const std::string& file) const override;

    bool Read(SdfLayer* layer,
              const std::string& resolvedPath,
              bool metadataOnly) const override;

protected:
    SDF_FILE_FORMAT_FACTORY_ACCESS;

    RdcFileFormat();
    ~RdcFileFormat() override;
};

PXR_NAMESPACE_CLOSE_SCOPE
