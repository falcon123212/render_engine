# Render_Engine — codec .rdc (prototype)

Plan complet : [PLAN.md](PLAN.md).

## Prérequis

- Windows, VS 2022, CMake ≥ 3.24, Git + Git LFS
- Blender **5.0.1** (USD 25.08), installé dans `C:\Program Files\Blender Foundation\Blender 5.0`

## Bibliothèques de Blender (une fois)

Le plugin USD doit être compilé contre l'USD exact de Blender (namespace
`pxrBlender_v25_08`). On récupère seulement `usd`, `tbb` et `python` (~620 Mo) :

```bash
git clone --depth 1 --branch v5.0.1 --filter=blob:none --sparse https://projects.blender.org/blender/lib-windows_x64.git external/lib-windows_x64
```

```bash
git -C external/lib-windows_x64 sparse-checkout set usd tbb python
```

## vcpkg (une fois)

Dépendances : zstd, meshoptimizer, Alembic, ZFP, OpenVDB + NanoVDB, Catch2 (voir `vcpkg.json`,
baseline figée). Triplet `x64-windows-release` (pas de Debug) et 6 jobs pour tenir dans 16 Go.

```bash
git clone https://github.com/microsoft/vcpkg.git external/vcpkg
```

```bash
external/vcpkg/bootstrap-vcpkg.bat -disableMetrics
```

## Compilation

Seules les configurations `Release` et `RelWithDebInfo` existent (CRT /MD comme Blender).
Le premier `configure` installe les dépendances vcpkg (long : OpenVDB, Boost).

```bash
cmake --preset default
```

```bash
cmake --build --preset default
```

## Vérifications de l'environnement

```bash
build/tools/RelWithDebInfo/depcheck.exe
```

```bash
build/tools/RelWithDebInfo/gpucheck.exe
```

Le plugin est assemblé dans `build/plugin/` (`rdcUsd.dll` + `rdcUsd/resources/plugInfo.json`).

## Tests du plugin dans Blender

```bash
powershell -ExecutionPolicy Bypass -File tests/usd/run_blender_tests.ps1
```

Le script règle `PXR_PLUGINPATH_NAME`, lance Blender en arrière-plan et vérifie :
découverte du plugin, lecture USD de `hello.rdc`, import de `shot.usda` avec animation,
rendu Cycles (`build/test_out/hello_f007.png`).

## Utiliser le plugin dans Blender (interactif)

Lancer Blender avec la variable d'environnement pointant sur le plugin, puis
Fichier › Importer › USD sur un `.usda` qui référence les `.rdc` :

```powershell
$env:PXR_PLUGINPATH_NAME = "$PWD\build\plugin\rdcUsd\resources"; & "C:\Program Files\Blender Foundation\Blender 5.0\blender.exe"
```
