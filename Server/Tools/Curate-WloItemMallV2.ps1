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
if (-not (Test-Path -LiteralPath $sqliteDll)) { throw "Missing SQLite provider: $sqliteDll" }
if (-not (Test-Path -LiteralPath $ItemDatPath)) { throw "Missing Rhode Island Item.dat: $ItemDatPath" }

if (Get-Process -Name 'Wonderland Private Server' -ErrorAction SilentlyContinue) {
    throw 'Close Wonderland Private Server.exe before running Item Mall curation.'
}

function Normalize-Name([string]$Name) {
    if ($null -eq $Name) { return '' }
    return (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Read-Catalog([string]$Path) {
    $json = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $parsed = ConvertFrom-Json -InputObject $json
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($parsed)
    $rows = New-Object System.Collections.Generic.List[object]

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($null -eq $current) { continue }
        if ($current -is [System.Array]) {
            foreach ($entry in $current) { $queue.Enqueue($entry) }
            continue
        }
        $rows.Add($current)
    }

    return $rows
}

function Decode-WloWord([UInt16]$Value) {
    return [int]((([int]$Value -bxor 0xEFC3) - 9) -band 0xFFFF)
}

function Read-RhodeIslandItemDat([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $recordSize = 457

    # The Rhode Island Item.dat used by this project is 408 bytes of header data
    # followed by 457-byte original WLO item records. Derive the header instead
    # of hard-coding it so the parser remains safe if the client build changes.
    $headerSize = $bytes.Length % $recordSize
    $payloadSize = $bytes.Length - $headerSize
    if ($payloadSize -le 0 -or ($payloadSize % $recordSize) -ne 0) {
        throw "Item.dat size $($bytes.Length) does not contain a valid 457-byte record payload."
    }

    $recordCount = [int]($payloadSize / $recordSize)
    Write-Host "Detected Item.dat header: $headerSize bytes; records: $recordCount" -ForegroundColor DarkGray

    $items = New-Object System.Collections.Generic.List[object]
    for ($record = 0; $record -lt $recordCount; $record++) {
        $offset = $headerSize + ($record * $recordSize)
        $nameLen = [int]$bytes[$offset]
        if ($nameLen -le 0 -or $nameLen -gt 20) { continue }

        $chars = New-Object char[] $nameLen
        $valid = $true
        for ($n = 0; $n -lt $nameLen; $n++) {
            $value = [int]$bytes[$offset + (20 - $n)]
            if ($value -lt 32 -or $value -gt 126) {
                $valid = $false
                break
            }
            $chars[$n] = [char]$value
        }
        if (-not $valid) { continue }

        $name = (-join $chars).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $rawId = [BitConverter]::ToUInt16($bytes, $offset + 22)
        $itemId = Decode-WloWord $rawId
        if ($itemId -le 0) { continue }

        $items.Add([pscustomobject]@{
            ItemID = $itemId
            Name = $name
            Normalized = Normalize-Name $name
        })
    }

    return $items
}

function Find-ItemMatch($Items, [string[]]$Aliases) {
    foreach ($alias in $Aliases) {
        $needle = Normalize-Name $alias
        $matches = @($Items | Where-Object { $_.Normalized -eq $needle })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    foreach ($alias in $Aliases) {
        $needle = Normalize-Name $alias
        $matches = @($Items | Where-Object {
            $_.Normalized.StartsWith($needle) -or $needle.StartsWith($_.Normalized)
        })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    return $null
}

function New-Spec([string]$Label, [string[]]$Aliases, [string]$Category, [int]$CategoryID, [string]$Group) {
    return [pscustomobject]@{
        Label = $Label
        Aliases = $Aliases
        Category = $Category
        CategoryID = $CategoryID
        Group = $Group
    }
}

function Get-Value($Object, [string]$Property, $Default) {
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Property]
    if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
    return $prop.Value
}

$removeNames = @(
    'Cyan Bone Dual Fan Bag','Gem Dharma Sword Bag','Cat Shoes Lucky Bag','Dark Dharma King Bag',
    'Pink Ribbon Lucky Bag','Snow Songstress Bag','Chinese General Bag','Roman Warrior Bag',
    'New Companion Gear Bag','Battle Boost Lucky Bag','Class Weapon Lucky Bag','Tongpu Box',
    'Dharma Sword Box','Beast Devil Fork Box','Spirit Devil Fork Box','Brilliant Staff Box',
    'Great Angel Wings Box','Gift Pack','War Pack','7 Colors Egg','Potato Chips Pack (50)',
    'Fried Chicken Pack (50)','Trilobite Pack','Naughty Monkey Pack','Naughty Dolphin Pack',
    'Ghost War Horse Pack','Training Box','Chili Sauce','Wasabi','Enhanced Skin Milk',
    'Newbie Box','Special Shadow Pack','Golden Shadow Pack'
)

# Remove the normal world fruit entries accidentally added by the first script.
$rawFruitNames = @(
    'Aligote','Apple','Banana','Big Apple','Brown Nut','Cantaloupe','Coconut','Coconut (Pulp)',
    'Golden Apple','Gooseberry','Green Apple','Grape','Hazelnut','Juicy Peach','Latania','Lemon',
    'Mandarin Orange','Mango','Muskmelon','Orange','Papaya','Persimmon','Pineapple','Strawberry','Watermelon'
)

$requestedSpecs = @(
    (New-Spec 'Super Potential Pill' @('Super Potential Pill','Super Potential') 'Grocery' 3 'Requested'),
    (New-Spec 'Shadow Pestle' @('Shadow Pestle') 'Weaponry' 1 'Requested'),
    (New-Spec 'Dragon Spar' @('Dragon Spar') 'Grocery' 3 'Requested'),
    (New-Spec '15X Holy EXP Potion' @('15X Holy EXP Potion','15X EXP Potion','15 Holy EXP Potion') 'Grocery' 3 'Requested'),
    (New-Spec 'Snow Girl Pack' @('Snow Girl Pack','Snow Girl Lucky Bag','Snow Girl Bag') 'Grocery' 3 'Requested'),
    (New-Spec 'Xmas Fork' @('Xmas Fork','X-mas Fork','Christmas Fork') 'Weaponry' 1 'Requested'),
    (New-Spec 'Forest Fork' @('Forest Fork') 'Weaponry' 1 'Requested'),
    (New-Spec "Soul's Reapers" @("Soul's Reapers",'Soul Reaper','Soul Reapers','Souls Reaper','Souls Reapers') 'Weaponry' 1 'Requested'),
    (New-Spec 'Attack Pestle' @('Attack Pestle','Attack Pestle Box','Attack Pestal') 'Weaponry' 1 'Requested'),
    (New-Spec '2X EXP Gold Card' @('2X EXP Gold Card','Gold Card') 'Grocery' 3 'Requested'),
    (New-Spec 'Snow Ears' @('Snow Ears') 'Armory' 2 'Requested')
)

# These are the individual partner/pet enhancement foods, not ordinary map fruit.
$petSpecs = @(
    (New-Spec 'Banana Boat' @('Banana Boat','Invincible Banana Boat') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Taming Pill' @('Taming Pill','Beast Taming Pill','Animal Taming Pill') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Barley Energy Pill' @('Barley Energy Pill','Barley Pill') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Fairy Honey' @('Fairy Honey') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Orchid Candy' @('Orchid Candy') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Niss Syrup' @('Niss Syrup','Silk Syrup') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Pirate Wine' @('Pirate Wine') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Old Whisky' @('Old Whisky','Old Whiskey','Aged Whisky','Aged Whiskey') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Elin Oil' @('Elin Oil','Elin Engine Oil','Engine Oil') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Roca Perfume' @('Roca Perfume') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Moon Bean' @('Moon Bean','Moon God Bean','Lunar Bean') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Strawberry Mochi' @('Strawberry Mochi','Strawberry Daifuku') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Forbidden Fruit' @('Forbidden Fruit','Devil Forbidden Fruit','Devil Fruit') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Shasha Marshmallow' @('Shasha Marshmallow','Marshmallow') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Taiyaki' @('Taiyaki','Fish Cake') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Wolf Bean' @('Wolf Bean','Wolf Tribe Bean') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Wasabi Rice Ball' @('Wasabi Rice Ball','Wasabi Riceball') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Tonic Soup' @('Tonic Soup','Bu Zhong Yi Qi Soup') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Angel Feather' @('Angel Feather') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Divine Bean' @('Divine Bean','Magic Bean','Godly Bean') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Love Water' @('Love Water') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'Wisdom Water' @('Wisdom Water') 'Grocery' 3 'Pet Fruit'),
    (New-Spec 'French Black Tea' @('French Black Tea','French Tea') 'Grocery' 3 'Pet Fruit')
)

Write-Host "Reading Item Mall catalog: $catalogPath"
$rows = Read-Catalog $catalogPath
Write-Host "Catalog rows loaded: $($rows.Count)"

Write-Host "Reading Rhode Island Item.dat: $ItemDatPath"
$itemDat = Read-RhodeIslandItemDat $ItemDatPath
Write-Host "Decoded named Item.dat records: $($itemDat.Count)"

# Sanity-check the decoder against an item whose server ID is already known.
$potentialCheck = Find-ItemMatch $itemDat @('Potential Pill')
if ($potentialCheck) {
    Write-Host "Decoder check: Potential Pill -> #$($potentialCheck.ItemID)" -ForegroundColor DarkGray
    if ([int]$potentialCheck.ItemID -ne 34269) {
        Write-Warning "Potential Pill decoded as #$($potentialCheck.ItemID), while this server catalog uses #34269. The client/server Item.dat may not be the same build."
    }
}
else {
    Write-Warning 'Decoder check could not find Potential Pill in this Item.dat.'
}

$removeSet = @{}
foreach ($name in ($removeNames + $rawFruitNames)) { $removeSet[(Normalize-Name $name)] = $true }

$curated = New-Object System.Collections.Generic.List[object]
$removed = New-Object System.Collections.Generic.List[object]
foreach ($row in $rows) {
    $name = [string](Get-Value $row 'item_name' '')
    if ($removeSet.ContainsKey((Normalize-Name $name))) {
        $removed.Add($row)
        continue
    }

    # Free testing mode for BOTH normal and bonus Item Mall listings.
    $row.point_cost = 0
    $row.original_price = 0
    $row.gold_cost = 0
    $row.on_sale = 0
    $row.discount = 100
    $curated.Add($row)
}

$resolved = New-Object System.Collections.Generic.List[object]
$unresolved = New-Object System.Collections.Generic.List[object]
$allSpecs = @($requestedSpecs + $petSpecs)

foreach ($spec in $allSpecs) {
    $existingAliases = @($spec.Aliases | ForEach-Object { Normalize-Name $_ })
    $existing = @($curated | Where-Object {
        [int](Get-Value $_ 'is_bonus' 0) -eq 0 -and $existingAliases -contains (Normalize-Name ([string](Get-Value $_ 'item_name' '')))
    })

    if ($existing.Count -gt 0) {
        foreach ($row in $existing) {
            $row.point_cost = 0
            $row.original_price = 0
            $row.gold_cost = 0
        }
        $resolved.Add([pscustomobject]@{
            Spec = $spec
            ItemID = [int](Get-Value $existing[0] 'item_id' 0)
            ItemDatName = [string](Get-Value $existing[0] 'item_name' $spec.Label)
            Existing = $true
        })
        continue
    }

    $match = Find-ItemMatch $itemDat $spec.Aliases
    if ($match) {
        $resolved.Add([pscustomobject]@{
            Spec = $spec
            ItemID = [int]$match.ItemID
            ItemDatName = [string]$match.Name
            Existing = $false
        })
    }
    else {
        $unresolved.Add($spec)
    }
}

$maxOrder = 0
foreach ($row in $curated) {
    $order = [int](Get-Value $row 'order_idx' 0)
    if ([int](Get-Value $row 'is_bonus' 0) -eq 0 -and $order -gt $maxOrder) { $maxOrder = $order }
}

foreach ($entry in $resolved) {
    if ($entry.Existing) { continue }

    $sameId = @($curated | Where-Object {
        [int](Get-Value $_ 'is_bonus' 0) -eq 0 -and [int](Get-Value $_ 'item_id' 0) -eq [int]$entry.ItemID
    })
    if ($sameId.Count -gt 0) {
        foreach ($row in $sameId) {
            $row.point_cost = 0
            $row.original_price = 0
            $row.gold_cost = 0
        }
        continue
    }

    $maxOrder++
    $spec = $entry.Spec
    $curated.Add([pscustomobject][ordered]@{
        item_id = [int]$entry.ItemID
        item_name = [string]$spec.Label
        category = [string]$spec.Category
        category_id = [int]$spec.CategoryID
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
        description = if ($spec.Group -eq 'Pet Fruit') { 'Pet / partner enhancement item' } else { '' }
    })
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$catalogBackup = "$catalogPath.before-curation-v2-$stamp.bak"
$dbBackup = "$databasePath.before-curation-v2-$stamp.bak"
Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup -Force
Copy-Item -LiteralPath $databasePath -Destination $dbBackup -Force

try {
    $jsonOut = $curated.ToArray() | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($catalogPath, $jsonOut + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    if (-not ('System.Data.SQLite.SQLiteConnection' -as [type])) {
        Add-Type -Path $sqliteDll
    }

    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()
    $tx = $connection.BeginTransaction()
    try {
        $clear = $connection.CreateCommand()
        $clear.Transaction = $tx
        $clear.CommandText = 'DELETE FROM item_mall;'
        [void]$clear.ExecuteNonQuery()
        $clear.Dispose()

        foreach ($row in $curated) {
            $insert = $connection.CreateCommand()
            $insert.Transaction = $tx
            $insert.CommandText = @'
INSERT INTO item_mall
(item_id,item_name,category,category_id,point_cost,original_price,gold_cost,count,is_hot,is_new,is_limited,on_sale,discount,badge,order_idx,is_bonus,subcategory_id,description)
VALUES
(@item_id,@item_name,@category,@category_id,0,0,0,@count,@is_hot,@is_new,@is_limited,0,100,@badge,@order_idx,@is_bonus,@subcategory_id,@description);
'@
            [void]$insert.Parameters.AddWithValue('@item_id', [int](Get-Value $row 'item_id' 0))
            [void]$insert.Parameters.AddWithValue('@item_name', [string](Get-Value $row 'item_name' ''))
            [void]$insert.Parameters.AddWithValue('@category', [string](Get-Value $row 'category' 'Grocery'))
            [void]$insert.Parameters.AddWithValue('@category_id', [int](Get-Value $row 'category_id' 3))
            [void]$insert.Parameters.AddWithValue('@count', [int](Get-Value $row 'count' 1))
            [void]$insert.Parameters.AddWithValue('@is_hot', [int](Get-Value $row 'is_hot' 0))
            [void]$insert.Parameters.AddWithValue('@is_new', [int](Get-Value $row 'is_new' 0))
            [void]$insert.Parameters.AddWithValue('@is_limited', [int](Get-Value $row 'is_limited' 0))
            [void]$insert.Parameters.AddWithValue('@badge', [int](Get-Value $row 'badge' 0))
            [void]$insert.Parameters.AddWithValue('@order_idx', [int](Get-Value $row 'order_idx' 0))
            [void]$insert.Parameters.AddWithValue('@is_bonus', [int](Get-Value $row 'is_bonus' 0))
            [void]$insert.Parameters.AddWithValue('@subcategory_id', [int](Get-Value $row 'subcategory_id' 1))
            [void]$insert.Parameters.AddWithValue('@description', [string](Get-Value $row 'description' ''))
            [void]$insert.ExecuteNonQuery()
            $insert.Dispose()
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
Write-Host 'Item Mall V2 curation complete.' -ForegroundColor Green
Write-Host "Rows removed: $($removed.Count)"
Write-Host "Final catalog rows: $($curated.Count)"
Write-Host 'All normal and bonus Item Mall prices: 0 points' -ForegroundColor Green

Write-Host ''
Write-Host 'Requested items:' -ForegroundColor Cyan
foreach ($entry in @($resolved | Where-Object { $_.Spec.Group -eq 'Requested' })) {
    $state = if ($entry.Existing) { 'existing' } else { 'added/resolved' }
    Write-Host "  + $($entry.Spec.Label) -> #$($entry.ItemID) [$state]"
}

Write-Host ''
Write-Host 'Individual pet/partner enhancement items:' -ForegroundColor Cyan
foreach ($entry in @($resolved | Where-Object { $_.Spec.Group -eq 'Pet Fruit' })) {
    Write-Host "  + $($entry.Spec.Label) -> #$($entry.ItemID)"
}

if ($unresolved.Count -gt 0) {
    Write-Host ''
    Write-Host 'Still unresolved from this Rhode Island Item.dat:' -ForegroundColor Yellow
    foreach ($spec in $unresolved) {
        Write-Host "  - [$($spec.Group)] $($spec.Label)"
        $tokens = @((Normalize-Name $spec.Label).Split(' ') | Where-Object { $_.Length -ge 4 })
        if ($tokens.Count -gt 0) {
            $near = @($itemDat | Where-Object {
                $candidate = $_.Normalized
                ($tokens | Where-Object { $candidate -match [regex]::Escape($_) }).Count -gt 0
            } | Select-Object -First 5)
            foreach ($candidate in $near) {
                Write-Host "      candidate: $($candidate.Name) (#$($candidate.ItemID))" -ForegroundColor DarkYellow
            }
        }
    }
}

Write-Host ''
Write-Host "Catalog backup: $catalogBackup"
Write-Host "Database backup: $dbBackup"
Write-Host 'Start the server after this, then rerun Download-WloWikiItemImages.ps1 -Force.' -ForegroundColor Cyan
