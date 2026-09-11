param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
$mainFormPath = Join-Path $RepoRoot 'Server\Src\Gui\MainForm1.cs'
if (-not (Test-Path -LiteralPath $mainFormPath)) { throw "Missing file: $mainFormPath" }

$text = [IO.File]::ReadAllText($mainFormPath)
$original = $text

# Normalize only while matching; write back using Windows line endings.
$text = $text -replace "`r`n", "`n"

if (-not $text.Contains('WLO_STATS_TAB_CHARACTER_REFRESH')) {
    $oldTabBlock = @'
                        else if (this.tabControl3.SelectedTab.Text.Contains("Item Mall"))
                        {
                            RefreshMallGrid();
                        }
'@
    $newTabBlock = @'
                        else if (this.tabControl3.SelectedTab.Text.Contains("Item Mall"))
                        {
                            RefreshMallGrid();
                        }
                        else if (this.tabControl3.SelectedTab.Text.Equals("Stats", StringComparison.OrdinalIgnoreCase))
                        {
                            // WLO_STATS_TAB_CHARACTER_REFRESH
                            // Form1_Load can run before the background server thread has created
                            // CharacterDataBase, so the first LoadCharacterFilters call may be empty.
                            // Reload when the Stats tab is actually opened, after DB startup.
                            LoadCharacterFilters();
                            btnRefreshStats_Click(null, null);
                        }
'@

    if (-not $text.Contains($oldTabBlock)) {
        throw 'Could not find Item Mall tab refresh block in MainForm1.cs.'
    }
    $text = $text.Replace($oldTabBlock, $newTabBlock)
}

if (-not $text.Contains('WLO_STATS_REFRESH_EMPTY_COMBO')) {
    $oldStatsStart = @'
        private void btnRefreshStats_Click(object sender, EventArgs e)
        {
            try
            {
                // Get selected character from filter
'@
    $newStatsStart = @'
        private void btnRefreshStats_Click(object sender, EventArgs e)
        {
            try
            {
                // WLO_STATS_REFRESH_EMPTY_COMBO
                // Refresh is also a recovery path if the form loaded before the DB was ready.
                if (cmbCharacterFilterStats.Items.Count == 0)
                    LoadCharacterFilters();

                // Get selected character from filter
'@

    if (-not $text.Contains($oldStatsStart)) {
        throw 'Could not find btnRefreshStats_Click in MainForm1.cs.'
    }
    $text = $text.Replace($oldStatsStart, $newStatsStart)
}

if (-not $text.Contains('WLO_CHARACTER_FILTER_AUTOSELECT')) {
    $oldFilterTail = @'
                    foreach (System.Data.DataRow row in characters.Rows)
                    {
                        string item = $"{row["charID"]} - {row["name"]}";
                        cmbCharacterFilter.Items.Add(item);
                        cmbCharacterFilterStats.Items.Add(item);
                    }
                }
'@
    $newFilterTail = @'
                    foreach (System.Data.DataRow row in characters.Rows)
                    {
                        string item = $"{row["charID"]} - {row["name"]}";
                        cmbCharacterFilter.Items.Add(item);
                        cmbCharacterFilterStats.Items.Add(item);
                    }

                    // WLO_CHARACTER_FILTER_AUTOSELECT
                    // Select the first persisted character so Inventory/Stats are useful
                    // immediately instead of leaving the drop-down blank.
                    if (cmbCharacterFilter.Items.Count > 0 && cmbCharacterFilter.SelectedIndex < 0)
                        cmbCharacterFilter.SelectedIndex = 0;
                    if (cmbCharacterFilterStats.Items.Count > 0 && cmbCharacterFilterStats.SelectedIndex < 0)
                        cmbCharacterFilterStats.SelectedIndex = 0;
                }
'@

    if (-not $text.Contains($oldFilterTail)) {
        throw 'Could not find LoadCharacterFilters population block in MainForm1.cs.'
    }
    $text = $text.Replace($oldFilterTail, $newFilterTail)
}

if ($text -eq ($original -replace "`r`n", "`n")) {
    Write-Host 'Stats tab fix is already applied.' -ForegroundColor Green
    exit 0
}

$text = $text -replace "(?<!`r)`n", "`r`n"
$backup = "$mainFormPath.before-stats-fix.bak"
Copy-Item -LiteralPath $mainFormPath -Destination $backup -Force
[IO.File]::WriteAllText($mainFormPath, $text, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host 'Stats tab character loading fix applied.' -ForegroundColor Green
Write-Host 'Fixed:'
Write-Host '  - Stats tab reloads persisted characters when opened'
Write-Host '  - Refresh Stats recovers if the initial DB load happened too early'
Write-Host '  - First character is automatically selected in Inventory/Stats filters'
Write-Host "Backup: $backup"
Write-Host ''
Write-Host 'Rebuild and restart the Wonderland Private Server.' -ForegroundColor Cyan
