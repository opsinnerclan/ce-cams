# ce_cams_build.ps1 - builds the "CE Cams" desktop client from Network Optix's open-source
# nx_open repository (MPL 2.0), matched to nx_stub_server:
#   * source: the public 6.1.2.42921 release tag (protocol 6113, same as the stub)
#   * licensing: your public key instead of Network Optix's (ce_cams_patch_fork.py)
#   * branding: "CE Cams" name, ids and artwork (ce_cams_branding.py), customization id "cecams"
#   * nxstub.json: "customization" and "brand" set to the package's id so client and stub match
#
# Run it with build_ce_cams.bat. The first build downloads several GB and takes hours.
#
#   build_ce_cams.bat                         release build with an installer (default)
#   build_ce_cams.bat -Dev                    faster developer build, run from the bin folder
#   build_ce_cams.bat -Package my.zip         use a customization package you made instead
#   build_ce_cams.bat -Root D:\ce             where to put sources and build (default C:\ce)
#   build_ce_cams.bat -PublicKey license_public.pem   your license public key (else -CloudHost)
#   build_ce_cams.bat -CloudHost cloud.example.com
#                                             your CE Cams Cloud, built in (default: the host of
#                                             "cloud-url" in nxstub.json; "none" for Nx's)
#
# Works with Windows PowerShell 5.1 and PowerShell 7.

param(
    [string]$Root = "",
    [string]$Package = "",
    [switch]$Dev,
    [string]$Name = "CE Cams",
    [string]$Id = "cecams",
    [string]$Company = "CE",
    [string]$CloudHost = "",
    [string]$PublicKey = ""
)

$ErrorActionPreference = 'Continue'   # native tools write to stderr; exit codes are checked instead
$StubDir     = $PSScriptRoot

# Remember where the build lives, so running the .bat again without -Root uses the same place.
$RootFile = Join-Path $StubDir 'ce_cams_build.json'
$savedCfg = $null
if (Test-Path $RootFile) {
    try { $savedCfg = Get-Content $RootFile -Raw | ConvertFrom-Json } catch { }
}
if (-not $Root) {
    $Root = 'C:\ce'
    if ($savedCfg -and $savedCfg.root) { $Root = $savedCfg.root }
}
# The cloud the client uses: -CloudHost, else the last one used, else nxstub.json's "cloud-url".
if (-not $CloudHost -and $savedCfg -and $savedCfg.cloudHost) { $CloudHost = $savedCfg.cloudHost }
if (-not $CloudHost) {
    $stubCfg = Join-Path $StubDir 'nxstub.json'
    if (Test-Path $stubCfg) {
        try {
            $url = (Get-Content $stubCfg -Raw | ConvertFrom-Json).'cloud-url'
            if ($url) { $CloudHost = ([Uri]$url).Host }
        } catch { }
    }
}
if ($CloudHost -eq 'none') { $CloudHost = '' }
@{ root = $Root; cloudHost = $(if ($CloudHost) { $CloudHost } else { 'none' }) } |
    ConvertTo-Json | Set-Content -Path $RootFile -Encoding ASCII
$Tag         = 'vms/6.1.2/release_42921_all'
$BuildNumber = '42921'
$Repo        = 'https://github.com/networkoptix/nx_open.git'
$Src         = Join-Path $Root 'nx_open'
$BuildDir    = "$Src-build"
$EnvDir      = Join-Path $Root 'buildenv'
$EnvPy       = Join-Path $EnvDir 'Scripts\python.exe'
$StubPy      = Join-Path $StubDir '.venv\Scripts\python.exe'
$DefaultPkgUrl = 'https://artifactory.nxvms.dev/artifactory/artifacts/customization/metavms/package.zip'

function Say($t)   { Write-Host $t -ForegroundColor Cyan }
function Warn($t)  { Write-Host $t -ForegroundColor Yellow }
function Fail($t)  { throw $t }
function Have($c)  { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function AskYes($q) { $a = Read-Host "$q [y/N]"; return ($a -match '^(y|yes)$') }

function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Step($n, $t) { Write-Host ''; Write-Host "[$n/8] $t" -ForegroundColor Green }

# ---- 1. prerequisites -----------------------------------------------------------------------

function Find-Python {
    $candidates = @()
    if (Have 'py')     { $candidates += ,@('py', '-3') }
    if (Have 'python') { $candidates += ,@('python') }
    $userInstalls = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path $userInstalls) {
        Get-ChildItem $userInstalls -Directory -Filter 'Python3*' | Sort-Object Name -Descending |
            ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path $exe) { $candidates += ,@($exe) }
            }
    }
    foreach ($c in $candidates) {
        $exe = $c[0]
        $pre = @($c | Select-Object -Skip 1)
        try {
            $out = & $exe @pre -c "import sys; print(sys.version_info >= (3, 8))" 2>$null
            if ($LASTEXITCODE -eq 0 -and "$out".Trim() -eq 'True') { return ,$c }
        } catch { }
    }
    return $null
}

function Find-Msvc1438 {
    # The build needs the MSVC 14.38 toolset; newer ones are known to break it (build.md).
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return @{ Install = $null; Found = $false } }
    $paths = & $vswhere -products * -version '[17.0,18.0)' -property installationPath 2>$null
    foreach ($p in @($paths)) {
        if (-not $p) { continue }
        $msvc = Join-Path $p 'VC\Tools\MSVC'
        if (Test-Path $msvc) {
            $hit = Get-ChildItem $msvc -Directory -Filter '14.38.*' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) { return @{ Install = $p; Found = $true; Version = $hit.Name } }
        }
        return @{ Install = $p; Found = $false }
    }
    return @{ Install = $null; Found = $false }
}

function Ensure-Prerequisites {
    Step 1 'Checking prerequisites'

    $longPaths = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
        -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
    if ($longPaths -ne 1) {
        Warn 'Windows long paths are off. The build has deep paths; keep -Root short (C:\ce).'
        Warn 'To turn them on (recommended), run once as Administrator:'
        Warn '  reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f'
    }

    if (-not (Have 'git')) {
        if (-not (Have 'winget')) { Fail 'Git is not installed. Install Git for Windows and run this again.' }
        if (-not (AskYes 'Git is not installed. Install it now with winget?')) { Fail 'Git is required.' }
        winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements
        Refresh-Path
        if (-not (Have 'git')) { Fail 'Git still not found. Open a new window and run this again.' }
    }

    $vs = Find-Msvc1438
    if (-not $vs.Found) {
        $components = '--add Microsoft.VisualStudio.Component.VC.14.38.17.8.x86.x64 ' +
                      '--add Microsoft.VisualStudio.Component.VC.14.38.17.8.ATL'
        if ($vs.Install) {
            Warn "Visual Studio 2022 is installed at $($vs.Install), but without the MSVC 14.38 toolset."
            $setup = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
            if (AskYes 'Add the MSVC 14.38 toolset and ATL now? (a few GB, needs Administrator)') {
                Start-Process -FilePath $setup -Verb RunAs -Wait -ArgumentList (
                    "modify --installPath `"$($vs.Install)`" --passive --norestart $components")
            }
        } else {
            Warn 'Visual Studio 2022 C++ Build Tools are not installed.'
            if (-not (Have 'winget')) { Fail 'Install Visual Studio 2022 Build Tools with the "MSVC v143 14.38" and "C++ v14.38 ATL" components, then run this again.' }
            if (AskYes 'Install VS 2022 Build Tools with the MSVC 14.38 toolset now? (~8 GB)') {
                winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-source-agreements `
                    --accept-package-agreements --override (
                    "--passive --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools " +
                    "--includeRecommended $components")
            }
        }
        $vs = Find-Msvc1438
        if (-not $vs.Found) {
            Fail ('The MSVC 14.38 toolset is still missing. In Visual Studio Installer > Modify > ' +
                  'Individual components, add "MSVC v143 - VS 2022 C++ x64/x86 build tools (v14.38-17.8)" ' +
                  'and "C++ v14.38 (17.8) ATL for v143 build tools (x86 & x64)", then run this again.')
        }
    }
    $env:NX_FORCED_VC_TOOLSET_VERSION = '14.38'
    Write-Host "  Visual Studio: $($vs.Install) (MSVC $($vs.Version))"

    if (-not (Test-Path $StubPy)) {
        Fail 'Run start_nxstub.bat once first (it sets up Python for the stub and the license tool).'
    }
}

# ---- 2. sources ----------------------------------------------------------------------------

function Ensure-Sources {
    Step 2 "Getting nx_open $Tag"
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    if (Test-Path (Join-Path $Src '.git')) {
        Write-Host "  Using existing checkout $Src"
        return
    }
    git -c core.longpaths=true clone --depth 1 --branch $Tag $Repo $Src
    if ($LASTEXITCODE -ne 0) { Fail 'git clone failed.' }
    git -C $Src config core.longpaths true
}

# ---- 3. build tools -------------------------------------------------------------------------

function Ensure-BuildEnv {
    Step 3 'Setting up build tools (CMake, Ninja, Conan) in buildenv'
    # A venv copied from another folder still points at the old one; start it over.
    $activate = Join-Path $EnvDir 'Scripts\activate.bat'
    if ((Test-Path $activate) -and -not (Select-String -Path $activate -SimpleMatch $EnvDir -Quiet)) {
        Warn "  $EnvDir was copied from somewhere else; recreating it"
        Remove-Item -Recurse -Force $EnvDir
    }
    if (-not (Test-Path $EnvPy)) {
        $py = Find-Python
        if (-not $py) { Fail 'Python 3.8+ not found.' }
        $exe = $py[0]; $pre = @($py | Select-Object -Skip 1)
        & $exe @pre -m venv $EnvDir
        if ($LASTEXITCODE -ne 0) { Fail 'Could not create the build Python environment.' }
    }
    # The 6.1.2 tag pins PyYAML 5.1.1, which has no wheels for current Python; 6.x works the same.
    $req = Join-Path $Root 'requirements_ce_cams.txt'
    (Get-Content (Join-Path $Src 'requirements.txt')) -replace '^PyYAML==.*$', 'PyYAML==6.0.2' |
        Set-Content -Path $req -Encoding ASCII
    Write-Host '  Installing about 25 packages; this usually takes a few minutes.'
    & $EnvPy -m pip install --disable-pip-version-check --progress-bar on -r $req pillow
    if ($LASTEXITCODE -ne 0) { Fail 'pip could not install the build tools.' }
    $env:Path = (Join-Path $EnvDir 'Scripts') + ';' + $env:Path     # python, cmake, ninja, conan
    $env:NX_CONAN_DOWNLOAD_CACHE = Join-Path $Root 'conan_cache'    # reuse downloads between builds
    New-Item -ItemType Directory -Force -Path $env:NX_CONAN_DOWNLOAD_CACHE | Out-Null
}

# ---- 4. licensing -------------------------------------------------------------------------------

function Ensure-Licensing {
    Step 4 'Putting your license public key into the client'
    $keyDir = Join-Path $Root 'license_key'
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    $pub = Join-Path $keyDir 'license_public.pem'
    if ($PublicKey) {
        Copy-Item -LiteralPath $PublicKey -Destination $pub -Force
        Say "  From $PublicKey"
    } elseif ($CloudHost) {
        # Only the public half: what the client checks licenses with. Your cloud signs with the rest.
        Say "  Downloading the license public key from https://$CloudHost"
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "https://$CloudHost/cdb/ce/licenses/public-key"
            $key = ($resp.Content | ConvertFrom-Json).publicKey
            if (-not $key) { throw 'no publicKey in the response' }
            Set-Content -LiteralPath $pub -Value $key -NoNewline -Encoding ASCII
        } catch {
            Fail "Couldn't get the license key from https://$CloudHost (is licensing on in the cloud?). Use -PublicKey FILE."
        }
        Say "  From your cloud (https://$CloudHost)"
    } else {
        Fail 'No license public key: pass -PublicKey FILE (license_public.pem from your CE Cams server/cloud).'
    }
    & $StubPy (Join-Path $StubDir 'ce_cams_patch_fork.py') --public-key $pub $Src
    if ($LASTEXITCODE -ne 0) { Fail 'ce_cams_patch_fork.py failed.' }
    & $StubPy (Join-Path $StubDir 'ce_cams_patches.py') $Src
    if ($LASTEXITCODE -ne 0) { Fail 'ce_cams_patches.py failed.' }
}

# ---- 5. branding --------------------------------------------------------------------------------

function Ensure-Branding {
    Step 5 "Branding: $Name"
    if ($Package) {
        if (-not (Test-Path $Package)) { Fail "Customization package not found: $Package" }
        $script:PackageFile = (Resolve-Path $Package).Path
        Write-Host "  Using your package $script:PackageFile"
        return
    }
    $default = Join-Path $Root 'metavms_package.zip'
    if (-not (Test-Path $default)) {
        Write-Host '  Downloading the default open-source customization package'
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $DefaultPkgUrl -OutFile $default -UseBasicParsing
        } catch {
            Fail "Could not download $DefaultPkgUrl ($($_.Exception.Message))."
        }
    }
    $script:PackageFile = Join-Path $Root 'ce_cams_customization.zip'
    $brandArgs = @('--name', $Name, '--id', $Id, '--company', $Company,
                   '--preview', (Join-Path $Root 'ce_cams_icon.png'))
    if ($CloudHost) {
        $brandArgs += @('--cloud-host', $CloudHost)
        Write-Host "  Cloud: $CloudHost (built in; no desktop_client.ini needed)"
    } else {
        Warn '  No cloud host: the client uses the package default (Nx Cloud)'
    }
    & $EnvPy (Join-Path $StubDir 'ce_cams_branding.py') $default $script:PackageFile @brandArgs
    if ($LASTEXITCODE -ne 0) { Fail 'Branding failed.' }
}

# ---- 6. match the stub ----------------------------------------------------------------------

function Match-Stub {
    Step 6 'Matching nx_stub_server to the client'
    $pack = Join-Path $Src 'build_utils\customization\pack.py'
    $pkgId = (& $EnvPy $pack get_value $script:PackageFile id).Trim()
    $pkgBrand = (& $EnvPy $pack get_value $script:PackageFile brand 2>$null)
    if ($pkgBrand) { $pkgBrand = $pkgBrand.Trim() } else { $pkgBrand = $pkgId }
    $cfgFile = Join-Path $StubDir 'nxstub.json'
    $code = @"
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p, encoding='utf-8-sig'))
except FileNotFoundError:
    cfg = {}
cfg['customization'] = sys.argv[2]
cfg['brand'] = sys.argv[3]
json.dump(cfg, open(p, 'w', encoding='utf-8'), indent=2)
"@
    & $StubPy -c $code $cfgFile $pkgId $pkgBrand
    Write-Host "  nxstub.json: customization=$pkgId, brand=$pkgBrand (restart the stub to apply)"
    Warn '  The stock Nx client will no longer connect to the stub; use CE Cams.'
}

# ---- 7-8. build ---------------------------------------------------------------------------------

function Build-Client {
    Step 7 'Building (the first run downloads dependencies and takes a long time)'
    # A build folder generated for another source location (e.g. copied from C:) can't be reused.
    $cache = Join-Path $BuildDir 'CMakeCache.txt'
    if (Test-Path $cache) {
        $cacheHome = (Select-String -Path $cache -Pattern '^CMAKE_HOME_DIRECTORY:INTERNAL=(.*)$' |
            Select-Object -First 1)
        $srcFwd = $Src -replace '\\', '/'
        if ($cacheHome -and ($cacheHome.Matches[0].Groups[1].Value.Trim() -ne $srcFwd)) {
            Warn "  $BuildDir was generated for $($cacheHome.Matches[0].Groups[1].Value); starting it fresh"
            Remove-Item -Recurse -Force $BuildDir
        }
    }
    # Regenerate every time so the package and options in effect are exactly these.
    Remove-Item -Force -ErrorAction SilentlyContinue $cache
    # Unit tests and the mobile client aren't needed for CE Cams; skipping them saves hours and
    # avoids an MSVC 14.38 internal compiler error in nx_utils_ut (partition_sums_ut.cpp).
    $cmakeArgs = @("-DbuildNumber=$BuildNumber", "-DcustomizationPackageFile=$script:PackageFile",
                   '-DwithTests=OFF', '-DwithMobileClient=OFF')
    if (-not $Dev) { $cmakeArgs += '-DdeveloperBuild=OFF' }
    $log = Join-Path $Root 'build.log'
    Write-Host "  Log: $log"
    & (Join-Path $Src 'build.bat') @cmakeArgs 2>&1 | Tee-Object -FilePath $log
    if ($LASTEXITCODE -ne 0) { Fail "The build failed. See $log (search for 'error')." }

    Step 8 'Done'
    if ($Dev) {
        $exe = Get-ChildItem (Join-Path $BuildDir 'bin') -Filter "$Name.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($exe) { Say "  Run: $($exe.FullName)" } else { Say "  Built into $BuildDir\bin" }
    } else {
        Say "  Installer and packages: $BuildDir\distrib"
        Get-ChildItem (Join-Path $BuildDir 'distrib') -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'client' } | ForEach-Object { Write-Host "    $($_.Name)" }
    }
    Write-Host ''
    Write-Host 'Next: restart start_nxstub.bat, open CE Cams, connect to the stub, then issue and'
    Write-Host 'activate licenses with nxstub_license.bat.'
}

try {
    if ($Root -match '\s' -or ($Package -and $Package -match '\s')) {
        Fail 'Use a folder path without spaces for -Root and -Package (e.g. C:\ce).'
    }
    Ensure-Prerequisites
    Ensure-Sources
    Ensure-BuildEnv
    Ensure-Licensing
    Ensure-Branding
    Match-Stub
    Build-Client
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
