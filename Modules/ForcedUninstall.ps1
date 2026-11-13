# Modules/ForcedUninstall.ps1
# Forced Uninstall and Residual Purge Engine (Reverse-engineered from Revo Uninstaller Pro)
# Allows purging corrupted, half-uninstalled, or unlisted applications directly from their folder path or executable.

function Start-ForcedUninstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Target,
        [string]$ConfigDir = "",
        [scriptblock]$ProgressCallback = $null
    )

    if (-not $ConfigDir) {
        $ConfigDir = Join-Path (Split-Path $PSScriptRoot -Parent) "Config"
    }

    $targetName = ""
    $targetPublisher = ""
    $targetPath = ""
    $targetFile = ""

    # Unsafe system roots and shared locations that must never be targeted as an application directory
    $unsafeRoots = @(
        $env:USERPROFILE,
        (Split-Path $env:USERPROFILE -Parent),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDesktopDirectory),
        (Join-Path $env:USERPROFILE "Desktop"),
        (Join-Path $env:USERPROFILE "Downloads"),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Personal),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDocuments),
        (Join-Path $env:USERPROFILE "Documents"),
        $env:TEMP,
        $env:TMP,
        [System.IO.Path]::GetTempPath(),
        (Join-Path $env:SystemRoot "Temp"),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramW6432,
        $env:SystemRoot,
        $env:windir,
        $env:PUBLIC,
        $env:ALLUSERSPROFILE,
        $env:ProgramData
    ) | Where-Object { $_ } | ForEach-Object { 
        $p = $_.TrimEnd('\')
        $p
        try { (Get-Item -LiteralPath $p -ErrorAction SilentlyContinue).FullName.TrimEnd('\') } catch { }
    } | Where-Object { $_ } | Select-Object -Unique

    $unsafeFolderNames = @(
        'Desktop', 'Downloads', 'Documents', 'My Documents',
        'Temp', 'Tmp',
        'Program Files', 'Program Files (x86)',
        'Windows', 'Users', 'System32', 'SysWOW64'
    )

    # Check if target is an existing path (directory or file)
    $cleanTarget = $Target.Trim().Trim('"', "'", ' ')
    if (Test-Path -LiteralPath $cleanTarget) {
        $item = Get-Item -LiteralPath $cleanTarget -ErrorAction SilentlyContinue
        if ($item -is [System.IO.FileInfo]) {
            $targetFile = $item.FullName
            $parentDir = Split-Path $item.FullName -Parent
            $targetName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
            try {
                $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($item.FullName)
                if ($vi.ProductName) { $targetName = $vi.ProductName }
                if ($vi.CompanyName) { $targetPublisher = $vi.CompanyName }
            } catch { }

            # Two-Tier Target Qualification Protocol:
            # Strictly refuse to target Desktop, Downloads, Documents, Temp, Program Files, Windows, Users, or any drive root.
            $cleanParent = $parentDir.TrimEnd('\')
            $parentResolved = try { (Get-Item -LiteralPath $parentDir -ErrorAction SilentlyContinue).FullName.TrimEnd('\') } catch { $cleanParent }
            $isDriveRoot = ([System.IO.Path]::GetPathRoot($parentDir).TrimEnd('\') -ieq $cleanParent) -or 
                           ([System.IO.Path]::GetPathRoot($parentDir) -eq $parentDir)
            $parentLeaf = Split-Path $parentDir -Leaf
            $isUnsafeName = $unsafeFolderNames -contains $parentLeaf
            $isUnsafeParent = $isDriveRoot -or $isUnsafeName -or ($unsafeRoots | Where-Object { 
                $_ -ieq $cleanParent -or $_ -ieq $parentResolved 
            })

            $nameMatches = ($targetName -and $parentLeaf -like "*$targetName*") -or 
                           ($targetPublisher -and $parentLeaf -like "*$targetPublisher*")

            if (-not $isUnsafeParent -and $nameMatches) {
                # Tier 1: Parent directory is verified as dedicated to the application
                $targetPath = $parentDir
            } else {
                # Tier 2: File is in a shared, root, or unverified directory - target ONLY the file itself
                $targetPath = ""
            }
        } else {
            $cleanDir = $item.FullName.TrimEnd('\')
            $dirResolved = try { (Get-Item -LiteralPath $item.FullName -ErrorAction SilentlyContinue).FullName.TrimEnd('\') } catch { $cleanDir }
            $isDriveRoot = ([System.IO.Path]::GetPathRoot($item.FullName).TrimEnd('\') -ieq $cleanDir) -or 
                           ([System.IO.Path]::GetPathRoot($item.FullName) -eq $item.FullName)
            $dirLeaf = Split-Path $cleanDir -Leaf
            $isUnsafeName = $unsafeFolderNames -contains $dirLeaf
            $isUnsafeRoot = $isDriveRoot -or $isUnsafeName -or ($unsafeRoots | Where-Object { 
                $_ -ieq $cleanDir -or $_ -ieq $dirResolved 
            })

            if ($isUnsafeRoot) {
                Write-Warning "Refusing to target protected system or shared root directory '$($item.FullName)' for forced uninstallation."
                return [PSCustomObject]@{
                    TargetName      = $item.Name
                    TargetPath      = $item.FullName
                    TargetPublisher = ""
                    Candidates      = @()
                }
            }

            $targetPath = $item.FullName
            $targetName = $item.Name

            # Try to discover an executable inside the directory to extract metadata
            $sampleExe = Get-ChildItem -LiteralPath $targetPath -Filter *.exe -File -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($sampleExe) {
                try {
                    $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($sampleExe.FullName)
                    if ($vi.ProductName) { $targetName = $vi.ProductName }
                    if ($vi.CompanyName) { $targetPublisher = $vi.CompanyName }
                } catch { }
            }
        }
    } else {
        # Target was supplied as a raw application name or keyword
        $targetName = $cleanTarget
    }

    # Construct synthetic application definition
    $mockApp = [PSCustomObject]@{
        DisplayName     = $targetName
        Publisher       = $targetPublisher
        InstallLocation = if ($targetPath) { $targetPath } else { $targetFile }
        Type            = "ForcedTarget"
    }

    $rawCandidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # 0. Active Running Processes
    if (Get-Command Scan-RunningAppProcesses -ErrorAction SilentlyContinue) {
        $procLeftovers = Scan-RunningAppProcesses -AppName $targetName -InstallLocation (if ($targetPath) { $targetPath } else { $targetFile })
        foreach ($pr in $procLeftovers) {
            $rawCandidates.Add([PSCustomObject]@{
                Category     = "Process"
                Type         = "Process"
                Id           = $pr.Id
                Name         = $pr.Name
                Path         = $pr.Path
                Size         = $pr.Size
                ItemCount    = 1
                MatchReason  = "Active running process for target application"
                MatchedToken = $targetName
            })
        }
    }

    # 1. Primary Target Directory or File
    if ($targetPath -and (Test-Path -LiteralPath $targetPath -PathType Container)) {
        $seenPaths.Add($targetPath) | Out-Null
        $stat = Get-FolderSizeSafe -Path $targetPath
        $rawCandidates.Add([PSCustomObject]@{
            Category     = "File"
            Type         = "Directory"
            Path         = $targetPath
            Size         = $stat.Size
            ItemCount    = $stat.Count
            MatchReason  = "Primary forced uninstall target path"
            MatchedToken = $targetName
        })
    } elseif ($targetFile -and (Test-Path -LiteralPath $targetFile)) {
        $seenPaths.Add($targetFile) | Out-Null
        $fItem = Get-Item -LiteralPath $targetFile -ErrorAction SilentlyContinue
        $rawCandidates.Add([PSCustomObject]@{
            Category     = "File"
            Type         = "File"
            Path         = $targetFile
            Size         = if ($fItem) { $fItem.Length } else { 0L }
            ItemCount    = 1
            MatchReason  = "Primary forced uninstall target executable"
            MatchedToken = $targetName
        })
    }

    # 2. File System Deep Scan for Target
    if ($ProgressCallback) { & $ProgressCallback 1 5 "Scanning file system remnants for '$targetName'..." }
    $fileLeftovers = Scan-FileLeftovers -AppName $targetName -Publisher $targetPublisher -InstallLocation $targetPath
    foreach ($fl in $fileLeftovers) {
        if (-not $seenPaths.Contains($fl.Path)) {
            $seenPaths.Add($fl.Path) | Out-Null
            $rawCandidates.Add($fl)
        }
    }

    # 3. Registry Scan
    if ($ProgressCallback) { & $ProgressCallback 2 5 "Scanning Windows Registry remnants..." }
    $regLeftovers = Scan-RegistryLeftovers -AppName $targetName -Publisher $targetPublisher
    foreach ($rl in $regLeftovers) {
        if (-not $seenPaths.Contains($rl.Path)) {
            $seenPaths.Add($rl.Path) | Out-Null
            $rawCandidates.Add($rl)
        }
    }

    # 4. Services Scan
    if ($ProgressCallback) { & $ProgressCallback 3 5 "Scanning associated Windows services..." }
    $svcLeftovers = Scan-ServiceLeftovers -AppName $targetName -Publisher $targetPublisher
    foreach ($sl in $svcLeftovers) {
        $rawCandidates.Add($sl)
    }

    # 5. Scheduled Tasks & Shortcuts
    if ($ProgressCallback) { & $ProgressCallback 4 5 "Scanning scheduled tasks and shortcuts..." }
    $taskLeftovers = Scan-TaskLeftovers -AppName $targetName
    foreach ($tl in $taskLeftovers) { $rawCandidates.Add($tl) }

    $shortcutLeftovers = Scan-ShortcutLeftovers -AppName $targetName -InstallLocation $targetPath
    foreach ($scl in $shortcutLeftovers) { $rawCandidates.Add($scl) }

    # 6. Safety and Evidence Scoring
    if ($ProgressCallback) { & $ProgressCallback 5 5 "Evaluating safety guardrails and scoring..." }
    $evaluated = Evaluate-CandidateEvidence -Candidates $rawCandidates -Application $mockApp -ConfigDir $ConfigDir

    return [PSCustomObject]@{
        TargetName      = $targetName
        TargetPath      = if ($targetPath) { $targetPath } else { $targetFile }
        TargetPublisher = $targetPublisher
        Candidates      = [array]@($evaluated)
    }
}
