#!/usr/bin/env pwsh
# Tests Assert-ZipLayoutSafe from install.ps1 (zip-slip / path-traversal defense).
# Dot-sources install.ps1 -LoadFunctionsOnly and feeds it crafted archives.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'install.ps1') -LoadFunctionsOnly

$script:failures = 0
function Check([bool]$cond, [string]$msg) {
    if ($cond) { Write-Host "  ok: $msg" } else { Write-Host "  FAIL: $msg" -ForegroundColor Red; $script:failures++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dcg_zipslip_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

function New-TestZip([string[]]$EntryNames) {
    $path = Join-Path $tmp ("z_" + [Guid]::NewGuid().ToString('N') + ".zip")
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $EntryNames) {
            $e = $zip.CreateEntry($name)
            $w = New-Object System.IO.StreamWriter($e.Open())
            $w.Write("x"); $w.Dispose()
        }
    } finally { $zip.Dispose(); $fs.Dispose() }
    $path
}
function New-SymlinkZip {
    $path = Join-Path $tmp ("z_" + [Guid]::NewGuid().ToString('N') + ".zip")
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Create)
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $e = $zip.CreateEntry('dcg.exe')
        # Unix mode 0120777 in the upper 16 bits marks this ZIP entry as a symlink.
        $e.ExternalAttributes = -1577123840
        $w = New-Object System.IO.StreamWriter($e.Open())
        $w.Write('target.exe'); $w.Dispose()
    } finally { $zip.Dispose(); $fs.Dispose() }
    # ZipArchive writes a Windows "version made by" host byte even when Unix
    # mode bits are supplied. Windows tar.exe therefore treats the fixture as a
    # regular file unless the central-directory creator is made authentically
    # Unix (host 3). Patch only that metadata byte in this one-entry test ZIP.
    [byte[]]$bytes = [System.IO.File]::ReadAllBytes($path)
    $patchedCreator = $false
    for ($i = 0; $i -le ($bytes.Length - 6); $i++) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i + 1] -eq 0x4B -and
            $bytes[$i + 2] -eq 0x01 -and $bytes[$i + 3] -eq 0x02) {
            $bytes[$i + 5] = 3
            $patchedCreator = $true
            break
        }
    }
    if (-not $patchedCreator) { throw 'test ZIP central directory was not found' }
    [System.IO.File]::WriteAllBytes($path, $bytes)
    $path
}
function ShouldThrow([string]$zip, [string]$why) {
    $threw = $false
    try { Assert-ZipLayoutSafe -ZipPath $zip } catch { $threw = $true }
    Check $threw $why
}
function ShouldPass([string]$zip, [string]$why) {
    $ok = $true
    try { Assert-ZipLayoutSafe -ZipPath $zip } catch { $ok = $false; Write-Host "    (threw: $_)" }
    Check $ok $why
}

try {
    ShouldPass  (New-TestZip @('dcg.exe'))                              "flat archive with dcg.exe is accepted"
    ShouldThrow (New-TestZip @('dcg-x86_64-pc-windows-msvc/dcg.exe'))   "rejects a nested dcg.exe"
    ShouldThrow (New-TestZip @('dcg.exe', 'README.txt'))                "rejects extra archive members"
    ShouldThrow (New-TestZip @('dcg.exe/'))                             "rejects a directory named dcg.exe"
    ShouldThrow (New-SymlinkZip)                                        "rejects a symlink named dcg.exe"
    ShouldThrow (New-TestZip @('DCG.EXE'))                              "requires the canonical member name"
    ShouldThrow (New-TestZip @('../evil.exe', 'dcg.exe'))               "rejects a '..' traversal entry"
    ShouldThrow (New-TestZip @('sub/../../evil', 'dcg.exe'))            "rejects an embedded '..' segment"
    ShouldThrow (New-TestZip @('/etc/cron.d/evil', 'dcg.exe'))          "rejects an absolute (/) path"
    ShouldThrow (New-TestZip @('C:\Windows\System32\evil.exe', 'dcg.exe')) "rejects a drive-letter path"
    ShouldThrow (New-TestZip @())                                       "rejects an empty archive"
    ShouldThrow (New-TestZip @('README.txt'))                           "rejects an archive missing dcg.exe"

    $windowsPowerShell = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($windowsPowerShell) {
        Write-Host "ConstrainedLanguage integration: inspect, extract, UTF-8 write, and SHA-256"
        $validZip = New-TestZip @('dcg.exe')
        $probeOut = Join-Path $tmp 'constrained-output'
        $probeScript = Join-Path $tmp 'constrained-probe.ps1'
        $versionMock = Join-Path $tmp 'dcg-version.cmd'
        $versionFailureMock = Join-Path $tmp 'dcg-version-failure.cmd'
        $selfTestMock = Join-Path $tmp 'dcg-self-test.cmd'
        @'
@echo off
echo 9.8.7
echo dcg v9.8.7 diagnostic banner 1>&2
exit /b 0
'@ | Set-Content -LiteralPath $versionMock -Encoding ASCII
        @'
@echo off
echo dcg version probe failed 1>&2
exit /b 23
'@ | Set-Content -LiteralPath $versionFailureMock -Encoding ASCII
        @'
@echo off
if "%~4"=="git status" goto allow
if "%~4"=="rm -rf /" goto deny
echo unexpected self-test arguments 1>&2
exit /b 64
:allow
echo {"decision":"allow"}
echo dcg safe diagnostic banner 1>&2
exit /b 0
:deny
echo {"decision":"deny"}
echo dcg deny diagnostic banner 1>&2
exit /b 1
'@ | Set-Content -LiteralPath $selfTestMock -Encoding ASCII
        @'
param(
    [string]$InstallPath,
    [string]$ZipPath,
    [string]$OutputPath,
    [string]$VersionCommand,
    [string]$VersionFailureCommand,
    [string]$SelfTestCommand
)
$ErrorActionPreference = 'Stop'
$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'
. $InstallPath -LoadFunctionsOnly
Assert-ZipLayoutSafe -ZipPath $ZipPath
$extract = Join-Path $OutputPath 'extract'
Expand-DcgArchive -ZipPath $ZipPath -DestinationPath $extract
if (-not (Test-Path -LiteralPath (Join-Path $extract 'dcg.exe'))) {
    throw 'verified archive did not extract dcg.exe'
}
$utf8 = Join-Path $OutputPath 'utf8.txt'
$text = 'snowman ' + [char]0x2603 + '; rocket ' + [char]0xD83D + [char]0xDE80
Write-Utf8NoBomText -Path $utf8 -Text $text
[byte[]]$bytes = @(Get-Content -LiteralPath $utf8 -Encoding Byte)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    throw 'UTF-8 helper emitted a BOM'
}
if (-not (Test-Sha256Token (Get-DcgFileSha256 -Path $utf8))) {
    throw 'SHA-256 fallback returned an invalid digest'
}
if ((Get-DcgReportedVersion -Path $VersionCommand) -cne 'v9.8.7') {
    throw 'native stdout/stderr version capture failed under ErrorActionPreference Stop'
}
if ($ErrorActionPreference -cne 'Stop') {
    throw 'Get-DcgReportedVersion did not restore ErrorActionPreference after success'
}
$versionFailure = $null
try {
    Get-DcgReportedVersion -Path $VersionFailureCommand | Out-Null
} catch {
    $versionFailure = $_.Exception.Message
}
if ($versionFailure -cne 'Installed dcg failed --version with exit code 23') {
    throw "unexpected nonzero native exit result: $versionFailure"
}
if ($ErrorActionPreference -cne 'Stop') {
    throw 'Get-DcgReportedVersion did not restore ErrorActionPreference after failure'
}
Invoke-DcgInstallSelfTest -Path $SelfTestCommand -ProbeRoot $OutputPath
if ($ErrorActionPreference -cne 'Stop') {
    throw 'Invoke-DcgInstallSelfTest did not restore ErrorActionPreference'
}
'ok'
'@ | Set-Content -LiteralPath $probeScript -Encoding UTF8
        New-Item -ItemType Directory -Path $probeOut | Out-Null
        $probeResult = & $windowsPowerShell.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $probeScript `
            -InstallPath (Join-Path $repoRoot 'install.ps1') -ZipPath $validZip -OutputPath $probeOut `
            -VersionCommand $versionMock -VersionFailureCommand $versionFailureMock `
            -SelfTestCommand $selfTestMock
        Check (($LASTEXITCODE -eq 0) -and ($probeResult -contains 'ok')) `
            "Windows PowerShell 5.1 ConstrainedLanguage installer primitives and native stream capture work end to end"
    } else {
        Write-Host "  skip: Windows PowerShell 5.1 is unavailable on this host"
    }
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) { Write-Host "$script:failures FAILURE(S)" -ForegroundColor Red; exit 1 }
Write-Host "All Assert-ZipLayoutSafe tests passed." -ForegroundColor Green
