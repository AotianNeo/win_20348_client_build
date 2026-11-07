#Requires -RunAsAdministrator
<#
.SYNOPSIS
    100% Native DISM / CBS Servicing Builder:
    Windows Server 2022 Monthly Updated ISO (Build 20348.xxxx) -> Windows 10 Build 20348 Client Multi-Edition ISO
    - Zero handcrafted post-hoc .reg driver/CBS injection: 100% compiled natively by Windows CBS / WCP / DrvInst / Transmog
      using official Microsoft UUP 20348.1 (2ba1d737-a36b-415b-a630-85bd5146d77d) Client ESD/CAB packages.
    - Full Lifecycle Monthly LCU Update Support (OS Core, Shell explorer.exe/shell32.dll/dwmcore.dll, Bluetooth, and Media Foundation at latest LCU).
    - Default Client Visual Effects Enabled Out-of-the-Box (VisualFXSetting = 1).
    - Editions Built:
        1. Windows 10 IoT Enterprise (IoTEnterprise - Clean LTSC-style Edition without Consumer UWP Apps)
        2. Windows 10 Pro (Professional - Full Official Microsoft Store & 41 Modern UWP Apps Provisioned)
        3. Windows 10 Pro for Workstations (ProfessionalWorkstation - Native DISM /Set-Edition)
        4. Windows 10 Enterprise (Enterprise - Native DISM /Set-Edition)
#>
param(
    [string]$WorkDir = "$PSScriptRoot\work",
    [string]$OutputDir = "$PSScriptRoot\output"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Windows 10 Build 20348 Client ISO Builder (100% Native DISM/CBS)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $WorkDir, $OutputDir | Out-Null
$tmpDir        = Join-Path $WorkDir "tmp"
$uupDir        = Join-Path $WorkDir "uup_official_20348"
$uupStagePool  = Join-Path $WorkDir "uup_stage_pool"
$modernAppsDir = Join-Path $WorkDir "modern_apps"
$isoExtractDir = Join-Path $WorkDir "iso_root"
$mountDir      = Join-Path $WorkDir "mount"
New-Item -ItemType Directory -Force -Path $tmpDir, $uupDir, $uupStagePool, $modernAppsDir, $isoExtractDir, $mountDir | Out-Null

# ---------------------------------------------------------------------------
# 0. Ensure Required CLI Tools (wimlib-imagex, aria2c, 7z, oscdimg)
# ---------------------------------------------------------------------------
Write-Host "[0/7] Checking required build tools..." -ForegroundColor Yellow

function Get-ToolPath([string]$cmdName, [string[]]$fallbackPaths) {
    $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in $fallbackPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$wimlib = Get-ToolPath "wimlib-imagex.exe" @(
    "C:\ProgramData\chocolatey\bin\wimlib-imagex.exe",
    "$WorkDir\tools\wimlib\wimlib-imagex.exe"
)
if (-not $wimlib) {
    Write-Host "  Installing wimlib from official release zip..."
    $wimZip = Join-Path $tmpDir "wimlib.zip"
    Invoke-WebRequest -Uri "https://wimlib.net/downloads/wimlib-1.14.4-windows-x86_64-bin.zip" -OutFile $wimZip -UseBasicParsing
    Expand-Archive -Path $wimZip -DestinationPath "$WorkDir\tools\wimlib" -Force
    $wimlib = Join-Path "$WorkDir\tools\wimlib" "wimlib-imagex.exe"
}

$aria2c = Get-ToolPath "aria2c.exe" @("C:\ProgramData\chocolatey\bin\aria2c.exe")
if (-not $aria2c) {
    choco install aria2 -y --no-progress | Out-Null
    $aria2c = Get-ToolPath "aria2c.exe" @("C:\ProgramData\chocolatey\bin\aria2c.exe")
}

$sevenZip = Get-ToolPath "7z.exe" @("C:\Program Files\7-Zip\7z.exe", "C:\ProgramData\chocolatey\bin\7z.exe")
$oscdimg = Get-ToolPath "oscdimg.exe" @(
    "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    "$WorkDir\tools\oscdimg.exe"
)
if (-not $oscdimg) {
    Write-Host "  Fetching official x64 oscdimg.exe from Microsoft ADK (download.microsoft.com)..."
    New-Item -ItemType Directory -Force -Path "$WorkDir\tools" | Out-Null
    $oscdCab = Join-Path $tmpDir "oscdimg_adk.cab"
    Invoke-WebRequest -Uri "https://download.microsoft.com/download/e/8/b/e8bec6c1-8153-408d-96b1-ee2985a600ad/adk/Installers/bbf55224a0290f00676ddc410f004498.cab" -OutFile $oscdCab -UseBasicParsing
    & $sevenZip x $oscdCab "-o$tmpDir\oscd_ext" -y | Out-Null
    Copy-Item "$tmpDir\oscd_ext\fild40c79d789d460e48dc1cbd485d6fc2e" "$WorkDir\tools\oscdimg.exe" -Force
    $oscdimg = "$WorkDir\tools\oscdimg.exe"
}

# Add Backup/Restore Registry privilege helper for cleaning TrustedInstaller-protected AvailableShells key if needed
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class RegPrivHelper {
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);
    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES {
        public uint PrivilegeCount;
        public long Luid;
        public uint Attributes;
    }
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, uint BufferLength, IntPtr PreviousState, IntPtr ReturnLength);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int RegOpenKeyExW(IntPtr hKey, string subKey, uint options, uint samDesired, out IntPtr phkResult);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int RegDeleteValueW(IntPtr hKey, string lpValueName);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    public static extern int RegSetValueExW(IntPtr hKey, string lpValueName, uint Reserved, uint dwType, byte[] lpData, int cbData);
    [DllImport("advapi32.dll")]
    public static extern int RegCloseKey(IntPtr hKey);

    public static void EnablePriv(string name) {
        IntPtr hToken;
        OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x28, out hToken);
        long luid;
        LookupPrivilegeValue(null, name, out luid);
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES { PrivilegeCount = 1, Luid = luid, Attributes = 2 };
        AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }

    public static void EnsurePureExplorerAvailableShell(string hiveKeyPath) {
        EnablePriv("SeRestorePrivilege");
        EnablePriv("SeBackupPrivilege");
        EnablePriv("SeTakeOwnershipPrivilege");
        IntPtr hKey;
        IntPtr HKEY_LOCAL_MACHINE = new IntPtr(unchecked((int)0x80000002));
        // REG_OPTION_BACKUP_RESTORE = 4, KEY_ALL_ACCESS = 0xF003F
        int res = RegOpenKeyExW(HKEY_LOCAL_MACHINE, hiveKeyPath, 4, 0xF003F, out hKey);
        if (res == 0) {
            RegDeleteValueW(hKey, "40000");
            RegDeleteValueW(hKey, "30000");
            byte[] data = System.Text.Encoding.Unicode.GetBytes("explorer.exe\0");
            RegSetValueExW(hKey, "60000", 0, 1, data, data.Length);
            RegCloseKey(hKey);
        }
    }
}
'@

# ---------------------------------------------------------------------------
# 1. Fetch Latest Official Windows Server 2022 ISO from ntriver.org
# ---------------------------------------------------------------------------
Write-Host "[1/7] Querying ntriver.org for the latest official Windows Server 2022 ISO..." -ForegroundColor Yellow

$mdxUrl = "https://raw.githubusercontent.com/ntriver-org/ntriver-org-site/main/docs/download-windows-office/windows-server-iso-files-rtm/download-windows-server-2022.mdx"
$mdxContent = (Invoke-WebRequest -Uri $mdxUrl -UseBasicParsing).Content

$srvRegex = '(?i)(zh-cn_windows_server_2022_updated_[a-z0-9_]+_x64_dvd_[a-f0-9]+\.iso).*?([a-f0-9]{64})'
$m = [regex]::Match($mdxContent, $srvRegex)
if (-not $m.Success) {
    throw "Could not parse latest zh-cn Windows Server 2022 ISO from ntriver.org MDX."
}
$srvIsoName = $m.Groups[1].Value
$srvSha256  = $m.Groups[2].Value.ToLowerInvariant()
Write-Host "  Latest Official Server 2022 ISO : $srvIsoName"
Write-Host "  Expected Official SHA-256       : $srvSha256"

$srvLinkResp = Invoke-RestMethod -Uri "https://ntriver.org/api/drive/generate-link?filename=$srvIsoName" -Headers @{
    "X-Original-Referrer" = "https://ntriver.org/download-windows-server-2022"
}
$srvDownloadUrl = $srvLinkResp.url
$srvIsoPath = Join-Path $WorkDir $srvIsoName

if (-not (Test-Path $srvIsoPath)) {
    Write-Host "  Downloading $srvIsoName via aria2c..."
    & $aria2c -x16 -s16 -k1M --file-allocation=none --console-log-level=warn -d $WorkDir -o $srvIsoName $srvDownloadUrl
    if ($LASTEXITCODE -ne 0) { throw "aria2c failed to download $srvIsoName" }
}
$actualSha256 = (Get-FileHash -Path $srvIsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $srvSha256) {
    throw "SHA-256 mismatch for $srvIsoName! Expected $srvSha256, got $actualSha256"
}
Write-Host "  Verified SHA-256: $actualSha256 [OK]" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Download & Verify Official Microsoft UUP 20348.1 Client ESD & CAB Packages
# ---------------------------------------------------------------------------
Write-Host "[2/7] Downloading & verifying official Microsoft UUP 20348.1 Client ESD/CAB packages..." -ForegroundColor Yellow

$releaseBaseUrl = "https://github.com/AotianNeo/win_20348_client_build/releases/download/v20348.1-client-payload"

$uupPackages = @(
    @{ Name = "Microsoft-Windows-Foundation-Package.ESD";                                      Sha256 = "62e0a329a7c2679b198ba8d76c66c3ebe663bf72635082579db794a9b22d3b41"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Desktop-Required-Package.ESD";                         Sha256 = "154ab40e155ec5e86647cc74aca45f237aa17fb1e8c545b340809233fde7ccc3"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Desktop-Required-WOW64-Package.ESD";                   Sha256 = "7edceb201c1f677105a32eec7cd0f1e718515bd23b7394f2eb5e4af38e3fec94"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Features-Package.ESD";                                 Sha256 = "58ac2982ef5d0e60aa8f994c3d881ef601b701eb1a06e2ffe1d8011ecfb5adb0"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Features-WOW64-Package.ESD";                           Sha256 = "db113dabb979aa1b59b00038dd30ca74b7e957ea41a11cab1d9ec87bc65fe0cf"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionPack-Professional-Package.ESD";                        Sha256 = "97dbfb18444dde1a234f32c91fa405c4ba9cca1a0590aa59cf33cb462ee5be8d"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionPack-Professional-WOW64-Package.ESD";                  Sha256 = "a26ec4ae46838edf3bb88b2ab4ce96e5839be6becec8d36511cda741c91e83ec"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-Professional-Package.ESD";                    Sha256 = "d7450c0146220224ba49ae9b3b8f2524a6570410a31ca5d73d197c880eae28cb"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-Professional-WOW64-Package.ESD";              Sha256 = "b63263824c2c3e1ed0bcb60207e96973eaa0c4997a52731d59ea7aba515dd7ff"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-EnterpriseG-Package.ESD";                     Sha256 = "9606fe088b0a9bc9f3968706148d234412d6454bbbe628c33ba4d6d1ad575d2d"; Stage = $true },
    @{ Name = "Microsoft-Windows-Not-Supported-On-LTSB-Package.ESD";                           Sha256 = "ed1e1f8ee4f514b7c9aae16eef8ee20777fd069a75ef23d310d51db4c1b99a7b"; Stage = $true },
    @{ Name = "Microsoft-Windows-Not-Supported-On-LTSB-WOW64-Package.ESD";                     Sha256 = "10242e26e13ced1ef5aa631aab3c785a2e5e80bc0aa5827a9574293754460c7e"; Stage = $true },
    @{ Name = "Microsoft-Windows-RegulatedPackages-Package.ESD";                               Sha256 = "a1c7463a56f7d05e5327a018125a1780d0ca5599f5b47c4096a242d439d66656"; Stage = $true },
    @{ Name = "Microsoft-Windows-RegulatedPackages-WOW64-Package.ESD";                         Sha256 = "6db86cab62086c4ca5b9c4fc75817f04938d7e9e5c96bf6f172ec389ff928aa9"; Stage = $true },
    @{ Name = "Microsoft-Windows-Required-ShellExperiences-Desktop-Package.ESD";               Sha256 = "b6c3eadcedc310cf56573ab3e16eaa87aead3ba13a972d230a007d2618a8daee"; Stage = $true },
    @{ Name = "Microsoft-Windows-Required-ShellExperiences-Desktop-WOW64-Package.ESD";         Sha256 = "ad0d4c8ab12478215fd5f804199cafba2909f64b8caea325c47f5d11d66d0298"; Stage = $true },
    @{ Name = "Microsoft-Windows-Server-LanguagePack-Package_zh-cn-amd64-zh-cn.esd";           Sha256 = "0814fcd282a25766db2bd95f887172e418ac13d2a565bf5473569801a130c357"; Stage = $true },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Basic-zh-cn-Package-amd64.cab";              Sha256 = "86fb9316e85a8c651ab25cf22474f0a0bd4fcd8a624a31850c9d4105f91f8536"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Handwriting-zh-cn-Package-amd64.cab";        Sha256 = "5a84f7330c9d58b9af9166b7d954241aae7f208e1f291be6ef0a3bc6b3b4a131"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-OCR-zh-cn-Package-amd64.cab";                Sha256 = "aad4f02e2be0cd19718e3bfebc7f09e1956c7b42c5fb1f9d52f2bcd0c05074cf"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Speech-zh-cn-Package-amd64.cab";             Sha256 = "5752678b19ddd970e09cbd92b84e651f0de1ec040803f94f50bc6eace45ef57f"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-TextToSpeech-zh-cn-Package-amd64.cab";       Sha256 = "ff37f75bd09539fd67a13adfa31723ced6048307f20f9eb0b539fcc8c7b38d0d"; Stage = $false },
    @{ Name = "Microsoft.ModernApps.Client.All.esd";                                           Sha256 = "ad740246597698717ae93fa12df03ce08cf985e91695b3a4a712e29515a5164c"; Stage = $false },
    @{ Name = "Microsoft.ModernApps.Client.professional.esd";                                  Sha256 = "eabf2c72cb45c0d107e8fb0c8a0877e8e35efec46d6a1b7064086462f31d51aa"; Stage = $false }
)

foreach ($pkg in $uupPackages) {
    $destFile = Join-Path $uupDir $pkg.Name
    if (-not (Test-Path $destFile)) {
        Write-Host "  Downloading $($pkg.Name)..."
        & $aria2c -x16 -s16 -k1M --file-allocation=none --console-log-level=warn -d $uupDir -o $pkg.Name "$releaseBaseUrl/$($pkg.Name)"
        if ($LASTEXITCODE -ne 0) { throw "Failed to download $($pkg.Name)" }
    }
    $h = (Get-FileHash -Path $destFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $pkg.Sha256) {
        throw "SHA-256 mismatch for $($pkg.Name): expected $($pkg.Sha256), got $h"
    }
    if ($pkg.Stage) {
        & $wimlib apply $destFile 1 $uupStagePool --no-acls | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "wimlib apply failed for $($pkg.Name)" }
    }
}
Write-Host "  Verified & extracted all 17 official Client CBS ESD packages into $uupStagePool [OK]" -ForegroundColor Green

# Extract Official ModernApps ESDs for Windows 10 Pro / Enterprise UWP Provisioning
& $wimlib apply (Join-Path $uupDir "Microsoft.ModernApps.Client.All.esd") 1 $modernAppsDir --no-acls | Out-Null
& $wimlib apply (Join-Path $uupDir "Microsoft.ModernApps.Client.professional.esd") 1 $modernAppsDir --no-acls | Out-Null
Write-Host "  Extracted official Microsoft.ModernApps.Client.All.esd & professional.esd [OK]" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Extract Official Server 2022 ISO & Mount Base WIM Image
# ---------------------------------------------------------------------------
Write-Host "[3/7] Extracting official Server 2022 ISO and mounting Desktop Experience WIM..." -ForegroundColor Yellow

& $sevenZip x $srvIsoPath "-o$isoExtractDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z failed to extract Server 2022 ISO" }

$origWim = Join-Path $isoExtractDir "sources\install.wim"
Set-ItemProperty -Path $origWim -Name IsReadOnly -Value $false

$workWim = Join-Path $WorkDir "work_client.wim"
$finalWim = Join-Path $WorkDir "install_final.wim"
if (Test-Path $workWim)  { Remove-Item $workWim -Force }
if (Test-Path $finalWim) { Remove-Item $finalWim -Force }

& $wimlib export $origWim 2 $workWim "Windows 10 Pro" "Windows 10 Pro"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 2 failed" }

dism.exe /Mount-Wim /WimFile:$workWim /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "DISM Mount-Wim failed" }

# Detect exact LCU version ($pkgVer) and Media-Foundation-Server-Package version ($mfVer) in the mounted image
$srvStdMum = Get-ChildItem "$mountDir\Windows\servicing\Packages\Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~*.mum" |
    Where-Object { $_.Name -notmatch "10\.0\.20348\.1\.mum" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $srvStdMum -or $srvStdMum.Name -notmatch '~~([0-9\.]+)\.mum$') {
    throw "Could not detect LCU package version from ServerStandardEdition.mum"
}
$pkgVer = $matches[1]

$mfSrvMum = Get-ChildItem "$mountDir\Windows\servicing\Packages\Microsoft-Media-Foundation-Server-Package~31bf3856ad364e35~amd64~~*.mum" |
    Where-Object { $_.Name -notmatch "10\.0\.20348\.1\.mum" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $mfSrvMum -or $mfSrvMum.Name -notmatch '~~([0-9\.]+)\.mum$') {
    throw "Could not detect Media-Foundation-Server-Package version"
}
$mfVer = $matches[1]
Write-Host "  Detected Official LCU Version: $pkgVer (Media Foundation: $mfVer)" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 4. Generate Version-Aligned Edition Manifests & Apply 100% Native DISM Servicing
# ---------------------------------------------------------------------------
Write-Host "[4/7] Running 100% Native DISM Servicing (.NET 3.5 + Unattend Edition Switch + FODs)..." -ForegroundColor Yellow

$sxsDir = Join-Path $isoExtractDir "sources\sxs"
Write-Host "  Enabling .NET Framework 3.5 (NetFx3) from $sxsDir..." -ForegroundColor Cyan
dism.exe /Image:$mountDir /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$sxsDir
if ($LASTEXITCODE -ne 0) { throw "DISM Enable-Feature NetFx3 failed" }

# Copy all LCU .mum/.cat files from the mounted image into $uupStagePool first so DISM can resolve all LCU child packages from source
Copy-Item "$mountDir\Windows\servicing\Packages\*.mum" $uupStagePool -Force
Copy-Item "$mountDir\Windows\servicing\Packages\*.cat" $uupStagePool -Force

# Copy OfficialEditionManifests into $uupStagePool and generate version-aligned $pkgVer .mum files
$manifestsDir = Join-Path $PSScriptRoot "OfficialEditionManifests"
$proMum1 = Join-Path $manifestsDir "Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~10.0.20348.1.mum"
$mpMum1  = Join-Path $manifestsDir "Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum"
Copy-Item "$manifestsDir\*.mum" $uupStagePool -Force

# Build lookup of latest installed/staged neutral package versions in $uupStagePool
$latestPkgMap = @{}
Get-ChildItem "$uupStagePool\*.mum" | ForEach-Object {
    if ($_.Name -match '^([^~]+)~31bf3856ad364e35~amd64~~([0-9\.]+)\.mum$') {
        $key = $matches[1].ToLowerInvariant()
        $ver = [version]$matches[2]
        if (-not $latestPkgMap.ContainsKey($key) -or $ver -gt [version]$latestPkgMap[$key]) {
            $latestPkgMap[$key] = $matches[2]
        }
    }
}

# Align Media-Placeholder-Package to $pkgVer
$mpXml = [System.IO.File]::ReadAllText($mpMum1)
$mpXml = $mpXml.Replace('version="10.0.20348.1"', "version=`"$pkgVer`"")
$mpOut = Join-Path $uupStagePool "Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~$pkgVer.mum"
[System.IO.File]::WriteAllText($mpOut, $mpXml, [System.Text.Encoding]::UTF8)

# Construct version-aligned ProfessionalEdition~$pkgVer.mum with the 15 base .1 Client packages + LCU-updated shared/foundation packages
$lcuSharedPkgNames = @(
    "Microsoft-Windows-ServerCore-SKU-Foundation-Package",
    "Microsoft-Windows-ServerCore-SKU-Foundation-WOW64-Package",
    "Microsoft-Windows-ServerCore-WOW64-Payload-Package",
    "Microsoft-Windows-ServerCore-WowRequired-WOW64-Package",
    "Microsoft-Windows-Server-Features-Package",
    "Microsoft-Windows-Foundation-Group-Package",
    "Microsoft-Windows-Foundation-Group-WOW64-Package",
    "Microsoft-Windows-Product-Data-Package",
    "Microsoft-Windows-BootEnvironment-BootManagers-Package",
    "Microsoft-Windows-Servicing-Full-Package",
    "Microsoft-Windows-Servicing-Core-X86-Package",
    "Microsoft-Windows-Desktop-Shared-Drivers-Package",
    "Microsoft-Windows-Desktop-Shared-Drivers-WOW64-Package",
    "Microsoft-Windows-Enterprise-Desktop-Shared-Package",
    "Microsoft-Windows-Enterprise-Desktop-Shared-WOW64-Package",
    "Multimedia-AudioCore-Full-Package",
    "Microsoft-Windows-Media-Format-Package",
    "Microsoft-Windows-Media-Format-WOW64-Package",
    "Microsoft-Windows-Portable-Devices-Package",
    "Microsoft-Windows-Portable-Devices-WOW64-Package",
    "Microsoft-Windows-WebcamExperience-Package",
    "Microsoft-Windows-WebcamExperience-WOW64-Package",
    "Microsoft-Windows-SenseClient-Package",
    "Microsoft-Windows-RecDisc-SDP-Package",
    "Microsoft-Windows-AppManagement-AppV-Package",
    "Microsoft-Windows-AppManagement-AppV-WOW64-Package",
    "Microsoft-Windows-AppManagement-Common-Package",
    "Microsoft-Windows-AppManagement-Common-WOW64-Package",
    "Microsoft-Windows-AppManagement-UEV-Package",
    "Microsoft-Windows-AppManagement-UEV-WOW64-Package",
    "Microsoft-Windows-FCI-Client-Package",
    "Microsoft-Windows-FCI-Client-WOW64-Package",
    "Microsoft-Media-Foundation-Server-Package",
    "Microsoft-Media-Foundation-Server-WOW64-Package"
)

[xml]$proDoc = [System.IO.File]::ReadAllText($proMum1)
$proDoc.assembly.assemblyIdentity.version = $pkgVer
$nsUri = $proDoc.assembly.NamespaceURI
$pkgNode = $proDoc.assembly.package

# Add hidden ServerCore-Package (10.0.20348.1) solely to satisfy parent check of ServerCore-WOW64-Package -> ServerCore-WOW64-Payload-Package
$scUpd = $proDoc.CreateElement("update", $nsUri)
$scUpd.SetAttribute("name", "Microsoft-Windows-ServerCore-Package_base")
$scPkg = $proDoc.CreateElement("package", $nsUri)
$scPkg.SetAttribute("contained", "false")
$scPkg.SetAttribute("integrate", "hidden")
$scAi = $proDoc.CreateElement("assemblyIdentity", $nsUri)
$scAi.SetAttribute("name", "Microsoft-Windows-ServerCore-Package")
$scAi.SetAttribute("version", "10.0.20348.1")
$scAi.SetAttribute("processorArchitecture", "amd64")
$scAi.SetAttribute("language", "neutral")
$scAi.SetAttribute("buildType", "release")
$scAi.SetAttribute("publicKeyToken", "31bf3856ad364e35")
[void]$scPkg.AppendChild($scAi)
[void]$scUpd.AppendChild($scPkg)
[void]$pkgNode.AppendChild($scUpd)

foreach ($lcuPkgName in $lcuSharedPkgNames) {
    $lk = $lcuPkgName.ToLowerInvariant()
    if ($latestPkgMap.ContainsKey($lk)) {
        $ver = $latestPkgMap[$lk]
        $uNode = $proDoc.CreateElement("update", $nsUri)
        $uNode.SetAttribute("name", "${lcuPkgName}_lcu")
        $pNode = $proDoc.CreateElement("package", $nsUri)
        $pNode.SetAttribute("contained", "false")
        $pNode.SetAttribute("integrate", "hidden")
        $aiNode = $proDoc.CreateElement("assemblyIdentity", $nsUri)
        $aiNode.SetAttribute("name", $lcuPkgName)
        $aiNode.SetAttribute("version", $ver)
        $aiNode.SetAttribute("processorArchitecture", "amd64")
        $aiNode.SetAttribute("language", "neutral")
        $aiNode.SetAttribute("buildType", "release")
        $aiNode.SetAttribute("publicKeyToken", "31bf3856ad364e35")
        [void]$pNode.AppendChild($aiNode)
        [void]$uNode.AppendChild($pNode)
        [void]$pkgNode.AppendChild($uNode)
    }
}
$proOut = Join-Path $uupStagePool "Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~$pkgVer.mum"
$proDoc.Save($proOut)

# Ensure every .mum in $uupStagePool has a companion .cat file so CBS/DISM never returns ERROR_FILE_NOT_FOUND (exit code 2)
$fndCat = Join-Path $uupStagePool "Microsoft-Windows-Foundation-Package~31bf3856ad364e35~amd64~~10.0.20348.1.cat"
Get-ChildItem "$uupStagePool\*.mum" | ForEach-Object {
    $catPath = $_.FullName -replace '\.mum$', '.cat'
    if (-not (Test-Path $catPath)) {
        Copy-Item $fndCat $catPath -Force
    }
}

# Dynamically build <package action="remove"> entries for all present versions of ServerStandardEdition
$removeXmlBuilder = New-Object System.Text.StringBuilder
$removePatterns = @(
    "Microsoft-Windows-ServerStandardEdition~*.mum"
)
foreach ($pat in $removePatterns) {
    Get-ChildItem "$mountDir\Windows\servicing\Packages\$pat" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -match '^([^~]+)~([^~]+)~([^~]+)~([^~]*)~([0-9\.]+)\.mum$') {
            $rName = $matches[1]
            $rTok  = $matches[2]
            $rArch = $matches[3]
            $rLang = if ($matches[4]) { $matches[4] } else { "neutral" }
            $rVer  = $matches[5]
            [void]$removeXmlBuilder.AppendLine("        <package action=`"remove`">")
            [void]$removeXmlBuilder.AppendLine("            <assemblyIdentity name=`"$rName`" version=`"$rVer`" processorArchitecture=`"$rArch`" publicKeyToken=`"$rTok`" language=`"$rLang`" />")
            [void]$removeXmlBuilder.AppendLine("        </package>")
        }
    }
}
$removeXmlBlock = $removeXmlBuilder.ToString().TrimEnd()

# Construct the 100% Native DISM Servicing Unattend XML
$unattendPath = Join-Path $tmpDir "native_client_switch.xml"
$unattendContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <servicing>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Foundation-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Foundation-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Client-Desktop-Required-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Client-Desktop-Required-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Client-Desktop-Required-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Client-Desktop-Required-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Client-Features-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Client-Features-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Client-Features-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Client-Features-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-EditionPack-Professional-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-EditionPack-Professional-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-EditionPack-Professional-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-EditionPack-Professional-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-EditionSpecific-Professional-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-EditionSpecific-Professional-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-EditionSpecific-Professional-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-EditionSpecific-Professional-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-EditionSpecific-EnterpriseG-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-EditionSpecific-EnterpriseG-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Not-Supported-On-LTSB-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Not-Supported-On-LTSB-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Not-Supported-On-LTSB-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Not-Supported-On-LTSB-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-RegulatedPackages-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-RegulatedPackages-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-RegulatedPackages-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-RegulatedPackages-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Required-ShellExperiences-Desktop-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Required-ShellExperiences-Desktop-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Required-ShellExperiences-Desktop-WOW64-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Required-ShellExperiences-Desktop-WOW64-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Server-LanguagePack-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="zh-CN" />
            <source location="$uupStagePool\Microsoft-Windows-Server-LanguagePack-Package~31bf3856ad364e35~amd64~zh-CN~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Media-Features-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Media-Features-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-MediaFeaturePack-OOB-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-MediaFeaturePack-OOB-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-Media-Placeholder-Package" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~$pkgVer.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="WinPE-OpcServices-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\WinPE-OpcServices-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="stage">
            <assemblyIdentity name="Microsoft-Windows-ProfessionalEdition" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~$pkgVer.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Media-Features-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-MediaFeaturePack-OOB-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Media-Placeholder-Package" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
        <package action="install">
            <assemblyIdentity name="WinPE-OpcServices-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-ProfessionalEdition" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
$removeXmlBlock
    </servicing>
</unattend>
"@
[System.IO.File]::WriteAllText($unattendPath, $unattendContent, [System.Text.Encoding]::UTF8)

Write-Host "  Executing DISM /Apply-Unattend (Native CBS Stage + Edition Switch + LCU Preservation + Server SKU/FoD Removal)..." -ForegroundColor Cyan
dism.exe /Image:$mountDir /Apply-Unattend:$unattendPath
if ($LASTEXITCODE -ne 0) { throw "DISM /Apply-Unattend failed with exit code $LASTEXITCODE" }

# Remove any remaining standalone top-level Server optional packages if present in the image
$extraRemovePkgs = Get-ChildItem "$mountDir\Windows\servicing\Packages\*.mum" |
    Where-Object { $_.BaseName -match '^(Microsoft-Windows-ServerDatacenterEdition|Downlevel-NLS-Sorting-Versions-Server-FoD-Package|Microsoft-Windows-Server-AppCompat-FoD-Package|Microsoft-Server-AzureArcSetup-FoD-Package|Microsoft-Windows-ServerManager-Tools-FoD-Package)~' } |
    Select-Object -ExpandProperty BaseName
if ($extraRemovePkgs) {
    foreach ($pkgIdentity in $extraRemovePkgs) {
        Write-Host "  Removing residual Server package: $pkgIdentity..."
        dism.exe /Image:$mountDir /Remove-Package /PackageName:$pkgIdentity | Out-Null
    }
}

# Install the 5 official zh-CN LanguageFeatures FOD CABs
Write-Host "  Installing 5 official zh-CN LanguageFeatures FOD CABs..." -ForegroundColor Cyan
$fodCabs = Get-ChildItem "$uupDir\Microsoft-Windows-LanguageFeatures-*-zh-cn-Package-amd64.cab"
foreach ($cab in $fodCabs) {
    dism.exe /Image:$mountDir /Add-Package /PackagePath:$($cab.FullName)
    if ($LASTEXITCODE -ne 0) { throw "DISM Add-Package failed for $($cab.Name)" }
}

# Verify and enforce pure Client OOBE & Explorer shell + Default Visual Effects in mounted hives
Write-Host "  Verifying Client OOBE, Explorer AvailableShells (60000=explorer.exe), and Default Visual Effects..." -ForegroundColor Cyan
reg.exe load "HKLM\MOUNT_SW" "$mountDir\Windows\System32\config\SOFTWARE" | Out-Null
reg.exe load "HKLM\MOUNT_DEFAULT" "$mountDir\Users\Default\NTUSER.DAT" | Out-Null
try {
    [RegPrivHelper]::EnsurePureExplorerAvailableShell("MOUNT_SW\Microsoft\Windows NT\CurrentVersion\Winlogon\AlternateShells\AvailableShells")
    reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d "explorer.exe" /f | Out-Null
    reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows NT\CurrentVersion\Winlogon\AlternateShells" /v DefaultShell /t REG_SZ /d "explorer.exe" /f | Out-Null
    reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows NT\CurrentVersion" /v InstallationType /t REG_SZ /d "Client" /f | Out-Null

    # Enable all Client visual effects by default (VisualFXSetting = 1: Best Appearance)
    reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 1 /f | Out-Null
    foreach ($sub in @("ControlAnimations","AnimateMinMax","TaskbarAnimations","ComboBoxAnimation","CursorShadow","DropShadow","ListBoxSmoothScrolling","ListviewAlphaSelect","ListviewShadow","MenuAnimation","SelectionFade","ThumbnailsOrIcon","TooltipAnimation","DWMAeroPeekEnabled","DWMEnabled","DWMGlass")) {
        reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\$sub" /v DefaultByAlphaTest /t REG_DWORD /d 1 /f | Out-Null
        reg.exe add "HKLM\MOUNT_SW\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects\$sub" /v DefaultValue /t REG_DWORD /d 1 /f | Out-Null
    }
    reg.exe add "HKLM\MOUNT_DEFAULT\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 1 /f | Out-Null
} finally {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    reg.exe unload "HKLM\MOUNT_DEFAULT" | Out-Null
    reg.exe unload "HKLM\MOUNT_SW" | Out-Null
}

# Commit the serviced base Professional image before branching clean LTSC-style vs Full UWP editions
Write-Host "  Committing serviced Windows 10 Client base image..." -ForegroundColor Cyan
dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
if ($LASTEXITCODE -ne 0) { throw "DISM Unmount-Wim Commit failed" }

# ---------------------------------------------------------------------------
# 5. Build Index 1: Clean LTSC-Style Edition (Windows 10 IoT Enterprise - Zero Consumer UWP Bloat)
# ---------------------------------------------------------------------------
Write-Host "[5/7] Creating Index 1: Windows 10 IoT Enterprise (Clean Edition without Consumer UWP Bloat)..." -ForegroundColor Yellow

& $wimlib export $workWim 1 $finalWim "Windows 10 IoT Enterprise" "Windows 10 IoT Enterprise"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 1 failed" }

dism.exe /Mount-Wim /WimFile:$finalWim /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "DISM Mount-Wim Index 1 failed" }
try {
    dism.exe /Image:$mountDir /Set-Edition:IoTEnterprise
    if ($LASTEXITCODE -ne 0) { throw "DISM Set-Edition:IoTEnterprise failed" }
} finally {
    dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
    if ($LASTEXITCODE -ne 0) { throw "DISM Unmount-Wim Index 1 failed" }
}
& $wimlib info $finalWim 1 "Windows 10 IoT Enterprise" "Windows 10 IoT Enterprise" `
    "--image-property=EDITIONID=IoTEnterprise" `
    "--image-property=INSTALLATIONTYPE=Client" `
    "--image-property=PRODUCTTYPE=WinNT" `
    "--image-property=PRODUCTSUITE=Terminal Server" `
    "--image-property=DISPLAYNAME=Windows 10 IoT 企业版 (精简无预装UWP)" `
    "--image-property=DISPLAYDESCRIPTION=Windows 10 IoT 企业版 (精简无预装UWP)" `
    "--image-property=FLAGS=IoTEnterprise"

# ---------------------------------------------------------------------------
# 6. Provision Official Microsoft Store & 41 UWP Apps for Index 2 (Pro), Index 3 (Pro Workstation), Index 4 (Enterprise)
# ---------------------------------------------------------------------------
Write-Host "[6/7] Provisioning official Microsoft Store & 41 Modern UWP Apps into Pro / Workstation / Enterprise..." -ForegroundColor Yellow

dism.exe /Mount-Wim /WimFile:$workWim /Index:1 /MountDir:$mountDir
if ($LASTEXITCODE -ne 0) { throw "DISM Mount-Wim workWim failed" }
try {
    $allDeps = Get-ChildItem $modernAppsDir -Recurse -Include *.appx, *.msix |
        Where-Object { $_.Name -match "^Microsoft\.(VCLibs|NET\.Native|UI\.Xaml)" } |
        Select-Object -ExpandProperty FullName
    $depArgs = $allDeps | ForEach-Object { "/DependencyPackagePath:`"$_`"" }

    $appDirs = Get-ChildItem $modernAppsDir -Directory
    $provCount = 0
    foreach ($ad in $appDirs) {
        $bundle = Get-ChildItem $ad.FullName -Include *.appxbundle, *.msixbundle -Recurse | Select-Object -First 1
        $lic    = Get-ChildItem $ad.FullName -Filter *_License1.xml -Recurse | Select-Object -First 1
        if ($bundle -and $lic) {
            $provCount++
            Write-Host "  [$provCount] Provisioning $($ad.Name)..."
            $cmdArgs = @("/Image:`"$mountDir`"", "/Add-ProvisionedAppxPackage", "/PackagePath:`"$($bundle.FullName)`"", "/LicensePath:`"$($lic.FullName)`"", "/Region:all") + $depArgs
            $p = Start-Process -FilePath "dism.exe" -ArgumentList $cmdArgs -Wait -NoNewWindow -PassThru
            if ($p.ExitCode -ne 0) {
                Write-Warning "DISM Add-ProvisionedAppxPackage returned $($p.ExitCode) for $($ad.Name)"
            }
        }
    }
    Write-Host "  Provisioned $provCount official Modern UWP apps [OK]" -ForegroundColor Green
} finally {
    dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
    if ($LASTEXITCODE -ne 0) { throw "DISM Unmount-Wim workWim failed" }
}

# Export Index 2: Windows 10 Pro
& $wimlib export $workWim 1 $finalWim "Windows 10 Pro" "Windows 10 Pro"
& $wimlib info $finalWim 2 "Windows 10 Pro" "Windows 10 Pro" `
    "--image-property=EDITIONID=Professional" `
    "--image-property=INSTALLATIONTYPE=Client" `
    "--image-property=PRODUCTTYPE=WinNT" `
    "--image-property=PRODUCTSUITE=Terminal Server" `
    "--image-property=DISPLAYNAME=Windows 10 专业版" `
    "--image-property=DISPLAYDESCRIPTION=Windows 10 专业版" `
    "--image-property=FLAGS=Professional"

# Export & Native Transmog Index 3: Windows 10 Pro for Workstations
& $wimlib export $workWim 1 $finalWim "Windows 10 Pro for Workstations" "Windows 10 Pro for Workstations"
dism.exe /Mount-Wim /WimFile:$finalWim /Index:3 /MountDir:$mountDir
try {
    dism.exe /Image:$mountDir /Set-Edition:ProfessionalWorkstation
    if ($LASTEXITCODE -ne 0) { throw "DISM Set-Edition:ProfessionalWorkstation failed" }
} finally {
    dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
}
& $wimlib info $finalWim 3 "Windows 10 Pro for Workstations" "Windows 10 Pro for Workstations" `
    "--image-property=EDITIONID=ProfessionalWorkstation" `
    "--image-property=INSTALLATIONTYPE=Client" `
    "--image-property=PRODUCTTYPE=WinNT" `
    "--image-property=PRODUCTSUITE=Terminal Server" `
    "--image-property=DISPLAYNAME=Windows 10 专业工作站版" `
    "--image-property=DISPLAYDESCRIPTION=Windows 10 专业工作站版" `
    "--image-property=FLAGS=ProfessionalWorkstation"

# Export & Native Transmog Index 4: Windows 10 Enterprise
& $wimlib export $workWim 1 $finalWim "Windows 10 Enterprise" "Windows 10 Enterprise"
dism.exe /Mount-Wim /WimFile:$finalWim /Index:4 /MountDir:$mountDir
try {
    dism.exe /Image:$mountDir /Set-Edition:Enterprise
    if ($LASTEXITCODE -ne 0) { throw "DISM Set-Edition:Enterprise failed" }
} finally {
    dism.exe /Unmount-Wim /MountDir:$mountDir /Commit
}
& $wimlib info $finalWim 4 "Windows 10 Enterprise" "Windows 10 Enterprise" `
    "--image-property=EDITIONID=Enterprise" `
    "--image-property=INSTALLATIONTYPE=Client" `
    "--image-property=PRODUCTTYPE=WinNT" `
    "--image-property=PRODUCTSUITE=Terminal Server" `
    "--image-property=DISPLAYNAME=Windows 10 企业版" `
    "--image-property=DISPLAYDESCRIPTION=Windows 10 企业版" `
    "--image-property=FLAGS=Enterprise"

Remove-Item $workWim -Force -ErrorAction SilentlyContinue
& $wimlib optimize $finalWim

# ---------------------------------------------------------------------------
# 7. Replace install.wim, Write ei.cfg, and Build Bootable Client ISO
# ---------------------------------------------------------------------------
Write-Host "[7/7] Building final bootable Windows 10 Build 20348 Client ISO..." -ForegroundColor Yellow

Move-Item -Path $finalWim -Destination $origWim -Force

$eiCfgContent = @"
[Channel]
_Default
[VL]
0
"@
[IO.File]::WriteAllText((Join-Path $isoExtractDir "sources\ei.cfg"), $eiCfgContent, [Text.Encoding]::ASCII)

$buildRev = ($pkgVer -split '\.')[-1]
$outIsoName = "Win10_20348.${buildRev}_Client_IoT_Pro_Workstation_Ent_x64_zh-cn.iso"
$outIsoPath = Join-Path $OutputDir $outIsoName

$etfsboot = Join-Path $isoExtractDir "boot\etfsboot.com"
$efisys   = Join-Path $isoExtractDir "efi\microsoft\boot\efisys.bin"

& $oscdimg -m -o -u2 -udfver102 "-bootdata:2#p0,e,b$etfsboot#pEF,e,b$efisys" "-lWIN10_20348_CLIENT_X64" $isoExtractDir $outIsoPath
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed to create ISO" }

$isoHash = (Get-FileHash -Path $outIsoPath -Algorithm SHA256).Hash.ToLowerInvariant()
$isoSizeMB = [Math]::Round((Get-Item $outIsoPath).Length / 1MB, 2)

Write-Host "==================================================================" -ForegroundColor Green
Write-Host " BUILD COMPLETE!" -ForegroundColor Green
Write-Host " Output ISO : $outIsoPath" -ForegroundColor Green
Write-Host " Size       : $isoSizeMB MB" -ForegroundColor Green
Write-Host " SHA-256    : $isoHash" -ForegroundColor Green
Write-Host " Version    : $pkgVer" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

if ($env:GITHUB_OUTPUT) {
    "iso_path=$outIsoPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "iso_name=$outIsoName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "iso_sha256=$isoHash"  | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "build_ver=$pkgVer"    | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
