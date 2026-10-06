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

if(RDC_ENABLE_CUDA)
    add_executable(gpucheck gpucheck/main.cu)
endif()
