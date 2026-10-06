# Lance les tests du plugin USD dans Blender 5.0.1 en arrière-plan.
# Usage : .\tests\usd\run_blender_tests.ps1 [-Blender <exe>] [-Build <dossier build>]
param(
    [string]$Blender = "C:\Program Files\Blender Foundation\Blender 5.0\blender.exe",
    [string]$Build = (Join-Path $PSScriptRoot "..\..\build")
)

$resources = Join-Path $Build "plugin\rdcUsd\resources"
if (-not (Test-Path (Join-Path $resources "plugInfo.json"))) {
    Write-Error "Plugin introuvable dans $resources : compiler d'abord (cmake --build build --config RelWithDebInfo)."
    exit 1
}
$env:PXR_PLUGINPATH_NAME = (Resolve-Path $resources).Path
$out = Join-Path $Build "test_out"

& $Blender -b --factory-startup --python-exit-code 1 `
    --python (Join-Path $PSScriptRoot "test_hello_plugin.py") -- --out $out
exit $LASTEXITCODE
