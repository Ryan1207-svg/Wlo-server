param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Replace-Required {
    param(
        [string]$Text,
        [string]$Old,
        [string]$New,
        [string]$Label
    )

    $normalizedText = $Text.Replace("`r`n", "`n")
    $normalizedOld  = $Old.Replace("`r`n", "`n")
    $normalizedNew  = $New.Replace("`r`n", "`n")

    if (-not $normalizedText.Contains($normalizedOld)) {
        throw "Could not find patch anchor: $Label"
    }

    return $normalizedText.Replace($normalizedOld, $normalizedNew)
}

$equipPath = Join-Path $RepoRoot 'Server\wlo.pserver.core\Game\PlayerRelated\Equip.cs'
$ac23Path  = Join-Path $RepoRoot 'Server\Src\Network\ActionCodes\AC23.cs'

if (-not (Test-Path $equipPath)) { throw "Missing file: $equipPath" }
if (-not (Test-Path $ac23Path))  { throw "Missing file: $ac23Path" }

$equip = [IO.File]::ReadAllText($equipPath)
$ac23  = [IO.File]::ReadAllText($ac23Path)

# -----------------------------------------------------------------------------
# EquipManager: timed EXP multipliers used by Holy EXP Potions.
# CurExp is the central EXP-gain path, so normal battle rewards inherit the boost.
# -----------------------------------------------------------------------------
if (-not $equip.Contains('SetExpMultiplier(double multiplier, TimeSpan duration)')) {
    $oldFields = @'
        byte head;
        int m_currexp, m_curhp, m_cursp, gold, m_skillpoint, m_potential;
        long m_totalexp = 0;
        BodyStyle body;
'@

    $newFields = @'
        byte head;
        int m_currexp, m_curhp, m_cursp, gold, m_skillpoint, m_potential;
        long m_totalexp = 0;
        double m_expMultiplier = 1.0;
        DateTime m_expMultiplierUntilUtc = DateTime.MinValue;
        BodyStyle body;
'@

    $equip = Replace-Required $equip $oldFields $newFields 'EquipManager EXP fields'

    $oldTotalExp = @'
        public long TotalExp
        {
            get
            {
                lock (m_Lock)
                {
                    return m_totalexp;
                }
            }
            set
            {
                lock (m_Lock)
                {
                    m_totalexp = value;
                }
            }
        }
'@

    $newTotalExp = @'
        public long TotalExp
        {
            get
            {
                lock (m_Lock)
                {
                    return m_totalexp;
                }
            }
            set
            {
                lock (m_Lock)
                {
                    m_totalexp = value;
                }
            }
        }

        public double ExpMultiplier
        {
            get
            {
                lock (m_Lock)
                {
                    if (DateTime.UtcNow >= m_expMultiplierUntilUtc)
                    {
                        m_expMultiplier = 1.0;
                        m_expMultiplierUntilUtc = DateTime.MinValue;
                    }
                    return m_expMultiplier;
                }
            }
        }

        public TimeSpan ExpMultiplierRemaining
        {
            get
            {
                lock (m_Lock)
                {
                    TimeSpan remaining = m_expMultiplierUntilUtc - DateTime.UtcNow;
                    return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
                }
            }
        }

        public void SetExpMultiplier(double multiplier, TimeSpan duration)
        {
            lock (m_Lock)
            {
                if (multiplier < 1.0) multiplier = 1.0;
                if (duration < TimeSpan.Zero) duration = TimeSpan.Zero;

                m_expMultiplier = multiplier;
                m_expMultiplierUntilUtc = DateTime.UtcNow.Add(duration);
            }
        }
'@

    $equip = Replace-Required $equip $oldTotalExp $newTotalExp 'EquipManager TotalExp property'

    $oldGain = @'
                    long expgain = value;

                    while (expgain > 0)
'@

    $newGain = @'
                    long expgain = value;

                    if (expgain > 0)
                    {
                        if (DateTime.UtcNow >= m_expMultiplierUntilUtc)
                        {
                            m_expMultiplier = 1.0;
                            m_expMultiplierUntilUtc = DateTime.MinValue;
                        }
                        else if (m_expMultiplier > 1.0)
                        {
                            expgain = (long)Math.Min(long.MaxValue, Math.Round(expgain * m_expMultiplier));
                        }
                    }

                    while (expgain > 0)
'@

    $equip = Replace-Required $equip $oldGain $newGain 'CurExp multiplier hook'
}

# -----------------------------------------------------------------------------
# AC23 item use support.
# -----------------------------------------------------------------------------
if (-not $ac23.Contains('using Game.Maps;')) {
    $ac23 = Replace-Required $ac23 "using Game.Code;`nusing Game.PlayerRelated;" "using Game.Code;`nusing Game.Maps;`nusing Game.PlayerRelated;" 'AC23 Game.Maps import'
}

# Fugu Hot Pot (#32176): +300 HP / +300 SP.
if (-not $ac23.Contains('Fugu Hot Pot (starter item #32176)')) {
    $oldRecovery = @'
            hpGain = 0;
            spGain = 0;

            if (itemInfo != null && itemInfo.StatusType != null && itemInfo.StatusUp != null)
'@

    $newRecovery = @'
            hpGain = 0;
            spGain = 0;

            // Fugu Hot Pot (starter item #32176): HP +300 / SP +300.
            if (itemId == 32176)
            {
                hpGain = 300;
                spGain = 300;
                return true;
            }

            if (itemInfo != null && itemInfo.StatusType != null && itemInfo.StatusUp != null)
'@

    $ac23 = Replace-Required $ac23 $oldRecovery $newRecovery 'Fugu Hot Pot recovery'
}

# Add special consumables to the standard double-click/use path.
if (-not $ac23.Contains('WLO SPECIAL CONSUMABLES - STANDARD USE PATH')) {
    $oldPotential = @'
                // Potential Pill
                if (itemId == 34269)
'@

    $newPotential = @'
                // WLO SPECIAL CONSUMABLES - STANDARD USE PATH
                // 10X Holy EXP Potion (#34190): 10x EXP for two hours.
                if (itemId == 34190)
                {
                    if (p.Eqs == null)
                    {
                        SendItemMessage(p, "Unable to activate the EXP potion right now; the item was not consumed.");
                        return;
                    }

                    p.Eqs.SetExpMultiplier(10.0, TimeSpan.FromHours(2));
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "10X Holy EXP Potion activated: EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                // Training Ticket. Both IDs have appeared in Rhode Island client data/logs.
                if (itemId == 34253 || itemId == 34258)
                {
                    if (p.Level < 1 || p.Level > 199)
                    {
                        SendItemMessage(p, "Training Tickets can only be used from level 1 to 199.");
                        return;
                    }
                    if (p.CurMap == null)
                    {
                        SendItemMessage(p, "Training Island is unavailable right now; the ticket was not consumed.");
                        return;
                    }

                    WarpData warp = new WarpData
                    {
                        DstMap = 13050,
                        DstX_Axis = 100,
                        DstY_Axis = 100
                    };

                    p.CurMap.Teleport(TeleportType.CmD, p, 0, warp);
                    p.Inv.RemoveItem(slot, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "Training Ticket used. Welcome to Training Island!");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} used Training Ticket (#{itemId}) and warped to map 13050.");
                    return;
                }

                // Potential Pill
                if (itemId == 34269)
'@

    $ac23 = Replace-Required $ac23 $oldPotential $newPotential 'special standard-use consumables'
}

# Rhode Island also sends special consumables through AC23:15. Handle those
# before the HP/SP-only fallback so valid special items do not report unsupported.
if (-not $ac23.Contains('WLO SPECIAL CONSUMABLES - AC23:15 PATH')) {
    $oldRecv15 = @'
                var itemInfo = cGlobal.ItemDatManager?.GetItemByID(item.ItemID);
                if (!TryGetRecovery(item.ItemID, itemInfo, out int hpGain, out int spGain))
'@

    $newRecv15 = @'
                var itemInfo = cGlobal.ItemDatManager?.GetItemByID(item.ItemID);

                // WLO SPECIAL CONSUMABLES - AC23:15 PATH
                if (item.ItemID == 34190)
                {
                    if (p.Eqs == null)
                    {
                        SendItemMessage(p, "Unable to activate the EXP potion right now; the item was not consumed.");
                        return;
                    }

                    p.Eqs.SetExpMultiplier(10.0, TimeSpan.FromHours(2));
                    p.Inv.RemoveItem(pos, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "10X Holy EXP Potion activated: EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.Recv15] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                if (item.ItemID == 34253 || item.ItemID == 34258)
                {
                    if (p.Level < 1 || p.Level > 199)
                    {
                        SendItemMessage(p, "Training Tickets can only be used from level 1 to 199.");
                        return;
                    }
                    if (p.CurMap == null)
                    {
                        SendItemMessage(p, "Training Island is unavailable right now; the ticket was not consumed.");
                        return;
                    }

                    WarpData warp = new WarpData
                    {
                        DstMap = 13050,
                        DstX_Axis = 100,
                        DstY_Axis = 100
                    };

                    p.CurMap.Teleport(TeleportType.CmD, p, 0, warp);
                    p.Inv.RemoveItem(pos, 1);
                    p.SaveCharacterData();
                    SendItemMessage(p, "Training Ticket used. Welcome to Training Island!");
                    DebugSystem.Write($"[AC23.Recv15] {p.CharName} used Training Ticket (#{item.ItemID}) and warped to map 13050.");
                    return;
                }

                if (item.ItemID == 34269)
                {
                    UsePotentialPill(p, pos, GetItemName(item, item.ItemID));
                    return;
                }

                if (!TryGetRecovery(item.ItemID, itemInfo, out int hpGain, out int spGain))
'@

    $ac23 = Replace-Required $ac23 $oldRecv15 $newRecv15 'AC23:15 special consumables'
}

[IO.File]::WriteAllText($equipPath, $equip, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($ac23Path, $ac23, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'WLO consumable patch applied.' -ForegroundColor Green
Write-Host 'Fixed:'
Write-Host '  - #32176 Fugu Hot Pot: +300 HP / +300 SP'
Write-Host '  - #34190 10X Holy EXP Potion: x10 EXP for 2 hours'
Write-Host '  - #34253 / #34258 Training Ticket: Training Island warp'
Write-Host '  - #34269 Potential Pill through standard and AC23:15 item-use paths'
Write-Host ''
