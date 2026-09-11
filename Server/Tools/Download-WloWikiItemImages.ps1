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

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = $projectImageDirectory
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$wikiApi = 'https://wonderlandonline.fandom.com/api.php'
$userAgent = 'WLOPrivateServer/1.2 (personal-use item image cache)'

function Invoke-WikiApi([hashtable]$Parameters) {
    $Parameters['format'] = 'json'
    $query = ($Parameters.GetEnumerator() | ForEach-Object {
        [uri]::EscapeDataString([string]$_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    Invoke-RestMethod -Uri ($wikiApi + '?' + $query) -Headers @{ 'User-Agent' = $userAgent } -Method Get -TimeoutSec 25
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
    if ([string]::IsNullOrWhiteSpace($SearchText)) { return $null }

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
        if (-not $bytes -or $bytes.Length -lt 32) {
            throw "Downloaded image was empty or invalid."
        }

        $ms = New-Object System.IO.MemoryStream(,$bytes)
        try {
            $image = [System.Drawing.Image]::FromStream($ms)
            try {
                $tmp = $Destination + '.tmp.png'
                $image.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
                Move-Item -LiteralPath $tmp -Destination $Destination -Force
            }
            finally { $image.Dispose() }
        }
        finally { $ms.Dispose() }
    }
    finally { $client.Dispose() }
}

function Get-LocalCatalog {
    $jsonPath = Join-Path $serverRoot 'Data\item_mall.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) { return @() }

    try {
        # Windows PowerShell 5.1 can return a top-level JSON array as one nested
        # System.Object[] when ConvertFrom-Json is wrapped by @(...). That made
        # $row.item_id become an Object[] containing every ID in the catalog.
        # Read once and explicitly flatten all JSON array levels instead.
        $jsonText = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
        $parsed = ConvertFrom-Json -InputObject $jsonText

        $pending = New-Object System.Collections.Queue
        $pending.Enqueue($parsed)
        $rows = New-Object System.Collections.Generic.List[object]

        while ($pending.Count -gt 0) {
            $current = $pending.Dequeue()
            if ($null -eq $current) { continue }

            if ($current -is [System.Array]) {
                foreach ($entry in $current) {
                    $pending.Enqueue($entry)
                }
                continue
            }

            # Also tolerate a future wrapper such as { "items": [ ... ] }.
            $itemsProperty = $current.PSObject.Properties['items']
            if ($itemsProperty -and $null -ne $itemsProperty.Value) {
                $pending.Enqueue($itemsProperty.Value)
                continue
            }

            $rows.Add($current)
        }

        $result = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) {
            $idValue = $null
            $nameValue = $null

            if ($row.PSObject.Properties['id']) { $idValue = $row.id }
            elseif ($row.PSObject.Properties['ItemID']) { $idValue = $row.ItemID }
            elseif ($row.PSObject.Properties['item_id']) { $idValue = $row.item_id }

            if ($row.PSObject.Properties['name']) { $nameValue = $row.name }
            elseif ($row.PSObject.Properties['ItemName']) { $nameValue = $row.ItemName }
            elseif ($row.PSObject.Properties['item_name']) { $nameValue = $row.item_name }

            $id = 0
            if ($null -ne $idValue) {
                [void][int]::TryParse([string]$idValue, [ref]$id)
            }

            $name = if ($null -ne $nameValue) { [string]$nameValue } else { '' }
            if ($id -gt 0 -and -not [string]::IsNullOrWhiteSpace($name)) {
                $result.Add([pscustomobject]@{ id = $id; name = $name.Trim() })
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
    $targets = New-Object System.Collections.Generic.List[string]

    # RegistrationServer checks AppDomain.CurrentDomain.BaseDirectory\Web\images\items first.
    # Mirror the cache beside every built server EXE so an empty runtime Web folder can never
    # hide the project-level cache.
    $exeFiles = @(Get-ChildItem -LiteralPath (Join-Path $serverRoot 'bin') -Recurse -File -Filter 'Wonderland Private Server.exe' -ErrorAction SilentlyContinue)
    foreach ($exe in $exeFiles) {
        $target = Join-Path $exe.DirectoryName 'Web\images\items'
        if (-not $targets.Contains($target)) { $targets.Add($target) }
    }

    # Include the normal classic .NET build folders even before the first EXE scan succeeds.
    foreach ($buildFolder in @('Debug', 'Release')) {
        $target = Join-Path $serverRoot ("bin\" + $buildFolder + "\Web\images\items")
        if (-not $targets.Contains($target)) { $targets.Add($target) }
    }

    foreach ($target in $targets) {
        try {
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Get-ChildItem -LiteralPath $SourceDirectory -File -Filter '*.png' -ErrorAction SilentlyContinue |
                Copy-Item -Destination $target -Force

            $manifestSource = Join-Path $SourceDirectory 'wiki-image-manifest.csv'
            if (Test-Path -LiteralPath $manifestSource) {
                Copy-Item -LiteralPath $manifestSource -Destination (Join-Path $target 'wiki-image-manifest.csv') -Force
            }

            $count = @(Get-ChildItem -LiteralPath $target -File -Filter '*.png' -ErrorAction SilentlyContinue).Count
            Write-Host "Runtime image cache: $target ($count PNG files)"
        }
        catch {
            Write-Warning "Could not mirror images to '$target': $($_.Exception.Message)"
        }
    }
}

Write-Host "Reading Item Mall catalog from $CatalogUrl ..."
$catalog = @()
try {
    $catalog = @(Invoke-RestMethod -Uri $CatalogUrl -Headers @{ 'User-Agent' = $userAgent } -TimeoutSec 10)
}
catch {
    Write-Warning "Live catalog was unavailable; trying Server\Data\item_mall.json instead."
    $catalog = @(Get-LocalCatalog)
}

# Flatten the live response too, because Windows PowerShell 5.1 can preserve
# the JSON array as one nested object when Invoke-RestMethod is wrapped by @().
$flatCatalog = New-Object System.Collections.Generic.List[object]
$catalogQueue = New-Object System.Collections.Queue
$catalogQueue.Enqueue($catalog)
while ($catalogQueue.Count -gt 0) {
    $entry = $catalogQueue.Dequeue()
    if ($null -eq $entry) { continue }
    if ($entry -is [System.Array]) {
        foreach ($child in $entry) { $catalogQueue.Enqueue($child) }
    }
    else {
        $flatCatalog.Add($entry)
    }
}

$catalog = @($flatCatalog.ToArray() | Where-Object { $_.id -and $_.name } | Sort-Object id -Unique)
if ($catalog.Count -eq 0) {
    Write-Error "No Item Mall catalog could be loaded from either the running portal or Server\Data\item_mall.json."
    exit 1
}

Write-Host "Found $($catalog.Count) unique Item Mall item IDs."
Write-Host "Project image cache: $OutputDirectory"

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
    try {
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
    }
    catch {
        Write-Warning "Wiki lookup failed for #$id $name : $($_.Exception.Message)"
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

    Start-Sleep -Milliseconds 125
}

$manifestPath = Join-Path $OutputDirectory 'wiki-image-manifest.csv'
$manifest | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $manifestPath
Mirror-ToRuntime $OutputDirectory

Write-Host ''
Write-Host "Done. Downloaded: $downloaded | Existing: $existing | Missing/failed: $missing"
Write-Host "Images: $OutputDirectory"
Write-Host "Manifest: $manifestPath"
Write-Host "Restart the WLO server (or hard-refresh the browser after the cache finishes) so the Item Mall uses the mirrored images."