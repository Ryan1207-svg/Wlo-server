param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$ItemDatPath = 'C:\Users\Ryans\Desktop\WLO PRIVATE SERVER\Client\WLRI\data\Item.dat'
)

$ErrorActionPreference = 'Stop'

$serverRoot = Join-Path $RepoRoot 'Server'
$curateScript = Join-Path $PSScriptRoot 'Curate-WloItemMall.ps1'
$architecture = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
$nativeDir = Join-Path $serverRoot $architecture
$interopDll = Join-Path $nativeDir 'SQLite.Interop.dll'

if (-not (Test-Path -LiteralPath $curateScript)) {
    throw "Missing curation script: $curateScript"
}
if (-not (Test-Path -LiteralPath $interopDll)) {
    throw "Missing native SQLite provider for $architecture PowerShell: $interopDll"
}

if (-not ('WloNativeDllLoader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WloNativeDllLoader
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string lpPathName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr LoadLibrary(string lpFileName);
}
'@
}

$oldPath = $env:PATH
try {
    $env:PATH = $nativeDir + ';' + $oldPath
    [void][WloNativeDllLoader]::SetDllDirectory($nativeDir)

    $nativeHandle = [WloNativeDllLoader]::LoadLibrary($interopDll)
    if ($nativeHandle -eq [IntPtr]::Zero) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not load $interopDll (Win32 error $errorCode)."
    }

    Write-Host "SQLite native provider loaded: $interopDll" -ForegroundColor DarkGray
    & $curateScript -RepoRoot $RepoRoot -ItemDatPath $ItemDatPath
}
finally {
    [void][WloNativeDllLoader]::SetDllDirectory($null)
    $env:PATH = $oldPath
}
