# Notice

## NVIDIA RTXGI SDK

`windows/patch/rtxgi_bench.patch` modifies the Pathtracer sample of the NVIDIA RTXGI 2.0 SDK
(https://github.com/NVIDIAGameWorks/RTXGI, commit `10b5770`).

**This software contains source code provided by NVIDIA Corporation.**

The SDK itself, its libraries (SHaRC, NRC, NRD, DLSS, Donut) and its sample assets are **not** redistributed here.
`windows/setup.sh` downloads them from NVIDIA's official repositories. By doing so, you accept the
NVIDIA RTX SDKs License (`License.md` in the SDK) and the licenses of each submodule.

## Bistro scene

The Bistro scene comes from NVIDIA's RTXGI-Assets repository (Amazon Lumberyard Bistro, CC BY 4.0).
It is not redistributed here. `windows/assets/` only contains our own scene description (two added street lamps
and a moving panel) and a generated unit cube (`BenchBox`).

## Our code

The bench scripts (`windows/*.sh`, `windows/*.py`), the bench additions in the patch (`Bench.h`, `BenchSnap.hlsl`,
and the bench code in `Pathtracer.cpp/.h/.hlsl`, `SharcResolve.hlsl`), and the CUDA bench (`cuda/`) are original work
written for this research.
