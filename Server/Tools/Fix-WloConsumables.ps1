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

    if (-not $Text.Contains($Old)) {
        throw "Could not find patch anchor: $Label"
    }

    return $Text.Replace($Old, $New)
}

$equipPath = Join-Path $RepoRoot 'Server\wlo.pserver.core\Game\PlayerRelated\Equip.cs'
$ac23Path  = Join-Path $RepoRoot 'Server\Src\Network\ActionCodes\AC23.cs'

if (-not (Test-Path $equipPath)) { throw "Missing file: $equipPath" }
if (-not (Test-Path $ac23Path))  { throw "Missing file: $ac23Path" }

$equip = [IO.File]::ReadAllText($equipPath)
$ac23  = [IO.File]::ReadAllText($ac23Path)

# -----------------------------------------------------------------------------
# EquipManager: add timed EXP multipliers used by Holy EXP Potions.
# CurExp is the central EXP-gain path, so applying the multiplier here makes it
# work for normal PvE rewards without duplicating logic in each battle system.
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
# AC23: Rhode Island client sends AC23:128 when an inventory item is double-clicked.
# Add explicit handlers for the starter consumables that Item.dat alone does not
# currently describe sufficiently for the emulator.
# -----------------------------------------------------------------------------
if (-not $ac23.Contains('using Game.Maps;')) {
    $ac23 = Replace-Required $ac23 "using Game.Code;`r`nusing Game.PlayerRelated;" "using Game.Code;`r`nusing Game.Maps;`r`nusing Game.PlayerRelated;" 'AC23 Game.Maps import'
}

if (-not $ac23.Contains('itemId == 32176')) {
    $oldRecovery = @'
            hpGain = 0;
            spGain = 0;

            if (itemInfo != null && itemInfo.StatusType != null && itemInfo.StatusUp != null)
'@

    $newRecovery = @'
            hpGain = 0;
            spGain = 0;

            // Fugu Hot Pot (starter item #32176): official effect is HP +300 / SP +300.
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

if (-not $ac23.Contains('10X Holy EXP Potion')) {
    $oldPotential = @'
                // Potential Pill
                if (itemId == 34269)
'@

    $newPotential = @'
                // 10X Holy EXP Potion (#34190): 10x battle EXP for two hours.
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
                    SendItemMessage(p, "10X Holy EXP Potion activated: battle EXP x10 for 2 hours.");
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} activated 10X Holy EXP Potion (#34190) for 2 hours.");
                    return;
                }

                // Training Ticket (#34258): enter Training Island. The ticket grants a six-hour
                // training session in the original game. The current emulator records the entry
                // by consuming the ticket and warping to the Training Island entrance map.
                if (itemId == 34258)
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
                    DebugSystem.Write($"[AC23.UseItem] {p.CharName} used Training Ticket (#34258) and warped to map 13050.");
                    return;
                }

                // Potential Pill
                if (itemId == 34269)
'@

    $ac23 = Replace-Required $ac23 $oldPotential $newPotential 'Holy EXP Potion and Training Ticket handlers'
}

[IO.File]::WriteAllText($equipPath, $equip, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($ac23Path, $ac23, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'WLO consumable patch applied.' -ForegroundColor Green
Write-Host 'Fixed:'
Write-Host '  - #32176 Fugu Hot Pot: +300 HP / +300 SP'
Write-Host '  - #34190 10X Holy EXP Potion: x10 EXP for 2 hours'
Write-Host '  - #34258 Training Ticket: warps to Training Island (map 13050)'
Write-Host ''
Write-Host 'Now rebuild Wonderland Private Server.sln.' -ForegroundColor Cyan
