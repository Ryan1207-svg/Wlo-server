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

# Refuse to touch the live SQLite DB while the WLO server is open.
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
    # PhxItemInfo is 47 bytes (Pack=1):
    # NameLength[1], Name[20], Type[1], ItemID[2], Icon[2], LargeIcon[2],
    # EquipPos[2], Level[2], Rank[1], Height[1], Width[1], StatusType[4], StatusUp[8].
    $bytes = [IO.File]::ReadAllBytes($Path)
    $recordSize = 47
    $items = New-Object System.Collections.Generic.List[object]

    for ($offset = 0; ($offset + $recordSize) -le $bytes.Length; $offset += $recordSize) {
        $nameLen = [Math]::Min([int]$bytes[$offset], 20)
        if ($nameLen -le 0) { $nameLen = 20 }
        $name = [Text.Encoding]::ASCII.GetString($bytes, $offset + 1, $nameLen)
        $name = $name.Trim([char]0).Trim()
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

    # WLO item names are limited to 20 bytes in this Item.dat structure, so allow
    # prefix matches for long aliases and common Box/Pack suffix differences.
    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $prefix = @($Items | Where-Object {
            $_.Normalized.StartsWith($n) -or $n.StartsWith($_.Normalized)
        })
        if ($prefix.Count -eq 1) { return $prefix[0] }
    }

    # Conservative token fallback: only accept one unique item containing every
    # meaningful word. This handles minor plural/spelling differences without
    # silently selecting a random WLO item.
    foreach ($alias in $Aliases) {
        $tokens = @((Normalize-Name $alias).Split(' ') | Where-Object { $_.Length -ge 3 -and $_ -notin @('holy','exp','pack','box') })
        if ($tokens.Count -eq 0) { continue }

        $matches = @($Items | Where-Object {
            $candidate = $_.Normalized
            ($tokens | Where-Object { $candidate -notmatch [regex]::Escape($_.TrimEnd('s')) }).Count -eq 0
        })
        if ($matches.Count -eq 1) { return $matches[0] }
    }

    return $null
}

$removeNames = @(
    'Cyan Bone Dual Fan Bag',
    'Gem Dharma Sword Bag',
    'Cat Shoes Lucky Bag',
    'Dark Dharma King Bag',
    'Pink Ribbon Lucky Bag',
    'Snow Songstress Bag',
    'Chinese General Bag',
    'Roman Warrior Bag',
    'New Companion Gear Bag',
    'Battle Boost Lucky Bag',
    'Class Weapon Lucky Bag',
    'Tongpu Box',
    'Dharma Sword Box',
    'Beast Devil Fork Box',
    'Spirit Devil Fork Box',
    'Brilliant Staff Box',
    'Great Angel Wings Box',
    'Gift Pack',
    'War Pack',
    '7 Colors Egg',
    'Potato Chips Pack (50)',
    'Fried Chicken Pack (50)',
    'Trilobite Pack',
    'Naughty Monkey Pack',
    'Naughty Dolphin Pack',
    'Ghost War Horse Pack',
    'Training Box',
    'Chili Sauce',
    'Wasabi',
    'Enhanced Skin Milk',
    'Newbie Box',
    'Special Shadow Pack',
    'Golden Shadow Pack'
)

# Prices below are private-server catalog prices and can be adjusted later from
# the Item Mall admin UI. Existing entries (for example 2X EXP Gold Card) are
# preserved rather than duplicated or repriced.
$addSpecs = @(
    [pscustomobject]@{ Name='Super Potential Pill'; Aliases=@('Super Potential Pill','Super Potential'); Category='Grocery'; CategoryID=3; Cost=120 },
    [pscustomobject]@{ Name='Shadow Pestle'; Aliases=@('Shadow Pestle'); Category='Weaponry'; CategoryID=1; Cost=180 },
    [pscustomobject]@{ Name='Dragon Spar'; Aliases=@('Dragon Spar'); Category='Grocery'; CategoryID=3; Cost=300 },
    [pscustomobject]@{ Name='15X Holy EXP Potion'; Aliases=@('15X Holy EXP Potion','15X EXP Potion','15x Holy EXP Potion'); Category='Grocery'; CategoryID=3; Cost=144 },
    [pscustomobject]@{ Name='Snow Girl Pack'; Aliases=@('Snow Girl Pack','Snow Girl Lucky Bag','Snow Girl Bag'); Category='Grocery'; CategoryID=3; Cost=72 },
    [pscustomobject]@{ Name='Xmas Fork'; Aliases=@('Xmas Fork','X-mas Fork','Christmas Fork'); Category='Weaponry'; CategoryID=1; Cost=324 },
    [pscustomobject]@{ Name='Forest Fork'; Aliases=@('Forest Fork'); Category='Weaponry'; CategoryID=1; Cost=324 },
    [pscustomobject]@{ Name='Soul Reaper'; Aliases=@('Soul Reaper','Soul Reapers','Souls Reaper','Souls Reapers',"Soul's Reaper"); Category='Weaponry'; CategoryID=1; Cost=324 },
    [pscustomobject]@{ Name='Attack Pestle'; Aliases=@('Attack Pestle','Attack Pestal','Attack Pestle Box'); Category='Weaponry'; CategoryID=1; Cost=216 },
    [pscustomobject]@{ Name='2X EXP Gold Card'; Aliases=@('2X EXP Gold Card','Gold Card'); Category='Grocery'; CategoryID=3; Cost=98 },
    [pscustomobject]@{ Name='Snow Ears'; Aliases=@('Snow Ears'); Category='Armory'; CategoryID=2; Cost=300 }
)

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
    } else {
        $kept.Add($row)
    }
}

$resolvedAdds = New-Object System.Collections.Generic.List[object]
$unresolved = New-Object System.Collections.Generic.List[object]

foreach ($spec in $addSpecs) {
    $aliasNorms = @($spec.Aliases | ForEach-Object { Normalize-Name $_ })
    $already = @($kept | Where-Object {
        [int]$_.is_bonus -eq 0 -and $aliasNorms -contains (Normalize-Name ([string]$_.item_name))
    })
    if ($already.Count -gt 0) {
        Write-Host "Already present: $($spec.Name) (#$($already[0].item_id))"
        continue
    }

    $match = Find-ItemMatch $itemDat $spec.Aliases
    if (-not $match) {
        $unresolved.Add($spec)
        continue
    }

    Write-Host "Resolved: $($spec.Name) -> Item.dat '$($match.Name)' (#$($match.ItemID))"
    $resolvedAdds.Add([pscustomobject]@{
        Spec = $spec
        ItemID = [int]$match.ItemID
        ItemDatName = [string]$match.Name
    })
}

if ($unresolved.Count -gt 0) {
    Write-Host ''
    Write-Host 'No files were changed because these requested additions could not be resolved safely:' -ForegroundColor Yellow
    foreach ($spec in $unresolved) {
        Write-Host "  - $($spec.Name)"
        $words = @((Normalize-Name $spec.Name).Split(' ') | Where-Object { $_.Length -ge 4 })
        $suggestions = @($itemDat | Where-Object {
            $n = $_.Normalized
            ($words | Where-Object { $n -like ('*' + $_.TrimEnd('s') + '*') }).Count -gt 0
        } | Select-Object -First 8)
        foreach ($s in $suggestions) {
            Write-Host "      candidate: #$($s.ItemID) $($s.Name)"
        }
    }
    Write-Host ''
    throw 'Item Mall curation stopped before making changes. Send the unresolved/candidate output back to ChatGPT.'
}

$maxOrder = 0
foreach ($row in $kept) {
    if ([int]$row.is_bonus -eq 0 -and [int]$row.order_idx -gt $maxOrder) { $maxOrder = [int]$row.order_idx }
}

foreach ($add in $resolvedAdds) {
    $spec = $add.Spec
    $maxOrder++
    $kept.Add([pscustomobject][ordered]@{
        item_id = [int]$add.ItemID
        item_name = [string]$spec.Name
        category = [string]$spec.Category
        category_id = [int]$spec.CategoryID
        point_cost = [int]$spec.Cost
        original_price = [int]$spec.Cost
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

        foreach ($add in $resolvedAdds) {
            $spec = $add.Spec
            $cmd = $connection.CreateCommand()
            $cmd.Transaction = $tx
            $cmd.CommandText = @'
INSERT INTO item_mall
(item_id,item_name,category,category_id,point_cost,original_price,gold_cost,count,is_hot,is_new,is_limited,on_sale,discount,badge,order_idx,is_bonus,subcategory_id,description)
SELECT @item_id,@item_name,@category,@category_id,@point_cost,@original_price,0,1,0,1,0,0,100,1,@order_idx,0,1,''
WHERE NOT EXISTS (
    SELECT 1 FROM item_mall WHERE item_id = @item_id AND is_bonus = 0
);
'@
            [void]$cmd.Parameters.AddWithValue('@item_id', [int]$add.ItemID)
            [void]$cmd.Parameters.AddWithValue('@item_name', [string]$spec.Name)
            [void]$cmd.Parameters.AddWithValue('@category', [string]$spec.Category)
            [void]$cmd.Parameters.AddWithValue('@category_id', [int]$spec.CategoryID)
            [void]$cmd.Parameters.AddWithValue('@point_cost', [int]$spec.Cost)
            [void]$cmd.Parameters.AddWithValue('@original_price', [int]$spec.Cost)
            [void]$cmd.Parameters.AddWithValue('@order_idx', [int](($kept | Where-Object { [int]$_.item_id -eq [int]$add.ItemID -and [int]$_.is_bonus -eq 0 } | Select-Object -First 1).order_idx))
            [void]$cmd.ExecuteNonQuery()
            $cmd.Dispose()
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
Write-Host "Added new standard listings: $($resolvedAdds.Count)"
Write-Host "Catalog backup: $catalogBackup"
Write-Host "Database backup: $dbBackup"
Write-Host ''
Write-Host 'Now start the server, then rerun Download-WloWikiItemImages.ps1 so the new listings get artwork.' -ForegroundColor Cyan
