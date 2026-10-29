# CI helper: fetch and build the OpenCL headers + ICD loader for Windows ARM64 with clang-cl.
# Usage: pwsh -File ci-opencl-deps.ps1 -Work <empty or new folder> [-Tag v2026.05.29]
# Output: <Work>\install\{include\CL, lib\OpenCL.lib, bin\OpenCL.dll}; prints the two CMake values.
param(
  [Parameter(Mandatory = $true)][string]$Work,
  [string]$Tag = 'v2026.05.29'
)
$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "ERROR: $msg"; exit 1 }

# 1. Locate Visual Studio (any edition with the ARM64 clang toolchain) via vswhere.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { Fail "vswhere.exe not found at $vswhere" }
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang -property installationPath
if (-not $vsPath) { Fail 'No Visual Studio install with the LLVM clang component found' }
$vsDev = Join-Path $vsPath 'Common7\Tools\VsDevCmd.bat'
$clang = Join-Path $vsPath 'VC\Tools\Llvm\ARM64\bin\clang-cl.exe'
$cmake = Join-Path $vsPath 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
foreach ($p in @($vsDev, $clang, $cmake)) { if (-not (Test-Path $p)) { Fail "missing $p" } }

# Import the ARM64 developer environment (Ninja, link.exe, Windows SDK paths).
# VsDevCmd calls vswhere by name, so put its folder on PATH first.
$env:PATH = (Split-Path $vswhere) + ';' + $env:PATH
$envLines = cmd /c "`"$vsDev`" -arch=arm64 -host_arch=arm64 -no_logo >nul && set"
foreach ($l in $envLines) {
  $i = $l.IndexOf('=')
  if ($i -gt 0) { Set-Item -Path ('env:' + $l.Substring(0, $i)) -Value $l.Substring($i + 1) -ErrorAction SilentlyContinue }
}

# 2. Clean folder, shallow clones at the pinned tag.
$Work = [IO.Path]::GetFullPath($Work)
if ((Test-Path $Work) -and (Get-ChildItem -Force $Work | Measure-Object).Count -gt 0) {
  Fail "$Work is not empty; pass a clean folder"
}
New-Item -ItemType Directory -Force $Work | Out-Null
$headers = Join-Path $Work 'OpenCL-Headers'
$loader = Join-Path $Work 'OpenCL-ICD-Loader'
$install = Join-Path $Work 'install'
git clone --depth 1 --branch $Tag https://github.com/KhronosGroup/OpenCL-Headers.git $headers
if ($LASTEXITCODE -ne 0) { Fail 'clone OpenCL-Headers failed' }
git clone --depth 1 --branch $Tag https://github.com/KhronosGroup/OpenCL-ICD-Loader.git $loader
if ($LASTEXITCODE -ne 0) { Fail 'clone OpenCL-ICD-Loader failed' }

# 3. Headers (install only, no tests).
# Note: every -D argument that contains a $variable is in double quotes; in
# PowerShell command mode a bare -Name=$var is passed through unexpanded.
$headersBld = Join-Path $Work 'build-headers'
$loaderBld = Join-Path $Work 'build-icd'
$incDir = Join-Path $install 'include'
& $cmake -S $headers -B $headersBld -G Ninja -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_TESTING=OFF -DOPENCL_HEADERS_BUILD_TESTING=OFF -DOPENCL_HEADERS_BUILD_CXX_TESTS=OFF `
  "-DCMAKE_INSTALL_PREFIX=$install"
if ($LASTEXITCODE -ne 0) { Fail 'headers configure failed' }
& $cmake --build $headersBld --target install
if ($LASTEXITCODE -ne 0) { Fail 'headers install failed' }

# 4. ICD loader, clang-cl, ARM64 Release.
& $cmake -S $loader -B $loaderBld -G Ninja -DCMAKE_BUILD_TYPE=Release `
  "-DCMAKE_C_COMPILER=$clang" "-DCMAKE_CXX_COMPILER=$clang" -DBUILD_TESTING=OFF `
  "-DCMAKE_PREFIX_PATH=$install" "-DCMAKE_INSTALL_PREFIX=$install" `
  "-DOPENCL_ICD_LOADER_HEADERS_DIR=$incDir"
if ($LASTEXITCODE -ne 0) { Fail 'loader configure failed' }
& $cmake --build $loaderBld --target install
if ($LASTEXITCODE -ne 0) { Fail 'loader build failed' }

# 5. Check the outputs and print the values for sd.cpp's CMake.
$inc = Join-Path $install 'include'
$lib = Join-Path $install 'lib\OpenCL.lib'
$dll = Join-Path $install 'bin\OpenCL.dll'
foreach ($p in @((Join-Path $inc 'CL\cl.h'), $lib, $dll)) { if (-not (Test-Path $p)) { Fail "missing output $p" } }
Write-Host "OpenCL_INCLUDE_DIR=$inc"
Write-Host "OpenCL_LIBRARY=$lib"
Write-Host "OPENCL_RUNTIME_DLL=$dll"
