<#
    install-windows.ps1 — installe l'indicateur LLM dans la zone de notification Windows.

    Exécution (PowerShell, aucun droit administrateur requis) :

        irm https://raw.githubusercontent.com/lydstyl/llm-panel-indicator/main/windows/install-windows.ps1 | iex

    (ou, si le dépôt vient d'être modifié — le CDN de raw.githubusercontent peut servir une
     version en cache — passer par l'API :
        irm "https://api.github.com/repos/lydstyl/llm-panel-indicator/contents/windows/install-windows.ps1?ref=main" | iex )

    Ce que ça fait :
      1. télécharge llm-tray.ps1 et llm-tray.vbs dans %USERPROFILE%\llm-tray ;
      2. place un lanceur dans le dossier « Démarrage » → démarrage automatique au logon,
         sans tâche planifiée ni droits admin ;
      3. démarre l'indicateur tout de suite ;
      4. rappelle comment épingler l'icône sur la barre des tâches.

    Réexécutable : une nouvelle exécution met à jour les fichiers ET remplace l'indicateur qui tourne
    (aucun doublon d'icône), sans droits administrateur.
#>
[CmdletBinding()]
param(
    [string]$Ref = 'main',
    [string]$Repository = 'lydstyl/llm-panel-indicator',
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

# Sortie console en UTF-8 : la console Windows est en CP850 par défaut, les accents y sortent cassés.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$apiBase = "https://api.github.com/repos/$Repository/contents"
$rawBase = "https://raw.githubusercontent.com/$Repository/$Ref"
$dest = Join-Path $env:USERPROFILE 'llm-tray'
$startup = [Environment]::GetFolderPath('Startup')

function Get-RepoFile {
    param([string]$RemotePath, [string]$OutFile)

    $apiUrl = "$apiBase/$RemotePath" + "?ref=$Ref"
    try {
        Invoke-WebRequest -Uri $apiUrl -Headers @{ Accept = 'application/vnd.github.raw' } -OutFile $OutFile -UseBasicParsing -TimeoutSec 20
        return $true
    } catch {
        Write-Host ("  · API GitHub indisponible, repli sur raw : " + $_.Exception.Message)
    }
    try {
        Invoke-WebRequest -Uri "$rawBase/$RemotePath" -OutFile $OutFile -UseBasicParsing -TimeoutSec 20
        return $true
    } catch {
        return $false
    }
}

Write-Host "`n> 1/4 — fichiers dans $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

foreach ($file in 'llm-tray.ps1', 'llm-tray.vbs') {
    if (Get-RepoFile -RemotePath "windows/$file" -OutFile (Join-Path $dest $file)) {
        Write-Host "  · téléchargé : $file"
    } else {
        throw "échec du téléchargement de $file"
    }
}

# ⚠️ Encodage : PowerShell 5.1 lit un .ps1 SANS BOM comme de l'ANSI (CP1252) → « · » devient « Â· »
# et les accents cassent. On force donc l'UTF-8 AVEC BOM sur les fichiers installés, quelle que soit
# la façon dont ils ont été téléchargés (l'API GitHub et les navigateurs ne mettent pas de BOM).
$utf8Bom = New-Object System.Text.UTF8Encoding $true
foreach ($file in 'llm-tray.ps1') {
    $target = Join-Path $dest $file
    $text = [System.IO.File]::ReadAllText($target, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($target, $text, $utf8Bom)
    $bytes = [System.IO.File]::ReadAllBytes($target)[0..2] | ForEach-Object { $_.ToString('X2') }
    Write-Host ("  · encodage normalisé UTF-8 + BOM (" + ($bytes -join ' ') + ") : $file")
}

# Débloquer les fichiers (marque « venant d'Internet » → sinon PowerShell refuse de lancer le script)
Get-ChildItem $dest -Filter 'llm-tray*' | Unblock-File -ErrorAction SilentlyContinue

Write-Host "`n> 2/4 — démarrage automatique au logon"
$launcher = Join-Path $startup 'llm-tray.vbs'
Copy-Item (Join-Path $dest 'llm-tray.vbs') $launcher -Force
Write-Host "  · lanceur installé : $launcher"

Write-Host "`n> 3/4 — démarrage immédiat"
if (-not $NoStart) {
    # tuer l'instance précédente : réinstaller doit METTRE À JOUR, pas empiler une 2e icône
    $anciens = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*llm-tray.ps1*' }
    foreach ($a in $anciens) {
        Stop-Process -Id $a.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host ("  · ancienne instance arrêtée (PID " + $a.ProcessId + ")")
    }
    if ($anciens) { Start-Sleep -Seconds 1 }

    Start-Process 'wscript.exe' -ArgumentList ('"{0}"' -f (Join-Path $dest 'llm-tray.vbs'))
    Start-Sleep -Seconds 3
    $vivant = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*llm-tray.ps1*' }
    if ($vivant) {
        Write-Host "  · indicateur lancé (icône à trois pastilles près de l'horloge)"
    } else {
        Write-Host "  · ⚠ l'indicateur ne semble pas tourner — lancer à la main :" -ForegroundColor Yellow
        Write-Host ("    wscript.exe `"{0}`"" -f (Join-Path $dest 'llm-tray.vbs'))
    }
} else {
    Write-Host "  · ignoré (-NoStart)"
}

Write-Host @"

> 4/4 — rendre l'icône visible en permanence
  Windows range les nouvelles icônes dans le tiroir « ^ ». Pour l'épingler sur la barre :
    · Paramètres → Personnalisation → Barre des tâches → « Autres icônes système » → activer
      « llm-tray » (ou « Windows PowerShell »), ou
    · cliquer sur « ^ » et faire glisser l'icône à côté de l'horloge.

  Icône : trois pastilles G / M / L — vert = libre, orange = partiel, rouge = saturé, gris = arrêté.
  Survol = état par machine · clic gauche = dashboard · clic droit = détail + quitter.

  Mise à jour : relancer ce script suffit — les fichiers sont réécrits ET l'instance en cours est
  remplacée (aucun doublon d'icône), sans droits administrateur.
"@
