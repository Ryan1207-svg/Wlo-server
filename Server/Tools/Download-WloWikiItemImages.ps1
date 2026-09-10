param(
    [string]$CatalogUrl = "http://localhost:8080/api/catalog",
    [string]$OutputDirectory = "",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Drawing

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $serverRoot = Split-Path -Parent $PSScriptRoot
    $OutputDirectory = Join-Path $serverRoot "Web\images\items"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$wikiApi = 'https://wonderlandonline.fandom.com/api.php'
$userAgent = 'WLOPrivateServer/1.0 (personal-use item image cache)'

function Invoke-WikiApi([hashtable]$Parameters) {
    $Parameters['format'] = 'json'
    $query = ($Parameters.GetEnumerator() | ForEach-Object {
        [uri]::EscapeDataString([string]$_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    Invoke-RestMethod -Uri ($wikiApi + '?' + $query) -Headers @{ 'User-Agent' = $userAgent } -Method Get
}

function Get-PageImage([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    $result = Invoke-WikiApi @{
        action = 'query'
        redirects = '1'
        prop = 'pageimages'
        piprop = 'thumbnail|original'
        pithumbsize = '320'
        titles = $Title
    }

    $pages = @($result.query.pages.PSObject.Properties.Value)
    if ($pages.Count -eq 0) { return $null }
    $page = $pages | Select-Object -First 1
    if ($page.missing -ne $null) { return $null }

    $url = $null
    if ($page.thumbnail -and $page.thumbnail.source) { $url = [string]$page.thumbnail.source }
    elseif ($page.original -and $page.original.source) { $url = [string]$page.original.source }
    if ([string]::IsNullOrWhiteSpace($url)) { return $null }

    [pscustomobject]@{ Title = [string]$page.title; Url = $url }
}

function Search-PageImage([string]$SearchText) {
    $search = Invoke-WikiApi @{
        action = 'query'
        list = 'search'
        srnamespace = '0'
        srlimit = '5'
        srsearch = $SearchText
    }
    foreach ($hit in @($search.query.search)) {
        $image = Get-PageImage ([string]$hit.title)
        if ($image) { return $image }
    }
    return $null
}

function Get-SearchCandidates([string]$Name) {
    $list = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Name)) { $list.Add($Name.Trim()) }

    $clean = $Name -replace '\s+[xX]\s*\d+\s*$', ''
    $clean = $clean -replace '\s*\([^)]*\)\s*$', ''
    $clean = $clean -replace '\s+-\s+.*$', ''
    $clean = $clean.Trim()
    if ($clean -and -not $list.Contains($clean)) { $list.Add($clean) }

    return $list
}

function Save-AsPng([string]$Url, [string]$Destination) {
    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = $userAgent
    try {
        $bytes = $client.DownloadData($Url)
        $ms = New-Object System.IO.MemoryStream(,$bytes)
        try {
            $image = [System.Drawing.Image]::FromStream($ms)
            try { $image.Save($Destination, [System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $image.Dispose() }
        }
        finally { $ms.Dispose() }
    }
    finally { $client.Dispose() }
}

Write-Host "Reading live Item Mall catalog from $CatalogUrl ..."
try {
    $catalog = @(Invoke-RestMethod -Uri $CatalogUrl -Headers @{ 'User-Agent' = $userAgent })
}
catch {
    Write-Error "Could not read the Item Mall catalog. Start the WLO server first, then run this script again. $($_.Exception.Message)"
    exit 1
}

$catalog = @($catalog | Where-Object { $_.id -and $_.name } | Sort-Object id -Unique)
Write-Host "Found $($catalog.Count) unique Item Mall item IDs."

$manifest = New-Object System.Collections.Generic.List[object]
$downloaded = 0
$missing = 0
$existing = 0

foreach ($item in $catalog) {
    $id = [int]$item.id
    $name = [string]$item.name
    $destination = Join-Path $OutputDirectory ($id.ToString() + '.png')

    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        $existing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; wikiTitle=''; source=''; status='existing' })
        continue
    }

    $match = $null
    foreach ($candidate in (Get-SearchCandidates $name)) {
        $match = Get-PageImage $candidate
        if ($match) { break }
    }

    if (-not $match) {
        foreach ($candidate in (Get-SearchCandidates $name)) {
            $match = Search-PageImage $candidate
            if ($match) { break }
        }
    }

    if (-not $match) {
        Write-Warning "No wiki image found: #$id $name"
        $missing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; wikiTitle=''; source=''; status='missing' })
        continue
    }

    try {
        Save-AsPng $match.Url $destination
        Write-Host "Downloaded #$id $name <- $($match.Title)"
        $downloaded++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; wikiTitle=$match.Title; source=$match.Url; status='downloaded' })
    }
    catch {
        Write-Warning "Failed #$id $name : $($_.Exception.Message)"
        $missing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; wikiTitle=$match.Title; source=$match.Url; status='failed' })
    }

    Start-Sleep -Milliseconds 150
}

$manifestPath = Join-Path $OutputDirectory 'wiki-image-manifest.csv'
$manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $manifestPath

Write-Host ''
Write-Host "Done. Downloaded: $downloaded | Existing: $existing | Missing/failed: $missing"
Write-Host "Images: $OutputDirectory"
Write-Host "Manifest: $manifestPath"
