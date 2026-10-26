#!/usr/bin/env bash
# run-core-tests.sh — teste le CŒUR de windows/llm-tray.ps1 depuis Linux, sans Windows.
#
# Le script Windows est coupé à la section « interface » (celle qui charge
# System.Windows.Forms, absent sous Linux) : ne restent que la configuration, les fonctions HTTP
# et le calcul d'état, exécutés VERBATIM contre les vraies APIs du LAN. C'est ce qui permet de
# valider une modification de la logique de sondage sans rebooter le .224 sous Windows.
#
# Usage :  windows/tests/run-core-tests.sh
#          PWSH=/usr/bin/pwsh windows/tests/run-core-tests.sh
#
# Dépendance : un PowerShell (pwsh). Sur une machine Linux sans pwsh, un binaire portable suffit :
#   mkdir -p ~/.local/pwsh && cd ~/.local/pwsh
#   curl -sSL -o ps.tar.gz https://github.com/PowerShell/PowerShell/releases/download/v7.4.5/powershell-7.4.5-linux-x64.tar.gz
#   tar xzf ps.tar.gz && rm ps.tar.gz && chmod +x pwsh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../llm-tray.ps1"
PWSH="${PWSH:-$HOME/.local/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"

if [ ! -x "$PWSH" ]; then
    echo "✗ aucun pwsh trouvé (voir l'en-tête pour un binaire portable)" >&2
    exit 2
fi
[ -f "$SCRIPT" ] || { echo "✗ introuvable : $SCRIPT" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1) contrôle syntaxique des fichiers livrés, en entier (+ contrôle du BOM UTF-8)
"$PWSH" -NoProfile -Command "
\$files = Get-ChildItem '$HERE/..' -Filter '*.ps1'
\$ko = \$false
foreach (\$f in \$files) {
    \$e=\$null; \$t=\$null
    [System.Management.Automation.Language.Parser]::ParseFile(\$f.FullName,[ref]\$t,[ref]\$e) | Out-Null
    if (\$e.Count) { \$ko=\$true; Write-Host ('✗ ' + \$f.Name); \$e | ForEach-Object { Write-Host ('   L' + \$_.Extent.StartLineNumber + ' : ' + \$_.Message) } }
    else {
        \$b = [System.IO.File]::ReadAllBytes(\$f.FullName)
        \$bom = (\$b[0] -eq 0xEF -and \$b[1] -eq 0xBB -and \$b[2] -eq 0xBF)
        # sans BOM, PowerShell 5.1 lit le .ps1 en ANSI (CP1252) et casse tous les accents
        if (\$bom) { Write-Host ('✓ ' + \$f.Name + ' — syntaxe OK, UTF-8 avec BOM (' + \$t.Count + ' tokens)') }
        else { \$ko=\$true; Write-Host ('✗ ' + \$f.Name + ' — UTF-8 SANS BOM : PowerShell 5.1 cassera les accents (· → Â·)') }
    }
}
if (\$ko) { exit 1 }
" || exit 1

# 2) construction du banc : jusqu'à la section interface, sans les assembly Windows
awk '/^# -+ interface/{exit} {print}' "$SCRIPT" | grep -v '^Add-Type -AssemblyName System\.' > "$TMP/core.ps1"

cat >> "$TMP/core.ps1" <<'PSEOF'

# ------------------------------ pilote de test ------------------------------
$Script:Failures = 0
$Script:Checks = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $Script:Checks++
    try {
        if (& $Body) { Write-Host ("  ✓ " + $Name) }
        else { Write-Host ("  ✗ " + $Name); $Script:Failures++ }
    } catch {
        Write-Host ("  ✗ " + $Name + " — " + $_.Exception.Message); $Script:Failures++
    }
}

function Get-States {
    $out = @()
    foreach ($n in $Script:Nodes) { $out += Get-NodeState -Node $n }
    return $out
}

Write-Host "`n▸ Etat des trois noeuds (code livre, verbatim)"
foreach ($s in Get-States) {
    Write-Host ("  {0} {1,-14} {2,-8} {3}/{4}  {5}" -f $s.Letter, $s.Label, $s.Level, $s.Active, $s.Slots, $s.Model)
}

Write-Host "`n▸ Controles"
Test-Case 'chaque noeud rend un niveau connu (free/partial/busy/off)' {
    foreach ($s in Get-States) { if (-not $Script:LevelColor.ContainsKey($s.Level)) { return $false } }
    return $true
}
Test-Case '0 <= actifs <= slots pour chaque noeud' {
    foreach ($s in Get-States) { if ($s.Active -lt 0 -or $s.Active -gt $s.Slots) { return $false } }
    return $true
}
Test-Case 'un noeud joignable avec slots > 0 n''est jamais « off »' {
    foreach ($s in Get-States) { if ($s.Slots -gt 0 -and $s.Level -eq 'off') { return $false } }
    return $true
}
Test-Case 'l''icone expose une couleur valide par noeud' {
    $colors = @()
    foreach ($s in Get-States) { $colors += $Script:LevelColor[$s.Level] }
    if ($colors.Count -ne $Script:Nodes.Count) { return $false }
    foreach ($c in $colors) { if ($c -notmatch '^#[0-9A-Fa-f]{6}$') { return $false } }
    return $true
}
Test-Case 'grille d''icone : une pastille par noeud, carree, dans les bornes 32x32' {
    $letters = @($Script:Nodes | ForEach-Object { $_.Letter })
    $colors = @()
    foreach ($s in Get-States) { $colors += $Script:LevelColor[$s.Level] }
    $chips = Get-ChipGrid -Letters $letters -HexColors $colors -Size $Script:IconPx -Cols 2
    if ($chips.Count -ne $letters.Count) { return $false }
    foreach ($c in $chips) {
        if ($c.X -lt 0 -or $c.Y -lt 0) { return $false }
        if ($c.Width -lt 4 -or $c.Height -lt 4) { return $false }
        if (($c.X + $c.Width) -gt $Script:IconPx -or ($c.Y + $c.Height) -gt $Script:IconPx) { return $false }
    }
    # 2 colonnes : les deux premieres pastilles partagent la meme ordonnee, les deux suivantes aussi
    if ($chips[0].Y -ne $chips[1].Y) { return $false }
    if ($chips[0].X -eq $chips[1].X) { return $false }
    return $true
}
Test-Case 'grille d''icone : 2x2 plus grande qu''une rangee de 4 (raison du carre)' {
    # une rangee de 4 dans une image 32x32 carree ne laisse que 8 px par pastille ; la grille 2x2 en laisse 16
    $letters = @($Script:Nodes | ForEach-Object { $_.Letter })
    $colors = @()
    foreach ($s in Get-States) { $colors += $Script:LevelColor[$s.Level] }
    $grid = Get-ChipGrid -Letters $letters -HexColors $colors -Size $Script:IconPx -Cols 2
    $row = Get-ChipGrid -Letters $letters -HexColors $colors -Size $Script:IconPx -Cols 4
    return ($grid[0].Width -ge ($row[0].Width * 2) - 2)
}
Test-Case 'HUD : rangee de 4 pastilles de 30 px = 138x36' {
    $letters = @($Script:Nodes | ForEach-Object { $_.Letter })
    $colors = @()
    foreach ($s in Get-States) { $colors += $Script:LevelColor[$s.Level] }
    $chips = Get-ChipRow -Letters $letters -HexColors $colors -Chip 30 -Gap 4 -Pad 3
    $size = Get-RowSize -Count $letters.Count -Chip 30 -Gap 4 -Pad 3
    if ($chips.Count -ne 4) { return $false }
    if ($size.Width -ne 138 -or $size.Height -ne 36) { return $false }
    if (($chips[3].X + $chips[3].Width) -gt $size.Width) { return $false }
    return $true
}
Test-Case 'le texte de survol tient dans les 63 caracteres imposes par Windows' {
    $short = @()
    foreach ($s in Get-States) { $short += ($s.Letter + ' ' + $s.Level) }
    return (('LLM locaux · ' + ($short -join ' · ')).Length -le 63)
}
Test-Case 'la file de prompts repond (nom d''hote puis repli)' {
    $q = Get-Json -Path '/api/stats' -Kind 'queue'
    return ($null -ne $q -and $null -ne $q.counts)
}
Test-Case 'le repli IP + en-tete Host sert le dashboard (cas DNS .lan casse)' {
    $saved = $Script:DashTargets
    $Script:DashTargets = @(@{ Base = 'http://192.168.3.102'; Host = 'dashboard.lan' })
    $Script:Working.Remove('dash') | Out-Null
    $r = Get-Json -Path '/api/llm-224' -Kind 'dash'
    $Script:DashTargets = $saved
    return ($null -ne $r)
}

Write-Host ""
if ($Script:Failures -eq 0) { Write-Host ("RESULTAT : " + $Script:Checks + "/" + $Script:Checks + " controles OK"); exit 0 }
Write-Host ("RESULTAT : " + $Script:Failures + " echec(s) sur " + $Script:Checks); exit 1
PSEOF

# 3) exécution
"$PWSH" -NoProfile -File "$TMP/core.ps1"
exit $?
