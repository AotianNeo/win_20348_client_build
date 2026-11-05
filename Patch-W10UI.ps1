param(
    [Parameter(Mandatory=$true)][string]$W10UICmdPath,
    [Parameter(Mandatory=$true)][string]$W10UIIniPath,
    [Parameter(Mandatory=$true)][string]$InjectScriptPath,
    [Parameter(Mandatory=$true)][string]$TemplateDirPath
)

$ErrorActionPreference = 'Stop'

# 1. Patch W10UI.cmd right before 'call :addlcu DismLCU'
$cmdContent = [System.IO.File]::ReadAllText($W10UICmdPath, [System.Text.Encoding]::Default)
$targetHook = "call :addlcu DismLCU"
$injectCall = @"
powershell -NoProfile -ExecutionPolicy Bypass -File "$InjectScriptPath" -MountDir "!mountdir!" -CabDir "!_cabdir!" -Cumulative "!cumulative!"
call :addlcu DismLCU
"@

if ($cmdContent.Contains($targetHook)) {
    $idx = $cmdContent.IndexOf($targetHook)
    $cmdContent = $cmdContent.Substring(0, $idx) + $injectCall + $cmdContent.Substring($idx + $targetHook.Length)
    [System.IO.File]::WriteAllText($W10UICmdPath, $cmdContent, [System.Text.Encoding]::Default)
    Write-Host "[Patch-W10UI] Successfully hooked Inject-20348-Client-LCU.ps1 before 'call :addlcu DismLCU' in $W10UICmdPath"
} else {
    throw "Could not find '$targetHook' in $W10UICmdPath"
}

# 2. Update W10UI.ini to ensure ResetBase=0 (preserves custom Client base component manifests across updates)
if (Test-Path $W10UIIniPath) {
    $iniContent = [System.IO.File]::ReadAllText($W10UIIniPath, [System.Text.Encoding]::Default)
    $iniContent = [regex]::Replace($iniContent, '(?m)^ResetBase\s*=\s*1', 'ResetBase=0')
    [System.IO.File]::WriteAllText($W10UIIniPath, $iniContent, [System.Text.Encoding]::Default)
    Write-Host "[Patch-W10UI] Set ResetBase=0 in $W10UIIniPath"
}

# 3. Make Start.cmd non-interactive in CI (remove pause / choice prompts)
$startCmdPath = Join-Path (Split-Path -Parent $W10UICmdPath) "Start.cmd"
if (Test-Path $startCmdPath) {
    $startContent = [System.IO.File]::ReadAllText($startCmdPath, [System.Text.Encoding]::Default)
    $startContent = [regex]::Replace($startContent, '(?mi)^\s*choice\s+/c\s+7\s+/n\s*$', 'rem choice /c 7 /n')
    $startContent = [regex]::Replace($startContent, '(?mi)^\s*pause\s*$', 'rem pause')
    [System.IO.File]::WriteAllText($startCmdPath, $startContent, [System.Text.Encoding]::Default)
    Write-Host "[Patch-W10UI] Made $startCmdPath non-interactive for CI"
}

