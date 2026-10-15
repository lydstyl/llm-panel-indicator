' llm-tray.vbs — lance llm-tray.ps1 sans fenêtre de console.
' Utilisé par le raccourci du dossier Démarrage (aucun droit administrateur requis).
Set shell = CreateObject("WScript.Shell")
profile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & profile & "\llm-tray\llm-tray.ps1""", 0, False
