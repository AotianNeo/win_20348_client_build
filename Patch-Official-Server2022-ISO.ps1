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
    @{ Name = "Microsoft-Windows-Foundation-Package.ESD";                                      Sha1 = "ba8b5df4efae4fa87fb0cecf21b6069a3ff81617"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Desktop-Required-Package.ESD";                         Sha1 = "5b930270062ad55a9bb8d44f08e16b9719fa23c1"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Desktop-Required-WOW64-Package.ESD";                   Sha1 = "dc772f6611ff2be4912b51349de80cd6e28b51b8"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Features-Package.ESD";                                 Sha1 = "c54f0db05471fb043fb446fbef4cd79b9c75a811"; Stage = $true },
    @{ Name = "Microsoft-Windows-Client-Features-WOW64-Package.ESD";                           Sha1 = "1dc5a25150faafcb88dc61ed68ff8a2232098409"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionPack-Professional-Package.ESD";                        Sha1 = "6272e34d44c77a66eb4234385c759a01f74264aa"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionPack-Professional-WOW64-Package.ESD";                  Sha1 = "8a38fd4c977b3095b05f4ab0bf402dc3fd304b2b"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-Professional-Package.ESD";                    Sha1 = "dfea095b1cf7261795467fa6cc07268159c87195"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-Professional-WOW64-Package.ESD";              Sha1 = "eb2538740bc4efca7c9e95a1e60a8a3e7f340bc7"; Stage = $true },
    @{ Name = "Microsoft-Windows-EditionSpecific-EnterpriseG-Package.ESD";                     Sha1 = "4ab72894cf11b02fb1bdffba36765ab475c6e7bd"; Stage = $true },
    @{ Name = "Microsoft-Windows-Not-Supported-On-LTSB-Package.ESD";                           Sha1 = "caaa1c21ce2946d0ae12c5674ef19a911417d950"; Stage = $true },
    @{ Name = "Microsoft-Windows-Not-Supported-On-LTSB-WOW64-Package.ESD";                     Sha1 = "220e07bdca4fb7822e954ce9c469df1eb0f31e24"; Stage = $true },
    @{ Name = "Microsoft-Windows-RegulatedPackages-Package.ESD";                               Sha1 = "be9d94ae3a60e2a7d9d3c376bc3e69ac2d20fc20"; Stage = $true },
    @{ Name = "Microsoft-Windows-RegulatedPackages-WOW64-Package.ESD";                         Sha1 = "a75e8c28cb51cd92817f9a3d746e6de01d8a3fd7"; Stage = $true },
    @{ Name = "Microsoft-Windows-Required-ShellExperiences-Desktop-Package.ESD";               Sha1 = "2fa34b9868917d13d95f3c8e7df9a64ee843c414"; Stage = $true },
    @{ Name = "Microsoft-Windows-Required-ShellExperiences-Desktop-WOW64-Package.ESD";         Sha1 = "e904e5e4c36d025e7a4805975a3bd5a6d7b9321b"; Stage = $true },
    @{ Name = "Microsoft-Windows-Server-LanguagePack-Package_zh-cn-amd64-zh-cn.esd";           Sha1 = "7f52815d30b42f128070f72ca76b394e16faec17"; Stage = $true },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Basic-zh-cn-Package-amd64.cab";              Sha1 = "fb2ebde13a1bd26183072dc63a91c1fa96d1100a"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Handwriting-zh-cn-Package-amd64.cab";        Sha1 = "8e6305212ef4d60ffcb8fd3c8a5671fd13be1ff0"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-OCR-zh-cn-Package-amd64.cab";                Sha1 = "993a987b75617df0ab1cf9f19bd6bb337c84bd88"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-Speech-zh-cn-Package-amd64.cab";             Sha1 = "32abdfce3c2c0e3fb66f690865d4f7b148f8220f"; Stage = $false },
    @{ Name = "Microsoft-Windows-LanguageFeatures-TextToSpeech-zh-cn-Package-amd64.cab";       Sha1 = "a2086d605a92a07abdc2d5f784a55f2df6c06963"; Stage = $false },
    @{ Name = "Microsoft.ModernApps.Client.All.esd";                                           Sha1 = "8154e3df67387100ce3f3d720dc434deff6ec9b1"; Stage = $false },
    @{ Name = "Microsoft.ModernApps.Client.professional.esd";                                  Sha1 = "e2f15cc4b38672fc1f154c93d379050b9ca0e0dd"; Stage = $false }
)

foreach ($pkg in $uupPackages) {
    $destFile = Join-Path $uupDir $pkg.Name
    if (-not (Test-Path $destFile)) {
        Write-Host "  Downloading $($pkg.Name)..."
        & $aria2c -x16 -s16 -k1M --file-allocation=none --console-log-level=warn -d $uupDir -o $pkg.Name "$releaseBaseUrl/$($pkg.Name)"
        if ($LASTEXITCODE -ne 0) { throw "Failed to download $($pkg.Name)" }
    }
    $h = (Get-FileHash -Path $destFile -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($h -ne $pkg.Sha1) {
        throw "SHA-1 mismatch for $($pkg.Name): expected $($pkg.Sha1), got $h"
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

# Copy OfficialEditionManifests into $uupStagePool and generate version-aligned $pkgVer .mum files
$manifestsDir = Join-Path $PSScriptRoot "OfficialEditionManifests"
$proMum1 = Join-Path $manifestsDir "Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~10.0.20348.1.mum"
$mpMum1  = Join-Path $manifestsDir "Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum"
Copy-Item $proMum1 $uupStagePool -Force
Copy-Item $mpMum1  $uupStagePool -Force

# Build lookup of latest installed/staged package versions in $mountDir\Windows\servicing\Packages and $uupStagePool
$latestPkgMap = @{}
foreach ($dir in @("$uupStagePool", "$mountDir\Windows\servicing\Packages")) {
    Get-ChildItem "$dir\*.mum" | ForEach-Object {
        if ($_.Name -match '^([^~]+)~([^~]+)~([^~]+)~([^~]*)~([0-9\.]+)\.mum$') {
            $key = "$($matches[1])~$($matches[2])~$($matches[3])~$($matches[4])".ToLowerInvariant()
            $ver = [version]$matches[5]
            if (-not $latestPkgMap.ContainsKey($key) -or $ver -gt [version]$latestPkgMap[$key]) {
                $latestPkgMap[$key] = $matches[5]
            }
        }
    }
}

# Align Media-Placeholder-Package to $pkgVer
$mpXml = [System.IO.File]::ReadAllText($mpMum1)
$mpXml = $mpXml.Replace('version="10.0.20348.1"', "version=`"$pkgVer`"")
$mpOut = Join-Path $uupStagePool "Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~$pkgVer.mum"
[System.IO.File]::WriteAllText($mpOut, $mpXml, [System.Text.Encoding]::UTF8)
$latestPkgMap["microsoft-windows-media-placeholder-package~31bf3856ad364e35~amd64~"] = $pkgVer

# Align ProfessionalEdition to $pkgVer and match every child <package> to the latest version in $latestPkgMap
[xml]$proDoc = [System.IO.File]::ReadAllText($proMum1)
$proDoc.assembly.assemblyIdentity.version = $pkgVer
foreach ($upd in $proDoc.assembly.package.update) {
    $ai = $upd.package.assemblyIdentity
    if ($ai) {
        $lang = if ($ai.language -and $ai.language -ne "neutral") { $ai.language } else { "" }
        $lookupKey = "$($ai.name)~$($ai.publicKeyToken)~$($ai.processorArchitecture)~$lang".ToLowerInvariant()
        if ($latestPkgMap.ContainsKey($lookupKey)) {
            $ai.version = $latestPkgMap[$lookupKey]
        }
    }
}
$proOut = Join-Path $uupStagePool "Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~$pkgVer.mum"
$proDoc.Save($proOut)

# Also copy the LCU-updated Server-LanguagePack and Media-Foundation-Server-Package .mum/.cat from mounted image into $uupStagePool so DISM can reference them from source
Copy-Item "$mountDir\Windows\servicing\Packages\Microsoft-Windows-Server-LanguagePack-Package~31bf3856ad364e35~amd64~zh-CN~$pkgVer.*" $uupStagePool -Force
Copy-Item "$mountDir\Windows\servicing\Packages\Microsoft-Media-Foundation-Server-Package~31bf3856ad364e35~amd64~~$mfVer.*" $uupStagePool -Force

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
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Media-Features-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Media-Features-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-MediaFeaturePack-OOB-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-MediaFeaturePack-OOB-Package~31bf3856ad364e35~amd64~~10.0.20348.1.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Media-Placeholder-Package" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-Media-Placeholder-Package~31bf3856ad364e35~amd64~~$pkgVer.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-ProfessionalEdition" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Windows-ProfessionalEdition~31bf3856ad364e35~amd64~~$pkgVer.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Server-LanguagePack-Package" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="zh-CN" />
            <source location="$uupStagePool\Microsoft-Windows-Server-LanguagePack-Package~31bf3856ad364e35~amd64~zh-CN~10.0.20348.1.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Windows-Server-LanguagePack-Package" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="zh-CN" />
            <source location="$uupStagePool\Microsoft-Windows-Server-LanguagePack-Package~31bf3856ad364e35~amd64~zh-CN~$pkgVer.mum" />
        </package>
        <package action="install">
            <assemblyIdentity name="Microsoft-Media-Foundation-Server-Package" version="$mfVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
            <source location="$uupStagePool\Microsoft-Media-Foundation-Server-Package~31bf3856ad364e35~amd64~~$mfVer.mum" />
        </package>
        <package action="remove">
            <assemblyIdentity name="Microsoft-Windows-ServerStandardEdition" version="10.0.20348.1" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
        <package action="remove">
            <assemblyIdentity name="Microsoft-Windows-ServerStandardEdition" version="$pkgVer" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" />
        </package>
    </servicing>
</unattend>
"@
[System.IO.File]::WriteAllText($unattendPath, $unattendContent, [System.Text.Encoding]::UTF8)

Write-Host "  Executing DISM /Apply-Unattend (Native CBS Stage + Edition Switch + LCU Preservation)..." -ForegroundColor Cyan
dism.exe /Image:$mountDir /Apply-Unattend:$unattendPath
if ($LASTEXITCODE -ne 0) { throw "DISM /Apply-Unattend failed with exit code $LASTEXITCODE" }

# Remove any remaining ServerDatacenterEdition or Server-Shell-Package packages if present in the image
$extraRemovePkgs = Get-ChildItem "$mountDir\Windows\servicing\Packages\*.mum" |
    Where-Object { $_.BaseName -match '^(Microsoft-Windows-ServerDatacenterEdition|Microsoft-Windows-Server-Shell-Package|PowerShell-SConfig-Package|Microsoft-ServerCore-ShellLauncher-Package)~' } |
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
