' llm-tray.vbs - lance llm-tray.ps1 sans fenetre de console.
' Utilise par le raccourci du dossier Demarrage (aucun droit administrateur requis).
Set shell = CreateObject("WScript.Shell")
profile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & profile & "\llm-tray\llm-tray.ps1""", 0, False
