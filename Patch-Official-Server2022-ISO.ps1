#Requires -RunAsAdministrator
<#
.SYNOPSIS
    100% Official Source Automated Patcher: Windows Server 2022 (Build 20348) -> Windows 20348 Client Multi-Edition ISO
    Editions Built:
      1. Windows 10 Enterprise LTSC 2021 (EnterpriseS)
      2. Windows 10 IoT Enterprise LTSC 2021 (IoTEnterpriseS)
      3. Windows 10 Pro (Professional)
      4. Windows 10 Enterprise (Enterprise)
    Features Included:
      - Full Client CBS Packages & WinSxS Components (EnterpriseS + Professional/Enterprise)
      - 71 Client-Only Hardware Drivers Registered in DRIVERS & SYSTEM Hives:
          * 12 Intel/AMD Serial IO I2C & GPIO Touchpad Host Controller Drivers
          * 7 Bluetooth Audio Profile Drivers (A2DP Sink/Source, AVRCP Transport, HFP Hands-Free/Audio Gateway)
          * 44 Desktop Wireless Wi-Fi Network Adapters (Intel/Realtek/Qualcomm/Broadcom) & 4 Xbox GIP/HID Drivers
      - 99 Client Services & Svchost Service Groups (BthAvctpSvc, BTAGService, BluetoothUserService, XboxGipSvc, etc.)
      - Default Pre-Enabled .NET Framework 3.5 (NetFx3) from Official ISO sources\sxs CAB
#>
param(
    [string]$WorkDir = "$PSScriptRoot\work",
    [string]$OutputDir = "$PSScriptRoot\output"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Windows 20348 Client ISO Builder (Full Client Packages & Drivers)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $WorkDir, $OutputDir | Out-Null
$tmpDir = Join-Path $WorkDir "tmp"
$ltscStaging = Join-Path $WorkDir "ltsc_official"
$proStaging = Join-Path $WorkDir "pro_official"
$clientOverlay = Join-Path $WorkDir "client_overlay"
$isoExtractDir = Join-Path $WorkDir "iso_root"
$mountDir = Join-Path $WorkDir "mount"
$pkgStaging = Join-Path $WorkDir "synth_pkgs"
$payloadEntSDir = Join-Path $WorkDir "payload_entS"
$payloadProExtraDir = Join-Path $WorkDir "payload_pro_extra"
New-Item -ItemType Directory -Force -Path $tmpDir, $ltscStaging, $proStaging, $clientOverlay, $isoExtractDir, $mountDir, $pkgStaging, $payloadEntSDir, $payloadProExtraDir | Out-Null

# ---------------------------------------------------------------------------
# 0. Ensure Required CLI Tools (wimlib-imagex, aria2c, 7z, oscdimg)
# ---------------------------------------------------------------------------
Write-Host "[0/6] Checking required build tools..." -ForegroundColor Yellow

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

Write-Host "  wimlib : $wimlib"
Write-Host "  aria2c : $aria2c"
Write-Host "  7z     : $sevenZip"
Write-Host "  oscdimg: $oscdimg"

# ---------------------------------------------------------------------------
# 1. Compile Embedded C# Helpers (Hex & ProductPolicy SKU Patcher)
# ---------------------------------------------------------------------------
Write-Host "[1/6] Compiling embedded C# helpers..." -ForegroundColor Yellow

Add-Type -TypeDefinition @'
using System;
using System.Text;

public class OfficialIsoHelper {
    public static byte[] HexToBytes(string hex) {
        byte[] bytes = new byte[hex.Length / 2];
        for (int i = 0; i < bytes.Length; i++) {
            bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        }
        return bytes;
    }

    public static byte[] PatchProductPolicySku(byte[] policyBytes, uint targetProductInfo) {
        byte[] b = (byte[])policyBytes.Clone();
        int pos = 20;
        int end = BitConverter.ToInt32(b, 0);
        while (pos + 16 <= end && pos + 16 <= b.Length) {
            ushort entrySize = BitConverter.ToUInt16(b, pos);
            ushort nameSize  = BitConverter.ToUInt16(b, pos + 2);
            ushort valType   = BitConverter.ToUInt16(b, pos + 4);
            ushort valSize   = BitConverter.ToUInt16(b, pos + 6);
            if (entrySize == 0) break;
            string name = Encoding.Unicode.GetString(b, pos + 16, nameSize);
            int valOff = pos + 16 + nameSize;
            if ((name == "Kernel-ProductInfo" || name == "Kernel-BrandingInfo") && valType == 4 && valSize == 4) {
                Buffer.BlockCopy(BitConverter.GetBytes(targetProductInfo), 0, b, valOff, 4);
            }
            pos += entrySize;
        }
        return b;
    }
}
'@

# ---------------------------------------------------------------------------
# 2. Fetch Latest Official Windows Server 2022 ISO from ntriver.org
# ---------------------------------------------------------------------------
Write-Host "[2/6] Querying ntriver.org for the latest official Windows Server 2022 ISO..." -ForegroundColor Yellow

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
# 3. Load Official Client Assets, Registry Exports & ClientPayload_20348.esd
# ---------------------------------------------------------------------------
Write-Host "[3/6] Loading official Client SKU tokens, Registry Hives & ClientPayload_20348.esd..." -ForegroundColor Yellow

$repoOfficialDir = Join-Path $PSScriptRoot "OfficialClientFiles"
if (Test-Path $repoOfficialDir) {
    Write-Host "  Using repository OfficialClientFiles ($repoOfficialDir)..." -ForegroundColor Cyan
    robocopy.exe "$repoOfficialDir\Windows" "$clientOverlay\Windows" /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
    [xml]$entSXml = [IO.File]::ReadAllText((Join-Path $repoOfficialDir "Manifests\enterprises-default.xml"))
    [xml]$entXml  = [IO.File]::ReadAllText((Join-Path $repoOfficialDir "Manifests\enterprise-default.xml"))
} else {
    throw "OfficialClientFiles directory not found at $repoOfficialDir"
}

$regDir = Join-Path $repoOfficialDir "Registry"
$regDriversFile  = Join-Path $regDir "ClientDrivers_DRIVERS.reg"
$regSysFile      = Join-Path $regDir "ClientDriversAndServices_SYSTEM.reg"
$regSwBaseFile   = Join-Path $regDir "ClientCbsAndSvchost_Base_SOFTWARE.reg"
$regSwProExtFile = Join-Path $regDir "ClientCbs_ProExtra_SOFTWARE.reg"

foreach ($rf in @($regDriversFile, $regSysFile, $regSwBaseFile, $regSwProExtFile)) {
    if (-not (Test-Path $rf)) { throw "Required registry file missing: $rf" }
}

$payloadEsdUrl = "https://github.com/AotianNeo/win_20348_client_build/releases/download/v20348.1-client-payload/ClientPayload_20348.esd"
$payloadEsdPath = Join-Path $WorkDir "ClientPayload_20348.esd"
if (-not (Test-Path $payloadEsdPath)) {
    Write-Host "  Downloading ClientPayload_20348.esd (~230 MB Solid LZMS)..." -ForegroundColor Cyan
    & $aria2c -x16 -s16 -k1M --file-allocation=none --console-log-level=warn -d $WorkDir -o "ClientPayload_20348.esd" $payloadEsdUrl
    if ($LASTEXITCODE -ne 0) { throw "Failed to download ClientPayload_20348.esd" }
}

Write-Host "  Extracting ClientPayload_20348.esd Image 1 (EnterpriseS Base Client Payload) & Image 2 (Pro/Enterprise Extra Payload)..." -ForegroundColor Cyan
& $wimlib apply $payloadEsdPath 1 $payloadEntSDir --no-acls | Out-Null
if ($LASTEXITCODE -ne 0) { throw "wimlib apply Image 1 of ClientPayload_20348.esd failed" }
& $wimlib apply $payloadEsdPath 2 $payloadProExtraDir --no-acls | Out-Null
if ($LASTEXITCODE -ne 0) { throw "wimlib apply Image 2 of ClientPayload_20348.esd failed" }

function Get-ManifestRegMap([xml]$xmlDoc) {
    $map = @{}
    foreach ($rk in $xmlDoc.assembly.registryKeys.registryKey) {
        foreach ($rv in $rk.registryValue) {
            $map[$rv.name] = $rv.value
        }
    }
    return $map
}

$ltscReg = Get-ManifestRegMap $entSXml
$proReg  = Get-ManifestRegMap $entXml
$ltscPolicyBytes = [OfficialIsoHelper]::HexToBytes($ltscReg["ProductPolicy"])
$proPolicyBytes  = [OfficialIsoHelper]::HexToBytes($proReg["ProductPolicy"])

Write-Host "  Loaded official EnterpriseS Policy ($($ltscPolicyBytes.Length) bytes) & Enterprise/Pro Policy ($($proPolicyBytes.Length) bytes)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Extract Official Server 2022 ISO, Enable .NET Framework 3.5 & Extract Base Hives
# ---------------------------------------------------------------------------
Write-Host "[4/6] Extracting official Server 2022 ISO, enabling .NET Framework 3.5 (NetFx3), and preparing base WIM..." -ForegroundColor Yellow

& $sevenZip x $srvIsoPath "-o$isoExtractDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z failed to extract Server 2022 ISO" }

$origWim = Join-Path $isoExtractDir "sources\install.wim"
Set-ItemProperty -Path $origWim -Name IsReadOnly -Value $false

$newWimPath = Join-Path $WorkDir "install_client.wim"
if (Test-Path $newWimPath) { Remove-Item $newWimPath -Force }

# Export base image (Index 2 of $origWim = ServerStandard Desktop Experience) to $newWimPath Index 1
Write-Host "  Exporting Server 2022 Desktop Experience (Index 2) to new install.wim Index 1..."
& $wimlib export $origWim 2 $newWimPath "Windows 10 Enterprise LTSC 2021" "Windows 10 Enterprise LTSC 2021"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 1 failed" }

# Pre-enable .NET Framework 3.5 (NetFx3) natively via DISM using official ISO sources\sxs before Client conversion
$sxsDir = Join-Path $isoExtractDir "sources\sxs"
Write-Host "  Mounting base image and enabling .NET Framework 3.5 (NetFx3) from $sxsDir..." -ForegroundColor Cyan
dism.exe /Mount-Wim /WimFile:$newWimPath /Index:1 /MountDir:$mountDir | Out-Null
if ($LASTEXITCODE -ne 0) { throw "DISM Mount-Wim failed" }
try {
    dism.exe /Image:$mountDir /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:$sxsDir | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM Enable-Feature NetFx3 failed" }
    Write-Host "  Successfully enabled .NET Framework 3.5 (NetFx3) [OK]" -ForegroundColor Green
} finally {
    dism.exe /Unmount-Wim /MountDir:$mountDir /Commit | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM Unmount-Wim Commit failed" }
}

$hivesExtractDir = Join-Path $tmpDir "orig_hives"
New-Item -ItemType Directory -Force -Path $hivesExtractDir | Out-Null

& $wimlib extract $newWimPath 1 `
    "\Windows\System32\config\SYSTEM" `
    "\Windows\System32\config\SOFTWARE" `
    "\Windows\System32\config\DRIVERS" `
    "\Windows\servicing\Packages\Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~*.mum" `
    "--dest-dir=$hivesExtractDir" "--no-acls" "--nullglob" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "wimlib extract of base hives and ServerStandardEdition.mum failed" }

$srvStdMum = Get-ChildItem -Path $hivesExtractDir -Filter "Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~*.mum" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $srvStdMum) { throw "Could not find Microsoft-Windows-ServerStandardEdition.mum in Index 1" }

if ($srvStdMum.Name -match '~~([0-9\.]+)\.mum$') {
    $pkgVer = $matches[1]
} else {
    throw "Could not parse package version from $($srvStdMum.Name)"
}
Write-Host "  Detected Official Server 2022 Package Version: $pkgVer" -ForegroundColor Cyan

# Update EditionMatrix.xml in $clientOverlay to match $pkgVer
$matrixPath = Join-Path "$clientOverlay\Windows\servicing\Editions" "EditionMatrix.xml"
$matrixText = [IO.File]::ReadAllText($matrixPath)
$matrixText = $matrixText -replace 'version="10\.0\.[0-9\.]+"', "version=`"$pkgVer`""
[IO.File]::WriteAllText($matrixPath, $matrixText, [Text.Encoding]::UTF8)

$hiveSysBase = Join-Path $hivesExtractDir "SYSTEM"
$hiveSwBase  = Join-Path $hivesExtractDir "SOFTWARE"
$hiveDrvBase = Join-Path $hivesExtractDir "DRIVERS"

# Inject 71 Client Drivers & 99 Client Services into base DRIVERS and SYSTEM hives once
Write-Host "  Registering 71 Client Drivers (Touchpad I2C/GPIO, Bluetooth Audio A2DP/AVRCP/HFP, Wi-Fi, Xbox) & 99 Services into base DRIVERS & SYSTEM hives..." -ForegroundColor Cyan
reg.exe load "HKLM\OFFLINE_DRV" $hiveDrvBase | Out-Null
if ($LASTEXITCODE -ne 0) { throw "reg load OFFLINE_DRV failed" }
try {
    reg.exe import $regDriversFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg import ClientDrivers_DRIVERS.reg failed" }
} finally {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    reg.exe unload "HKLM\OFFLINE_DRV" | Out-Null
}

reg.exe load "HKLM\OFFLINE_SYS" $hiveSysBase | Out-Null
if ($LASTEXITCODE -ne 0) { throw "reg load OFFLINE_SYS failed" }
try {
    reg.exe import $regSysFile | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg import ClientDriversAndServices_SYSTEM.reg failed" }
} finally {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    reg.exe unload "HKLM\OFFLINE_SYS" | Out-Null
}

# ---------------------------------------------------------------------------
# 5. Export 4 Client Editions & Inject Per-Edition Payloads/Hives via wimlib-imagex
# ---------------------------------------------------------------------------
Write-Host "[5/6] Injecting Client payloads and exporting 4 Client editions into unified install.wim..." -ForegroundColor Yellow

function Build-EditionHives([string]$baseSwHive, [string]$baseSysHive, [string]$editionId, [string]$compEditionId, [string]$productName, [byte[]]$policyBytes, [hashtable]$regMap, [bool]$includeProExtraCbs, [string]$outHiveDir) {
    New-Item -ItemType Directory -Force -Path $outHiveDir | Out-Null
    $swFile  = Join-Path $outHiveDir "SOFTWARE"
    $sysFile = Join-Path $outHiveDir "SYSTEM"
    Copy-Item $baseSwHive  $swFile -Force
    Copy-Item $baseSysHive $sysFile -Force

    reg.exe load "HKLM\OFFLINE_SYS" $sysFile | Out-Null
    reg.exe load "HKLM\OFFLINE_SW"  $swFile  | Out-Null
    try {
        # Import Client CBS Packages & Svchost Groups into SOFTWARE hive
        reg.exe import $regSwBaseFile | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "reg import ClientCbsAndSvchost_Base_SOFTWARE.reg failed" }
        if ($includeProExtraCbs) {
            reg.exe import $regSwProExtFile | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "reg import ClientCbs_ProExtra_SOFTWARE.reg failed" }
        }

        # Remove ServerStandardEdition & ServerDatacenterEdition from CBS\Packages so Edition correlates cleanly as Client
        $cbsPkgsKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("OFFLINE_SW\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages", $true)
        if ($cbsPkgsKey) {
            foreach ($sub in $cbsPkgsKey.GetSubKeyNames()) {
                if ($sub -like "Microsoft-Windows-Server*Edition~*") {
                    $cbsPkgsKey.DeleteSubKeyTree($sub, $false)
                }
            }
            $cbsPkgsKey.Close()
        }

        $poKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("OFFLINE_SYS\ControlSet001\Control\ProductOptions", $true)
        $poKey.SetValue("ProductType", "WinNT", [Microsoft.Win32.RegistryValueKind]::String)
        $poKey.SetValue("ProductSuite", [string[]]@("Terminal Server"), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $poKey.SetValue("ProductPolicy", $policyBytes, [Microsoft.Win32.RegistryValueKind]::Binary)
        if ($regMap["OSProductPfn"]) {
            $poKey.SetValue("OSProductPfn", [string]$regMap["OSProductPfn"], [Microsoft.Win32.RegistryValueKind]::String)
        }
        if ($regMap["OSProductContentId"]) {
            $poKey.SetValue("OSProductContentId", [string]$regMap["OSProductContentId"], [Microsoft.Win32.RegistryValueKind]::String)
        }
        $poKey.Close()

        $cvKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("OFFLINE_SW\Microsoft\Windows NT\CurrentVersion", $true)
        $cvKey.SetValue("InstallationType", "Client", [Microsoft.Win32.RegistryValueKind]::String)
        $cvKey.SetValue("EditionID", $editionId, [Microsoft.Win32.RegistryValueKind]::String)
        $cvKey.SetValue("CompositionEditionID", $compEditionId, [Microsoft.Win32.RegistryValueKind]::String)
        $cvKey.SetValue("ProductName", $productName, [Microsoft.Win32.RegistryValueKind]::String)
        if ($regMap["ProductId"]) {
            $cvKey.SetValue("ProductId", [string]$regMap["ProductId"], [Microsoft.Win32.RegistryValueKind]::String)
        }
        if ($regMap["DigitalProductId"]) {
            $cvKey.SetValue("DigitalProductId", [OfficialIsoHelper]::HexToBytes($regMap["DigitalProductId"]), [Microsoft.Win32.RegistryValueKind]::Binary)
        }
        if ($regMap["DigitalProductId4"]) {
            $cvKey.SetValue("DigitalProductId4", [OfficialIsoHelper]::HexToBytes($regMap["DigitalProductId4"]), [Microsoft.Win32.RegistryValueKind]::Binary)
        }

        foreach ($subName in @("DefaultProductKey", "DefaultProductKey2")) {
            $dpk = $cvKey.CreateSubKey($subName)
            if ($regMap["ProductId"]) {
                $dpk.SetValue("ProductId", [string]$regMap["ProductId"], [Microsoft.Win32.RegistryValueKind]::String)
            }
            if ($regMap["DigitalProductId"]) {
                $dpk.SetValue("DigitalProductId", [OfficialIsoHelper]::HexToBytes($regMap["DigitalProductId"]), [Microsoft.Win32.RegistryValueKind]::Binary)
            }
            if ($regMap["DigitalProductId4"]) {
                $dpk.SetValue("DigitalProductId4", [OfficialIsoHelper]::HexToBytes($regMap["DigitalProductId4"]), [Microsoft.Win32.RegistryValueKind]::Binary)
            }
            $dpk.Close()
        }
        $cvKey.Close()

        $smKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("OFFLINE_SW\Microsoft\ServerManager")
        $smKey.SetValue("DoNotOpenServerManagerAtLogon", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $smKey.Close()
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        reg.exe unload "HKLM\OFFLINE_SYS" | Out-Null
        reg.exe unload "HKLM\OFFLINE_SW"  | Out-Null
    }
}

# Apply ClientPayload_20348.esd Image 1 + OfficialClientFiles overlay + updated DRIVERS hive + remove Server SKUs and Server Manager once on Index 1
Write-Host "  Applying base Client payload (WinSxS, DriverStore, System32, servicing\Packages, DRIVERS hive) to Index 1..." -ForegroundColor Cyan
$baseOverlayCmds = @"
add '$payloadEntSDir' '\'
add '$clientOverlay\Windows' '\Windows'
add '$hiveDrvBase' '\Windows\System32\config\DRIVERS'
delete --force --recursive '\Windows\System32\spp\tokens\skus\ServerStandard'
delete --force --recursive '\Windows\System32\spp\tokens\skus\ServerDatacenter'
delete --force '\Windows\servicing\Editions\ServerStandardEdition.xml'
delete --force '\Windows\servicing\Editions\ServerDatacenterEdition.xml'
delete --force --recursive '\Windows\System32\Tasks\Microsoft\Windows\Server Manager'
delete --force '\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Server Manager.lnk'
delete --force '\ProgramData\Microsoft\Windows\Start Menu\Programs\System Tools\Server Manager.lnk'
delete --force '\Windows\System32\ServerManager.exe'
delete --force '\Windows\System32\ServerManagerLauncher.exe'
"@
$baseOverlayCmds | & $wimlib update $newWimPath 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "wimlib base overlay update failed" }

# Instant intra-WIM exports for Indexes 2, 3, 4 (shares 100% of file streams)
& $wimlib export $newWimPath 1 $newWimPath "Windows 10 IoT Enterprise LTSC 2021" "Windows 10 IoT Enterprise LTSC 2021"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 2 failed" }

& $wimlib export $newWimPath 1 $newWimPath "Windows 10 Pro" "Windows 10 Pro"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 3 failed" }

# Apply Pro/Enterprise extra payload to Index 3 before cloning Index 4 so Index 3 & 4 share single-instance streams
Write-Host "  Applying Pro/Enterprise extra Client payload to Index 3 (and sharing with Index 4)..." -ForegroundColor Cyan
$proOverlayCmds = @"
add '$payloadProExtraDir' '\'
"@
$proOverlayCmds | & $wimlib update $newWimPath 3 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "wimlib pro extra overlay update failed" }

& $wimlib export $newWimPath 3 $newWimPath "Windows 10 Enterprise" "Windows 10 Enterprise"
if ($LASTEXITCODE -ne 0) { throw "wimlib export Index 4 failed" }

$editions = @(
    @{
        Index = 1
        EditionId = "EnterpriseS"
        CompId = "EnterpriseS"
        Name = "Windows 10 Enterprise LTSC 2021"
        DisplayName = "Windows 10 企业版 LTSC"
        BaseSw = $hiveSwBase
        Policy = [OfficialIsoHelper]::PatchProductPolicySku($ltscPolicyBytes, 0x7D)
        RegMap = $ltscReg
        ProExtraCbs = $false
    },
    @{
        Index = 2
        EditionId = "IoTEnterpriseS"
        CompId = "EnterpriseS"
        Name = "Windows 10 IoT Enterprise LTSC 2021"
        DisplayName = "Windows 10 IoT 企业版 LTSC"
        BaseSw = $hiveSwBase
        Policy = [OfficialIsoHelper]::PatchProductPolicySku($ltscPolicyBytes, 0xBD)
        RegMap = $ltscReg
        ProExtraCbs = $false
    },
    @{
        Index = 3
        EditionId = "Professional"
        CompId = "Enterprise"
        Name = "Windows 10 Pro"
        DisplayName = "Windows 10 专业版"
        BaseSw = $hiveSwBase
        Policy = [OfficialIsoHelper]::PatchProductPolicySku($proPolicyBytes, 0x30)
        RegMap = $proReg
        ProExtraCbs = $true
    },
    @{
        Index = 4
        EditionId = "Enterprise"
        CompId = "Enterprise"
        Name = "Windows 10 Enterprise"
        DisplayName = "Windows 10 企业版"
        BaseSw = $hiveSwBase
        Policy = [OfficialIsoHelper]::PatchProductPolicySku($proPolicyBytes, 0x04)
        RegMap = $proReg
        ProExtraCbs = $true
    }
)

foreach ($ed in $editions) {
    Write-Host "  Configuring Index $($ed.Index): $($ed.Name) ($($ed.EditionId))..." -ForegroundColor Cyan
    $edHiveDir = Join-Path $tmpDir "hives_$($ed.EditionId)"
    Build-EditionHives $ed.BaseSw $hiveSysBase $ed.EditionId $ed.CompId $ed.Name $ed.Policy $ed.RegMap $ed.ProExtraCbs $edHiveDir

    $updateCmds = @"
add '$edHiveDir\SYSTEM' '\Windows\System32\config\SYSTEM'
add '$edHiveDir\SOFTWARE' '\Windows\System32\config\SOFTWARE'
"@
    $updateCmds | & $wimlib update $newWimPath $ed.Index | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "wimlib update failed for Index $($ed.Index)" }

    & $wimlib info $newWimPath $ed.Index $ed.Name $ed.Name `
        "--image-property=EDITIONID=$($ed.EditionId)" `
        "--image-property=INSTALLATIONTYPE=Client" `
        "--image-property=PRODUCTTYPE=WinNT" `
        "--image-property=PRODUCTSUITE=Terminal Server" `
        "--image-property=DISPLAYNAME=$($ed.DisplayName)" `
        "--image-property=DISPLAYDESCRIPTION=$($ed.DisplayName)" `
        "--image-property=FLAGS=$($ed.EditionId)"
    if ($LASTEXITCODE -ne 0) { throw "wimlib info failed for Index $($ed.Index)" }
}

& $wimlib optimize $newWimPath

# ---------------------------------------------------------------------------
# 6. Replace install.wim, Write ei.cfg, and Build Bootable Client ISO
# ---------------------------------------------------------------------------
Write-Host "[6/6] Building final bootable Windows 20348 Client ISO..." -ForegroundColor Yellow

Move-Item -Path $newWimPath -Destination $origWim -Force

$eiCfgContent = @"
[Channel]
_Default
[VL]
0
"@
[IO.File]::WriteAllText((Join-Path $isoExtractDir "sources\ei.cfg"), $eiCfgContent, [Text.Encoding]::ASCII)

$buildRev = ($pkgVer -split '\.')[-1]
$outIsoName = "Win10_20348.${buildRev}_Client_LTSC_Pro_Ent_x64_zh-cn.iso"
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
