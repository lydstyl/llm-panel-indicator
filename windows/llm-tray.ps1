<#
    llm-tray.ps1 — indicateur « LLM locaux » dans la zone de notification Windows.

    Windows 11 n'autorise plus les greffons dans la barre des tâches (l'API DeskBand est morte) :
    l'équivalent le plus proche est une ICÔNE DE ZONE DE NOTIFICATION, à épingler pour qu'elle
    reste visible en permanence (Paramètres → Personnalisation → Barre des tâches → Autres icônes
    système, ou glisser l'icône depuis le tiroir « ^ »).

    Même sémantique que l'applet COSMIC : trois pastilles G / M / L dans l'icône
        vert    aucune tâche en cours
        orange  une partie des slots tourne, au moins un slot libre (ex. Marie 1/2)
        rouge   tous les slots tournent (saturé)
        gris    serveur arrêté ou PC hors ligne
    Survol = état par machine · clic gauche = dashboard · clic droit = menu détaillé.

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
    [string]$QueueFallback = 'http://192.168.3.102:8108'
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

$Script:Nodes = @(
    [pscustomobject]@{ Id = '224';   Letter = 'G'; Label = 'Gabriel .224'; Ip = '192.168.3.224'; Card = $null },
    [pscustomobject]@{ Id = 'marie'; Letter = 'M'; Label = 'Marie .57';    Ip = '192.168.3.57';  Card = 'marie' },
    [pscustomobject]@{ Id = 'louis'; Letter = 'L'; Label = 'Louis .206';   Ip = '192.168.3.206'; Card = 'louis' }
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

# ---------------------------------------------------------------- icône (3 pastilles)
function New-DotsIcon {
    param([string[]]$HexColors)

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $gfx.Clear([System.Drawing.Color]::Transparent)

    for ($i = 0; $i -lt $HexColors.Count; $i++) {
        $color = [System.Drawing.ColorTranslator]::FromHtml($HexColors[$i])
        $brush = New-Object System.Drawing.SolidBrush -ArgumentList $color
        $gfx.FillEllipse($brush, (2 + $i * 10), 12, 8, 8)
        $brush.Dispose()
    }
    $gfx.Dispose()

    $handle = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($handle)
    $copy = $icon.Clone()                                  # clone indépendant du handle
    [LlmTrayIconTools]::DestroyIcon($handle) | Out-Null     # sinon fuite de handle à chaque cycle
    $icon.Dispose()
    $bmp.Dispose()
    return $copy
}

# ---------------------------------------------------------------- interface
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true
$notify.Icon = New-DotsIcon @('#6B7280', '#6B7280', '#6B7280')

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$notify.ContextMenuStrip = $menu

$Script:Refreshing = $false

function Set-Tooltip {
    param([string]$Text)
    # NotifyIcon.Text est limité à 63 caractères : dépasser lève une exception.
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '…' }
    $notify.Text = $Text
}

function Update-Interface {
    if ($Script:Refreshing) { return }
    $Script:Refreshing = $true
    try {
        $nodes = @()
        foreach ($n in $Script:Nodes) { $nodes += Get-NodeState -Node $n }

        $colors = @()
        $short = @()
        $online = 0
        $active = 0
        $capacity = 0
        foreach ($n in $nodes) {
            $colors += $Script:LevelColor[$n.Level]
            if ($n.Level -eq 'off') {
                $short += ('{0} off' -f $n.Letter)
            } else {
                $short += ('{0} {1}/{2}' -f $n.Letter, $n.Active, $n.Slots)
                $online++
                $active += $n.Active
                $capacity += $n.Slots
            }
        }

        $newIcon = New-DotsIcon $colors
        $oldIcon = $notify.Icon
        $notify.Icon = $newIcon
        if ($oldIcon) { $oldIcon.Dispose() }
        Set-Tooltip ('LLM locaux · ' + ($short -join ' · '))

        $queue = Get-Json -Path '/api/stats' -Kind 'queue'
        $qRun = 0
        $qWait = 0
        if ($queue -and $queue.counts) {
            if ($queue.counts.in_progress) { $qRun = [int]$queue.counts.in_progress }
            if ($queue.counts.pending) { $qWait = [int]$queue.counts.pending }
        }

        $menu.Items.Clear()
        foreach ($n in $nodes) {
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

        $summaryText = 'Aucun LLM local en ligne'
        if ($online -gt 0) {
            $summaryText = '{0} tâche(s) en cours · {1} slot(s) sur {2} serveur(s)' -f $active, $capacity, $online
        }
        $summary = New-Object System.Windows.Forms.ToolStripMenuItem
        $summary.Text = $summaryText
        $summary.Enabled = $false
        [void]$menu.Items.Add($summary)

        $qLabel = 'File de prompts : injoignable'
        if ($queue) {
            if ($qRun -or $qWait) {
                $qLabel = 'File : {0} en cours, {1} en attente' -f $qRun, $qWait
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

        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

        $quit = New-Object System.Windows.Forms.ToolStripMenuItem
        $quit.Text = 'Quitter'
        $quit.Add_Click({
                $notify.Visible = $false
                [System.Windows.Forms.Application]::Exit()
            })
        [void]$menu.Items.Add($quit)
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

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(2, $IntervalSec) * 1000
$timer.Add_Tick({ Update-Interface })
$timer.Start()

Update-Interface
[System.Windows.Forms.Application]::Run()

$timer.Stop()
$notify.Visible = $false
$notify.Dispose()
