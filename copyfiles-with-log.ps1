param(
    [string]$Source      = "C:\Path\To\Source",
    [string]$Destination = "C:\Path\To\Destination",
    [string]$LogFile     = "C:\Path\To\Log\CopyLog.txt"
)

$ErrorActionPreference = 'Stop'
$copied = 0
$skipped = 0
$deleted = 0
$foldersRemoved = 0
$errors = 0
$cleanupAllowed = $true

# Files and folders excluded from backup
$ExcludedFiles = @(
    'desktop.ini'
    'Thumbs.db'
    '~$*'
)

$ExcludedFolders = @(
    '$RECYCLE.BIN'
    'System Volume Information'
)

function BackupExcluded {
    param(
        [System.IO.FileInfo]$File,
        [string]$Root
    )

    foreach ($Pattern in $ExcludedFiles) {
        if ($File.Name -like $Pattern) {
            return $true
        }
    }

    $RelativePath = Get-RelativePath $File.FullName $Root
    $Folders = @($RelativePath -split '\\')

    if ($Folders.Count -gt 1) {
        foreach ($Folder in $Folders[0..($Folders.Count - 2)]) {
            foreach ($Pattern in $ExcludedFolders) {
                if ($Folder -like $Pattern) {
                    return $true
                }
            }
        }
    }

    return $false
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Log failures are fatal: otherwise a silent scheduled task would hide problems.
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
}

function Log-Error {
    param([string]$Context, [System.Management.Automation.ErrorRecord]$Record)
    $script:errors++
    $script:cleanupAllowed = $false
    Write-Log 'ERROR' ("{0}: {1}" -f $Context, $Record.Exception.Message)
}

function Get-RelativePath {
    param([string]$FullPath, [string]$Root)
    $FullPath.Substring($Root.Length).TrimStart('\')
}

try {
    # Create the log folder before attempting nonfatal rotation.
    $logDirectory = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $logDirectory -Force -ErrorAction Stop | Out-Null
    }
    # Best-effort log rotation only; failure must never prevent the backup.
    # Archive the prior run's log, retain up to 7 archives, and start a fresh log.
    try {
        if (Test-Path -LiteralPath $LogFile -PathType Leaf) {
            $currentLog = Get-Item -LiteralPath $LogFile -ErrorAction Stop
            if ($currentLog.Length -gt 0) {
                $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
                $archive = Join-Path $logDirectory ("CopyProtonLog-{0}.txt" -f $stamp)
                Copy-Item -LiteralPath $LogFile -Destination $archive -ErrorAction Stop
                Clear-Content -LiteralPath $LogFile -ErrorAction Stop
            }
        }
        Get-ChildItem -LiteralPath $logDirectory -Filter 'CopyProtonLog-*.txt' -File -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -Skip 7 |
            Remove-Item -Force -ErrorAction Stop
    } catch {
        # Keep the current log intact if rotation fails and continue the backup.
        try {
            Add-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction Stop -Value (
                '[{0}] [WARN] Log rotation failed (backup continuing): {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $_.Exception.Message
            )
        } catch { }
    }

    Write-Log 'INFO' 'Copy operation started'

    $Source = $Source.TrimEnd('\')
    $Destination = $Destination.TrimEnd('\')

    if ($Destination -match 'YOUR-TAILSCALE-IP') {
        throw 'Set $Destination to your actual UNC path: \\100.x.x.x\Ryan\Proton Drive'
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Container -ErrorAction Stop)) {
        throw "Source folder inaccessible: $Source"
    }
    # Do NOT create the destination: a misspelled SMB share/path must fail safely.
    if (-not (Test-Path -LiteralPath $Destination -PathType Container -ErrorAction Stop)) {
        throw "NAS destination inaccessible or missing: $Destination"
    }
    if ($Source -ieq $Destination) {
        throw 'Source and destination cannot be the same directory.'
    }

    # Enumerate the complete source BEFORE changing or deleting any NAS files.
    # A failed enumeration must abort (rather than making missing files look deleted).
    $sourceFiles = @(
    Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction Stop |
        Where-Object {
            -not (BackupExcluded -File $_ -Root $Source)
        }
	)
    Write-Log 'INFO' ("Source scan complete: {0} file(s)" -f $sourceFiles.Count)

    foreach ($file in $sourceFiles) {
        $relativePath = Get-RelativePath $file.FullName $Source
        $destFile = Join-Path $Destination $relativePath
        try {
            $destDir = Split-Path -Parent $destFile
            if (-not (Test-Path -LiteralPath $destDir -PathType Container -ErrorAction Stop)) {
                New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop | Out-Null
            }

            $existing = Get-Item -LiteralPath $destFile -Force -ErrorAction SilentlyContinue
            # Preserve the original script's policy: only copy when missing or newer.
            if ($null -eq $existing -or $file.LastWriteTimeUtc -gt $existing.LastWriteTimeUtc) {
                Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force -ErrorAction Stop
                # Verify a destination file exists; Copy-Item returning alone is not sufficient.
                $verified = Get-Item -LiteralPath $destFile -Force -ErrorAction Stop
                if ($verified.PSIsContainer -or $verified.Length -ne $file.Length) {
                    throw "Destination verification failed (size mismatch): $relativePath"
                }
                $copied++
                Write-Log 'INFO' ("Copied: $relativePath")
            } else {
                $skipped++
                Write-Log 'INFO' ("Skipped: $relativePath (up-to-date)")
            }
        } catch {
            Log-Error "Copy/check '$relativePath'" $_
        }
    }

    # Avoid mass deletion when the cloud drive is empty/unmounted/unhydrated.
    if ($sourceFiles.Count -eq 0) {
        $cleanupAllowed = $false
        $errors++
        Write-Log 'ERROR' 'Source contained zero files. Deletion and empty-folder cleanup skipped for safety.'
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Container -ErrorAction Stop)) {
        $cleanupAllowed = $false
        Write-Log 'WARN' 'Source disappeared during the run. Cleanup skipped.'
    }

    if ($cleanupAllowed) {
        try {
            $destinationFiles = @(
				Get-ChildItem -LiteralPath $Destination -File -Recurse -Force -ErrorAction Stop |
					Where-Object {
						-not (BackupExcluded -File $_ -Root $Destination)
					}
			)
        } catch {
            Log-Error 'Destination enumeration before cleanup' $_
        }
    }
    if ($cleanupAllowed) {
        # Compare against the successfully enumerated source snapshot; do not
        # re-query each cloud file and interpret a transient error as deletion.
        $sourceRelativePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $sourceFiles) {
            [void]$sourceRelativePaths.Add((Get-RelativePath $file.FullName $Source))
        }
        foreach ($file in $destinationFiles) {
            $relativePath = Get-RelativePath $file.FullName $Destination
            if (-not $sourceRelativePaths.Contains($relativePath)) {
                try {
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    $deleted++
                    Write-Log 'INFO' ("Deleted: $relativePath (missing in source)")
                } catch {
                    Log-Error "Delete '$relativePath'" $_
                }
            }
        }
        if ($cleanupAllowed) {
            try {
                $directories = @(Get-ChildItem -LiteralPath $Destination -Directory -Recurse -Force -ErrorAction Stop |
                    Sort-Object { $_.FullName.Length } -Descending)
                foreach ($directory in $directories) {
                    try {
                        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop).Count -eq 0) {
                            Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
                            $foldersRemoved++
                            Write-Log 'INFO' ("Removed empty folder: {0}" -f (Get-RelativePath $directory.FullName $Destination))
                        }
                    } catch {
                        Log-Error "Remove/check folder '$($directory.FullName)'" $_
                    }
                }
            } catch {
                Log-Error 'Destination folder enumeration' $_
            }
        }
    } else {
        Write-Log 'WARN' 'Deletion and empty-folder cleanup skipped because of errors or source safety checks.'
    }

    $summary = "Copied=$copied; Skipped=$skipped; Deleted=$deleted; EmptyFoldersRemoved=$foldersRemoved; Errors=$errors"
    if ($errors -gt 0) {
        Write-Log 'ERROR' "Copy operation FAILED. $summary"
        exit 1
    }
    Write-Log 'INFO' "Copy operation completed. $summary"
    exit 0
} catch {
    # Handles preflight failures and any unexpected fatal error.
    try {
        Write-Log 'ERROR' ("Copy operation FAILED: {0}" -f $_.Exception.Message)
    } catch {
        # When even logging is unavailable, return a nonzero exit status.
    }
    exit 1
}

