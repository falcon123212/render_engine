@echo off
rem Compile le bench CUDA sous Windows (invite de commandes). Builds the CUDA bench on Windows.
rem Requiert / requires : CUDA Toolkit >= 12.8, Visual Studio 2022 (ou Build Tools) avec le C++.
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "VSDIR="
set "VSTMP=%TEMP%\vsdir_bench.txt"
"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath > "%VSTMP%"
set /p VSDIR=<"%VSTMP%"
if not defined VSDIR goto novs
echo Visual Studio : %VSDIR%
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
if "%CUDA_ARCH%"=="" set CUDA_ARCH=native
nvcc -O3 -arch=%CUDA_ARCH% -std=c++17 -DGX=8 -DGY=4 -DGZ=4 -DNLIGHTS=3 poc_gpu.cu -o poc_gpu_l3.exe || exit /b 1
nvcc -O3 -arch=%CUDA_ARCH% -std=c++17 -DGX=8 -DGY=4 -DGZ=4 -DNLIGHTS=8 poc_gpu.cu -o poc_gpu_l8.exe || exit /b 1
echo OK : poc_gpu_l3.exe et poc_gpu_l8.exe
exit /b 0
:novs
echo ERREUR : Visual Studio C++ introuvable / not found
exit /b 1
