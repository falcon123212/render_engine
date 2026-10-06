find_package(zstd CONFIG REQUIRED)
find_package(meshoptimizer CONFIG REQUIRED)
find_package(zfp CONFIG REQUIRED)
find_package(Alembic CONFIG REQUIRED)
find_package(OpenVDB REQUIRED COMPONENTS openvdb nanovdb)

add_executable(depcheck depcheck/main.cpp)
target_link_libraries(depcheck PRIVATE
    zstd::libzstd
    meshoptimizer::meshoptimizer
    zfp::zfp
    Alembic::Alembic
    OpenVDB::openvdb
    OpenVDB::nanovdb
)
# Active la conversion OpenVDB -> NanoVDB dans les en-têtes NanoVDB.
target_compile_definitions(depcheck PRIVATE NANOVDB_USE_OPENVDB)

# Conversion des jeux de données vers les références du banc.
add_executable(objseq2abc convert/objseq2abc.cpp)
target_link_libraries(objseq2abc PRIVATE Alembic::Alembic)

add_executable(vdbnorm convert/vdbnorm.cpp)
target_link_libraries(vdbnorm PRIVATE OpenVDB::openvdb)

# Mesure des références du banc (volumes).
add_executable(vdbref refs/vdbref.cpp)
target_link_libraries(vdbref PRIVATE OpenVDB::openvdb OpenVDB::nanovdb zfp::zfp zstd::libzstd)
target_compile_definitions(vdbref PRIVATE NANOVDB_USE_OPENVDB)

if(RDC_ENABLE_CUDA)
    add_executable(gpucheck gpucheck/main.cu)
endif()
