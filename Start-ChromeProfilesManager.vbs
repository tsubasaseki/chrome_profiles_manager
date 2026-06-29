Option Explicit

Dim shell, scriptDir, scriptPath, command
Set shell = CreateObject("WScript.Shell")

scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
scriptPath = scriptDir & "ChromeProfilesManager.ps1"
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)

shell.Run command, 0, False
