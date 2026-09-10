param(
    [string]$ClientRoot = "C:\Users\Ryans\Desktop\WLO PRIVATE SERVER\Client\WLRI",
    [string]$OutputPath = "$env:USERPROFILE\Desktop\wlo-item-assets-report.txt"
)

$ErrorActionPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $ClientRoot)) {
    Write-Error "Client root not found: $ClientRoot"
    exit 1
}

$files = Get-ChildItem -LiteralPath $ClientRoot -Recurse -File -Force

$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("WLO Rhode Island client asset scan")
$null = $sb.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$null = $sb.AppendLine("Client: $ClientRoot")
$null = $sb.AppendLine("Total files: $($files.Count)")
$null = $sb.AppendLine('')

$null = $sb.AppendLine('=== EXTENSION SUMMARY ===')
$groups = $files | Group-Object { if ([string]::IsNullOrWhiteSpace($_.Extension)) { '<no extension>' } else { $_.Extension.ToLowerInvariant() } } |
    ForEach-Object {
        [pscustomobject]@{
            Extension = $_.Name
            Count = $_.Count
            Bytes = ($_.Group | Measure-Object Length -Sum).Sum
        }
    } | Sort-Object Bytes -Descending
foreach ($g in $groups) {
    $null = $sb.AppendLine(("{0,-18} {1,7} files  {2,14:N0} bytes" -f $g.Extension, $g.Count, $g.Bytes))
}

$null = $sb.AppendLine('')
$null = $sb.AppendLine('=== TOP 200 LARGEST FILES ===')
foreach ($f in ($files | Sort-Object Length -Descending | Select-Object -First 200)) {
    $null = $sb.AppendLine(("{0,14:N0}  {1}" -f $f.Length, $f.FullName))
}

$null = $sb.AppendLine('')
$null = $sb.AppendLine('=== ROOT-LEVEL FILES ===')
foreach ($f in ($files | Where-Object { $_.DirectoryName -eq $ClientRoot } | Sort-Object Name)) {
    $null = $sb.AppendLine(("{0,14:N0}  {1}" -f $f.Length, $f.FullName))
}

$null = $sb.AppendLine('')
$null = $sb.AppendLine('=== LIKELY GRAPHIC / ARCHIVE / ITEM ASSETS ===')
$rx = '(?i)(item|icon|sprite|image|graphic|texture|atlas|mall|shop|goods|virtual|package|pack|resource|res|odd|data|ui|pic|bmp|png|jpg|gif|pak|img|spr|wdf|bin|dat)'
foreach ($f in ($files | Where-Object { $_.Name -match $rx -or $_.DirectoryName -match '(?i)(item|icon|sprite|texture|atlas)' } | Sort-Object FullName)) {
    $null = $sb.AppendLine(("{0,14:N0}  {1}" -f $f.Length, $f.FullName))
}

# Pull useful printable strings from the client executable. This often reveals
# the real item-icon path/pattern even when graphics are stored in a custom pack.
$alogin = $files | Where-Object { $_.Name -ieq 'aLogin.exe' } | Select-Object -First 1
if ($alogin) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('=== ALOGIN ASSET-RELATED STRINGS ===')
    $bytes = [System.IO.File]::ReadAllBytes($alogin.FullName)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
    $strings = [regex]::Matches($ascii, '[ -~]{4,}') | ForEach-Object { $_.Value }
    $hits = $strings | Where-Object { $_ -match '(?i)(item|icon|sprite|\.bmp|\.png|\.jpg|\.gif|\.dat|\.pak|\.img|\.spr|\.wdf|odd)' } | Sort-Object -Unique
    foreach ($s in ($hits | Select-Object -First 1000)) {
        $null = $sb.AppendLine($s)
    }
}
else {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('aLogin.exe was not found under the supplied client root.')
}

[System.IO.File]::WriteAllText($OutputPath, $sb.ToString(), [System.Text.Encoding]::UTF8)
Write-Host "Done. Report written to: $OutputPath"
