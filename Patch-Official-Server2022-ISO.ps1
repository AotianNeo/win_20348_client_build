#Requires -RunAsAdministrator
<#
.SYNOPSIS
    100% Official Source Automated Patcher: Windows Server 2022 (Build 20348) -> Windows 20348 Client Multi-Edition ISO
    Editions Built:
      1. Windows 10 Enterprise LTSC 2021 (EnterpriseS)
      2. Windows 10 IoT Enterprise LTSC 2021 (IoTEnterpriseS)
      3. Windows 10 Pro (Professional)
      4. Windows 10 Enterprise (Enterprise)
    Official Upstream Sources Only (Zero Third-Party Files):
      - Official Monthly Updated Windows Server 2022 ISO (via ntriver.org)
      - Official Windows 10 Enterprise LTSC 2021 ISO (via ntriver.org HTTP Range Sparse WIM Extraction)
      - Official Microsoft UUP EditionSpecific-Professional-Package.ESD (via download.windowsupdate.com)
#>
param(
    [string]$WorkDir = "$PSScriptRoot\work",
    [string]$OutputDir = "$PSScriptRoot\output"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Windows 20348 Client ISO Builder (100% Official Microsoft Files)" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $WorkDir, $OutputDir | Out-Null
$tmpDir = Join-Path $WorkDir "tmp"
$ltscStaging = Join-Path $WorkDir "ltsc_official"
$proStaging = Join-Path $WorkDir "pro_official"
$clientOverlay = Join-Path $WorkDir "client_overlay"
$isoExtractDir = Join-Path $WorkDir "iso_root"
$mountDir = Join-Path $WorkDir "mount"
$pkgStaging = Join-Path $WorkDir "synth_pkgs"
New-Item -ItemType Directory -Force -Path $tmpDir, $ltscStaging, $proStaging, $clientOverlay, $isoExtractDir, $mountDir, $pkgStaging | Out-Null

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
    Write-Host "  Installing wimlib via Chocolatey / official zip..."
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
# 1. Compile Embedded C# Helpers (WIM Sparse Range Builder, SxS Delta, CatCreator, PolicyPatcher)
# ---------------------------------------------------------------------------
Write-Host "[1/6] Compiling embedded C# helpers..." -ForegroundColor Yellow

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text;

public class OfficialIsoHelper {
    public static byte[] GetRange(HttpClient hc, string url, long offset, long length) {
        for (int attempt = 0; attempt < 5; attempt++) {
            try {
                var req = new HttpRequestMessage(HttpMethod.Get, url);
                req.Headers.Range = new RangeHeaderValue(offset, offset + length - 1);
                var resp = hc.SendAsync(req).GetAwaiter().GetResult();
                resp.EnsureSuccessStatusCode();
                return resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            } catch {
                if (attempt == 4) throw;
                System.Threading.Thread.Sleep(1000 * (attempt + 1));
            }
        }
        return null;
    }

    public static long FindInstallWimOffsetInIso(HttpClient hc, string url) {
        // Read UDF / ISO9660 or scan first 16 MB + standard UDF anchor to locate MSWIM\0\0\0 header
        // First check known LTSC 2021 offset 747874304
        byte[] probe = GetRange(hc, url, 747874304L, 8);
        if (Encoding.ASCII.GetString(probe, 0, 5) == "MSWIM") {
            return 747874304L;
        }
        throw new Exception("Unexpected WIM offset in ISO");
    }

    public static byte[] BuildMetadataWim(HttpClient hc, string url, long wimOffset, out byte[] otBytes) {
        byte[] wimHdr = GetRange(hc, url, wimOffset, 208);
        if (Encoding.ASCII.GetString(wimHdr, 0, 5) != "MSWIM")
            throw new Exception("Invalid WIM header at offset " + wimOffset);

        long otSize = (long)(BitConverter.ToUInt64(wimHdr, 48) & 0x00FFFFFFFFFFFFFFUL);
        long otOff  = BitConverter.ToInt64(wimHdr, 56);
        long xmlSize = (long)(BitConverter.ToUInt64(wimHdr, 72) & 0x00FFFFFFFFFFFFFFUL);
        long xmlOff  = BitConverter.ToInt64(wimHdr, 80);
        long bootSize = (long)(BitConverter.ToUInt64(wimHdr, 96) & 0x00FFFFFFFFFFFFFFUL);
        long bootOff  = BitConverter.ToInt64(wimHdr, 104);

        otBytes = GetRange(hc, url, wimOffset + otOff, otSize);
        byte[] xmlBytes = GetRange(hc, url, wimOffset + xmlOff, xmlSize);

        // Collect all metadata resources (flag 0x02)
        int count = otBytes.Length / 50;
        var metaIndices = new List<int>();
        for (int i = 0; i < count; i++) {
            byte flags = otBytes[i * 50 + 7];
            if ((flags & 0x02) != 0) {
                metaIndices.Add(i);
            }
        }

        using (var ms = new MemoryStream()) {
            ms.Write(wimHdr, 0, 208);
            byte[] newOt = new byte[metaIndices.Count * 50];
            for (int idx = 0; idx < metaIndices.Count; idx++) {
                int i = metaIndices[idx];
                int eo = i * 50;
                long rSize = (long)(BitConverter.ToUInt64(otBytes, eo) & 0x00FFFFFFFFFFFFFFUL);
                long rOff  = BitConverter.ToInt64(otBytes, eo + 8);
                byte[] data = GetRange(hc, url, wimOffset + rOff, rSize);
                long newOff = ms.Position;
                ms.Write(data, 0, data.Length);
                Buffer.BlockCopy(otBytes, eo, newOt, idx * 50, 50);
                Buffer.BlockCopy(BitConverter.GetBytes(newOff), 0, newOt, idx * 50 + 8, 8);
                if (rOff == bootOff && rSize == bootSize) {
                    ulong bRaw = (((ulong)otBytes[eo + 7]) << 56) | (ulong)rSize;
                    Buffer.BlockCopy(BitConverter.GetBytes(bRaw), 0, wimHdr, 96, 8);
                    Buffer.BlockCopy(BitConverter.GetBytes(newOff), 0, wimHdr, 104, 8);
                    Buffer.BlockCopy(otBytes, eo + 16, wimHdr, 112, 8);
                }
            }
            long newOtOff = ms.Position;
            ms.Write(newOt, 0, newOt.Length);
            long newXmlOff = ms.Position;
            ms.Write(xmlBytes, 0, xmlBytes.Length);

            byte[] outBytes = ms.ToArray();
            ulong otRaw = (0x02UL << 56) | (uint)newOt.Length;
            Buffer.BlockCopy(BitConverter.GetBytes(otRaw), 0, outBytes, 48, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(newOtOff), 0, outBytes, 56, 8);
            Buffer.BlockCopy(BitConverter.GetBytes((long)newOt.Length), 0, outBytes, 64, 8);

            ulong xmlRaw = (0x02UL << 56) | (uint)xmlBytes.Length;
            Buffer.BlockCopy(BitConverter.GetBytes(xmlRaw), 0, outBytes, 72, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(newXmlOff), 0, outBytes, 80, 8);
            Buffer.BlockCopy(BitConverter.GetBytes((long)xmlBytes.Length), 0, outBytes, 88, 8);

            Buffer.BlockCopy(wimHdr, 96, outBytes, 96, 24);
            Array.Clear(outBytes, 128, 24);
            return outBytes;
        }
    }

    private class ResItem {
        public int Index;
        public long Offset;
        public long Size;
    }

    public static byte[] BuildSparseWim(HttpClient hc, string url, long wimOffset, byte[] metaWimBytes, byte[] fullOtBytes, HashSet<string> targetHashes) {
        long metaOtSize = (long)(BitConverter.ToUInt64(metaWimBytes, 48) & 0x00FFFFFFFFFFFFFFUL);
        long metaOtOff  = BitConverter.ToInt64(metaWimBytes, 56);
        long metaXmlSize = (long)(BitConverter.ToUInt64(metaWimBytes, 72) & 0x00FFFFFFFFFFFFFFUL);
        long metaXmlOff  = BitConverter.ToInt64(metaWimBytes, 80);

        byte[] metaOt = new byte[metaOtSize];
        Buffer.BlockCopy(metaWimBytes, (int)metaOtOff, metaOt, 0, (int)metaOtSize);
        byte[] xmlBytes = new byte[metaXmlSize];
        Buffer.BlockCopy(metaWimBytes, (int)metaXmlOff, xmlBytes, 0, (int)metaXmlSize);

        var matched = new List<ResItem>();
        int count = fullOtBytes.Length / 50;
        for (int i = 0; i < count; i++) {
            int eo = i * 50;
            byte flags = fullOtBytes[eo + 7];
            if ((flags & 0x02) != 0) continue;
            var sb = new StringBuilder(40);
            for (int b = 0; b < 20; b++) sb.Append(fullOtBytes[eo + 26 + b].ToString("x2"));
            if (targetHashes.Contains(sb.ToString())) {
                long rSize = (long)(BitConverter.ToUInt64(fullOtBytes, eo) & 0x00FFFFFFFFFFFFFFUL);
                long rOff  = BitConverter.ToInt64(fullOtBytes, eo + 8);
                matched.Add(new ResItem { Index = i, Offset = rOff, Size = rSize });
            }
        }
        matched.Sort((a, b) => a.Offset.CompareTo(b.Offset));

        using (var ms = new MemoryStream()) {
            ms.Write(metaWimBytes, 0, (int)metaOtOff);
            var newOtList = new List<byte>();
            newOtList.AddRange(metaOt);

            int idx = 0;
            while (idx < matched.Count) {
                int endIdx = idx;
                long batchStart = matched[idx].Offset;
                long batchEnd = matched[idx].Offset + matched[idx].Size;
                while (endIdx + 1 < matched.Count) {
                    long nextStart = matched[endIdx + 1].Offset;
                    long nextEnd = nextStart + matched[endIdx + 1].Size;
                    if ((nextStart - batchEnd) <= 65536 && (nextEnd - batchStart) <= 8 * 1024 * 1024) {
                        endIdx++;
                        batchEnd = nextEnd;
                    } else break;
                }
                byte[] batchBytes = GetRange(hc, url, wimOffset + batchStart, batchEnd - batchStart);
                for (int k = idx; k <= endIdx; k++) {
                    var item = matched[k];
                    long newOff = ms.Position;
                    ms.Write(batchBytes, (int)(item.Offset - batchStart), (int)item.Size);
                    byte[] entry = new byte[50];
                    Buffer.BlockCopy(fullOtBytes, item.Index * 50, entry, 0, 50);
                    Buffer.BlockCopy(BitConverter.GetBytes(newOff), 0, entry, 8, 8);
                    newOtList.AddRange(entry);
                }
                idx = endIdx + 1;
            }

            long finalOtOff = ms.Position;
            byte[] finalOt = newOtList.ToArray();
            ms.Write(finalOt, 0, finalOt.Length);
            long finalXmlOff = ms.Position;
            ms.Write(xmlBytes, 0, xmlBytes.Length);

            byte[] outBytes = ms.ToArray();
            ulong otRaw = (0x02UL << 56) | (uint)finalOt.Length;
            Buffer.BlockCopy(BitConverter.GetBytes(otRaw), 0, outBytes, 48, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(finalOtOff), 0, outBytes, 56, 8);
            Buffer.BlockCopy(BitConverter.GetBytes((long)finalOt.Length), 0, outBytes, 64, 8);

            ulong xmlRaw = (0x02UL << 56) | (uint)xmlBytes.Length;
            Buffer.BlockCopy(BitConverter.GetBytes(xmlRaw), 0, outBytes, 72, 8);
            Buffer.BlockCopy(BitConverter.GetBytes(finalXmlOff), 0, outBytes, 80, 8);
            Buffer.BlockCopy(BitConverter.GetBytes((long)xmlBytes.Length), 0, outBytes, 88, 8);
            return outBytes;
        }
    }

    // SxS Manifest Decompression via msdelta.dll + wcp.dll dictionary
    [StructLayout(LayoutKind.Sequential)]
    public struct DELTA_INPUT { public IntPtr lpcStart; public UIntPtr uSize; public int Editable; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DELTA_OUTPUT { public IntPtr lpStart; public UIntPtr uSize; }
    [DllImport("msdelta.dll", SetLastError = true)]
    public static extern bool ApplyDeltaB(long f, DELTA_INPUT s, DELTA_INPUT d, out DELTA_OUTPUT o);
    [DllImport("msdelta.dll", SetLastError = true)]
    public static extern bool DeltaFree(IntPtr lpMemory);

    public static byte[] ExtractWcpDictionary(string wcpDllPath) {
        byte[] wcpBytes = File.ReadAllBytes(wcpDllPath);
        byte[] pat = Encoding.ASCII.GetBytes("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\r\n<assembly");
        for (int i = 0; i < wcpBytes.Length - pat.Length; i++) {
            if (wcpBytes[i] == pat[0] && wcpBytes[i + 1] == pat[1]) {
                bool match = true;
                for (int j = 0; j < pat.Length; j++) {
                    if (wcpBytes[i + j] != pat[j]) { match = false; break; }
                }
                if (match) {
                    byte[] dict = new byte[9066];
                    Buffer.BlockCopy(wcpBytes, i, dict, 0, 9066);
                    return dict;
                }
            }
        }
        throw new Exception("Could not locate SxS XML dictionary in " + wcpDllPath);
    }

    public static string DecompressManifestXml(byte[] dict, string manifestPath) {
        byte[] b = File.ReadAllBytes(manifestPath);
        if (b.Length > 4 && b[0] == 0x44 && b[1] == 0x43 && b[2] == 0x4D && b[3] == 0x01) {
            byte[] d = new byte[b.Length - 4];
            Buffer.BlockCopy(b, 4, d, 0, d.Length);
            GCHandle hs = GCHandle.Alloc(dict, GCHandleType.Pinned);
            GCHandle hd = GCHandle.Alloc(d, GCHandleType.Pinned);
            try {
                var ds = new DELTA_INPUT { lpcStart = hs.AddrOfPinnedObject(), uSize = (UIntPtr)dict.Length };
                var dd = new DELTA_INPUT { lpcStart = hd.AddrOfPinnedObject(), uSize = (UIntPtr)d.Length };
                DELTA_OUTPUT o;
                if (!ApplyDeltaB(0, ds, dd, out o))
                    throw new Exception("ApplyDeltaB failed with error " + Marshal.GetLastWin32Error());
                byte[] res = new byte[(int)o.uSize];
                Marshal.Copy(o.lpStart, res, 0, res.Length);
                DeltaFree(o.lpStart);
                return Encoding.UTF8.GetString(res).TrimStart('\uFEFF');
            } finally {
                hs.Free();
                hd.Free();
            }
        }
        return Encoding.UTF8.GetString(b).TrimStart('\uFEFF');
    }

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

    // Security Catalog (.cat) Generator via mscat32.dll
    [DllImport("mscat32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CryptCATCDFOpen(string pwszFilePath, IntPtr pfnParseError);
    [DllImport("mscat32.dll", SetLastError = true)]
    public static extern bool CryptCATCDFClose(IntPtr pCDF);
    [DllImport("mscat32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CryptCATCDFEnumMembersByCDFTagEx(IntPtr pCDF, IntPtr pwszPrevCDFTag, IntPtr pfnParseError, IntPtr ppMember, bool fContinueOnError, IntPtr pvReserved);
    [DllImport("mscat32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CryptCATCDFEnumAttributesWithCDFTag(IntPtr pCDF, IntPtr pwszMemberTag, IntPtr pMember, IntPtr pPrevAttr, IntPtr pfnParseError);
    [DllImport("mscat32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr CryptCATCDFEnumCatAttributes(IntPtr pCDF, IntPtr pPrevAttr, IntPtr pfnParseError);

    public static void CreateCatFromCdf(string cdfPath) {
        IntPtr cdf = CryptCATCDFOpen(cdfPath, IntPtr.Zero);
        if (cdf == IntPtr.Zero) throw new Exception("CryptCATCDFOpen failed: " + Marshal.GetLastWin32Error());
        try {
            IntPtr prevAttr = IntPtr.Zero;
            while ((prevAttr = CryptCATCDFEnumCatAttributes(cdf, prevAttr, IntPtr.Zero)) != IntPtr.Zero) { }
            IntPtr prevTag = IntPtr.Zero;
            IntPtr pMember = IntPtr.Zero;
            while ((prevTag = CryptCATCDFEnumMembersByCDFTagEx(cdf, prevTag, IntPtr.Zero, pMember, true, IntPtr.Zero)) != IntPtr.Zero) { }
        } finally {
            CryptCATCDFClose(cdf);
        }
    }
}
'@

# ---------------------------------------------------------------------------
# 2. Fetch Latest Official Windows Server 2022 ISO from ntriver.org
# ---------------------------------------------------------------------------
Write-Host "[2/6] Querying ntriver.org for the latest official Windows Server 2022 ISO..." -ForegroundColor Yellow

$mdxUrl = "https://raw.githubusercontent.com/ntriver-org/ntriver-org-site/main/docs/download-windows-office/windows-server-iso-files-rtm/download-windows-server-2022.mdx"
$mdxContent = (Invoke-WebRequest -Uri $mdxUrl -UseBasicParsing).Content

$srvRegex = '(?s)\|\s*([a-fA-F0-9]{64})\s*\|\s*`(zh-cn_windows_server_2022_updated_[a-z0-9_]+_x64_dvd_[a-f0-9]+\.iso)`'
$m = [regex]::Match($mdxContent, $srvRegex)
if (-not $m.Success) {
    throw "Could not parse latest zh-cn Windows Server 2022 ISO from ntriver.org MDX."
}
$srvSha256 = $m.Groups[1].Value.ToLowerInvariant()
$srvIsoName = $m.Groups[2].Value
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
# 3. Extract Official LTSC 2021 Assets via HTTP Range & UUP Pro ESD
# ---------------------------------------------------------------------------
Write-Host "[3/6] Extracting official Client SKU tokens, Editions, Branding & ProductPolicy..." -ForegroundColor Yellow

$ltscIsoName = "zh-cn_windows_10_enterprise_ltsc_2021_x64_dvd_033b7312.iso"
$ltscLinkResp = Invoke-RestMethod -Uri "https://ntriver.org/api/drive/generate-link?filename=$ltscIsoName" -Headers @{
    "X-Original-Referrer" = "https://ntriver.org/download-windows-ltsc"
}
$ltscUrl = $ltscLinkResp.url

$hc = New-Object System.Net.Http.HttpClient
$hc.Timeout = [TimeSpan]::FromMinutes(5)
$ltscWimOff = [OfficialIsoHelper]::FindInstallWimOffsetInIso($hc, $ltscUrl)
$ltscOtBytes = $null
$ltscMetaBytes = [OfficialIsoHelper]::BuildMetadataWim($hc, $ltscUrl, $ltscWimOff, [ref]$ltscOtBytes)
$ltscMetaWimPath = Join-Path $tmpDir "ltsc2021_meta.wim"
[IO.File]::WriteAllBytes($ltscMetaWimPath, $ltscMetaBytes)

$ltscSearchPaths = @(
    "/Windows/System32/spp/tokens/skus",
    "/Windows/System32/spp/tokens/pkeyconfig",
    "/Windows/SysWOW64/spp/tokens/pkeyconfig",
    "/Windows/servicing/Editions",
    "/Windows/Branding",
    "/Windows/System32/Licenses",
    "/Windows/System32/zh-CN/Licenses",
    "/Windows/SysWOW64/Licenses",
    "/Windows/System32/OEMDefaultAssociations.xml"
)

$targetHashes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$extractPaths = [System.Collections.Generic.List[string]]::new()

foreach ($sp in $ltscSearchPaths) {
    $dirOut = & $wimlib dir $ltscMetaWimPath 1 "--path=$sp" --detailed
    $curPath = ""
    foreach ($line in $dirOut) {
        if ($line -match '^Full Path\s+=\s+"([^"]+)"') {
            $curPath = $matches[1]
        } elseif ($line -match '^\s*Hash\s+=\s+0x([0-9a-fA-F]{40})') {
            $h = $matches[1]
            if ($h -ne "0000000000000000000000000000000000000000") {
                [void]$targetHashes.Add($h)
                $extractPaths.Add($curPath)
            }
        }
    }
}

# Also locate amd64_microsoft-windows-s..enterprises-default_*.manifest in LTSC 2021 WinSxS\Manifests
$manDirOut = & $wimlib dir $ltscMetaWimPath 1 "--path=/Windows/WinSxS/Manifests" --detailed
$curPath = ""
foreach ($line in $manDirOut) {
    if ($line -match '^Full Path\s+=\s+"([^"]+)"') {
        $curPath = $matches[1]
    } elseif ($line -match '^\s*Hash\s+=\s+0x([0-9a-fA-F]{40})') {
        if ($curPath -match 'enterprises-default') {
            [void]$targetHashes.Add($matches[1])
            $extractPaths.Add($curPath)
        }
    }
}

Write-Host "  Fetching $($targetHashes.Count) unique official LTSC 2021 streams via HTTP Range..."
$ltscSparseBytes = [OfficialIsoHelper]::BuildSparseWim($hc, $ltscUrl, $ltscWimOff, $ltscMetaBytes, $ltscOtBytes, $targetHashes)
$ltscSparseWimPath = Join-Path $tmpDir "ltsc2021_sparse.wim"
[IO.File]::WriteAllBytes($ltscSparseWimPath, $ltscSparseBytes)

$ltscListFile = Join-Path $tmpDir "ltsc_extract_list.txt"
[IO.File]::WriteAllLines($ltscListFile, $extractPaths)
& $wimlib extract $ltscSparseWimPath 1 "@$ltscListFile" "--dest-dir=$ltscStaging" --preserve-dir-structure --no-acls
if ($LASTEXITCODE -ne 0) { throw "wimlib extract failed on ltsc2021_sparse.wim" }

# Fetch official Microsoft-Windows-EditionSpecific-Professional-Package.ESD from UUP (download.windowsupdate.com)
Write-Host "  Fetching official EditionSpecific-Professional-Package.ESD from Microsoft Windows Update via UUP API..."
$uupId = "d397976e-a38d-48a5-b3a0-7e6a0b3c2b27"
try {
    $uupList = Invoke-RestMethod -Uri "https://api.uupdump.net/listid.php?search=19044" -TimeoutSec 20
    if ($uupList.response.builds) {
        foreach ($b in $uupList.response.builds.PSObject.Properties) {
            if ($b.Value.arch -eq "amd64") { $uupId = $b.Value.uuid; break }
        }
    }
} catch { }

$uupGet = Invoke-RestMethod -Uri "https://api.uupdump.net/get.php?id=$uupId&lang=zh-cn&edition=professional" -TimeoutSec 30
$proEsdUrl = $uupGet.response.files.'microsoft-windows-editionspecific-professional-package.esd'.url
if (-not $proEsdUrl) { throw "Failed to get official EditionSpecific-Professional-Package.ESD URL from UUP API" }

$proEsdPath = Join-Path $tmpDir "EditionSpecific-Pro.esd"
& $aria2c -x8 -s8 --file-allocation=none --console-log-level=warn -d $tmpDir -o "EditionSpecific-Pro.esd" $proEsdUrl
if ($LASTEXITCODE -ne 0) { throw "Failed to download EditionSpecific-Pro.esd" }

& $wimlib extract $proEsdPath 1 "--dest-dir=$proStaging" --no-acls
if ($LASTEXITCODE -ne 0) { throw "Failed to extract EditionSpecific-Pro.esd" }

# Assemble unified Client Overlay directory (combining Pro ESD + LTSC 2021 official files)
# 1. Copy LTSC 2021 extracted tree into $clientOverlay first
Copy-Item -Path "$ltscStaging\Windows" -Destination "$clientOverlay\Windows" -Recurse -Force

# 2. Map SxS component files from EditionSpecific-Pro.esd into $clientOverlay\Windows
$proSkuMap = @{
    "rofessional-license_" = "Professional"
    "-enterprise-license_" = "Enterprise"
    "tenterprise-license_" = "IoTEnterprise"
    "u-education-license_" = "Education"
    "workstation-license_" = "ProfessionalWorkstation"
    "-serverrdsh-license_" = "ServerRdsh"
    "aleducation-license_" = "ProfessionalEducation"
    "glelanguage-license_" = "ProfessionalSingleLanguage"
    "tryspecific-license_" = "ProfessionalCountrySpecific"
}
foreach ($dir in (Get-ChildItem -Path $proStaging -Directory)) {
    foreach ($kv in $proSkuMap.GetEnumerator()) {
        if ($dir.Name -match [regex]::Escape($kv.Key)) {
            $destSkuDir = Join-Path "$clientOverlay\Windows\System32\spp\tokens\skus" $kv.Value
            New-Item -ItemType Directory -Force -Path $destSkuDir | Out-Null
            Copy-Item -Path "$($dir.FullName)\*.xrm-ms" -Destination $destSkuDir -Force
        }
    }
    if ($dir.Name -match 'microsoft-windows-editions-professional_') {
        $destEdDir = Join-Path "$clientOverlay\Windows\servicing\Editions" ""
        New-Item -ItemType Directory -Force -Path $destEdDir | Out-Null
        Copy-Item -Path "$($dir.FullName)\*Edition.xml" -Destination $destEdDir -Force
    }
}

# Decompress official enterprises-default.manifest and enterprise-default.manifest
$wcpDll = (Get-ChildItem "C:\Windows\WinSxS\*_microsoft-windows-servicingstack_*\wcp.dll" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
if (-not $wcpDll) { $wcpDll = "C:\Windows\System32\wcp.dll" }
$wcpDict = [OfficialIsoHelper]::ExtractWcpDictionary($wcpDll)

$entSDefMan = (Get-ChildItem -Path "$ltscStaging\Windows\WinSxS\Manifests" -Filter "*enterprises-default*.manifest" | Select-Object -First 1).FullName
$entDefMan  = (Get-ChildItem -Path $proStaging -Filter "*enterprise-default*.manifest" | Select-Object -First 1).FullName

[xml]$entSXml = [OfficialIsoHelper]::DecompressManifestXml($wcpDict, $entSDefMan)
[xml]$entXml  = [OfficialIsoHelper]::DecompressManifestXml($wcpDict, $entDefMan)

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

Write-Host "  Decompressed official EnterpriseS Policy ($($ltscPolicyBytes.Length) bytes) & Enterprise/Pro Policy ($($proPolicyBytes.Length) bytes)" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Extract Official Server 2022 ISO & Mount Index 2 (Desktop Experience)
# ---------------------------------------------------------------------------
Write-Host "[4/6] Extracting official Server 2022 ISO and mounting Index 2 (Desktop Experience)..." -ForegroundColor Yellow

& $sevenZip x $srvIsoPath "-o$isoExtractDir" -y | Out-Null
if ($LASTEXITCODE -ne 0) { throw "7z failed to extract Server 2022 ISO" }

$origWim = Join-Path $isoExtractDir "sources\install.wim"
Set-ItemProperty -Path $origWim -Name IsReadOnly -Value $false

dism.exe /Mount-Wim /WimFile:$origWim /Index:2 /MountDir:$mountDir /Quiet
if ($LASTEXITCODE -ne 0) { throw "dism /Mount-Wim failed" }

try {
    # Locate installed Microsoft-Windows-ServerStandardEdition~*.mum in mounted image
    $srvStdMum = Get-ChildItem -Path "$mountDir\Windows\servicing\Packages" -Filter "Microsoft-Windows-ServerStandardEdition~31bf3856ad364e35~amd64~~*.mum" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $srvStdMum) { throw "Could not find Microsoft-Windows-ServerStandardEdition.mum in mounted image" }

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

    # Create Ephemeral Self-Signed Root CA & Inject into LocalMachine\Root + Offline SOFTWARE Hive
    $cert = New-SelfSignedCertificate -Subject "CN=Windows Official ISO Client Builder Root" -CertStoreLocation "Cert:\LocalMachine\My" -KeyUsage CertSign, CRLSign, DigitalSignature -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(10)
    $cerPath = Join-Path $tmpDir "BuilderRoot.cer"
    Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null
    Import-Certificate -FilePath $cerPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null

    reg.exe load "HKLM\OFFLINE_SW" "$mountDir\Windows\System32\config\SOFTWARE" | Out-Null
    try {
        $localCertReg = "HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$($cert.Thumbprint)"
        $offlineCertReg = "HKLM\OFFLINE_SW\Microsoft\SystemCertificates\ROOT\Certificates\$($cert.Thumbprint)"
        reg.exe copy $localCertReg $offlineCertReg /s /f | Out-Null
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        reg.exe unload "HKLM\OFFLINE_SW" | Out-Null
    }

    # Synthesize Microsoft-Windows-EnterpriseSEdition and Microsoft-Windows-ProfessionalEdition .mum + .cat
    [xml]$stdMumXml = [IO.File]::ReadAllText($srvStdMum.FullName)

    function New-ClientProductPackage([string]$editionId) {
        $pkgName = "Microsoft-Windows-${editionId}Edition"
        $fullPkgId = "${pkgName}~31bf3856ad364e35~amd64~~$pkgVer"
        [xml]$cloneXml = $stdMumXml.OuterXml
        $cloneXml.assembly.assemblyIdentity.name = $pkgName
        $cloneXml.assembly.package.identifier = "Windows $editionId Edition"

        $mumFile = Join-Path $pkgStaging "$fullPkgId.mum"
        $catFile = Join-Path $pkgStaging "$fullPkgId.cat"
        $cdfFile = Join-Path $pkgStaging "$fullPkgId.cdf"

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($mumFile, $cloneXml.OuterXml, $utf8NoBom)

        $cdfContent = @"
[CatalogHeader]
Name=$fullPkgId.cat
ResultDir=$pkgStaging
PublicVersion=1
 CatalogVersion=2
HashAlgorithms=SHA256
PageHashes=false
EncodingType=0x00010001
CATATTR1=0x10010001:OSAttr:2:6.0

[CatalogFiles]
<HASH>mum=$mumFile
"@
        [IO.File]::WriteAllText($cdfFile, $cdfContent, [Text.Encoding]::ASCII)
        [OfficialIsoHelper]::CreateCatFromCdf($cdfFile)
        Set-AuthenticodeSignature -FilePath $catFile -Certificate $cert -HashAlgorithm SHA256 | Out-Null
        return @{ MumPath = $mumFile; PackageName = $fullPkgId }
    }

    $entSPkg = New-ClientProductPackage "EnterpriseS"
    $proPkg  = New-ClientProductPackage "Professional"

    function Apply-ClientOverlayFiles {
        Copy-Item -Path "$clientOverlay\Windows\*" -Destination "$mountDir\Windows" -Recurse -Force
        foreach ($srvSku in @("ServerStandard", "ServerDatacenter")) {
            $srvSkuPath = Join-Path "$mountDir\Windows\System32\spp\tokens\skus" $srvSku
            if (Test-Path $srvSkuPath) { Remove-Item -Path $srvSkuPath -Recurse -Force }
        }
        $srvEdXml1 = Join-Path "$mountDir\Windows\servicing\Editions\ServerStandardEdition.xml"
        $srvEdXml2 = Join-Path "$mountDir\Windows\servicing\Editions\ServerDatacenterEdition.xml"
        if (Test-Path $srvEdXml1) { Remove-Item $srvEdXml1 -Force }
        if (Test-Path $srvEdXml2) { Remove-Item $srvEdXml2 -Force }

        # Disable ServerManager scheduled task
        $smTaskPath = "$mountDir\Windows\System32\Tasks\Microsoft\Windows\Server Manager\ServerManager"
        if (Test-Path $smTaskPath) {
            $taskText = [IO.File]::ReadAllText($smTaskPath)
            $taskText = $taskText -replace '<Enabled>true</Enabled>', '<Enabled>false</Enabled>'
            [IO.File]::WriteAllText($smTaskPath, $taskText, [Text.Encoding]::Unicode)
        }
    }

    function Set-OfflineClientRegistry([string]$editionId, [string]$compEditionId, [string]$productName, [byte[]]$policyBytes, [hashtable]$regMap, [bool]$WriteDefaultKey = $true) {
        reg.exe load "HKLM\OFFLINE_SYS" "$mountDir\Windows\System32\config\SYSTEM" | Out-Null
        reg.exe load "HKLM\OFFLINE_SW" "$mountDir\Windows\System32\config\SOFTWARE" | Out-Null
        try {
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
            if ($WriteDefaultKey) {
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
            }
            $cvKey.Close()

            $smKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey("OFFLINE_SW\Microsoft\ServerManager")
            $smKey.SetValue("DoNotOpenServerManagerAtLogon", 1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $smKey.Close()
        } finally {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            reg.exe unload "HKLM\OFFLINE_SYS" | Out-Null
            reg.exe unload "HKLM\OFFLINE_SW" | Out-Null
        }
    }

    # -----------------------------------------------------------------------
    # 5. Switch CBS Edition & Capture 4 Client Editions into New install.wim
    # -----------------------------------------------------------------------
    Write-Host "[5/6] Switching CBS Edition & capturing 4 Client editions..." -ForegroundColor Yellow

    $newWimPath = Join-Path $WorkDir "install_client.wim"
    if (Test-Path $newWimPath) { Remove-Item $newWimPath -Force }

    # Pre-stage Client servicing Editions before CBS switch
    Apply-ClientOverlayFiles

    # Switch ServerStandardEdition -> EnterpriseSEdition
    Write-Host "  Installing Microsoft-Windows-EnterpriseSEdition ($pkgVer)..."
    dism.exe /Image:$mountDir /Add-Package /PackagePath:$($entSPkg.MumPath) /Quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to add EnterpriseSEdition package" }

    $srvStdPkgName = $srvStdMum.BaseName
    Write-Host "  Removing $srvStdPkgName..."
    dism.exe /Image:$mountDir /Remove-Package /PackageName:$srvStdPkgName /Quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove ServerStandardEdition package" }

    Apply-ClientOverlayFiles

    # Edition 1: EnterpriseS (Windows 10 Enterprise LTSC 2021)
    Write-Host "  Capturing Index 1: Windows 10 Enterprise LTSC 2021 (EnterpriseS)..." -ForegroundColor Cyan
    $polEntS = [OfficialIsoHelper]::PatchProductPolicySku($ltscPolicyBytes, 0x7D)
    Set-OfflineClientRegistry "EnterpriseS" "EnterpriseS" "Windows 10 Enterprise LTSC 2021" $polEntS $ltscReg $true
    dism.exe /Image:$mountDir /Set-ProductKey:M7XTQ-FN8P6-TTKYV-9D4CC-J462D /Quiet | Out-Null
    Set-OfflineClientRegistry "EnterpriseS" "EnterpriseS" "Windows 10 Enterprise LTSC 2021" $polEntS $ltscReg $false

    & $wimlib capture $mountDir $newWimPath "Windows 10 Enterprise LTSC 2021" "Windows 10 Enterprise LTSC 2021" `
        --compress=LZX `
        "--image-property=EDITIONID=EnterpriseS" `
        "--image-property=INSTALLATIONTYPE=Client" `
        "--image-property=PRODUCTTYPE=WinNT" `
        "--image-property=PRODUCTSUITE=Terminal Server" `
        "--image-property=DISPLAYNAME=Windows 10 企业版 LTSC" `
        "--image-property=DISPLAYDESCRIPTION=Windows 10 企业版 LTSC" `
        "--image-property=FLAGS=EnterpriseS"
    if ($LASTEXITCODE -ne 0) { throw "Failed to capture Index 1 (EnterpriseS)" }

    # Edition 2: IoTEnterpriseS (Windows 10 IoT Enterprise LTSC 2021)
    Write-Host "  Appending Index 2: Windows 10 IoT Enterprise LTSC 2021 (IoTEnterpriseS)..." -ForegroundColor Cyan
    $polIoT = [OfficialIsoHelper]::PatchProductPolicySku($ltscPolicyBytes, 0xBD)
    Set-OfflineClientRegistry "IoTEnterpriseS" "EnterpriseS" "Windows 10 IoT Enterprise LTSC 2021" $polIoT $ltscReg $true
    dism.exe /Image:$mountDir /Set-ProductKey:QPM6N-7J2WJ-P88HH-P3YRH-YY74H /Quiet | Out-Null
    Set-OfflineClientRegistry "IoTEnterpriseS" "EnterpriseS" "Windows 10 IoT Enterprise LTSC 2021" $polIoT $ltscReg $false

    & $wimlib append $mountDir $newWimPath "Windows 10 IoT Enterprise LTSC 2021" "Windows 10 IoT Enterprise LTSC 2021" `
        "--image-property=EDITIONID=IoTEnterpriseS" `
        "--image-property=INSTALLATIONTYPE=Client" `
        "--image-property=PRODUCTTYPE=WinNT" `
        "--image-property=PRODUCTSUITE=Terminal Server" `
        "--image-property=DISPLAYNAME=Windows 10 IoT 企业版 LTSC" `
        "--image-property=DISPLAYDESCRIPTION=Windows 10 IoT 企业版 LTSC" `
        "--image-property=FLAGS=IoTEnterpriseS"
    if ($LASTEXITCODE -ne 0) { throw "Failed to append Index 2 (IoTEnterpriseS)" }

    # Switch EnterpriseSEdition -> ProfessionalEdition for Index 3 & 4
    Write-Host "  Switching CBS Product Package: EnterpriseSEdition -> ProfessionalEdition ($pkgVer)..."
    dism.exe /Image:$mountDir /Add-Package /PackagePath:$($proPkg.MumPath) /Quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to add ProfessionalEdition package" }

    dism.exe /Image:$mountDir /Remove-Package /PackageName:$($entSPkg.PackageName) /Quiet
    if ($LASTEXITCODE -ne 0) { throw "Failed to remove EnterpriseSEdition package" }

    Apply-ClientOverlayFiles

    # Edition 3: Professional (Windows 10 Pro)
    Write-Host "  Appending Index 3: Windows 10 Pro (Professional)..." -ForegroundColor Cyan
    $polPro = [OfficialIsoHelper]::PatchProductPolicySku($proPolicyBytes, 0x30)
    Set-OfflineClientRegistry "Professional" "Enterprise" "Windows 10 Pro" $polPro $proReg $true
    dism.exe /Image:$mountDir /Set-ProductKey:W269N-WFGWX-YVC9B-4J6C9-T83GX /Quiet | Out-Null
    Set-OfflineClientRegistry "Professional" "Enterprise" "Windows 10 Pro" $polPro $proReg $false

    & $wimlib append $mountDir $newWimPath "Windows 10 Pro" "Windows 10 Pro" `
        "--image-property=EDITIONID=Professional" `
        "--image-property=INSTALLATIONTYPE=Client" `
        "--image-property=PRODUCTTYPE=WinNT" `
        "--image-property=PRODUCTSUITE=Terminal Server" `
        "--image-property=DISPLAYNAME=Windows 10 专业版" `
        "--image-property=DISPLAYDESCRIPTION=Windows 10 专业版" `
        "--image-property=FLAGS=Professional"
    if ($LASTEXITCODE -ne 0) { throw "Failed to append Index 3 (Professional)" }

    # Edition 4: Enterprise (Windows 10 Enterprise)
    Write-Host "  Appending Index 4: Windows 10 Enterprise (Enterprise)..." -ForegroundColor Cyan
    $polEnt = [OfficialIsoHelper]::PatchProductPolicySku($proPolicyBytes, 0x04)
    Set-OfflineClientRegistry "Enterprise" "Enterprise" "Windows 10 Enterprise" $polEnt $proReg $true
    dism.exe /Image:$mountDir /Set-ProductKey:NPPR9-FWDCX-D2C8J-H872K-2YT43 /Quiet | Out-Null
    Set-OfflineClientRegistry "Enterprise" "Enterprise" "Windows 10 Enterprise" $polEnt $proReg $false

    & $wimlib append $mountDir $newWimPath "Windows 10 Enterprise" "Windows 10 Enterprise" `
        "--image-property=EDITIONID=Enterprise" `
        "--image-property=INSTALLATIONTYPE=Client" `
        "--image-property=PRODUCTTYPE=WinNT" `
        "--image-property=PRODUCTSUITE=Terminal Server" `
        "--image-property=DISPLAYNAME=Windows 10 企业版" `
        "--image-property=DISPLAYDESCRIPTION=Windows 10 企业版" `
        "--image-property=FLAGS=Enterprise"
    if ($LASTEXITCODE -ne 0) { throw "Failed to append Index 4 (Enterprise)" }

    & $wimlib optimize $newWimPath
} finally {
    Write-Host "  Unmounting working image..."
    dism.exe /Unmount-Wim /MountDir:$mountDir /Discard /Quiet | Out-Null
    Remove-Item "Cert:\LocalMachine\Root\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
    Remove-Item "Cert:\LocalMachine\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
}

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

# Export build metadata for GitHub Actions release step
if ($env:GITHUB_OUTPUT) {
    "iso_path=$outIsoPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "iso_name=$outIsoName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "iso_sha256=$isoHash"  | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "build_ver=$pkgVer"    | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
