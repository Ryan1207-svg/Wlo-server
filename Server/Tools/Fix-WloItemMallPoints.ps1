param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Read-Text([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Missing file: $Path" }
    return [IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Replace-Once {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
        [string]$Label
    )

    if ($Text.Contains($New)) { return $Text }
    if (-not $Text.Contains($Old)) { throw "Could not find patch anchor: $Label" }
    return $Text.Replace($Old, $New)
}

$ac23Path = Join-Path $RepoRoot 'Server\Src\Network\ActionCodes\AC23.cs'
$playerPath = Join-Path $RepoRoot 'Server\wlo.pserver.core\Game\Player.cs'
$registrationPath = Join-Path $RepoRoot 'Server\Src\Server\API\RegistrationServer.cs'

$ac23 = Read-Text $ac23Path
$player = Read-Text $playerPath
$registration = Read-Text $registrationPath

# -----------------------------------------------------------------------------
# Native Rhode Island Item Mall purchase (AC23:26)
# The byte sent after ItemID is the ADVERTISED BUNDLE COUNT, not the number of
# packages the player wants to buy. Passing it as PurchaseItem(quantity) caused
# a 600-point bundle advertised as x200 to be charged as 600 * 200 = 120,000.
# -----------------------------------------------------------------------------
$ac23 = Replace-Once $ac23 `
    'bool success = ItemMallManager.PurchaseItem(p, itemId, count);' `
    'bool success = ItemMallManager.PurchaseAdvertisedItem(p, itemId, count);' `
    'AC23 advertised bundle purchase'

# Keep the online in-memory balance synchronized with the users.IM database
# value before balance display/purchase. This matters when IM is edited in the
# server GUI/database while the account is already logged in.
if (-not $ac23.Contains('private static void RefreshItemMallBalance(Player p)')) {
    $marker = '        void Recv25(Player p, RecievePacket r)'
    if (-not $ac23.Contains($marker)) { throw 'Could not find patch anchor: AC23 Recv25' }

    $helper = @'
        private static void RefreshItemMallBalance(Player p)
        {
            try
            {
                if (p?.UserAccount == null || p.UserAccount.DataBaseID == 0 || cGlobal.gUserDataBase == null)
                    return;

                int dbPoints = cGlobal.gUserDataBase.GetIMPoints(p.UserAccount.DataBaseID);
                p.UserAccount.IM = Math.Max(0, dbPoints);
                DebugSystem.Write($"[ItemMall] Refreshed IM balance for {p.CharName}: {p.UserAccount.IM} points (UserID {p.UserAccount.DataBaseID}).");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[ItemMall] Could not refresh IM balance for {p?.CharName ?? "Unknown"}: {ex.Message}");
            }
        }

'@
    $ac23 = $ac23.Replace($marker, $helper + $marker)
}

$ac23 = Replace-Once $ac23 `
    '            try { ItemMallManager.SendPointBalance(p); }' `
    '            try { RefreshItemMallBalance(p); ItemMallManager.SendPointBalance(p); }' `
    'AC23 balance refresh'

$purchaseLine = '                bool success = ItemMallManager.PurchaseAdvertisedItem(p, itemId, count);'
$purchaseWithRefresh = @'
                // Refresh from users.IM first, then resolve the exact advertised bundle row.
                RefreshItemMallBalance(p);
                bool success = ItemMallManager.PurchaseAdvertisedItem(p, itemId, count);
'@
if (-not $ac23.Contains('// Refresh from users.IM first, then resolve the exact advertised bundle row.')) {
    if (-not $ac23.Contains($purchaseLine)) { throw 'Could not find patch anchor: AC23 purchase refresh' }
    $ac23 = $ac23.Replace($purchaseLine, $purchaseWithRefresh.TrimEnd("`r", "`n"))
}

# -----------------------------------------------------------------------------
# Chat /buy command had the same bundle-count bug.
# -----------------------------------------------------------------------------
$player = Replace-Once $player `
    'Game.PlayerRelated.ItemMallManager.PurchaseItem(c, targetItem.ItemID, targetItem.Count)' `
    'Game.PlayerRelated.ItemMallManager.PurchaseAdvertisedItem(c, targetItem.ItemID, targetItem.Count)' `
    'Player /buy advertised bundle purchase'

# -----------------------------------------------------------------------------
# Web Item Mall already resolves advertised bundle rows correctly. Make its
# online player balance use the same users.IM value immediately before buying.
# -----------------------------------------------------------------------------
if (-not $registration.Contains('// Synchronize the online account with the authoritative users.IM balance before purchase.')) {
    $oldWebBuy = '            bool ok = Game.PlayerRelated.ItemMallManager.PurchaseAdvertisedItem(target, itemId, advertisedCount, false);'
    if (-not $registration.Contains($oldWebBuy)) { throw 'Could not find patch anchor: web Item Mall purchase' }

    $newWebBuy = @'
            // Synchronize the online account with the authoritative users.IM balance before purchase.
            if (target.UserAccount != null)
            {
                int dbPoints = _userDb.GetIMPoints(session.UserId);
                target.UserAccount.IM = Math.Max(0, dbPoints);
            }

            bool ok = Game.PlayerRelated.ItemMallManager.PurchaseAdvertisedItem(target, itemId, advertisedCount, false);
'@
    $registration = $registration.Replace($oldWebBuy, $newWebBuy.TrimEnd("`r", "`n"))
}

Write-Text $ac23Path $ac23
Write-Text $playerPath $player
Write-Text $registrationPath $registration

Write-Host ''
Write-Host 'WLO Item Mall purchase fix applied.' -ForegroundColor Green
Write-Host 'Fixed:'
Write-Host '  - Native Item Mall bundle count no longer multiplies the listed price'
Write-Host '  - /buy uses the advertised bundle instead of treating bundle size as quantity'
Write-Host '  - IM balance refreshes from users.IM before native purchases'
Write-Host '  - Web Item Mall refreshes users.IM before purchases'
Write-Host ''
Write-Host 'Rebuild and restart the server before testing.' -ForegroundColor Cyan
