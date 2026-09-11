param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$ItemDatPath = 'C:\Users\Ryans\Desktop\WLO PRIVATE SERVER\Client\WLRI\data\Item.dat'
)

$ErrorActionPreference = 'Stop'

$serverRoot = Join-Path $RepoRoot 'Server'
$catalogPath = Join-Path $serverRoot 'Data\item_mall.json'
$databasePath = Join-Path $serverRoot 'Data\ServerDataBase.db'
$sqliteDll = Join-Path $serverRoot 'DLLS\System.Data.SQLite.dll'

if (-not (Test-Path -LiteralPath $catalogPath)) { throw "Missing catalog: $catalogPath" }
if (-not (Test-Path -LiteralPath $databasePath)) { throw "Missing database: $databasePath" }
if (-not (Test-Path -LiteralPath $ItemDatPath)) { throw "Missing Item.dat: $ItemDatPath" }

function Normalize-Name([string]$Name) {
    if ($null -eq $Name) { return '' }
    return (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Read-ItemDat([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $recordSize = 47
    $items = New-Object System.Collections.Generic.List[object]

    for ($offset = 0; ($offset + $recordSize) -le $bytes.Length; $offset += $recordSize) {
        $nameLen = [Math]::Min([int]$bytes[$offset], 20)
        if ($nameLen -le 0) { $nameLen = 20 }
        $name = [Text.Encoding]::ASCII.GetString($bytes, $offset + 1, $nameLen).Trim([char]0).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $id = [BitConverter]::ToUInt16($bytes, $offset + 22)
        if ($id -eq 0) { continue }

        $items.Add([pscustomobject]@{
            ItemID = [int]$id
            Name = $name
            Normalized = Normalize-Name $name
        })
    }
    return $items
}

function Find-UniqueMatch($Items, [string[]]$Aliases) {
    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $exact = @($Items | Where-Object { $_.Normalized -eq $n })
        if ($exact.Count -eq 1) { return $exact[0] }
    }

    foreach ($alias in $Aliases) {
        $tokens = @((Normalize-Name $alias).Split(' ') | Where-Object { $_.Length -ge 3 })
        if ($tokens.Count -eq 0) { continue }
        $matches = @($Items | Where-Object {
            $candidate = $_.Normalized
            ($tokens | Where-Object { $candidate -notmatch [regex]::Escape($_) }).Count -eq 0
        })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    return $null
}

# These were mistakenly added by the first curation script. They are normal world food,
# not the pet/partner enhancement foods requested for the Item Mall.
$rawFruitNames = @(
    'Aligote','Apple','Banana','Big Apple','Brown Nut','Cantaloupe','Coconut','Coconut (Pulp)',
    'Golden Apple','Gooseberry','Green Apple','Grape','Hazelnut','Juicy Peach','Latania','Lemon',
    'Mandarin Orange','Mango','Muskmelon','Orange','Papaya','Persimmon','Pineapple','Strawberry','Watermelon'
)

# Wonderland's partner-enhancement foods from the official Partner Enhancement Bag pool.
# The Rhode Island client can use slightly different English localisation, so aliases are
# intentionally conservative and only a unique Item.dat match is accepted.
$petSpecs = @(
    @{ Label='Invincible Banana Boat'; Aliases=@('Invincible Banana Boat','Banana Boat') },
    @{ Label='Taming Pill'; Aliases=@('Taming Pill','Beast Taming Pill','Animal Taming Pill') },
    @{ Label='Barley Energy Pill'; Aliases=@('Barley Energy Pill','Barley Pill') },
    @{ Label='Fairy Honey'; Aliases=@('Fairy Honey') },
    @{ Label='Orchid Candy'; Aliases=@('Orchid Candy') },
    @{ Label='Niss Syrup'; Aliases=@('Niss Syrup','Silk Syrup') },
    @{ Label='Pirate Wine'; Aliases=@('Pirate Wine') },
    @{ Label='Old Whisky'; Aliases=@('Old Whisky','Old Whiskey','Aged Whisky','Aged Whiskey') },
    @{ Label='Elin Oil'; Aliases=@('Elin Oil','Elin Engine Oil','Engine Oil') },
    @{ Label='Roca Perfume'; Aliases=@('Roca Perfume') },
    @{ Label='Moon Bean'; Aliases=@('Moon Bean','Moon God Bean','Lunar Bean') },
    @{ Label='Strawberry Mochi'; Aliases=@('Strawberry Mochi','Strawberry Daifuku') },
    @{ Label='Devil Forbidden Fruit'; Aliases=@('Devil Forbidden Fruit','Forbidden Fruit','Devil Fruit') },
    @{ Label='Shasha Marshmallow'; Aliases=@('Shasha Marshmallow','Marshmallow') },
    @{ Label='Taiyaki'; Aliases=@('Taiyaki','Fish Cake') },
    @{ Label='Wolf Bean'; Aliases=@('Wolf Bean','Wolf Tribe Bean') },
    @{ Label='Wasabi Rice Ball'; Aliases=@('Wasabi Rice Ball','Wasabi Riceball') },
    @{ Label='Tonic Soup'; Aliases=@('Tonic Soup','Bu Zhong Yi Qi Soup') },
    @{ Label='Angel Feather'; Aliases=@('Angel Feather') },
    @{ Label='Divine Bean'; Aliases=@('Divine Bean','Magic Bean','Godly Bean') },
    @{ Label='Love Water'; Aliases=@('Love Water') },
    @{ Label='Wisdom Water'; Aliases=@('Wisdom Water') },
    @{ Label='French Black Tea'; Aliases=@('French Black Tea','French Tea') },
    @{ Label='Pet Food Pack'; Aliases=@('Pet Food Pack','Pet food pack') }
)

$json = [IO.File]::ReadAllText($catalogPath, [Text.Encoding]::UTF8)
$rows = @(ConvertFrom-Json -InputObject $json)
$itemDat = Read-ItemDat $ItemDatPath

$rawSet = @{}
foreach ($name in $rawFruitNames) { $rawSet[(Normalize-Name $name)] = $true }

$kept = New-Object System.Collections.Generic.List[object]
$removed = New-Object System.Collections.Generic.List[object]
foreach ($row in $rows) {
    if ([int]$row.is_bonus -eq 0 -and $rawSet.ContainsKey((Normalize-Name ([string]$row.item_name)))) {
        $removed.Add($row)
        continue
    }
    $kept.Add($row)
}

$matches = New-Object System.Collections.Generic.List[object]
$unresolved = New-Object System.Collections.Generic.List[string]
foreach ($spec in $petSpecs) {
    $match = Find-UniqueMatch $itemDat $spec.Aliases
    if ($match) {
        if (-not ($matches | Where-Object { $_.ItemID -eq $match.ItemID })) {
            $matches.Add([pscustomobject]@{ ItemID=$match.ItemID; Name=$match.Name; Label=$spec.Label })
        }
    }
    else {
        $unresolved.Add([string]$spec.Label)
    }
}

# Also pick up explicitly-localised Pet Fruit/Food names that may not be in the alias list.
$autoPetFoods = @($itemDat | Where-Object {
    $_.Normalized -match '\bpet\b' -and $_.Normalized -match '\b(fruit|food)\b'
})
foreach ($match in $autoPetFoods) {
    if (-not ($matches | Where-Object { $_.ItemID -eq $match.ItemID })) {
        $matches.Add([pscustomobject]@{ ItemID=$match.ItemID; Name=$match.Name; Label=$match.Name })
    }
}

$maxOrder = 0
foreach ($row in $kept) {
    if ([int]$row.is_bonus -eq 0 -and [int]$row.order_idx -gt $maxOrder) { $maxOrder = [int]$row.order_idx }
}

foreach ($match in $matches) {
    $existing = @($kept | Where-Object { [int]$_.is_bonus -eq 0 -and [int]$_.item_id -eq [int]$match.ItemID })
    if ($existing.Count -gt 0) {
        foreach ($row in $existing) {
            $row.point_cost = 0
            $row.original_price = 0
            $row.gold_cost = 0
        }
        continue
    }

    $maxOrder++
    $kept.Add([pscustomobject][ordered]@{
        item_id = [int]$match.ItemID
        item_name = [string]$match.Name
        category = 'Grocery'
        category_id = 4
        point_cost = 0
        original_price = 0
        gold_cost = 0
        count = 1
        is_hot = 0
        is_new = 1
        is_limited = 0
        on_sale = 0
        discount = 100
        badge = 1
        order_idx = $maxOrder
        is_bonus = 0
        subcategory_id = 1
        description = 'Pet / partner enhancement item'
    })
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$catalogBackup = "$catalogPath.before-petfruit-$stamp.bak"
$dbBackup = "$databasePath.before-petfruit-$stamp.bak"
Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup -Force
Copy-Item -LiteralPath $databasePath -Destination $dbBackup -Force

try {
    $jsonOut = $kept.ToArray() | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($catalogPath, $jsonOut + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    if (-not ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()
    $tx = $connection.BeginTransaction()
    try {
        foreach ($name in $rawFruitNames) {
            $delete = $connection.CreateCommand()
            $delete.Transaction = $tx
            $delete.CommandText = 'DELETE FROM item_mall WHERE is_bonus=0 AND lower(trim(item_name))=lower(trim(@name));'
            [void]$delete.Parameters.AddWithValue('@name', $name)
            [void]$delete.ExecuteNonQuery()
            $delete.Dispose()
        }

        foreach ($match in $matches) {
            $update = $connection.CreateCommand()
            $update.Transaction = $tx
            $update.CommandText = 'UPDATE item_mall SET point_cost=0, original_price=0, gold_cost=0 WHERE item_id=@id AND is_bonus=0;'
            [void]$update.Parameters.AddWithValue('@id', [int]$match.ItemID)
            $affected = $update.ExecuteNonQuery()
            $update.Dispose()

            if ($affected -eq 0) {
                $orderRow = $kept | Where-Object { [int]$_.item_id -eq [int]$match.ItemID -and [int]$_.is_bonus -eq 0 } | Select-Object -First 1
                $insert = $connection.CreateCommand()
                $insert.Transaction = $tx
                $insert.CommandText = @'
INSERT INTO item_mall
(item_id,item_name,category,category_id,point_cost,original_price,gold_cost,count,is_hot,is_new,is_limited,on_sale,discount,badge,order_idx,is_bonus,subcategory_id,description)
VALUES (@id,@name,'Grocery',4,0,0,0,1,0,1,0,0,100,1,@order,0,1,'Pet / partner enhancement item');
'@
                [void]$insert.Parameters.AddWithValue('@id', [int]$match.ItemID)
                [void]$insert.Parameters.AddWithValue('@name', [string]$match.Name)
                [void]$insert.Parameters.AddWithValue('@order', [int]$orderRow.order_idx)
                [void]$insert.ExecuteNonQuery()
                $insert.Dispose()
            }
        }

        $tx.Commit()
    }
    catch {
        try { $tx.Rollback() } catch { }
        throw
    }
    finally {
        $tx.Dispose()
        $connection.Close()
        $connection.Dispose()
    }
}
catch {
    Copy-Item -LiteralPath $catalogBackup -Destination $catalogPath -Force
    Copy-Item -LiteralPath $dbBackup -Destination $databasePath -Force
    throw
}

Write-Host ''
Write-Host 'Pet fruit correction complete.' -ForegroundColor Green
Write-Host "Removed normal fruit rows: $($removed.Count)"
Write-Host "Pet/partner enhancement items resolved: $($matches.Count)"
foreach ($match in $matches) { Write-Host "  + $($match.Name) (#$($match.ItemID))" }

if ($unresolved.Count -gt 0) {
    Write-Host ''
    Write-Host 'Pet enhancement aliases not found in this Item.dat (not added):' -ForegroundColor DarkYellow
    foreach ($name in $unresolved) { Write-Host "  - $name" }
}
