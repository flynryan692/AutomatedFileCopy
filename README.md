This script is intended to be used through Task Scheduler in Windows to automatically copy files from one directory to another, like to a NAS. I made this script to copy my OneDrive folder to my NAS, but it can be used to copy any directory to any location.

The script will perform the following:
- Copy files from source directory to destination directory
- Check to see if the source is newer than the destination, if the source is newer it will copy and overwrite, if it is not it will skip them
- Check the destination for files that do not exist at the source and delete them from the destination
- Run a cleanup to remove empty folders

Contents:
- copyfiles-with-log.ps1 
	- The powershell script that copies the files
- RunCopyScript.vbs
	- The vbs script that will execute the powershell script silently through task scheduler


To setup the scrip to run:
- Edit the source, destination, and log path within copyfiles-with-log.ps1 (you can use Notepad++ or VS Code)
- Edit the path to the copyfiles-with-log.ps1 file within RunCopyScript.vbs (you can use Notepad++ or VS Code)
- Create a new task in Task Scheduler with triggers as needed (I use a scheduled time - YMMV with other triggers)

- Under Actions: 
	- Start a program: wscript.exe
	- Arguments: "C:\Path\To\RunCopyScript.vbs"


To skip the use of the vbs file, do the following (it flickers a console for a millisecond while vbs option above is truly silent):

- Under Actions: 
	- Start a program: powershell.exe
	- Arguments: -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Path\To\RunCopyScript.vbs"

Once it is set up, a log file will be generated in the path you set containing what action was taken for each file.
