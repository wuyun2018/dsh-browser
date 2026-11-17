' Zero-window entry for the DSH one-click restart.
' wscript.exe is a GUI-subsystem host, so no console flashes; restart-dsh.ps1 does the
' work (stop every DSH process tree + the dedicated DSH browser window, then relaunch
' through launcher.ps1). -Quiet keeps the run silent, any failure still pops a message box.
' Extra arguments are forwarded, e.g.:
'   wscript "<this file>" -DryRun      (only list what would be stopped)
Option Explicit
Dim fso, sh, dir, ps, scriptPath, args, i, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = dir
ps = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
scriptPath = fso.BuildPath(dir, "restart-dsh.ps1")
args = ""
For i = 0 To WScript.Arguments.Count - 1
  args = args & " " & Chr(34) & Replace(WScript.Arguments(i), Chr(34), Chr(34) & Chr(34)) & Chr(34)
Next
cmd = Chr(34) & ps & Chr(34) & " -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34) & " -Quiet -Progress" & args
sh.Run cmd, 0, False
WScript.Quit 0
