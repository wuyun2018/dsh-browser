' Zero-window entry for the DSH browser launcher.
' wscript.exe is a GUI-subsystem host, so no console is ever created; the
' launcher runs in Windows PowerShell with its console hidden and forwards any
' arguments (e.g. -NoBrowser, -Check).
Option Explicit
Dim fso, sh, dir, ps, scriptPath, args, i, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = fso.BuildPath(dir, "launcher.ps1")
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & Replace(WScript.Arguments(i), Chr(34), Chr(34) & Chr(34)) & Chr(34)
Next
cmd = Chr(34) & ps & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34) & args
sh.Run cmd, 0, False
WScript.Quit 0