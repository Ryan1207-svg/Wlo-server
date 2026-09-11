param(
    [string]$CatalogUrl = "http://localhost:8080/api/catalog",
    [string]$OutputDirectory = "",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 8
Add-Type -AssemblyName System.Drawing

$serverRoot = Split-Path -Parent $PSScriptRoot
$projectImageDirectory = Join-Path $serverRoot "Web\images\items"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $projectImageDirectory }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WLOPrivateServer/2.0'
$wikiApi = 'https://wonderlandonline.fandom.com/api.php'

function Test-PngBytes([byte[]]$Bytes) {
    return $Bytes -and $Bytes.Length -gt 8 -and
        $Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47
}

function Test-JpegBytes([byte[]]$Bytes) {
    return $Bytes -and $Bytes.Length -gt 4 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8
}

function Test-GifBytes([byte[]]$Bytes) {
    return $Bytes -and $Bytes.Length -gt 6 -and $Bytes[0] -eq 0x47 -and $Bytes[1] -eq 0x49 -and $Bytes[2] -eq 0x46
}

function Download-Bytes([string]$Url, [string]$Referer = '') {
    $client = New-Object System.Net.WebClient
    $client.Headers['User-Agent'] = $userAgent
    $client.Headers['Accept'] = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8'
    if (-not [string]::IsNullOrWhiteSpace($Referer)) { $client.Headers['Referer'] = $Referer }
    try { return $client.DownloadData($Url) }
    finally { $client.Dispose() }
}

function Save-ImageAsPng([byte[]]$Bytes, [string]$Destination) {
    if (Test-PngBytes $Bytes) {
        [IO.File]::WriteAllBytes($Destination, $Bytes)
        return
    }

    if (-not ((Test-JpegBytes $Bytes) -or (Test-GifBytes $Bytes))) {
        throw 'Downloaded response was not a PNG/JPEG/GIF image (likely an HTML/CDN response).'
    }

    $stream = New-Object IO.MemoryStream(,$Bytes)
    try {
        $image = [Drawing.Image]::FromStream($stream)
        try { $image.Save($Destination, [Drawing.Imaging.ImageFormat]::Png) }
        finally { $image.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Get-WloHubImage([int]$ItemId) {
    $pageUrl = "https://wlohub.com/items/$ItemId"
    try {
        $page = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -Headers @{ 'User-Agent'=$userAgent } -TimeoutSec 20
        $html = [System.Net.WebUtility]::HtmlDecode([string]$page.Content)

        # WLOHUB item pages use /images/items/<image-number>.png. The image number
        # is not always the same as the WLO item ID, so scrape it from the item page.
        $matches = [regex]::Matches($html, '(?i)(?:src|href)=["'']([^"'']*/images/items/\d+\.png(?:\?[^"'']*)?)["'']')
        if ($matches.Count -eq 0) { return $null }

        foreach ($m in $matches) {
            $url = $m.Groups[1].Value
            if ($url.StartsWith('//')) { $url = 'https:' + $url }
            elseif ($url.StartsWith('/')) { $url = 'https://wlohub.com' + $url }
            elseif (-not $url.StartsWith('http')) { $url = 'https://wlohub.com/' + $url.TrimStart('/') }

            try {
                $bytes = Download-Bytes $url $pageUrl
                if (Test-PngBytes $bytes) {
                    return [pscustomobject]@{ Title="WLOHUB item #$ItemId"; Url=$url; Bytes=$bytes; Source='WLOHUB' }
                }
            }
            catch { }
        }
    }
    catch { }
    return $null
}

function Invoke-WikiApi([hashtable]$Parameters) {
    $Parameters['format'] = 'json'
    $query = ($Parameters.GetEnumerator() | ForEach-Object {
        [uri]::EscapeDataString([string]$_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    Invoke-RestMethod -Uri ($wikiApi + '?' + $query) -Headers @{ 'User-Agent'=$userAgent } -Method Get -TimeoutSec 25
}

function Get-WikiPageImage([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    try {
        $result = Invoke-WikiApi @{
            action='query'; redirects='1'; prop='pageimages'; piprop='thumbnail|original'; pithumbsize='320'; titles=$Title
        }
        $pages = @($result.query.pages.PSObject.Properties.Value)
        if ($pages.Count -eq 0) { return $null }
        $page = $pages | Select-Object -First 1
        if ($page.missing -ne $null) { return $null }
        $url = $null
        if ($page.original -and $page.original.source) { $url = [string]$page.original.source }
        elseif ($page.thumbnail -and $page.thumbnail.source) { $url = [string]$page.thumbnail.source }
        if (-not $url) { return $null }

        $bytes = Download-Bytes $url 'https://wonderlandonline.fandom.com/'
        if ((Test-PngBytes $bytes) -or (Test-JpegBytes $bytes) -or (Test-GifBytes $bytes)) {
            return [pscustomobject]@{ Title=[string]$page.title; Url=$url; Bytes=$bytes; Source='Fandom' }
        }
    }
    catch { }
    return $null
}

function Search-WikiImage([string]$Name) {
    $candidates = New-Object Collections.Generic.List[string]
    if ($Name) { $candidates.Add($Name.Trim()) }
    $clean = ($Name -replace '\s+[xX]\s*\d+\s*$', '' -replace '\s*\([^)]*\)\s*$', '').Trim()
    if ($clean -and -not $candidates.Contains($clean)) { $candidates.Add($clean) }

    foreach ($candidate in $candidates) {
        $direct = Get-WikiPageImage $candidate
        if ($direct) { return $direct }
    }

    foreach ($candidate in $candidates) {
        try {
            $search = Invoke-WikiApi @{ action='query'; list='search'; srnamespace='0'; srlimit='5'; srsearch=$candidate }
            foreach ($hit in @($search.query.search)) {
                $img = Get-WikiPageImage ([string]$hit.title)
                if ($img) { return $img }
            }
        }
        catch { }
    }
    return $null
}

function Get-LocalCatalog {
    $jsonPath = Join-Path $serverRoot 'Data\item_mall.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return @() }

    try {
        $jsonText = [IO.File]::ReadAllText($jsonPath, [Text.Encoding]::UTF8)
        $parsed = ConvertFrom-Json -InputObject $jsonText
        $pending = New-Object Collections.Queue
        $pending.Enqueue($parsed)
        $rows = New-Object Collections.Generic.List[object]

        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            if ($null -eq $current) { continue }
            if ($current -is [System.Array]) {
                foreach ($entry in $current) { $pending.Enqueue($entry) }
                continue
            }
            $itemsProperty = $current.PSObject.Properties['items']
            if ($itemsProperty -and $null -ne $itemsProperty.Value) {
                $pending.Enqueue($itemsProperty.Value)
                continue
            }
            $rows.Add($current)
        }

        $result = New-Object Collections.Generic.List[object]
        foreach ($row in $rows) {
            $idValue = $null; $nameValue = $null
            if ($row.PSObject.Properties['id']) { $idValue = $row.id }
            elseif ($row.PSObject.Properties['ItemID']) { $idValue = $row.ItemID }
            elseif ($row.PSObject.Properties['item_id']) { $idValue = $row.item_id }

            if ($row.PSObject.Properties['name']) { $nameValue = $row.name }
            elseif ($row.PSObject.Properties['ItemName']) { $nameValue = $row.ItemName }
            elseif ($row.PSObject.Properties['item_name']) { $nameValue = $row.item_name }

            $id = 0
            if ($null -ne $idValue) { [void][int]::TryParse([string]$idValue, [ref]$id) }
            $name = if ($null -ne $nameValue) { [string]$nameValue } else { '' }
            if ($id -gt 0 -and -not [string]::IsNullOrWhiteSpace($name)) {
                $result.Add([pscustomobject]@{ id=$id; name=$name.Trim() })
            }
        }
        Write-Host "Loaded $($result.Count) Item Mall rows from Server\Data\item_mall.json."
        return @($result.ToArray())
    }
    catch {
        Write-Warning "Could not read local Data\item_mall.json: $($_.Exception.Message)"
        return @()
    }
}

function Mirror-ToRuntime([string]$SourceDirectory) {
    $targets = New-Object Collections.Generic.List[string]
    $exeFiles = @(Get-ChildItem -LiteralPath (Join-Path $serverRoot 'bin') -Recurse -File -Filter 'Wonderland Private Server.exe' -ErrorAction SilentlyContinue)
    foreach ($exe in $exeFiles) {
        $target = Join-Path $exe.DirectoryName 'Web\images\items'
        if (-not $targets.Contains($target)) { $targets.Add($target) }
    }
    foreach ($buildFolder in @('Debug','Release')) {
        $target = Join-Path $serverRoot ("bin\" + $buildFolder + "\Web\images\items")
        if (-not $targets.Contains($target)) { $targets.Add($target) }
    }

    foreach ($target in $targets) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Get-ChildItem -LiteralPath $SourceDirectory -File -Filter '*.png' -ErrorAction SilentlyContinue | Copy-Item -Destination $target -Force
        $count = @(Get-ChildItem -LiteralPath $target -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
        Write-Host "Runtime image cache: $target ($count PNG files)"
    }
}

Write-Host "Reading Item Mall catalog from $CatalogUrl ..."
$catalog = @()
try { $catalog = @(Invoke-RestMethod -Uri $CatalogUrl -Headers @{ 'User-Agent'=$userAgent } -TimeoutSec 10) }
catch {
    Write-Warning "Live catalog was unavailable; trying Server\Data\item_mall.json instead."
    $catalog = @(Get-LocalCatalog)
}

$flat = New-Object Collections.Generic.List[object]
$q = New-Object Collections.Queue
$q.Enqueue($catalog)
while ($q.Count -gt 0) {
    $entry = $q.Dequeue()
    if ($null -eq $entry) { continue }
    if ($entry -is [System.Array]) { foreach ($child in $entry) { $q.Enqueue($child) } }
    else { $flat.Add($entry) }
}

$catalog = @($flat.ToArray() | Where-Object { $_.id -and $_.name } | Sort-Object id -Unique)
if ($catalog.Count -eq 0) {
    Write-Error "No Item Mall catalog could be loaded from either the running portal or Server\Data\item_mall.json."
    exit 1
}

Write-Host "Found $($catalog.Count) unique Item Mall item IDs."
Write-Host "Project image cache: $OutputDirectory"

$manifest = New-Object Collections.Generic.List[object]
$downloaded = 0; $existing = 0; $missing = 0

foreach ($item in $catalog) {
    $id = [int]$item.id
    $name = [string]$item.name
    $destination = Join-Path $OutputDirectory ($id.ToString() + '.png')

    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        $existing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; source=''; imageUrl=''; status='existing' })
        continue
    }

    $match = Get-WloHubImage $id
    if (-not $match) { $match = Search-WikiImage $name }

    if (-not $match) {
        Write-Warning "No usable image found: #$id $name"
        $missing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; source=''; imageUrl=''; status='missing' })
        continue
    }

    try {
        Save-ImageAsPng $match.Bytes $destination
        Write-Host "Downloaded #$id $name <- $($match.Source)"
        $downloaded++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; source=$match.Source; imageUrl=$match.Url; status='downloaded' })
    }
    catch {
        Write-Warning "Failed #$id $name : $($_.Exception.Message)"
        $missing++
        $manifest.Add([pscustomobject]@{ id=$id; name=$name; source=$match.Source; imageUrl=$match.Url; status='failed' })
    }

    Start-Sleep -Milliseconds 75
}

$manifestPath = Join-Path $OutputDirectory 'item-image-manifest.csv'
$manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $manifestPath
Mirror-ToRuntime $OutputDirectory

Write-Host ''
Write-Host "Done. Downloaded: $downloaded | Existing: $existing | Missing/failed: $missing"
Write-Host "Images: $OutputDirectory"
Write-Host "Manifest: $manifestPath"
Write-Host 'The downloader now uses WLOHUB item pages by real WLO item ID first, with the Wonderland Wiki only as a fallback.'
Write-Host 'Restart the WLO server, then hard-refresh /shop (Ctrl+F5).'
