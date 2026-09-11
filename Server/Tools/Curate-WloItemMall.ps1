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

$serverProcess = Get-Process -Name 'Wonderland Private Server' -ErrorAction SilentlyContinue
if ($serverProcess) {
    throw 'Close the Wonderland Private Server before running this curation tool.'
}

if (-not (Test-Path -LiteralPath $ItemDatPath)) {
    $fallbacks = @(
        (Join-Path $serverRoot 'Data\Item.dat'),
        (Join-Path $serverRoot 'Data\itemDat.wpdat')
    )
    $ItemDatPath = $fallbacks | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ItemDatPath -or -not (Test-Path -LiteralPath $ItemDatPath)) {
    throw 'Item.dat was not found. Pass -ItemDatPath with the path to the Rhode Island client Item.dat.'
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

function Read-ItemDat([string]$Path) {
    # PhxItemInfo is 47 bytes (Pack=1): NameLength[1], Name[20], Type[1],
    # ItemID[2], Icon[2], LargeIcon[2], EquipPos[2], Level[2], Rank[1],
    # Height[1], Width[1], StatusType[4], StatusUp[8].
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

function Find-ItemMatch($Items, [string[]]$Aliases) {
    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $exact = @($Items | Where-Object { $_.Normalized -eq $n })
        if ($exact.Count -eq 1) { return $exact[0] }
    }

    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $prefix = @($Items | Where-Object {
            $_.Normalized.StartsWith($n) -or $n.StartsWith($_.Normalized)
        })
        if ($prefix.Count -eq 1) { return $prefix[0] }
    }

    foreach ($alias in $Aliases) {
        $tokens = @((Normalize-Name $alias).Split(' ') | Where-Object {
            $_.Length -ge 3 -and $_ -notin @('holy','exp','pack','box','the')
        })
        if ($tokens.Count -eq 0) { continue }

        $matches = @($Items | Where-Object {
            $candidate = $_.Normalized
            ($tokens | Where-Object { $candidate -notmatch [regex]::Escape($_.TrimEnd('s')) }).Count -eq 0
        })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    return $null
}

function New-AddSpec([string]$Name, [string[]]$Aliases, [string]$Category, [int]$CategoryID, [string]$Group) {
    return [pscustomobject]@{
        Name = $Name
        Aliases = $Aliases
        Category = $Category
        CategoryID = $CategoryID
        Cost = 0
        Group = $Group
    }
}

$removeNames = @(
    'Cyan Bone Dual Fan Bag', 'Gem Dharma Sword Bag', 'Cat Shoes Lucky Bag',
    'Dark Dharma King Bag', 'Pink Ribbon Lucky Bag', 'Snow Songstress Bag',
    'Chinese General Bag', 'Roman Warrior Bag', 'New Companion Gear Bag',
    'Battle Boost Lucky Bag', 'Class Weapon Lucky Bag', 'Tongpu Box',
    'Dharma Sword Box', 'Beast Devil Fork Box', 'Spirit Devil Fork Box',
    'Brilliant Staff Box', 'Great Angel Wings Box', 'Gift Pack', 'War Pack',
    '7 Colors Egg', 'Potato Chips Pack (50)', 'Fried Chicken Pack (50)',
    'Trilobite Pack', 'Naughty Monkey Pack', 'Naughty Dolphin Pack',
    'Ghost War Horse Pack', 'Training Box', 'Chili Sauce', 'Wasabi',
    'Enhanced Skin Milk', 'Newbie Box', 'Special Shadow Pack', 'Golden Shadow Pack'
)

$addSpecs = New-Object System.Collections.Generic.List[object]

# User-requested Item Mall additions.
$addSpecs.Add((New-AddSpec 'Super Potential Pill' @('Super Potential Pill','Super Potential') 'Grocery' 3 'Requested'))
$addSpecs.Add((New-AddSpec 'Shadow Pestle' @('Shadow Pestle') 'Weaponry' 1 'Requested'))
$addSpecs.Add((New-AddSpec 'Dragon Spar' @('Dragon Spar') 'Grocery' 3 'Requested'))
$addSpecs.Add((New-AddSpec '15X Holy EXP Potion' @('15X Holy EXP Potion','15X EXP Potion','15x Holy EXP Potion') 'Grocery' 3 'Requested'))
$addSpecs.Add((New-AddSpec 'Snow Girl Pack' @('Snow Girl Pack','Snow Girl Lucky Bag','Snow Girl Bag') 'Grocery' 3 'Requested'))
$addSpecs.Add((New-AddSpec 'Xmas Fork' @('Xmas Fork','X-mas Fork','Christmas Fork') 'Weaponry' 1 'Requested'))
$addSpecs.Add((New-AddSpec 'Forest Fork' @('Forest Fork') 'Weaponry' 1 'Requested'))
$addSpecs.Add((New-AddSpec 'Soul Reaper' @('Soul Reaper','Soul Reapers','Souls Reaper','Souls Reapers',"Soul's Reaper") 'Weaponry' 1 'Requested'))
$addSpecs.Add((New-AddSpec 'Attack Pestle' @('Attack Pestle','Attack Pestal','Attack Pestle Box') 'Weaponry' 1 'Requested'))
$addSpecs.Add((New-AddSpec '2X EXP Gold Card' @('2X EXP Gold Card','Gold Card') 'Grocery' 3 'Requested'))
$addSpecs.Add((New-AddSpec 'Snow Ears' @('Snow Ears') 'Armory' 2 'Requested'))

# Individual raw fruit listings. These are deliberately single-item listings so
# they can be bought one-by-one for pets/food use rather than as a pack.
$fruitSpecs = @(
    @{ Name='Aligote'; Aliases=@('Aligote') },
    @{ Name='Apple'; Aliases=@('Apple') },
    @{ Name='Banana'; Aliases=@('Banana') },
    @{ Name='Big Apple'; Aliases=@('Big Apple') },
    @{ Name='Brown Nut'; Aliases=@('Brown Nut') },
    @{ Name='Cantaloupe'; Aliases=@('Cantaloupe') },
    @{ Name='Coconut'; Aliases=@('Coconut') },
    @{ Name='Coconut (Pulp)'; Aliases=@('Coconut (Pulp)','Coconut Pulp') },
    @{ Name='Golden Apple'; Aliases=@('Golden Apple') },
    @{ Name='Gooseberry'; Aliases=@('Gooseberry','Little Gooseberry') },
    @{ Name='Green Apple'; Aliases=@('Green Apple') },
    @{ Name='Grape'; Aliases=@('Grape') },
    @{ Name='Hazelnut'; Aliases=@('Hazelnut') },
    @{ Name='Juicy Peach'; Aliases=@('Juicy Peach') },
    @{ Name='Latania'; Aliases=@('Latania') },
    @{ Name='Lemon'; Aliases=@('Lemon','Little Lemon') },
    @{ Name='Mandarin Orange'; Aliases=@('Mandarin Orange','Mandarin') },
    @{ Name='Mango'; Aliases=@('Mango') },
    @{ Name='Muskmelon'; Aliases=@('Muskmelon','Big Muskmelon') },
    @{ Name='Orange'; Aliases=@('Orange') },
    @{ Name='Papaya'; Aliases=@('Papaya') },
    @{ Name='Persimmon'; Aliases=@('Persimmon') },
    @{ Name='Pineapple'; Aliases=@('Pineapple','Small Pineapple') },
    @{ Name='Strawberry'; Aliases=@('Strawberry') },
    @{ Name='Watermelon'; Aliases=@('Watermelon') }
)
foreach ($fruit in $fruitSpecs) {
    $addSpecs.Add((New-AddSpec $fruit.Name $fruit.Aliases 'Grocery' 4 'Pet Fruit'))
}

Write-Host "Reading catalog: $catalogPath"
$rows = Read-Catalog $catalogPath
Write-Host "Reading item IDs from: $ItemDatPath"
$itemDat = Read-ItemDat $ItemDatPath
Write-Host "Loaded $($itemDat.Count) named Item.dat records."

$removeSet = @{}
foreach ($name in $removeNames) { $removeSet[(Normalize-Name $name)] = $true }

$kept = New-Object System.Collections.Generic.List[object]
$removedRows = New-Object System.Collections.Generic.List[object]
foreach ($row in $rows) {
    $name = [string]$row.item_name
    if ($removeSet.ContainsKey((Normalize-Name $name))) {
        $removedRows.Add($row)
        continue
    }

    # Everything in both the normal and bonus malls is free for now.
    $row.point_cost = 0
    $row.original_price = 0
    $row.gold_cost = 0
    $row.on_sale = 0
    $row.discount = 100
    $kept.Add($row)
}

$resolvedAdds = New-Object System.Collections.Generic.List[object]
$unresolvedRequested = New-Object System.Collections.Generic.List[object]
$unresolvedFruit = New-Object System.Collections.Generic.List[object]

foreach ($spec in $addSpecs) {
    $aliasNorms = @($spec.Aliases | ForEach-Object { Normalize-Name $_ })
    $already = @($kept | Where-Object {
        [int]$_.is_bonus -eq 0 -and $aliasNorms -contains (Normalize-Name ([string]$_.item_name))
    })

    if ($already.Count -gt 0) {
        foreach ($existing in $already) {
            $existing.point_cost = 0
            $existing.original_price = 0
            $existing.gold_cost = 0
        }
        Write-Host "Already present/free: $($spec.Name) (#$($already[0].item_id))"
        continue
    }

    $match = Find-ItemMatch $itemDat $spec.Aliases
    if (-not $match) {
        if ($spec.Group -eq 'Requested') { $unresolvedRequested.Add($spec) }
        else { $unresolvedFruit.Add($spec) }
        continue
    }

    Write-Host "Resolved [$($spec.Group)]: $($spec.Name) -> Item.dat '$($match.Name)' (#$($match.ItemID))"
    $resolvedAdds.Add([pscustomobject]@{
        Spec = $spec
        ItemID = [int]$match.ItemID
        ItemDatName = [string]$match.Name
    })
}

$maxOrder = 0
foreach ($row in $kept) {
    if ([int]$row.is_bonus -eq 0 -and [int]$row.order_idx -gt $maxOrder) { $maxOrder = [int]$row.order_idx }
}

foreach ($add in $resolvedAdds) {
    $spec = $add.Spec
    $existingById = @($kept | Where-Object { [int]$_.is_bonus -eq 0 -and [int]$_.item_id -eq [int]$add.ItemID })
    if ($existingById.Count -gt 0) {
        foreach ($existing in $existingById) {
            $existing.point_cost = 0
            $existing.original_price = 0
            $existing.gold_cost = 0
        }
        continue
    }

    $maxOrder++
    $kept.Add([pscustomobject][ordered]@{
        item_id = [int]$add.ItemID
        item_name = [string]$spec.Name
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
        description = ''
    })
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$catalogBackup = "$catalogPath.before-curation-$stamp.bak"
$dbBackup = "$databasePath.before-curation-$stamp.bak"
Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup -Force
Copy-Item -LiteralPath $databasePath -Destination $dbBackup -Force

try {
    $jsonOut = $kept.ToArray() | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($catalogPath, $jsonOut + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    Add-Type -Path $sqliteDll
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()
    $tx = $connection.BeginTransaction()
    try {
        foreach ($removeName in $removeNames) {
            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $tx
            $cmd.CommandText = 'DELETE FROM item_mall WHERE lower(trim(item_name)) = lower(trim(@name));'
            [void]$cmd.Parameters.AddWithValue('@name', $removeName)
            [void]$cmd.ExecuteNonQuery()
            $cmd.Dispose()
        }

        # Zero both normal IM and bonus IM prices.
        $zero = $connection.CreateCommand()
        $zero.Transaction = $tx
        $zero.CommandText = 'UPDATE item_mall SET point_cost = 0, original_price = 0, gold_cost = 0, on_sale = 0, discount = 100;'
        [void]$zero.ExecuteNonQuery()
        $zero.Dispose()

        foreach ($add in $resolvedAdds) {
            $spec = $add.Spec
            $orderRow = $kept | Where-Object { [int]$_.item_id -eq [int]$add.ItemID -and [int]$_.is_bonus -eq 0 } | Select-Object -First 1
            $order = if ($orderRow) { [int]$orderRow.order_idx } else { ++$maxOrder }

            $update = $connection.CreateCommand()
            $update.Transaction = $tx
            $update.CommandText = @'
UPDATE item_mall
SET point_cost=0, original_price=0, gold_cost=0
WHERE item_id=@item_id AND is_bonus=0;
'@
            [void]$update.Parameters.AddWithValue('@item_id', [int]$add.ItemID)
            $affected = $update.ExecuteNonQuery()
            $update.Dispose()

            if ($affected -eq 0) {
                $insert = $connection.CreateCommand()
                $insert.Transaction = $tx
                $insert.CommandText = @'
INSERT INTO item_mall
(item_id,item_name,category,category_id,point_cost,original_price,gold_cost,count,is_hot,is_new,is_limited,on_sale,discount,badge,order_idx,is_bonus,subcategory_id,description)
VALUES (@item_id,@item_name,@category,@category_id,0,0,0,1,0,1,0,0,100,1,@order_idx,0,1,'');
'@
                [void]$insert.Parameters.AddWithValue('@item_id', [int]$add.ItemID)
                [void]$insert.Parameters.AddWithValue('@item_name', [string]$spec.Name)
                [void]$insert.Parameters.AddWithValue('@category', [string]$spec.Category)
                [void]$insert.Parameters.AddWithValue('@category_id', [int]$spec.CategoryID)
                [void]$insert.Parameters.AddWithValue('@order_idx', $order)
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
Write-Host 'Item Mall curation complete.' -ForegroundColor Green
Write-Host "Removed catalog rows: $($removedRows.Count)"
Write-Host "Resolved additions: $($resolvedAdds.Count)"
Write-Host 'All normal and bonus Item Mall prices are now 0 points.' -ForegroundColor Green
Write-Host "Catalog backup: $catalogBackup"
Write-Host "Database backup: $dbBackup"

if ($unresolvedRequested.Count -gt 0) {
    Write-Host ''
    Write-Host 'Requested items that could not be resolved from Item.dat:' -ForegroundColor Yellow
    foreach ($spec in $unresolvedRequested) { Write-Host "  - $($spec.Name)" }
}
if ($unresolvedFruit.Count -gt 0) {
    Write-Host ''
    Write-Host 'Fruit names not present exactly enough in this Item.dat (others were still added):' -ForegroundColor DarkYellow
    foreach ($spec in $unresolvedFruit) { Write-Host "  - $($spec.Name)" }
}

Write-Host ''
Write-Host 'Start the server after this. Then run Download-WloWikiItemImages.ps1 to populate artwork.' -ForegroundColor Cyan
