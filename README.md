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

## Compilation

Seules les configurations `Release` et `RelWithDebInfo` existent (CRT /MD comme Blender).

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
```

```bash
cmake --build build --config RelWithDebInfo
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
