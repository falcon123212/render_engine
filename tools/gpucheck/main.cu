// gpucheck : vérifie l'environnement CUDA et mesure ce qui compte pour le
// décodage .rdc (phase 0) :
//   - débit hôte -> GPU, mémoire paginée et épinglée (attendu : PCIe 3.0 x8,
//     ~6-7 Go/s, le Ryzen 5 5500 étant limité au PCIe 3.0) ;
//   - latence de lancement d'un noyau et d'un aller-retour petit transfert.

#include <cuda_runtime.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#ifdef _WIN32
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#define CHECK(call)                                                        \
    do {                                                                     \
        cudaError_t err_ = (call);                                           \
        if (err_ != cudaSuccess) {                                           \
            std::fprintf(stderr, "CUDA : %s (%s:%d)\n",                      \
                         cudaGetErrorString(err_), __FILE__, __LINE__);      \
            std::exit(1);                                                    \
        }                                                                    \
    } while (0)

__global__ void emptyKernel() {}

__global__ void scaleKernel(const int* in, float* out, float step, size_t n)
{
    const size_t i = blockIdx.x * size_t(blockDim.x) + threadIdx.x;
    if (i < n) {
        out[i] = float(in[i]) * step;
    }
}

// Débit en Go/s (1e9 octets/s), médiane de `reps` copies.
static double measureCopy(void* dst, const void* src, size_t bytes,
                          cudaMemcpyKind kind, int reps)
{
    cudaEvent_t a, b;
    CHECK(cudaEventCreate(&a));
    CHECK(cudaEventCreate(&b));
    CHECK(cudaMemcpy(dst, src, bytes, kind)); // échauffement
    std::vector<float> ms(reps);
    for (int r = 0; r < reps; ++r) {
        CHECK(cudaEventRecord(a));
        CHECK(cudaMemcpy(dst, src, bytes, kind));
        CHECK(cudaEventRecord(b));
        CHECK(cudaEventSynchronize(b));
        CHECK(cudaEventElapsedTime(&ms[r], a, b));
    }
    std::nth_element(ms.begin(), ms.begin() + reps / 2, ms.end());
    CHECK(cudaEventDestroy(a));
    CHECK(cudaEventDestroy(b));
    return bytes / (ms[reps / 2] * 1e-3) / 1e9;
}

int main()
{
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    int count = 0;
    CHECK(cudaGetDeviceCount(&count));
    if (count == 0) {
        std::printf("Aucun GPU CUDA\n");
        return 1;
    }
    cudaDeviceProp p{};
    CHECK(cudaGetDeviceProperties(&p, 0));
    int runtime = 0, driver = 0;
    CHECK(cudaRuntimeGetVersion(&runtime));
    CHECK(cudaDriverGetVersion(&driver));
    std::printf("GPU        : %s, sm_%d%d, %d SM, %.1f Go\n", p.name, p.major,
                p.minor, p.multiProcessorCount, p.totalGlobalMem / 1073741824.0);
    std::printf("CUDA       : runtime %d.%d, pilote %d.%d\n", runtime / 1000,
                (runtime % 1000) / 10, driver / 1000, (driver % 1000) / 10);
    std::printf("Bus PCI    : %04x:%02x:%02x\n", p.pciDomainID, p.pciBusID,
                p.pciDeviceID);

    // Débits : 64 Mo (gros volume) et 1 Mo (image du personnage, ~100 k sommets).
    for (size_t mb : {64, 1}) {
        const size_t bytes = mb << 20;
        void* d = nullptr;
        void* pinned = nullptr;
        CHECK(cudaMalloc(&d, bytes));
        CHECK(cudaMallocHost(&pinned, bytes));
        std::vector<char> pageable(bytes, 1);
        std::fill_n(static_cast<char*>(pinned), bytes, 1);
        const int reps = mb > 1 ? 10 : 50;
        std::printf("%3zu Mo     : H->D paginée %5.2f Go/s | H->D épinglée %5.2f Go/s"
                    " | D->H épinglée %5.2f Go/s\n", mb,
                    measureCopy(d, pageable.data(), bytes, cudaMemcpyHostToDevice, reps),
                    measureCopy(d, pinned, bytes, cudaMemcpyHostToDevice, reps),
                    measureCopy(pinned, d, bytes, cudaMemcpyDeviceToHost, reps));
        CHECK(cudaFreeHost(pinned));
        CHECK(cudaFree(d));
    }

    // Latence de lancement (noyau vide, synchronisé), médiane sur 1000.
    emptyKernel<<<1, 1>>>();
    CHECK(cudaDeviceSynchronize());
    std::vector<double> us(1000);
    for (double& u : us) {
        const auto t0 = std::chrono::high_resolution_clock::now();
        emptyKernel<<<1, 1>>>();
        CHECK(cudaDeviceSynchronize());
        u = std::chrono::duration<double, std::micro>(
                std::chrono::high_resolution_clock::now() - t0).count();
    }
    std::nth_element(us.begin(), us.begin() + 500, us.end());
    std::printf("Lancement  : noyau vide + synchro %.1f us (médiane)\n", us[500]);

    // Cas personnage : 100 k sommets x 3 entiers, envoi épinglé + déquantification
    // + synchro. Ordre de grandeur du plancher pour le critère « <= 1 ms ».
    const size_t n = 300000;
    int* hIn = nullptr;
    int* dIn = nullptr;
    float* dOut = nullptr;
    CHECK(cudaMallocHost(&hIn, n * sizeof(int)));
    CHECK(cudaMalloc(&dIn, n * sizeof(int)));
    CHECK(cudaMalloc(&dOut, n * sizeof(float)));
    for (size_t i = 0; i < n; ++i) {
        hIn[i] = int(i % 4096);
    }
    for (double& u : us) {
        const auto t0 = std::chrono::high_resolution_clock::now();
        CHECK(cudaMemcpyAsync(dIn, hIn, n * sizeof(int), cudaMemcpyHostToDevice));
        scaleKernel<<<unsigned((n + 255) / 256), 256>>>(dIn, dOut, 1e-4f, n);
        CHECK(cudaDeviceSynchronize());
        u = std::chrono::duration<double, std::micro>(
                std::chrono::high_resolution_clock::now() - t0).count();
    }
    std::nth_element(us.begin(), us.begin() + 500, us.end());
    std::printf("Personnage : 1,2 Mo épinglé -> GPU + déquantif. %.1f us (médiane)\n",
                us[500]);
    CHECK(cudaFreeHost(hIn));
    CHECK(cudaFree(dIn));
    CHECK(cudaFree(dOut));
    return 0;
}
