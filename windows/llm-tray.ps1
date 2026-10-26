<#
    llm-tray.ps1 — indicateur « LLM locaux » sous Windows.

    Deux affichages, même sémantique de couleurs :
      1. ICÔNE DE ZONE DE NOTIFICATION — 4 pastilles carrées portant les lettres G / M / L / S,
         disposées en grille 2x2 (carré : Windows réduit l'icône à 16x16 en conservant le ratio,
         donc une image large gaspille la place et rend les pastilles minuscules).
      2. HUD — petite fenêtre sans bordure, toujours au premier plan, 4 grosses lettres colorées
         (30 px par défaut, soit ~4x la taille des pastilles d'origine), déplaçable à la souris :
         elle mémorise sa position dans %USERPROFILE%\llm-tray\hud-pos.json.
         Désactivable avec -NoHud.

        vert    aucune tâche en cours
        orange  une partie des slots tourne, au moins un slot libre (ex. Marie 1/2)
        rouge   tous les slots tournent (saturé)
        gris    serveur arrêté ou PC hors ligne

    Survol de l'icône = état par machine · clic gauche = dashboard · clic droit = menu détaillé.
    Windows 11 n'autorise plus les greffons dans la barre des tâches (API DeskBand morte) : l'icône
    de zone de notification doit être épinglée pour rester visible en permanence.

    Zéro dépendance : Windows PowerShell 5.1 + .NET Framework (System.Windows.Forms / System.Drawing).
    Lancement au logon : windows/llm-tray.vbs (voir install-windows.ps1).

    ⚠️ ENCODAGE : ce fichier doit rester enregistré en UTF-8 **AVEC BOM**. PowerShell 5.1 (le shell
    standard de Windows 11) lit un .ps1 sans BOM comme de l'ANSI/CP1252 : « · » sort alors « Â· » et
    tous les accents sont cassés. Ne jamais réenregistrer ce fichier sans BOM ; en cas de doute,
    install-windows.ps1 réapplique le BOM après téléchargement.

    ⚠️ Syntaxe Windows PowerShell 5.1 : pas d'assignation depuis un `if` (`$x = if (...) {...}`
    est du PowerShell 7 et casse en 5.1) — d'où les if/else explicites ci-dessous.
#>
[CmdletBinding()]
param(
    [int]$IntervalSec = 5,
    [string]$DashboardUrl = 'http://dashboard.lan/',
    [string]$QueueUrl = 'http://prompts.gab.lan/',
    [string]$DashboardFallback = 'http://192.168.3.102',
    [string]$DashboardHostHeader = 'dashboard.lan',
    [string]$QueueFallback = 'http://192.168.3.102:8108',
    [switch]$NoHud,
    [int]$HudChip = 30
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LlmTrayIconTools {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@

# ---------------------------------------------------------------- configuration
# Cibles du dashboard : nom d'hôte d'abord, puis IP + en-tête Host explicite
# (nginx sert un vhost par nom : une requête sur l'IP sans Host renvoie 404).
$Script:DashTargets = @(
    @{ Base = 'http://dashboard.lan'; Host = $null },
    @{ Base = $DashboardFallback;     Host = $DashboardHostHeader }
)
$Script:QueueTargets = @(
    @{ Base = 'http://prompts.gab.lan'; Host = $null },
    @{ Base = $QueueFallback;           Host = $null }
)
$Script:Working = @{}          # dernière cible qui a répondu, par type d'appel
$Script:DefaultPort = 8080

# Taille de l'image d'icône livrée à Windows. Windows la réduit à SM_CXSMICON (16 px en 100 %),
# mais fournir 32 px garde le rendu net aux échelles 150-200 %.
$Script:IconPx = 32
$Script:HudPath = Join-Path $PSScriptRoot 'hud-pos.json'

$Script:Nodes = @(
    [pscustomobject]@{ Id = '224';   Letter = 'G'; Label = 'Gabriel .224'; Ip = '192.168.3.224'; Card = $null },
    [pscustomobject]@{ Id = 'marie'; Letter = 'M'; Label = 'Marie .57';    Ip = '192.168.3.57';  Card = 'marie' },
    [pscustomobject]@{ Id = 'louis'; Letter = 'L'; Label = 'Louis .206';   Ip = '192.168.3.206'; Card = 'louis' },
    [pscustomobject]@{ Id = 'skillorp'; Letter = 'S'; Label = 'SkillORP .249'; Ip = '192.168.3.249'; Card = 'boncoin' }
)

$Script:LevelColor = @{
    'free'    = '#22C55E'
    'partial' = '#F59E0B'
    'busy'    = '#EF4444'
    'off'     = '#6B7280'
}
$Script:LevelText = @{
    'free'    = 'libre'
    'partial' = 'partiel'
    'busy'    = 'saturé'
    'off'     = 'arrêté ou hors ligne'
}

# ---------------------------------------------------------------- accès HTTP
function Get-JsonBody {
    param([string]$Url, [string]$HostHeader, [int]$TimeoutSec = 3)

    if ($HostHeader) {
        # ⚠️ l'en-tête Host ne peut pas passer par -Headers (interdit par .NET) : on le pose sur
        # la propriété Host de la requête, sinon « The 'Host' header must be modified... ».
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Host = $HostHeader
        $req.Timeout = $TimeoutSec * 1000
        $req.UserAgent = 'llm-tray'
        $resp = $null
        $reader = $null
        try {
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            return $reader.ReadToEnd()
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($resp) { $resp.Dispose() }
        }
    }

    $obj = Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -UserAgent 'llm-tray'
    return ($obj | ConvertTo-Json -Depth 8 -Compress)
}

function Get-Json {
    param([string]$Path, [string]$Kind = 'dash')

    $targets = $Script:QueueTargets
    if ($Kind -eq 'dash') { $targets = $Script:DashTargets }

    # commencer par la cible qui marchait au cycle précédent
    $ordered = @()
    if ($Script:Working.ContainsKey($Kind)) {
        $last = $Script:Working[$Kind]
        $ordered += $last
        foreach ($t in $targets) { if ($t -ne $last) { $ordered += $t } }
    } else {
        $ordered = $targets
    }

    foreach ($t in $ordered) {
        try {
            $body = Get-JsonBody -Url ($t.Base + $Path) -HostHeader $t.Host
            if (-not $body) { continue }
            $data = $body | ConvertFrom-Json
            $Script:Working[$Kind] = $t
            return $data
        } catch {
            continue
        }
    }
    return $null
}

# ---------------------------------------------------------------- sondage d'une machine
function Get-NodeState {
    param([pscustomobject]$Node)

    $state = [pscustomobject]@{
        Id     = $Node.Id
        Letter = $Node.Letter
        Label  = $Node.Label
        Ip     = $Node.Ip
        Level  = 'off'
        Model  = ''
        Active = 0
        Slots  = 0
    }

    $card = $null
    if ($Node.Card) { $card = Get-Json -Path ('/api/pc-' + $Node.Card) }
    $cardOk = $false
    if ($card) {
        $cardOk = -not ($card.PSObject.Properties.Name -contains 'error' -and $card.error)
    }

    $port = $null
    if ($Node.Id -eq '224') {
        # .224 = dual-boot : Strata sous Windows, llama.cpp sous Pop OS (jamais les deux).
        $info = Get-Json -Path '/api/llm-224'
        if ($info -and $info.state -eq 'running') {
            $state.Model = [string]$info.model
            if ($info.port) { $port = [int]$info.port }
        } elseif ($cardOk -and $card.llm_status -eq 'active') {
            $state.Model = [string]$card.llm_model
            if ($card.llm_cmd -match '--(?:listen-)?port\s+(\d+)') { $port = [int]$Matches[1] }
        } elseif ($cardOk) {
            return $state        # serveur arrêté, machine joignable
        }
    } elseif ($cardOk) {
        if ($card.llm_status -ne 'active') { return $state }
        $state.Model = [string]$card.llm_model
        if ($card.llm_cmd -match '--(?:listen-)?port\s+(\d+)') { $port = [int]$Matches[1] }
        if ($card.PSObject.Properties.Name -contains 'llm_slots_total') {
            $total = 0
            if ([int]::TryParse([string]$card.llm_slots_total, [ref]$total) -and $total -gt 0) {
                $state.Slots = $total      # repli si /slots est injoignable
            }
        }
    }

    # /slots décide de l'état : le tableau donne le nombre RÉEL de slots et l'occupation.
    $ports = @()
    if ($port) { $ports += $port }
    if ($ports -notcontains $Script:DefaultPort) { $ports += $Script:DefaultPort }

    foreach ($p in $ports) {
        $slots = $null
        try {
            $slots = Invoke-RestMethod -Uri ("http://{0}:{1}/slots" -f $Node.Ip, $p) -TimeoutSec 3 -UserAgent 'llm-tray'
        } catch {
            continue
        }
        if (-not $slots) { continue }

        $arr = @($slots)
        if ($arr.Count -eq 0) { continue }

        $state.Slots = $arr.Count
        $busy = 0
        foreach ($s in $arr) {
            if ($s.PSObject.Properties.Name -contains 'is_processing' -and $s.is_processing) { $busy++ }
        }
        $state.Active = $busy

        if ($busy -le 0) {
            $state.Level = 'free'
        } elseif ($busy -ge $arr.Count) {
            $state.Level = 'busy'
        } else {
            $state.Level = 'partial'
        }

        if (-not $state.Model) {
            try {
                $props = Invoke-RestMethod -Uri ("http://{0}:{1}/props" -f $Node.Ip, $p) -TimeoutSec 3 -UserAgent 'llm-tray'
                if ($props.model_path) { $state.Model = Split-Path -Leaf ([string]$props.model_path) }
            } catch { }
        }
        return $state
    }

    if ($state.Slots -gt 0) { $state.Level = 'free' }   # /slots muet mais le collecteur voit le serveur
    return $state
}

# ---------------------------------------------------------------- géométrie des pastilles
# Fonctions pures (aucun System.Drawing) : testables depuis Linux, cf. windows/tests.

# Grille carrée 2x2 pour l'icône : Windows réduit l'image à 16x16 en gardant le ratio, donc une
# image carrée donne des pastilles 2x plus grandes qu'une rangée de 4.
function Get-ChipGrid {
    param([string[]]$Letters, [string[]]$HexColors, [int]$Size = 32, [int]$Cols = 2)

    $out = @()
    $count = $Letters.Count
    if ($count -lt 1) { return $out }
    if ($Cols -lt 1) { $Cols = 1 }
    if ($Cols -gt $count) { $Cols = $count }
    $rows = [int][math]::Ceiling($count / [double]$Cols)
    $cell = [int][math]::Floor($Size / [math]::Max($Cols, $rows))
    if ($cell -lt 1) { $cell = 1 }

    for ($i = 0; $i -lt $count; $i++) {
        $col = $i % $Cols
        $row = [int][math]::Floor($i / $Cols)
        # 1 px d'écart entre pastilles (sauf dernière colonne/ligne) pour rester lisible à 16 px
        $w = $cell
        if ($col -lt ($Cols - 1)) { $w = $cell - 1 }
        $h = $cell
        if ($row -lt ($rows - 1)) { $h = $cell - 1 }
        $out += [pscustomobject]@{
            Letter = [string]$Letters[$i]
            Color  = [string]$HexColors[$i]
            X      = $col * $cell
            Y      = $row * $cell
            Width  = $w
            Height = $h
        }
    }
    return $out
}

# Rangée horizontale pour le HUD : chaque pastille a la largeur demandée (30 px par défaut).
function Get-ChipRow {
    param([string[]]$Letters, [string[]]$HexColors, [int]$Chip = 30, [int]$Gap = 4, [int]$Pad = 3)

    $out = @()
    for ($i = 0; $i -lt $Letters.Count; $i++) {
        $out += [pscustomobject]@{
            Letter = [string]$Letters[$i]
            Color  = [string]$HexColors[$i]
            X      = $Pad + $i * ($Chip + $Gap)
            Y      = $Pad
            Width  = $Chip
            Height = $Chip
        }
    }
    return $out
}

function Get-RowSize {
    param([int]$Count, [int]$Chip = 30, [int]$Gap = 4, [int]$Pad = 3)
    if ($Count -lt 1) { $Count = 1 }
    return [pscustomobject]@{
        Width  = 2 * $Pad + $Count * $Chip + ($Count - 1) * $Gap
        Height = 2 * $Pad + $Chip
    }
}

# ---------------------------------------------------------------- rendu
function Draw-Chips {
    param([System.Drawing.Graphics]$Gfx, $Chips)

    $Gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Gfx.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $Gfx.Clear([System.Drawing.Color]::Transparent)

    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center

    foreach ($c in $Chips) {
        $color = [System.Drawing.ColorTranslator]::FromHtml($c.Color)
        $chipBrush = New-Object System.Drawing.SolidBrush -ArgumentList $color
        $rect = New-Object System.Drawing.RectangleF -ArgumentList ([float]$c.X), ([float]$c.Y), ([float]$c.Width), ([float]$c.Height)
        $Gfx.FillRectangle($chipBrush, $rect)
        $chipBrush.Dispose()

        # lettre blanche : lisible sur les 4 couleurs, en thème clair comme sombre
        $px = [float]([math]::Floor([math]::Min($c.Width, $c.Height) * 0.68))
        if ($px -lt 5) { $px = 5 }
        $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $px, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $textBrush = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::White)
        $Gfx.DrawString($c.Letter, $font, $textBrush, $rect, $fmt)
        $textBrush.Dispose()
        $font.Dispose()
    }
    $fmt.Dispose()
}

function New-StatusIcon {
    param([string[]]$Letters, [string[]]$HexColors)

    $px = $Script:IconPx
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $px, $px
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-Chips -Gfx $gfx -Chips (Get-ChipGrid -Letters $Letters -HexColors $HexColors -Size $px -Cols 2)
    $gfx.Dispose()

    $handle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $copy = $icon.Clone()                                  # clone indépendant du handle
    [LlmTrayIconTools]::DestroyIcon($handle) | Out-Null     # sinon fuite de handle à chaque cycle
    $icon.Dispose()
    $bmp.Dispose()
    return $copy
}

function New-HudBitmap {
    param([string[]]$Letters, [string[]]$HexColors, [int]$Chip = 30)

    $size = Get-RowSize -Count $Letters.Count -Chip $Chip
    $bmp = New-Object System.Drawing.Bitmap -ArgumentList $size.Width, $size.Height
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-Chips -Gfx $gfx -Chips (Get-ChipRow -Letters $Letters -HexColors $HexColors -Chip $Chip)
    $gfx.Dispose()
    return $bmp
}

# ---------------------------------------------------------------- interface
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Icon = New-StatusIcon -Letters @($Script:Nodes | ForEach-Object { $_.Letter }) -HexColors @('#6B7280', '#6B7280', '#6B7280', '#6B7280')

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

# HUD : fenêtre sans bordure, toujours au premier plan, 4 grosses lettres colorées.
$hud = $null
$hudBox = $null
$hudTip = $null
$Script:HudW = 0
$Script:HudH = 0
if (-not $NoHud) {
    $letters0 = @($Script:Nodes | ForEach-Object { $_.Letter })
    $size0 = Get-RowSize -Count $letters0.Count -Chip $HudChip
    $Script:HudW = $size0.Width
    $Script:HudH = $size0.Height

    $hud = New-Object System.Windows.Forms.Form
    $hud.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $hud.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $hud.TopMost = $true
    $hud.ShowInTaskbar = $false
    $hud.Text = 'LLM locaux'
    $hud.BackColor = [System.Drawing.Color]::FromArgb(18, 18, 20)
    $hud.ClientSize = New-Object System.Drawing.Size -ArgumentList $Script:HudW, $Script:HudH

    $hudBox = New-Object System.Windows.Forms.PictureBox
    $hudBox.Location = New-Object System.Drawing.Point -ArgumentList 0, 0
    $hudBox.Size = New-Object System.Drawing.Size -ArgumentList $Script:HudW, $Script:HudH
    $hudBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Normal
    $hudBox.BackColor = [System.Drawing.Color]::Transparent
    [void]$hud.Controls.Add($hudBox)
    $hud.ContextMenuStrip = $menu
    $hudBox.ContextMenuStrip = $menu

    $hudTip = New-Object System.Windows.Forms.ToolTip
    $hudTip.SetToolTip($hudBox, 'LLM locaux')

    # position : celle mémorisée, sinon coin bas-droit de la zone de travail (juste au-dessus de
    # la barre des tâches, donc près de l'horloge sans rien masquer)
    $placed = $false
    if (Test-Path $Script:HudPath) {
        try {
            $saved = Get-Content -Path $Script:HudPath -Raw | ConvertFrom-Json
            $sx = 0
            $sy = 0
            if ([int]::TryParse([string]$saved.x, [ref]$sx) -and [int]::TryParse([string]$saved.y, [ref]$sy)) {
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
                # ne restaurer que si la position est encore visible (écran débranché, résolution changée)
                if ($sx -gt ($screen.Left - $Script:HudW + 40) -and $sx -lt $screen.Right -and
                    $sy -gt ($screen.Top - $Script:HudH + 40) -and $sy -lt $screen.Bottom) {
                    $hud.Location = New-Object System.Drawing.Point -ArgumentList $sx, $sy
                    $placed = $true
                }
            }
        } catch { }
    }
    if (-not $placed) {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $hud.Location = New-Object System.Drawing.Point -ArgumentList ([int]($wa.Right - $Script:HudW - 12)), ([int]($wa.Bottom - $Script:HudH - 12))
    }
}

function Save-HudPosition {
    if (-not $hud) { return }
    try {
        $payload = '{"x":' + $hud.Left + ',"y":' + $hud.Top + '}'
        [System.IO.File]::WriteAllText($Script:HudPath, $payload, (New-Object System.Text.UTF8Encoding $false))
    } catch { }
}

$Script:Refreshing = $false

function Set-Tooltip {
    param([string]$Text)
    # NotifyIcon.Text est limité à 63 caractères : dépasser lève une exception.
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '…' }
    $notify.Text = $Text
    if ($hudTip) { $hudTip.SetToolTip($hudBox, $Text) }
}

function Update-Menu {
    param($Nodes, [int]$QRun, [int]$QWait, [bool]$QueueOk)

    $menu.Items.Clear()
    foreach ($n in $Nodes) {
        $label = '{0} · {1} — {2}' -f $n.Letter, $n.Label, $Script:LevelText[$n.Level]
        if ($n.Level -ne 'off') {
            $model = $n.Model
            if (-not $model) { $model = '?' }
            if ($model.Length -gt 34) { $model = $model.Substring(0, 31) + '…' }
            $label += (' · {0}/{1} · {2}' -f $n.Active, $n.Slots, $model)
        }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem
        $item.Text = $label
        $item.Enabled = $false
        [void]$menu.Items.Add($item)
    }

    $online = 0
    $active = 0
    $capacity = 0
    foreach ($n in $Nodes) {
        if ($n.Level -ne 'off') {
            $online++
            $active += $n.Active
            $capacity += $n.Slots
        }
    }
    $summaryText = 'Aucun LLM local en ligne'
    if ($online -gt 0) {
        $summaryText = '{0} tâche(s) en cours · {1} slot(s) sur {2} serveur(s)' -f $active, $capacity, $online
    }
    $summary = New-Object System.Windows.Forms.ToolStripMenuItem
    $summary.Text = $summaryText
    $summary.Enabled = $false
    [void]$menu.Items.Add($summary)

    $qLabel = 'File de prompts : injoignable'
    if ($QueueOk) {
        if ($QRun -or $QWait) {
            $qLabel = 'File : {0} en cours, {1} en attente' -f $QRun, $QWait
        } else {
            $qLabel = 'File de prompts : vide'
        }
    }
    $qItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $qItem.Text = $qLabel
    $qItem.Enabled = $false
    [void]$menu.Items.Add($qItem)

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $openDash = New-Object System.Windows.Forms.ToolStripMenuItem
    $openDash.Text = 'Ouvrir le dashboard'
    $openDash.Add_Click({ Start-Process $DashboardUrl })
    [void]$menu.Items.Add($openDash)

    $openQueue = New-Object System.Windows.Forms.ToolStripMenuItem
    $openQueue.Text = 'Ouvrir la file de prompts'
    $openQueue.Add_Click({ Start-Process $QueueUrl })
    [void]$menu.Items.Add($openQueue)

    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $refresh.Text = 'Rafraîchir'
    $refresh.Add_Click({ Update-Interface })
    [void]$menu.Items.Add($refresh)

    if ($hud) {
        $toggleHud = New-Object System.Windows.Forms.ToolStripMenuItem
        $toggleHud.Text = 'Masquer le bandeau de lettres'
        $toggleHud.Add_Click({
                $hud.Visible = -not $hud.Visible
            })
        [void]$menu.Items.Add($toggleHud)
    }

    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

    $quit = New-Object System.Windows.Forms.ToolStripMenuItem
    $quit.Text = 'Quitter'
    $quit.Add_Click({
            $notify.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        })
    [void]$menu.Items.Add($quit)
}

function Update-Interface {
    if ($Script:Refreshing) { return }
    $Script:Refreshing = $true
    try {
        $nodes = @()
        foreach ($n in $Script:Nodes) { $nodes += Get-NodeState -Node $n }

        $colors = @()
        $letters = @()
        $short = @()
        foreach ($n in $nodes) {
            $colors += $Script:LevelColor[$n.Level]
            $letters += [string]$n.Letter
            if ($n.Level -eq 'off') {
                $short += ('{0} off' -f $n.Letter)
            } else {
                $short += ('{0} {1}/{2}' -f $n.Letter, $n.Active, $n.Slots)
            }
        }

        $newIcon = New-StatusIcon -Letters $letters -HexColors $colors
        $oldIcon = $notify.Icon
        $notify.Icon = $newIcon
        if ($oldIcon) { $oldIcon.Dispose() }

        if ($hud) {
            $newBmp = New-HudBitmap -Letters $letters -HexColors $colors -Chip $HudChip
            $oldBmp = $hudBox.Image
            $hudBox.Image = $newBmp
            if ($oldBmp) { $oldBmp.Dispose() }
        }
        Set-Tooltip ('LLM locaux · ' + ($short -join ' · '))

        $queue = Get-Json -Path '/api/stats' -Kind 'queue'
        $qRun = 0
        $qWait = 0
        if ($queue -and $queue.counts) {
            if ($queue.counts.in_progress) { $qRun = [int]$queue.counts.in_progress }
            if ($queue.counts.pending) { $qWait = [int]$queue.counts.pending }
        }
        Update-Menu -Nodes $nodes -QRun $qRun -QWait $qWait -QueueOk ($null -ne $queue)
    } catch {
        Set-Tooltip ('LLM locaux — erreur : ' + $_.Exception.Message)
    } finally {
        $Script:Refreshing = $false
    }
}

$notify.Add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Start-Process $DashboardUrl }
    })

if ($hud) {
    # déplacement à la souris (position mémorisée au relâchement) — la fenêtre n'a ni bordure ni
    # barre de titre, donc tout le déplacement passe par le PictureBox
    $Script:DragOn = $false
    $Script:DragCursor = $null
    $Script:DragOrigin = $null

    $hudBox.Add_MouseDown({
            param($sender, $eventArgs)
            if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                $Script:DragOn = $true
                $Script:DragCursor = [System.Windows.Forms.Cursor]::Position
                $Script:DragOrigin = $hud.Location
            }
        })
    $hudBox.Add_MouseMove({
            param($sender, $eventArgs)
            if ($Script:DragOn) {
                $p = [System.Windows.Forms.Cursor]::Position
                $nx = $Script:DragOrigin.X + ($p.X - $Script:DragCursor.X)
                $ny = $Script:DragOrigin.Y + ($p.Y - $Script:DragCursor.Y)
                $hud.Location = New-Object System.Drawing.Point -ArgumentList $nx, $ny
            }
        })
    $hudBox.Add_MouseUp({
            param($sender, $eventArgs)
            if ($Script:DragOn) {
                $Script:DragOn = $false
                Save-HudPosition
            }
        })
    $hudBox.Add_DoubleClick({ Start-Process $DashboardUrl })

    $hud.Show()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(2, $IntervalSec) * 1000
$timer.Add_Tick({ Update-Interface })
$timer.Start()

Update-Interface
[System.Windows.Forms.Application]::Run()

$timer.Stop()
$notify.Visible = $false
$notify.Dispose()
if ($hud) { $hud.Dispose() }
