param(
    [string]$Source      = "C:\Path\To\Source",
    [string]$Destination = "C:\Path\To\Destination",
    [string]$LogFile     = "C:\Path\To\Log\CopyLog.txt"
)

# Ensure destination directory exists
if (-not (Test-Path -Path $Destination)) {
    New-Item -ItemType Directory -Path $Destination | Out-Null
}

# Prepare log file
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"[$timestamp] Copy operation started" | Out-File -FilePath $LogFile -Encoding UTF8

# Copy/update files from source to destination
Get-ChildItem -Path $Source -File -Recurse | ForEach-Object {
    $RelativePath = $_.FullName.Substring($Source.Length).TrimStart('\')
    $DestFile     = Join-Path $Destination $RelativePath

    # Ensure the destination subfolder exists
    $DestDir = Split-Path $DestFile
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir | Out-Null
    }

    # Copy if missing or newer
    if (-not (Test-Path $DestFile) -or ($_.LastWriteTime -gt (Get-Item $DestFile).LastWriteTime)) {
        Copy-Item -Path $_.FullName -Destination $DestFile -Force
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Copied: $RelativePath" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
    else {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Skipped: $RelativePath (up-to-date)" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

#Remove files from destination that are missing in source
Get-ChildItem -Path $Destination -File -Recurse | ForEach-Object {
    $RelativePath = $_.FullName.Substring($Destination.Length).TrimStart('\')
    $SourceFile   = Join-Path $Source $RelativePath

    if (-not (Test-Path $SourceFile)) {
        Remove-Item -Path $_.FullName -Force
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Deleted: $RelativePath (missing in source)" | Out-File -FilePath $LogFile -Append -Encoding UTF8
    }
}

# Remove empty directories from destination
Get-ChildItem -Path $Destination -Directory -Recurse |
    Sort-Object FullName -Descending |  # remove deeper folders first
    ForEach-Object {
        if (-not (Get-ChildItem -Path $_.FullName -Force)) {
            Remove-Item -Path $_.FullName -Force
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Removed empty folder: $($_.FullName.Substring($Destination.Length).TrimStart('\'))" |
                Out-File -FilePath $LogFile -Append -Encoding UTF8
        }
    }

"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Copy operation completed" | Out-File -FilePath $LogFile -Append -Encoding UTF8

