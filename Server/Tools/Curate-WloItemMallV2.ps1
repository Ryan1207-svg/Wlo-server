param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$ItemDatPath = 'C:\Users\Ryans\Desktop\WLO PRIVATE SERVER\Client\WLRI\data\Item.dat'
)

$ErrorActionPreference = 'Stop'

$serverRoot = Join-Path $RepoRoot 'Server'
$dataRoot = Join-Path $serverRoot 'Data'
$catalogPath = Join-Path $dataRoot 'item_mall.json'
$databasePath = Join-Path $dataRoot 'ServerDataBase.db'
$compactItemPath = Join-Path $dataRoot 'itemDat.wpdat'
$sqliteDll = Join-Path $serverRoot 'DLLS\System.Data.SQLite.dll'
$supportReportPath = Join-Path $dataRoot 'wlri-item-support.csv'

if (-not (Test-Path -LiteralPath $catalogPath)) { throw "Missing catalog: $catalogPath" }
if (-not (Test-Path -LiteralPath $databasePath)) { throw "Missing database: $databasePath" }
if (-not (Test-Path -LiteralPath $sqliteDll)) { throw "Missing SQLite provider: $sqliteDll" }
if (-not (Test-Path -LiteralPath $ItemDatPath)) { throw "Missing Rhode Island Item.dat: $ItemDatPath" }
if (Get-Process -Name 'Wonderland Private Server' -ErrorAction SilentlyContinue) {
    throw 'Close Wonderland Private Server.exe before running WLRI item sync/curation.'
}

function Normalize-Name([string]$Name) {
    if ($null -eq $Name) { return '' }
    return (($Name.ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -replace '\s+', ' ')
}

function Decode-WloByte([byte]$Value) {
    return [int]((([int]$Value -bxor 0x9A) - 9) -band 0xFF)
}

function Decode-WloWord([UInt16]$Value) {
    return [int]((([int]$Value -bxor 0xEFC3) - 9) -band 0xFFFF)
}

function Decode-StatWord([UInt16]$Value) {
    return [int]((([int]$Value -bxor 0xF4B4) - 109) -band 0xFFFF)
}

function Read-FlatJsonRows([string]$Path) {
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $parsed = ConvertFrom-Json -InputObject $text
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($parsed)
    $rows = New-Object System.Collections.Generic.List[object]
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if ($null -eq $current) { continue }
        if ($current -is [System.Array]) {
            foreach ($entry in $current) { $queue.Enqueue($entry) }
        }
        else {
            $rows.Add($current)
        }
    }
    return @($rows)
}

function Get-IntValue($Object, [string]$Property, [int]$Default = 0) {
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Property]
    if ($null -eq $prop) { return $Default }
    $value = $prop.Value
    if ($value -is [System.Array]) { $value = @($value) | Select-Object -First 1 }
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { return $Default }
    $parsed = 0
    if ([int]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-StringValue($Object, [string]$Property, [string]$Default = '') {
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Property]
    if ($null -eq $prop) { return $Default }
    $value = $prop.Value
    if ($value -is [System.Array]) { $value = @($value) | Select-Object -First 1 }
    if ($null -eq $value) { return $Default }
    return [string]$value
}

function Get-RecordName([byte[]]$Bytes, [int]$Offset, [bool]$ReverseName) {
    $len = [int]$Bytes[$Offset]
    if ($len -lt 1 -or $len -gt 20) { return $null }

    $chars = New-Object char[] $len
    for ($i = 0; $i -lt $len; $i++) {
        $index = if ($ReverseName) { $Offset + 20 - $i } else { $Offset + 1 + $i }
        if ($index -lt 0 -or $index -ge $Bytes.Length) { return $null }
        $v = [int]$Bytes[$index]
        if ($v -lt 32 -or $v -gt 126) { return $null }
        $chars[$i] = [char]$v
    }

    $name = (-join $chars).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    if ($name -notmatch '[A-Za-z0-9?]') { return $null }
    return $name
}

function Test-ItemLayout([byte[]]$Bytes, [int]$RecordSize, [int]$HeaderSize, [bool]$ReverseName) {
    if ($RecordSize -lt 120 -or $HeaderSize -lt 0 -or $HeaderSize -ge $Bytes.Length) { return $null }
    $recordCount = [Math]::Floor(($Bytes.Length - $HeaderSize) / $RecordSize)
    if ($recordCount -lt 100) { return $null }

    $valid = 0
    $unique = @{}
    $anchor = 0
    for ($r = 0; $r -lt $recordCount; $r++) {
        $offset = $HeaderSize + ($r * $RecordSize)
        if (($offset + 28) -gt $Bytes.Length) { break }
        $name = Get-RecordName $Bytes $offset $ReverseName
        if ($null -eq $name) { continue }

        $rawId = [BitConverter]::ToUInt16($Bytes, $offset + 22)
        $id = Decode-WloWord $rawId
        if ($id -le 0) { continue }

        $valid++
        $unique[$id] = $true
        $norm = Normalize-Name $name
        if (($norm -eq 'potential pill' -and $id -eq 34269) -or
            ($norm -eq '2x exp gold card' -and $id -eq 34101) -or
            ($norm -eq 'bamboo dragonfly' -and $id -eq 34169)) {
            $anchor += 1
        }
    }

    $score = $valid + ([double]$unique.Count * 0.25) + ($anchor * 20000)
    return [pscustomobject]@{
        RecordSize = $RecordSize
        HeaderSize = $HeaderSize
        ReverseName = $ReverseName
        RecordCount = $recordCount
        ValidCount = $valid
        UniqueIDs = $unique.Count
        AnchorCount = $anchor
        Score = $score
    }
}

function Detect-ItemLayout([byte[]]$Bytes) {
    $tests = New-Object System.Collections.Generic.List[object]
    $preferred = @(451, 457)
    foreach ($size in $preferred) {
        $header = $Bytes.Length % $size
        if ($header -le 2048) {
            $tests.Add((Test-ItemLayout $Bytes $size $header $true))
            $tests.Add((Test-ItemLayout $Bytes $size $header $false))
        }
    }

    $best = @($tests | Where-Object { $_ -ne $null } | Sort-Object Score -Descending | Select-Object -First 1)
    if ($best.Count -eq 0 -or $best[0].ValidCount -lt 1000) {
        $tests.Clear()
        foreach ($size in 440..470) {
            $header = $Bytes.Length % $size
            if ($header -gt 2048) { continue }
            $tests.Add((Test-ItemLayout $Bytes $size $header $true))
            $tests.Add((Test-ItemLayout $Bytes $size $header $false))
        }
        $best = @($tests | Where-Object { $_ -ne $null } | Sort-Object Score -Descending | Select-Object -First 1)
    }

    if ($best.Count -eq 0) { throw 'Could not detect a WLRI Item.dat record layout.' }
    $layout = $best[0]
    if ($layout.ValidCount -lt 1000) {
        $top = @($tests | Where-Object { $_ -ne $null } | Sort-Object Score -Descending | Select-Object -First 5)
        Write-Host 'Best Item.dat layout candidates:' -ForegroundColor Yellow
        foreach ($t in $top) {
            Write-Host "  size=$($t.RecordSize) header=$($t.HeaderSize) reverse=$($t.ReverseName) valid=$($t.ValidCount) unique=$($t.UniqueIDs) anchors=$($t.AnchorCount)"
        }
        throw "WLRI Item.dat decoding is not reliable enough (best valid record count: $($layout.ValidCount)). No catalog/database changes were made."
    }
    return $layout
}

function Read-WlriItems([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $layout = Detect-ItemLayout $bytes
    Write-Host "Detected WLRI Item.dat layout: record=$($layout.RecordSize) bytes, header=$($layout.HeaderSize), records=$($layout.RecordCount), reverseNames=$($layout.ReverseName)"
    Write-Host "Layout validation: $($layout.ValidCount) plausible names, $($layout.UniqueIDs) unique IDs, anchors=$($layout.AnchorCount)"

    $items = New-Object System.Collections.Generic.List[object]
    for ($r = 0; $r -lt $layout.RecordCount; $r++) {
        $offset = $layout.HeaderSize + ($r * $layout.RecordSize)
        if (($offset + 414) -ge $bytes.Length) { break }
        $name = Get-RecordName $bytes $offset ([bool]$layout.ReverseName)
        if ($null -eq $name) { continue }

        $id = Decode-WloWord ([BitConverter]::ToUInt16($bytes, $offset + 22))
        if ($id -le 0) { continue }

        $itemType = Decode-WloByte $bytes[$offset + 21]
        $icon = Decode-WloWord ([BitConverter]::ToUInt16($bytes, $offset + 24))
        $largeIcon = Decode-WloWord ([BitConverter]::ToUInt16($bytes, $offset + 26))
        $statusType1 = Decode-WloWord ([BitConverter]::ToUInt16($bytes, $offset + 36))
        $statusType2 = Decode-WloWord ([BitConverter]::ToUInt16($bytes, $offset + 38))
        $statusUp1 = Decode-StatWord ([BitConverter]::ToUInt16($bytes, $offset + 42))
        $statusUp2 = Decode-StatWord ([BitConverter]::ToUInt16($bytes, $offset + 46))
        $rank = Decode-WloByte $bytes[$offset + 51]
        $equipPos = Decode-WloByte $bytes[$offset + 52]
        $level = Decode-WloByte $bytes[$offset + 119]
        $width = Decode-WloByte $bytes[$offset + 412]
        $height = Decode-WloByte $bytes[$offset + 413]
        if ($width -lt 1 -or $width -gt 10) { $width = 1 }
        if ($height -lt 1 -or $height -gt 10) { $height = 1 }

        $items.Add([pscustomobject]@{
            ItemID = [int]$id
            Name = $name
            Normalized = Normalize-Name $name
            ItemType = [int]$itemType
            IconNum = [int]$icon
            LargeIconNum = [int]$largeIcon
            EquipPos = [int]$equipPos
            Level = [int]$level
            Rank = [int]$rank
            CellWidth = [int]$width
            CellHeight = [int]$height
            StatusType1 = [int]$statusType1
            StatusType2 = [int]$statusType2
            StatusUp1 = [int]$statusUp1
            StatusUp2 = [int]$statusUp2
        })
    }

    $unique = @($items | Group-Object ItemID | ForEach-Object { $_.Group | Select-Object -First 1 } | Sort-Object ItemID)
    if ($unique.Count -lt 1000) { throw "Decoded only $($unique.Count) unique WLRI items; refusing to overwrite server item data." }

    $potential = $unique | Where-Object { $_.ItemID -eq 34269 } | Select-Object -First 1
    if ($potential) {
        Write-Host "Decoder check: #34269 = '$($potential.Name)'" -ForegroundColor Green
    }
    else {
        Write-Warning 'Decoder did not find expected ItemID #34269 (Potential Pill). The layout is plausible, but this client may use a different catalog revision.'
    }

    return $unique
}

function Write-CompactItemDat($Items, [string]$Path) {
    $tmp = $Path + '.tmp'
    $stream = [IO.File]::Open($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $writer = New-Object IO.BinaryWriter($stream)
    try {
        foreach ($item in $Items) {
            $nameBytes = [Text.Encoding]::ASCII.GetBytes([string]$item.Name)
            $nameLength = [Math]::Min(20, $nameBytes.Length)
            $writer.Write([byte]$nameLength)
            for ($i = 0; $i -lt 20; $i++) {
                if ($i -lt $nameLength) { $writer.Write([byte]$nameBytes[$i]) }
                else { $writer.Write([byte]0) }
            }
            $writer.Write([byte]([Math]::Max(0, [Math]::Min(255, [int]$item.ItemType))))
            $writer.Write([UInt16]$item.ItemID)
            $writer.Write([UInt16]$item.IconNum)
            $writer.Write([UInt16]$item.LargeIconNum)
            $writer.Write([UInt16]$item.EquipPos)
            $writer.Write([UInt16]$item.Level)
            $writer.Write([byte]([Math]::Max(0, [Math]::Min(255, [int]$item.Rank))))
            $writer.Write([byte]$item.CellHeight)
            $writer.Write([byte]$item.CellWidth)
            $writer.Write([UInt16]$item.StatusType1)
            $writer.Write([UInt16]$item.StatusType2)
            $writer.Write([Int32]$item.StatusUp1)
            $writer.Write([Int32]$item.StatusUp2)
        }
    }
    finally {
        $writer.Dispose()
        $stream.Dispose()
    }

    $expected = $Items.Count * 47
    $actual = (Get-Item -LiteralPath $tmp).Length
    if ($actual -ne $expected) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "Generated itemDat.wpdat size mismatch: expected $expected bytes, got $actual."
    }

    if (Test-Path -LiteralPath $Path) {
        Copy-Item -LiteralPath $Path -Destination ($Path + '.before-wlri-sync.bak') -Force
    }
    Move-Item -LiteralPath $tmp -Destination $Path -Force

    foreach ($configuration in @('Debug','Release')) {
        $binRoot = Join-Path $serverRoot ("bin\" + $configuration)
        if (Test-Path -LiteralPath $binRoot) {
            $targetDir = Join-Path $binRoot 'Data'
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
            Copy-Item -LiteralPath $Path -Destination (Join-Path $targetDir 'itemDat.wpdat') -Force
        }
    }

    Write-Host "Synced $($Items.Count) WLRI items into server runtime itemDat.wpdat." -ForegroundColor Green
}

function Find-ItemMatch($Items, [string[]]$Aliases) {
    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $exact = @($Items | Where-Object { $_.Normalized -eq $n })
        if ($exact.Count -eq 1) { return $exact[0] }
    }
    foreach ($alias in $Aliases) {
        $n = Normalize-Name $alias
        $contains = @($Items | Where-Object { $_.Normalized -like ('*' + $n + '*') -or $n -like ('*' + $_.Normalized + '*') })
        if ($contains.Count -eq 1) { return $contains[0] }
    }
    foreach ($alias in $Aliases) {
        $tokens = @((Normalize-Name $alias).Split(' ') | Where-Object { $_.Length -ge 3 -and $_ -notin @('holy','exp','pack','box','the') })
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
    return [pscustomobject]@{ Name=$Name; Aliases=$Aliases; Category=$Category; CategoryID=$CategoryID; Group=$Group }
}

function New-MallRow($Spec, $Item, [int]$OrderIndex) {
    return [pscustomobject][ordered]@{
        item_id = [int]$Item.ItemID
        item_name = [string]$Spec.Name
        category = [string]$Spec.Category
        category_id = [int]$Spec.CategoryID
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
        order_idx = $OrderIndex
        is_bonus = 0
        subcategory_id = 1
        description = if ($Spec.Group -eq 'Pet Enhancement') { 'Pet / partner enhancement item' } else { '' }
    }
}

function Normalize-MallRow($Row) {
    return [pscustomobject][ordered]@{
        item_id = Get-IntValue $Row 'item_id' 0
        item_name = Get-StringValue $Row 'item_name' ''
        category = Get-StringValue $Row 'category' ''
        category_id = Get-IntValue $Row 'category_id' 1
        point_cost = 0
        original_price = 0
        gold_cost = 0
        count = [Math]::Max(1, (Get-IntValue $Row 'count' 1))
        is_hot = Get-IntValue $Row 'is_hot' 0
        is_new = Get-IntValue $Row 'is_new' 0
        is_limited = Get-IntValue $Row 'is_limited' 0
        on_sale = 0
        discount = 100
        badge = Get-IntValue $Row 'badge' 0
        order_idx = Get-IntValue $Row 'order_idx' 0
        is_bonus = Get-IntValue $Row 'is_bonus' 0
        subcategory_id = Get-IntValue $Row 'subcategory_id' 1
        description = Get-StringValue $Row 'description' ''
    }
}

function Ensure-ItemMallSchema($Connection) {
    $create = $Connection.CreateCommand()
    $create.CommandText = @'
CREATE TABLE IF NOT EXISTS item_mall (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 item_id INT NOT NULL,
 item_name TEXT,
 category TEXT,
 category_id INT DEFAULT 1,
 point_cost INT DEFAULT 0,
 original_price INT DEFAULT 0,
 gold_cost INT DEFAULT 0,
 count INT DEFAULT 1,
 is_hot INT DEFAULT 0,
 is_new INT DEFAULT 0,
 is_limited INT DEFAULT 0,
 on_sale INT DEFAULT 0,
 discount INT DEFAULT 100,
 badge INT DEFAULT 0,
 order_idx INT DEFAULT 0,
 is_bonus INT DEFAULT 0,
 subcategory_id INT DEFAULT 1,
 description TEXT DEFAULT ''
);
'@
    [void]$create.ExecuteNonQuery()
    $create.Dispose()

    $readerCmd = $Connection.CreateCommand()
    $readerCmd.CommandText = 'PRAGMA table_info(item_mall);'
    $reader = $readerCmd.ExecuteReader()
    $columns = @{}
    while ($reader.Read()) { $columns[[string]$reader['name']] = $true }
    $reader.Close(); $reader.Dispose(); $readerCmd.Dispose()

    $definitions = [ordered]@{
        item_name='TEXT'; category='TEXT'; category_id='INT DEFAULT 1'; point_cost='INT DEFAULT 0';
        original_price='INT DEFAULT 0'; gold_cost='INT DEFAULT 0'; count='INT DEFAULT 1'; is_hot='INT DEFAULT 0';
        is_new='INT DEFAULT 0'; is_limited='INT DEFAULT 0'; on_sale='INT DEFAULT 0'; discount='INT DEFAULT 100';
        badge='INT DEFAULT 0'; order_idx='INT DEFAULT 0'; is_bonus='INT DEFAULT 0'; subcategory_id='INT DEFAULT 1';
        description="TEXT DEFAULT ''"
    }
    foreach ($name in $definitions.Keys) {
        if (-not $columns.ContainsKey($name)) {
            $alter = $Connection.CreateCommand()
            $alter.CommandText = "ALTER TABLE item_mall ADD COLUMN $name $($definitions[$name]);"
            [void]$alter.ExecuteNonQuery()
            $alter.Dispose()
            Write-Host "Added missing item_mall.$name column."
        }
    }
}

function Write-SupportReport($Items, [string]$Path) {
    $known = @{ 34269='Potential Pill'; 30025='Star'; 34258='Training Ticket'; 32176='Fugu Hot Pot'; 34190='10X Holy EXP Potion' }
    $rows = foreach ($item in $Items) {
        $support = 'Needs special handler'
        if ($known.ContainsKey([int]$item.ItemID)) { $support = 'Usable - explicit server handler' }
        elseif ([int]$item.EquipPos -gt 0) { $support = 'Usable - equipment' }
        elseif ([int]$item.ItemType -eq 27) { $support = 'Usable - tent' }
        elseif (@(207,208) -contains [int]$item.StatusType1 -or @(207,208) -contains [int]$item.StatusType2) { $support = 'Usable - HP/SP recovery metadata' }
        elseif ([int]$item.ItemType -eq 20) { $support = 'Needs pet-target effect handler' }
        elseif (@(17,26,41) -contains [int]$item.ItemType) { $support = 'Needs box/pack contents handler' }
        elseif ([int]$item.ItemType -eq 39) { $support = 'Needs vehicle handler' }
        elseif (@(28,29,31,33,34,35,36,37,38,51,52,54) -contains [int]$item.ItemType) { $support = 'Available - material/passive item' }
        [pscustomobject]@{
            ItemID=$item.ItemID; Name=$item.Name; ItemType=$item.ItemType; EquipPos=$item.EquipPos;
            StatusType1=$item.StatusType1; StatusUp1=$item.StatusUp1; StatusType2=$item.StatusType2; StatusUp2=$item.StatusUp2;
            Support=$support
        }
    }
    $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    $needs = @($rows | Where-Object { $_.Support -like 'Needs*' }).Count
    $usable = $rows.Count - $needs
    Write-Host "WLRI compatibility report: $usable currently generic/usable/passive, $needs still require special behavior handlers."
    Write-Host "Report: $Path"
}

Write-Host "Reading Item Mall catalog: $catalogPath"
$catalogRows = @(Read-FlatJsonRows $catalogPath)
Write-Host "Catalog rows loaded: $($catalogRows.Count)"

Write-Host "Reading Rhode Island Item.dat: $ItemDatPath"
$wlriItems = @(Read-WlriItems $ItemDatPath)
Write-Host "Decoded unique WLRI items: $($wlriItems.Count)"

# Sync every decoded Rhode Island item into the compact 47-byte format that the server
# actually loads first at startup (itemDat.wpdat). This is what makes the inventory
# recognise the entire WLRI item ID set instead of rejecting client-only IDs.
Write-CompactItemDat $wlriItems $compactItemPath
Write-SupportReport $wlriItems $supportReportPath

$removeNames = @(
    'Cyan Bone Dual Fan Bag','Gem Dharma Sword Bag','Cat Shoes Lucky Bag','Dark Dharma King Bag','Pink Ribbon Lucky Bag',
    'Snow Songstress Bag','Chinese General Bag','Roman Warrior Bag','New Companion Gear Bag','Battle Boost Lucky Bag',
    'Class Weapon Lucky Bag','Tongpu Box','Dharma Sword Box','Beast Devil Fork Box','Spirit Devil Fork Box',
    'Brilliant Staff Box','Great Angel Wings Box','Gift Pack','War Pack','7 Colors Egg','Potato Chips Pack (50)',
    'Fried Chicken Pack (50)','Trilobite Pack','Naughty Monkey Pack','Naughty Dolphin Pack','Ghost War Horse Pack',
    'Training Box','Chili Sauce','Wasabi','Enhanced Skin Milk','Newbie Box','Special Shadow Pack','Golden Shadow Pack',
    'Aligote','Apple','Banana','Big Apple','Brown Nut','Cantaloupe','Coconut','Coconut (Pulp)','Golden Apple','Gooseberry',
    'Green Apple','Grape','Hazelnut','Juicy Peach','Latania','Lemon','Mandarin Orange','Mango','Muskmelon','Orange',
    'Papaya','Persimmon','Pineapple','Strawberry','Watermelon'
)
$removeSet = @{}
foreach ($n in $removeNames) { $removeSet[(Normalize-Name $n)] = $true }

$kept = New-Object System.Collections.Generic.List[object]
$removedCount = 0
foreach ($raw in $catalogRows) {
    $row = Normalize-MallRow $raw
    if ($removeSet.ContainsKey((Normalize-Name $row.item_name))) { $removedCount++; continue }
    if ($row.item_id -le 0) { continue }
    $kept.Add($row)
}

$specs = New-Object System.Collections.Generic.List[object]
$specs.Add((New-AddSpec 'Super Potential Pill' @('Super Potential Pill','Super Potential') 'Grocery' 4 'Requested'))
$specs.Add((New-AddSpec 'Shadow Pestle' @('Shadow Pestle') 'Weaponry' 3 'Requested'))
$specs.Add((New-AddSpec 'Dragon Spar' @('Dragon Spar') 'Grocery' 4 'Requested'))
$specs.Add((New-AddSpec '15X Holy EXP Potion' @('15X Holy EXP Potion','15X EXP Potion','15x Holy EXP Potion','15 Holy EXP Potion') 'Grocery' 4 'Requested'))
$specs.Add((New-AddSpec 'Snow Girl Pack' @('Snow Girl Pack','Snow Girl Lucky Bag','Snow Girl Bag') 'Grocery' 4 'Requested'))
$specs.Add((New-AddSpec 'Xmas Fork' @('Xmas Fork','X-mas Fork','Christmas Fork') 'Weaponry' 3 'Requested'))
$specs.Add((New-AddSpec 'Forest Fork' @('Forest Fork') 'Weaponry' 3 'Requested'))
$specs.Add((New-AddSpec 'Soul Reaper' @('Soul Reaper','Soul Reapers','Souls Reaper','Souls Reapers',"Soul's Reaper","Soul's Reapers") 'Weaponry' 3 'Requested'))
$specs.Add((New-AddSpec 'Attack Pestle' @('Attack Pestle','Attack Pestal') 'Weaponry' 3 'Requested'))
$specs.Add((New-AddSpec '2X EXP Gold Card' @('2X EXP Gold Card','Gold Card') 'Grocery' 4 'Requested'))
$specs.Add((New-AddSpec 'Snow Ears' @('Snow Ears','Snow Ear') 'Armory' 2 'Requested'))

$petSpecs = @(
    @{Name='Invincible Banana Boat';Aliases=@('Invincible Banana Boat','Banana Boat')},
    @{Name='Taming Pill';Aliases=@('Taming Pill','Beast Taming Pill','Animal Taming Pill')},
    @{Name='Barley Energy Pill';Aliases=@('Barley Energy Pill','Barley Pill')},
    @{Name='Fairy Honey';Aliases=@('Fairy Honey')}, @{Name='Orchid Candy';Aliases=@('Orchid Candy')},
    @{Name='Niss Syrup';Aliases=@('Niss Syrup','Silk Syrup')}, @{Name='Pirate Wine';Aliases=@('Pirate Wine')},
    @{Name='Old Whisky';Aliases=@('Old Whisky','Old Whiskey','Aged Whisky','Aged Whiskey')},
    @{Name='Elin Oil';Aliases=@('Elin Oil','Elin Engine Oil')}, @{Name='Roca Perfume';Aliases=@('Roca Perfume')},
    @{Name='Moon Bean';Aliases=@('Moon Bean','Moon God Bean','Lunar Bean')},
    @{Name='Strawberry Mochi';Aliases=@('Strawberry Mochi','Strawberry Daifuku')},
    @{Name='Devil Forbidden Fruit';Aliases=@('Devil Forbidden Fruit','Forbidden Fruit','Devil Fruit')},
    @{Name='Shasha Marshmallow';Aliases=@('Shasha Marshmallow')}, @{Name='Taiyaki';Aliases=@('Taiyaki')},
    @{Name='Wolf Bean';Aliases=@('Wolf Bean','Wolf Tribe Bean')}, @{Name='Wasabi Rice Ball';Aliases=@('Wasabi Rice Ball','Wasabi Riceball')},
    @{Name='Tonic Soup';Aliases=@('Tonic Soup')}, @{Name='Angel Feather';Aliases=@('Angel Feather')},
    @{Name='Divine Bean';Aliases=@('Divine Bean','Magic Bean','Godly Bean')}, @{Name='Love Water';Aliases=@('Love Water')},
    @{Name='Wisdom Water';Aliases=@('Wisdom Water')}, @{Name='French Black Tea';Aliases=@('French Black Tea','French Tea')},
    @{Name='Pet Food Pack';Aliases=@('Pet Food Pack')}
)
foreach ($p in $petSpecs) { $specs.Add((New-AddSpec $p.Name $p.Aliases 'Grocery' 4 'Pet Enhancement')) }

$maxOrder = 0
foreach ($row in $kept) { if ($row.is_bonus -eq 0 -and $row.order_idx -gt $maxOrder) { $maxOrder = $row.order_idx } }
$unresolved = New-Object System.Collections.Generic.List[string]
$resolvedCount = 0
foreach ($spec in $specs) {
    $match = Find-ItemMatch $wlriItems $spec.Aliases
    if (-not $match) { $unresolved.Add([string]$spec.Name); continue }

    $existing = @($kept | Where-Object { $_.is_bonus -eq 0 -and $_.item_id -eq $match.ItemID })
    if ($existing.Count -gt 0) {
        foreach ($row in $existing) { $row.point_cost=0; $row.original_price=0; $row.gold_cost=0; $row.on_sale=0; $row.discount=100 }
        Write-Host "Already present/free: $($spec.Name) (#$($match.ItemID))"
    }
    else {
        $maxOrder++
        $kept.Add((New-MallRow $spec $match $maxOrder))
        $resolvedCount++
        Write-Host "Resolved [$($spec.Group)]: $($spec.Name) -> '$($match.Name)' (#$($match.ItemID))"
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$catalogBackup = "$catalogPath.before-wlri-sync-$stamp.bak"
$dbBackup = "$databasePath.before-wlri-sync-$stamp.bak"
Copy-Item -LiteralPath $catalogPath -Destination $catalogBackup -Force
Copy-Item -LiteralPath $databasePath -Destination $dbBackup -Force

try {
    $jsonOut = @($kept) | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($catalogPath, $jsonOut + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    if (-not ('System.Data.SQLite.SQLiteConnection' -as [type])) { Add-Type -Path $sqliteDll }
    $connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$databasePath;Version=3;")
    $connection.Open()
    try {
        Ensure-ItemMallSchema $connection
        $tx = $connection.BeginTransaction()
        try {
            $delete = $connection.CreateCommand(); $delete.Transaction=$tx; $delete.CommandText='DELETE FROM item_mall;'; [void]$delete.ExecuteNonQuery(); $delete.Dispose()
            foreach ($row in $kept) {
                $insert = $connection.CreateCommand(); $insert.Transaction=$tx
                $insert.CommandText = @'
INSERT INTO item_mall
(item_id,item_name,category,category_id,point_cost,original_price,gold_cost,count,is_hot,is_new,is_limited,on_sale,discount,badge,order_idx,is_bonus,subcategory_id,description)
VALUES (@item_id,@item_name,@category,@category_id,0,0,0,@count,@is_hot,@is_new,@is_limited,0,100,@badge,@order_idx,@is_bonus,@subcategory_id,@description);
'@
                [void]$insert.Parameters.AddWithValue('@item_id',[int]$row.item_id)
                [void]$insert.Parameters.AddWithValue('@item_name',[string]$row.item_name)
                [void]$insert.Parameters.AddWithValue('@category',[string]$row.category)
                [void]$insert.Parameters.AddWithValue('@category_id',[int]$row.category_id)
                [void]$insert.Parameters.AddWithValue('@count',[int]$row.count)
                [void]$insert.Parameters.AddWithValue('@is_hot',[int]$row.is_hot)
                [void]$insert.Parameters.AddWithValue('@is_new',[int]$row.is_new)
                [void]$insert.Parameters.AddWithValue('@is_limited',[int]$row.is_limited)
                [void]$insert.Parameters.AddWithValue('@badge',[int]$row.badge)
                [void]$insert.Parameters.AddWithValue('@order_idx',[int]$row.order_idx)
                [void]$insert.Parameters.AddWithValue('@is_bonus',[int]$row.is_bonus)
                [void]$insert.Parameters.AddWithValue('@subcategory_id',[int]$row.subcategory_id)
                [void]$insert.Parameters.AddWithValue('@description',[string]$row.description)
                [void]$insert.ExecuteNonQuery(); $insert.Dispose()
            }
            $tx.Commit()
        }
        catch { try { $tx.Rollback() } catch {}; throw }
        finally { if ($tx) { $tx.Dispose() } }
    }
    finally { if ($connection) { $connection.Close(); $connection.Dispose() } }
}
catch {
    Copy-Item -LiteralPath $catalogBackup -Destination $catalogPath -Force
    Copy-Item -LiteralPath $dbBackup -Destination $databasePath -Force
    throw
}

Write-Host ''
Write-Host 'WLRI item sync + Item Mall curation complete.' -ForegroundColor Green
Write-Host "WLRI runtime items synced: $($wlriItems.Count)"
Write-Host "Catalog rows removed: $removedCount"
Write-Host "New requested/pet mall rows added: $resolvedCount"
Write-Host "Final Item Mall rows: $($kept.Count)"
Write-Host 'All normal and bonus Item Mall prices are 0 points.' -ForegroundColor Green
Write-Host "Runtime item file: $compactItemPath"
Write-Host "Support report: $supportReportPath"

if ($unresolved.Count -gt 0) {
    Write-Host ''
    Write-Host 'Requested/pet items not found by name in this exact WLRI client revision:' -ForegroundColor Yellow
    foreach ($name in $unresolved) { Write-Host "  - $name" }
}

Write-Host ''
Write-Host 'Important: all decoded WLRI item IDs now exist in the server item database. Items marked Needs* in wlri-item-support.csv still need an authentic special-effect handler before their unique behavior can be claimed as fully implemented.' -ForegroundColor Cyan
