param(
    [Parameter(Mandatory=$true)][string]$MountDir,
    [Parameter(Mandatory=$true)][string]$CabDir,
    [Parameter(Mandatory=$true)][string]$Cumulative
)

$ErrorActionPreference = 'Stop'

# Compile native P/Invoke helpers for:
# 1. wcp.dll 64-bit SxS component manifest hash calculation
# 2. msdelta.dll PA30 / DCM v1 manifest decompression
# 3. reg.exe / offline registry root certificate injection
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

public class SxsHelper {
    [StructLayout(LayoutKind.Sequential)]
    public struct DELTA_INPUT {
        public IntPtr lpcStart;
        public UIntPtr uSize;
        public int Editable;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DELTA_OUTPUT {
        public IntPtr lpStart;
        public UIntPtr uSize;
    }

    [DllImport("msdelta.dll", SetLastError = true)]
    public static extern bool ApplyDeltaB(long ApplyFlags, DELTA_INPUT Source, DELTA_INPUT Delta, out DELTA_OUTPUT lpOutput);

    [DllImport("msdelta.dll", SetLastError = true)]
    public static extern bool DeltaFree(IntPtr lpMemory);

    public static byte[] DecompressManifest(byte[] dict, byte[] fileBytes) {
        if (fileBytes != null && fileBytes.Length > 4 &&
            fileBytes[0] == 0x44 && fileBytes[1] == 0x43 && fileBytes[2] == 0x4D && fileBytes[3] == 0x01) {
            byte[] delta = new byte[fileBytes.Length - 4];
            Array.Copy(fileBytes, 4, delta, 0, delta.Length);
            GCHandle hSrc = GCHandle.Alloc(dict, GCHandleType.Pinned);
            GCHandle hDlt = GCHandle.Alloc(delta, GCHandleType.Pinned);
            try {
                DELTA_INPUT srcIn = new DELTA_INPUT { lpcStart = hSrc.AddrOfPinnedObject(), uSize = (UIntPtr)dict.Length, Editable = 0 };
                DELTA_INPUT dltIn = new DELTA_INPUT { lpcStart = hDlt.AddrOfPinnedObject(), uSize = (UIntPtr)delta.Length, Editable = 0 };
                DELTA_OUTPUT outData;
                if (ApplyDeltaB(0, srcIn, dltIn, out outData)) {
                    byte[] res = new byte[(int)outData.uSize];
                    Marshal.Copy(outData.lpStart, res, 0, res.Length);
                    DeltaFree(outData.lpStart);
                    return res;
                }
            } finally {
                hSrc.Free();
                hDlt.Free();
            }
        }
        return fileBytes;
    }

    private static ulong HStr(string s) {
        if (string.IsNullOrEmpty(s)) return 0UL;
        ulong h = 0UL;
        foreach (char c in s.ToLowerInvariant()) {
            h = unchecked(h * 0x1003FUL + (ulong)c);
        }
        return h;
    }

    private static ulong HPair(string name, string val) {
        ulong hn = HStr(name);
        ulong hv = HStr(val);
        return unchecked(hv + 0x1FFFFFCE800000D5UL * hn);
    }

    public static string ComputeSxsHash(string name, string type, string version, string publicKeyToken, string processorArchitecture, string versionScope, string culture) {
        string[] attrs = new string[] {
            "name", name,
            "type", type,
            "version", version,
            "publicKeyToken", publicKeyToken,
            "processorArchitecture", processorArchitecture,
            "versionScope", versionScope,
            "culture", culture
        };
        ulong total = 0UL;
        for (int i = 0; i < attrs.Length; i += 2) {
            string k = attrs[i];
            string v = attrs[i + 1];
            if (!string.IsNullOrEmpty(v)) {
                ulong p = HPair(k, v);
                total = unchecked(p + 0x1FFFFF9B00000625UL * total);
            }
        }
        return total.ToString("x16");
    }

    public static string GetShortComponentName(string compName) {
        string lower = compName.ToLowerInvariant();
        if (lower.Length > 40) {
            return lower.Substring(0, 19) + ".." + lower.Substring(lower.Length - 19);
        }
        return lower;
    }
}
'@

Write-Host "======================================================================="
Write-Host "[20348-Client-LCU] Injecting Client CBS Bridge & Signing Catalogs"
Write-Host "  MountDir  : $MountDir"
Write-Host "  CabDir    : $CabDir"
Write-Host "  Cumulative: $Cumulative"
Write-Host "======================================================================="

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateDir  = Join-Path $CabDir "_20348_Client_State"
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

# ---------------------------------------------------------------------------
# 1. Load or Create Two-Tier Self-Signed Certificate (Root CA + Leaf Signer)
# ---------------------------------------------------------------------------
$RootCerPath = Join-Path $StateDir "RootCA.cer"
$LeafPfxPath = Join-Path $StateDir "LeafSigner.pfx"
$PfxPassword = ConvertTo-SecureString -String "20348Client" -Force -AsPlainText

if (-not (Test-Path $LeafPfxPath)) {
    Write-Host "[20348-Client-LCU] Generating Root CA and Leaf CodeSigning Certificate..."
    $rootCert = New-SelfSignedCertificate -Type Custom `
        -Subject "CN=Microsoft Windows Root Authority, O=Microsoft Corporation, C=US" `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -NotBefore (Get-Date).AddYears(-5) -NotAfter (Get-Date).AddYears(20) `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -TextExtension @("2.5.29.19={critical}{text}ca=1&pathlength=1")

    $leafCert = New-SelfSignedCertificate -Type Custom `
        -Subject "CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" `
        -Signer $rootCert `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -NotBefore (Get-Date).AddYears(-5) -NotAfter (Get-Date).AddYears(20) `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -TextExtension @(
            "2.5.29.19={critical}{text}ca=0",
            "2.5.29.37={text}1.3.6.1.5.5.7.3.3,1.3.6.1.4.1.311.10.3.6,1.3.6.1.4.1.311.10.3.13"
        )

    Export-Certificate -Cert $rootCert -FilePath $RootCerPath -Force | Out-Null
    Export-PfxCertificate -Cert $leafCert -FilePath $LeafPfxPath -Password $PfxPassword -Force | Out-Null
    Import-Certificate -FilePath $RootCerPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
} else {
    $leafCert = Get-PfxCertificate -FilePath $LeafPfxPath -Password $PfxPassword
    Import-Certificate -FilePath $RootCerPath -CertStoreLocation "Cert:\LocalMachine\Root" | Out-Null
}

# ---------------------------------------------------------------------------
# 2. Extract 9066-byte DCM XML Dictionary from wcp.dll
# ---------------------------------------------------------------------------
$DictPath = Join-Path $StateDir "wcp_dict.bin"
if (-not (Test-Path $DictPath)) {
    $wcpCandidates = @(Get-ChildItem "$MountDir\Windows\WinSxS\*_microsoft-windows-servicingstack_*\wcp.dll" -ErrorAction SilentlyContinue)
    if ($wcpCandidates.Count -eq 0) {
        $wcpCandidates = @(Get-ChildItem "C:\Windows\WinSxS\*_microsoft-windows-servicingstack_*\wcp.dll" -ErrorAction SilentlyContinue)
    }
    $wcpFile = ($wcpCandidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
    $wcpBytes = [IO.File]::ReadAllBytes($wcpFile)
    $pat = [Text.Encoding]::ASCII.GetBytes("<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?>`r`n<assembly")
    $dictOffset = -1
    for ($i = 0; $i -lt $wcpBytes.Length - $pat.Length; $i++) {
        if ($wcpBytes[$i] -eq $pat[0] -and $wcpBytes[$i + 57] -eq $pat[57]) {
            $match = $true
            for ($j = 0; $j -lt $pat.Length; $j++) {
                if ($wcpBytes[$i + $j] -ne $pat[$j]) { $match = $false; break }
            }
            if ($match) { $dictOffset = $i; break }
        }
    }
    if ($dictOffset -lt 0) { throw "Failed to locate DCM XML dictionary in $wcpFile" }
    $dictBytes = New-Object byte[] 9066
    [Array]::Copy($wcpBytes, $dictOffset, $dictBytes, 0, 9066)
    [IO.File]::WriteAllBytes($DictPath, $dictBytes)
} else {
    $dictBytes = [IO.File]::ReadAllBytes($DictPath)
}

# ---------------------------------------------------------------------------
# 3. Inject Root CA into Mounted Offline Registry (SOFTWARE\Microsoft\SystemCertificates\ROOT)
# ---------------------------------------------------------------------------
Write-Host "[20348-Client-LCU] Trusting Root CA in offline image registry..."
$OfflineSoftHive = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
$TempHiveKey = "HKLM\OFFLINE_SW_20348"
& reg.exe load $TempHiveKey $OfflineSoftHive | Out-Null
try {
    $rootThumb = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($RootCerPath)).Thumbprint
    # Copy the Blob from host's HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$rootThumb to offline hive
    $srcRegKey = "HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT\Certificates\$rootThumb"
    $dstRegKey = "$TempHiveKey\Microsoft\SystemCertificates\ROOT\Certificates\$rootThumb"
    & reg.exe copy $srcRegKey $dstRegKey /s /f | Out-Null
    # Also add to AuthRoot just in case
    $dstAuthKey = "$TempHiveKey\Microsoft\SystemCertificates\AuthRoot\Certificates\$rootThumb"
    & reg.exe copy $srcRegKey $dstAuthKey /s /f | Out-Null
} finally {
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    & reg.exe unload $TempHiveKey | Out-Null
}

# ---------------------------------------------------------------------------
# 4. Re-sign all existing custom-signed .cat files in Mounted Image Servicing\Packages
# ---------------------------------------------------------------------------
Write-Host "[20348-Client-LCU] Re-signing existing custom .cat files in mounted image..."
$MountPkgDir = Join-Path $MountDir "Windows\servicing\Packages"
$resignedCount = 0
foreach ($catFile in (Get-ChildItem "$MountPkgDir\*.cat")) {
    $sig = Get-AuthenticodeSignature $catFile.FullName
    if ($sig.Status -ne 'Valid') {
        Set-AuthenticodeSignature -FilePath $catFile.FullName -Certificate $leafCert -HashAlgorithm SHA256 -ErrorAction Stop | Out-Null
        $resignedCount++
    }
}
Write-Host "[20348-Client-LCU] Re-signed $resignedCount custom .cat files in mounted image (100% Valid)."

# ---------------------------------------------------------------------------
# 5. Patch LCU folder(s) once per W10UI run
# ---------------------------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$lcuRelPaths = @($Cumulative -split '\s+' | Where-Object { $_ -ne '' -and $_ -like '*update.mum*' })

foreach ($relMum in $lcuRelPaths) {
    $cleanRel = $relMum.Trim('"')
    $lcuUpdateMum = Join-Path $CabDir $cleanRel
    if (-not (Test-Path $lcuUpdateMum)) { continue }

    $lcuDir = Split-Path -Parent $lcuUpdateMum
    $lcuMarker = Join-Path $lcuDir "_20348_client_patched.marker"
    if (Test-Path $lcuMarker) {
        Write-Host "[20348-Client-LCU] LCU folder $lcuDir already patched for Client editions."
        continue
    }

    Write-Host "[20348-Client-LCU] Synthesizing Client CBS packages into LCU folder: $lcuDir"
    [xml]$uXml = Get-Content $lcuUpdateMum
    $kbId = $uXml.assembly.package.identifier
    $newVer = $uXml.assembly.package.customInformation.Version
    if (-not $newVer) {
        $wrapId = $uXml.assembly.package.update | Select-Object -First 1
        $newVer = $wrapId.package.assemblyIdentity.version
    }
    $supportUrl = $uXml.assembly.supportInformation
    $timeStamp = $uXml.assembly.creationTimeStamp

    # Find ServicingStack version from an existing Server wrapper .mum in $lcuDir
    $ssuVer = "10.0.20348.1960"
    $srvWrap = Get-ChildItem "$lcuDir\microsoft-windows-server*edition-wrapper*.mum" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($srvWrap) {
        [xml]$swXml = Get-Content $srvWrap.FullName
        if ($swXml.assembly.package.installerAssembly.version) {
            $ssuVer = $swXml.assembly.package.installerAssembly.version
        }
    }
    Write-Host "  LCU Version: $newVer | KB: $kbId | SSU MinVer: $ssuVer"

    # 5a. Build lookup of all components updated in $lcuDir
    # Key: "arch|compNameLower|langLower" -> Version
    # And also fallback by shortName: "arch|shortNameLower|langLower" -> Version
    $lcuCompVer = @{}
    $lcuShortCompVer = @{}
    foreach ($mf in (Get-ChildItem "$lcuDir\*.manifest" -Recurse)) {
        $parts = $mf.BaseName -split '_'
        if ($parts.Count -ge 6) {
            $mArch = $parts[0].ToLowerInvariant()
            $mShort = $parts[1].ToLowerInvariant()
            $mVer = $parts[3]
            $mLang = $parts[4].ToLowerInvariant()
            $sKey = "${mArch}|${mShort}|${mLang}"
            if (-not $lcuShortCompVer.ContainsKey($sKey) -or ([version]$mVer -gt [version]$lcuShortCompVer[$sKey])) {
                $lcuShortCompVer[$sKey] = $mVer
            }
            if ($mShort -notlike '*..*') {
                $cKey = "${mArch}|${mShort}|${mLang}"
                $lcuCompVer[$cKey] = $mVer
            }
        }
    }
    Write-Host "  Indexed $($lcuShortCompVer.Count) component manifests in LCU."

    # 5b. Build lookup of all official packages (.mum) in $lcuDir + mounted image
    # Key: "pkgNameLower|archLower|langLower" -> @{ Ver = $ver; IsInLcu = $bool }
    $pkgVerMap = @{}
    foreach ($pf in (Get-ChildItem "$MountPkgDir\*.mum")) {
        $parts = $pf.BaseName -split '~'
        if ($parts.Count -ge 5) {
            $pKey = "$($parts[0].ToLowerInvariant())|$($parts[2].ToLowerInvariant())|$($parts[3].ToLowerInvariant())"
            $pVer = $parts[4]
            if (-not $pkgVerMap.ContainsKey($pKey) -or ([version]$pVer -gt [version]$pkgVerMap[$pKey].Ver)) {
                $pkgVerMap[$pKey] = @{ Ver = $pVer; Updated = $false }
            }
        }
    }
    foreach ($pf in (Get-ChildItem "$lcuDir\*.mum" -Recurse)) {
        if ($pf.Name -eq 'update.mum') { continue }
        [xml]$px = Get-Content $pf.FullName
        $id = $px.assembly.assemblyIdentity
        if ($id -and $id.name -and $id.version -match '^10\.0\.20348\.') {
            $lang = if ($id.language -eq 'neutral' -or -not $id.language) { '' } else { $id.language.ToLowerInvariant() }
            $pKey = "$($id.name.ToLowerInvariant())|$($id.processorArchitecture.ToLowerInvariant())|${lang}"
            $pkgVerMap[$pKey] = @{ Ver = $id.version; Updated = $true }
        }
    }

    # 5c. Process all 52 custom Client deployment manifest templates
    $TplManDir = Join-Path $ScriptDir "ClientTemplates\Manifests"
    $TplPkgDir = Join-Path $ScriptDir "ClientTemplates\Packages"

    # Track updated custom deployment manifests: "arch|compNameLower|langLower" -> @{ Ver = $ver; FilePath = $path; Updated = $bool }
    $customCompMap = @{}
    $updatedCustomManCount = 0

    foreach ($tplMan in (Get-ChildItem "$TplManDir\*.manifest")) {
        $rawText = [IO.File]::ReadAllText($tplMan.FullName, [Text.Encoding]::UTF8)
        if ($rawText[0] -eq [char]0xFEFF) { $rawText = $rawText.Substring(1) }
        [xml]$mx = $rawText
        $rootId = $mx.assembly.assemblyIdentity
        $cName = $rootId.name
        $cArch = $rootId.processorArchitecture.ToLowerInvariant()
        $cLangXml = $rootId.language
        $cLangFile = if ($cLangXml -eq 'neutral' -or -not $cLangXml) { 'none' } else { $cLangXml.ToLowerInvariant() }
        $cKey = "${cArch}|$($cName.ToLowerInvariant())|${cLangFile}"

        # Only custom microsoft-windows-client-*-deployment* manifests are synthesized by us;
        # standard Microsoft deployment manifests are already in $lcuShortCompVer if updated.
        if ($cName -notmatch '^microsoft-windows-client-.*-deployment') {
            continue
        }

        $anyDepUpdated = $false
        $newXmlText = $rawText

        foreach ($dep in @($mx.assembly.dependency)) {
            $depId = $dep.dependentAssembly.assemblyIdentity
            if (-not $depId) { continue }
            $dName = $depId.name
            $dArch = $depId.processorArchitecture.ToLowerInvariant()
            $dLangXml = $depId.language
            $dLangFile = if ($dLangXml -eq 'neutral' -or -not $dLangXml) { 'none' } else { $dLangXml.ToLowerInvariant() }
            $dShort = [SxsHelper]::GetShortComponentName($dName)
            $dShortKey = "${dArch}|${dShort}|${dLangFile}"

            if ($lcuShortCompVer.ContainsKey($dShortKey)) {
                $targetVer = $lcuShortCompVer[$dShortKey]
                if ($depId.version -ne $targetVer) {
                    $anyDepUpdated = $true
                    $escapedName = [regex]::Escape($dName)
                    $escapedArch = [regex]::Escape($depId.processorArchitecture)
                    $escapedLang = [regex]::Escape($dLangXml)
                    $pattern = "(<assemblyIdentity\s+name=`"$escapedName`"\s+version=`")[^`"]+(`"\s+processorArchitecture=`"$escapedArch`"\s+language=`"$escapedLang`")"
                    $newXmlText = [regex]::Replace($newXmlText, $pattern, "`${1}$targetVer`${2}")
                }
            }
        }

        # Always generate the custom deployment manifest at $newVer if any dependency updated
        # (or if it is one of the root custom deployment manifests)
        if ($anyDepUpdated) {
            $escapedRoot = [regex]::Escape($cName)
            $rootPattern = "(<assemblyIdentity\s+name=`"$escapedRoot`"\s+version=`")[^`"]+(`")"
            $newXmlText = [regex]::Replace($newXmlText, $rootPattern, "`${1}$newVer`${2}", 1)

            $cultureVal = if ($cLangXml -eq 'neutral') { $null } else { $cLangXml }
            $hash16 = [SxsHelper]::ComputeSxsHash($cName, $null, $newVer, "31bf3856ad364e35", $cArch, "nonSxS", $cultureVal)
            $shortRoot = [SxsHelper]::GetShortComponentName($cName)
            $manFileName = "${cArch}_${shortRoot}_31bf3856ad364e35_${newVer}_${cLangFile}_${hash16}.manifest"
            $manOutPath = Join-Path $lcuDir $manFileName
            [IO.File]::WriteAllText($manOutPath, $newXmlText, $utf8NoBom)

            $customCompMap[$cKey] = @{ Ver = $newVer; FilePath = $manOutPath; Updated = $true }
            $updatedCustomManCount++
        } else {
            # Keep existing version in mounted image and find its file path for catalog hashing if needed
            $shortRoot = [SxsHelper]::GetShortComponentName($cName)
            $existingMan = Get-ChildItem "$MountDir\Windows\WinSxS\Manifests\${cArch}_${shortRoot}_31bf3856ad364e35_*_${cLangFile}_*.manifest" -ErrorAction SilentlyContinue |
                Sort-Object { [version](($_.BaseName -split '_')[3]) } -Descending | Select-Object -First 1
            $existingVer = if ($existingMan) { ($existingMan.BaseName -split '_')[3] } else { $rootId.version }
            $customCompMap[$cKey] = @{ Ver = $existingVer; FilePath = $tplMan.FullName; Updated = $false }
        }
    }
    Write-Host "  Synthesized $updatedCustomManCount updated custom Client deployment manifests in LCU."

    # 5d. Bottom-up fixed-point pass over all 316 custom .mum templates
    $mumTemplates = @{}
    foreach ($tf in (Get-ChildItem "$TplPkgDir\*.mum")) {
        $rawMum = [IO.File]::ReadAllText($tf.FullName, [Text.Encoding]::UTF8)
        if ($rawMum[0] -eq [char]0xFEFF) { $rawMum = $rawMum.Substring(1) }
        [xml]$mx = $rawMum
        $id = $mx.assembly.assemblyIdentity
        $lang = if ($id.language -eq 'neutral' -or -not $id.language) { '' } else { $id.language.ToLowerInvariant() }
        $pKey = "$($id.name.ToLowerInvariant())|$($id.processorArchitecture.ToLowerInvariant())|${lang}"
        $mumTemplates[$pKey] = @{
            File = $tf.FullName
            RawText = $rawMum
            Xml = $mx
            Name = $id.name
            Arch = $id.processorArchitecture
            LangXml = $id.language
            LangFile = if ($id.language -eq 'neutral' -or -not $id.language) { '' } else { $id.language }
            Updated = $false
        }
    }

    # Always force top-level Client Edition packages and LanguagePack to update to $newVer
    $forceUpdateKeys = @(
        "microsoft-windows-enterprisesedition|amd64|",
        "microsoft-windows-professionaledition|amd64|",
        "microsoft-windows-client-languagepack-package|amd64|zh-cn"
    )
    foreach ($fk in $forceUpdateKeys) {
        if ($mumTemplates.ContainsKey($fk)) {
            $mumTemplates[$fk].Updated = $true
            $pkgVerMap[$fk] = @{ Ver = $newVer; Updated = $true }
        }
    }

    # Iterative fixed-point propagation from leaves to roots
    do {
        $changedInPass = 0
        foreach ($kv in $mumTemplates.GetEnumerator()) {
            $pKey = $kv.Key
            $entry = $kv.Value
            if ($entry.Updated) { continue }

            $needsUpdate = $false
            foreach ($u in @($entry.Xml.assembly.package.update)) {
                foreach ($c in @($u.component)) {
                    if ($c -and $c.assemblyIdentity) {
                        $cid = $c.assemblyIdentity
                        $cArch = $cid.processorArchitecture.ToLowerInvariant()
                        $cLang = if ($cid.language -eq 'neutral' -or -not $cid.language) { 'none' } else { $cid.language.ToLowerInvariant() }
                        $cNameLower = $cid.name.ToLowerInvariant()
                        $cFullKey = "${cArch}|${cNameLower}|${cLang}"
                        $cShortKey = "${cArch}|$([SxsHelper]::GetShortComponentName($cNameLower))|${cLang}"

                        if ($customCompMap.ContainsKey($cFullKey) -and $customCompMap[$cFullKey].Updated) {
                            $needsUpdate = $true; break
                        }
                        if ($lcuShortCompVer.ContainsKey($cShortKey)) {
                            $lcuVer = $lcuShortCompVer[$cShortKey]
                            if ($lcuVer -eq $newVer -or ([version]$lcuVer -gt [version]$cid.version)) {
                                $needsUpdate = $true; break
                            }
                        }
                    }
                }
                if ($needsUpdate) { break }

                foreach ($p in @($u.package)) {
                    if ($p -and $p.assemblyIdentity) {
                        $pidNode = $p.assemblyIdentity
                        $pArch = $pidNode.processorArchitecture.ToLowerInvariant()
                        $pLang = if ($pidNode.language -eq 'neutral' -or -not $pidNode.language) { '' } else { $pidNode.language.ToLowerInvariant() }
                        $childKey = "$($pidNode.name.ToLowerInvariant())|${pArch}|${pLang}"
                        if ($pkgVerMap.ContainsKey($childKey) -and $pkgVerMap[$childKey].Updated) {
                            $needsUpdate = $true; break
                        }
                    }
                }
                if ($needsUpdate) { break }
            }

            if ($needsUpdate) {
                $entry.Updated = $true
                $pkgVerMap[$pKey] = @{ Ver = $newVer; Updated = $true }
                $changedInPass++
            }
        }
    } while ($changedInPass -gt 0)

    # 5e. Write updated custom .mum files and generate/sign their .cat files in $lcuDir
    $generatedMumCount = 0
    $tempCatStaging = Join-Path $StateDir "CatStaging"

    foreach ($kv in $mumTemplates.GetEnumerator()) {
        $entry = $kv.Value
        if (-not $entry.Updated) { continue }

        $newMumText = $entry.RawText
        # Update root assemblyIdentity version
        $escRootName = [regex]::Escape($entry.Name)
        $rootPat = "(<assemblyIdentity\s+name=`"$escRootName`"\s+version=`")[^`"]+(`")"
        $newMumText = [regex]::Replace($newMumText, $rootPat, "`${1}$newVer`${2}", 1)

        $ownedManifestPaths = @()

        # Update child component versions
        foreach ($u in @($entry.Xml.assembly.package.update)) {
            foreach ($c in @($u.component)) {
                if ($c -and $c.assemblyIdentity) {
                    $cid = $c.assemblyIdentity
                    $cName = $cid.name
                    $cArch = $cid.processorArchitecture.ToLowerInvariant()
                    $cLangXml = $cid.language
                    $cLang = if ($cLangXml -eq 'neutral' -or -not $cLangXml) { 'none' } else { $cLangXml.ToLowerInvariant() }
                    $cFullKey = "${cArch}|$($cName.ToLowerInvariant())|${cLang}"
                    $cShortKey = "${cArch}|$([SxsHelper]::GetShortComponentName($cName))|${cLang}"

                    $targetCompVer = $null
                    if ($customCompMap.ContainsKey($cFullKey)) {
                        $targetCompVer = $customCompMap[$cFullKey].Ver
                        if ($customCompMap[$cFullKey].FilePath -and (Test-Path $customCompMap[$cFullKey].FilePath)) {
                            $ownedManifestPaths += $customCompMap[$cFullKey].FilePath
                        }
                    } elseif ($lcuShortCompVer.ContainsKey($cShortKey)) {
                        $targetCompVer = $lcuShortCompVer[$cShortKey]
                    }

                    if ($targetCompVer -and $targetCompVer -ne $cid.version) {
                        $escCName = [regex]::Escape($cName)
                        $escCArch = [regex]::Escape($cid.processorArchitecture)
                        $escCLang = [regex]::Escape($cLangXml)
                        $cPat = "(<assemblyIdentity\s+name=`"$escCName`"\s+version=`")[^`"]+(`"\s+processorArchitecture=`"$escCArch`"\s+language=`"$escCLang`")"
                        $newMumText = [regex]::Replace($newMumText, $cPat, "`${1}$targetCompVer`${2}")
                    }
                }
            }

            # Update child package versions
            foreach ($p in @($u.package)) {
                if ($p -and $p.assemblyIdentity) {
                    $pidNode = $p.assemblyIdentity
                    $pName = $pidNode.name
                    $pArch = $pidNode.processorArchitecture.ToLowerInvariant()
                    $pLangXml = $pidNode.language
                    $pLang = if ($pLangXml -eq 'neutral' -or -not $pLangXml) { '' } else { $pLangXml.ToLowerInvariant() }
                    $childKey = "$($pName.ToLowerInvariant())|${pArch}|${pLang}"

                    if ($pkgVerMap.ContainsKey($childKey)) {
                        $targetPkgVer = $pkgVerMap[$childKey].Ver
                        if ($targetPkgVer -ne $pidNode.version) {
                            $escPName = [regex]::Escape($pName)
                            $escPArch = [regex]::Escape($pidNode.processorArchitecture)
                            $escPLang = [regex]::Escape($pLangXml)
                            $pPat = "(<assemblyIdentity\s+name=`"$escPName`"\s+version=`")[^`"]+(`"\s+processorArchitecture=`"$escPArch`"\s+language=`"$escPLang`")"
                            $newMumText = [regex]::Replace($newMumText, $pPat, "`${1}$targetPkgVer`${2}")
                        }
                    }
                }
            }
        }

        $mumFileName = "$($entry.Name)~31bf3856ad364e35~$($entry.Arch)~$($entry.LangFile)~${newVer}.mum"
        $catFileName = "$($entry.Name)~31bf3856ad364e35~$($entry.Arch)~$($entry.LangFile)~${newVer}.cat"
        $mumOutPath = Join-Path $lcuDir $mumFileName
        $catOutPath = Join-Path $lcuDir $catFileName

        [IO.File]::WriteAllText($mumOutPath, $newMumText, $utf8NoBom)

        # Build .cat file containing the .mum and any custom deployment .manifest owned by this package
        Remove-Item $tempCatStaging -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $tempCatStaging -Force | Out-Null
        Copy-Item $mumOutPath -Destination (Join-Path $tempCatStaging $mumFileName) -Force
        foreach ($omp in $ownedManifestPaths) {
            Copy-Item $omp -Destination (Join-Path $tempCatStaging ([IO.Path]::GetFileName($omp))) -Force
        }
        New-FileCatalog -Path $tempCatStaging -CatalogFilePath $catOutPath -CatalogVersion 2 -HashAlgorithm SHA256 | Out-Null
        Set-AuthenticodeSignature -FilePath $catOutPath -Certificate $leafCert -HashAlgorithm SHA256 -ErrorAction Stop | Out-Null
        $generatedMumCount++
    }
    Remove-Item $tempCatStaging -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Synthesized and signed $generatedMumCount custom Client .mum/.cat packages in LCU."

    # 5f. Create Wrapper .mum/.cat files in $lcuDir and append to update.mum
    $updateCatPath = Join-Path $lcuDir "update.cat"
    $wrappersToCreate = @(
        @{ Name = "microsoft-windows-enterprisesedition"; LangXml = "neutral"; LangFile = "" },
        @{ Name = "microsoft-windows-professionaledition"; LangXml = "neutral"; LangFile = "" },
        @{ Name = "microsoft-windows-client-languagepack-package"; LangXml = "zh-CN"; LangFile = "zh-CN" }
    )

    $appendXmlBuilder = New-Object System.Text.StringBuilder
    foreach ($w in $wrappersToCreate) {
        $wName = "$($w.Name)-Wrapper"
        $wLangXml = $w.LangXml
        $wLangFile = $w.LangFile
        $wUpdSuffix = if ($wLangXml -eq 'neutral') { 'neutral_PACKAGE' } else { "${wLangXml}_PACKAGE" }

        $wMumName = "${wName}~31bf3856ad364e35~amd64~${wLangFile}~${newVer}.mum"
        $wCatName = "${wName}~31bf3856ad364e35~amd64~${wLangFile}~${newVer}.cat"
        $wMumPath = Join-Path $lcuDir $wMumName
        $wCatPath = Join-Path $lcuDir $wCatName

        $wContent = @"
<?xml version="1.0" encoding="utf-8"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v3" manifestVersion="1.0" description="" displayName="default" company="Microsoft Corporation" copyright="Microsoft Corporation" supportInformation="$supportUrl" creationTimeStamp="$timeStamp" lastUpdateTimeStamp="$timeStamp">
  <assemblyIdentity name="$wName" version="$newVer" processorArchitecture="amd64" language="$wLangXml" buildType="release" publicKeyToken="31bf3856ad364e35" />
  <package identifier="$kbId" releaseType="Security Update" restart="possible">
    <parent revisionCompare="GE" integrate="standalone" disposition="detect">
      <assemblyIdentity name="$($w.Name)" version="10.0.20348.1" processorArchitecture="amd64" language="$wLangXml" buildType="release" publicKeyToken="31bf3856ad364e35" />
    </parent>
    <installerAssembly name="Microsoft-Windows-ServicingStack" version="$ssuVer" language="neutral" processorArchitecture="amd64" versionScope="nonSxS" publicKeyToken="31bf3856ad364e35" />
    <update name="$($w.Name)_$wUpdSuffix">
      <package integrate="liberate">
        <assemblyIdentity name="$($w.Name)" version="$newVer" processorArchitecture="amd64" language="$wLangXml" buildType="release" publicKeyToken="31bf3856ad364e35" />
      </package>
    </update>
  </package>
</assembly>
"@
        [IO.File]::WriteAllText($wMumPath, $wContent, $utf8NoBom)
        Copy-Item $updateCatPath -Destination $wCatPath -Force

        [void]$appendXmlBuilder.AppendLine(@"
    <update name="${wName}_${wUpdSuffix}">
      <package>
        <assemblyIdentity name="$wName" version="$newVer" processorArchitecture="amd64" language="$wLangXml" buildType="release" publicKeyToken="31bf3856ad364e35" />
      </package>
    </update>
"@)
    }

    $origUpdateMumText = [IO.File]::ReadAllText($lcuUpdateMum, [Text.Encoding]::UTF8)
    $closingTag = "  </package>`r`n</assembly>"
    if ($origUpdateMumText.Contains($closingTag)) {
        $patchedUpdateMumText = $origUpdateMumText.Replace($closingTag, $appendXmlBuilder.ToString() + $closingTag)
    } else {
        $patchedUpdateMumText = $origUpdateMumText -replace '</package>\s*</assembly>', ($appendXmlBuilder.ToString() + "  </package>`r`n</assembly>")
    }
    [IO.File]::WriteAllText($lcuUpdateMum, $patchedUpdateMumText, $utf8NoBom)
    [IO.File]::WriteAllText($lcuMarker, "Patched at $(Get-Date -Format o)", $utf8NoBom)
    Write-Host "  Appended Client Edition Wrappers to $lcuUpdateMum."
}

Write-Host "[20348-Client-LCU] Completed successfully for $MountDir."
