Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -File ""C:\Path\To\CopyScript\copyfiles-with-log.ps1""", 0, True
