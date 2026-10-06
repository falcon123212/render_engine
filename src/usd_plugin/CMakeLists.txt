add_library(rdcUsd SHARED
    fileFormat.cpp
    fileFormat.h
)

target_link_libraries(rdcUsd PRIVATE blender::usd)

# TF_REGISTRY_FUNCTION s'appuie sur le nom de paquet MFB.
target_compile_definitions(rdcUsd PRIVATE
    MFB_PACKAGE_NAME=rdcUsd
    MFB_ALT_PACKAGE_NAME=rdcUsd
)

# Disposition du plugin (point d'entrée de PXR_PLUGINPATH_NAME) :
#   <build>/plugin/rdcUsd.dll
#   <build>/plugin/rdcUsd/resources/plugInfo.json
set(RDC_PLUGIN_DIR "${CMAKE_BINARY_DIR}/plugin")
set(RDC_PLUGIN_RESOURCES "${RDC_PLUGIN_DIR}/rdcUsd/resources" PARENT_SCOPE)

# plugInfo.json doit être en UTF-8 sans BOM, sinon USD le rejette.
configure_file(plugInfo.json "${RDC_PLUGIN_DIR}/rdcUsd/resources/plugInfo.json" @ONLY)

add_custom_command(TARGET rdcUsd POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_FILE:rdcUsd>" "${RDC_PLUGIN_DIR}/"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "$<TARGET_PDB_FILE:rdcUsd>" "${RDC_PLUGIN_DIR}/"
)
