param(
    [Parameter(Mandatory=$true)]
    [string]$EnvName,

    [int]$MaxRounds = 5  # how many times we loop trying to fix issues
)

<#
.SYNOPSIS
  Automated script to fix:
  1) Missing packages (install them)
  2) Version conflicts (attempt upgrade/downgrade)

.DESCRIPTION
  1) Runs pip check in the specified Conda env using 'conda run'.
  2) Searches for lines about missing packages: 
     "<pkg> <ver> requires <missingDep>, which is not installed."
  3) Searches for version conflict lines:
     - "XYZ <ver> has requirement ABC >= 4.4, but you have ABC 4.3.0."
     - "XYZ <ver> has requirement ABC < 4.3, but you have ABC 4.4.0."
  4) Attempts to fix each conflict by installing the needed version or
     removing the conflict if the user chooses.
  5) Loops up to MaxRounds. If still conflicting, you need manual intervention.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Auto-FixEnv.ps1 -EnvName test_env
#>

Write-Host "=== Automated Fix Script for Conda Environment '$EnvName' ===`n"

function Run-PipCheck {
    # Runs pip check and returns array of lines (stdout + stderr merged)
    $output = conda run -n $EnvName pip check 2>&1
    $lines  = ($output | Out-String) -split "`r?`n"
    return $lines
}

function Install-MissingPackages {
    param(
        [string[]]$CheckLines
    )
    # Regex for:  "tqdm 4.63.0 requires importlib-resources, which is not installed."
    $missingRegex = "(?<Pkg>[^ ]+)\s+\S+\s+requires\s+(?<MissingDep>[^,]+),\s+which\s+is\s+not\s+installed\."

    $depsToInstall = @()
    foreach ($line in $CheckLines) {
        $m = [regex]::Match($line, $missingRegex)
        if ($m.Success) {
            $needed = $m.Groups["MissingDep"].Value
            if ($needed -notin $depsToInstall) {
                $depsToInstall += $needed
            }
        }
    }
    if ($depsToInstall.Count -gt 0) {
        Write-Host "`nMissing dependencies detected: $($depsToInstall -join ', ')"
        conda install -n $EnvName -y $depsToInstall
        return $true
    }
    return $false
}

function Fix-VersionConflicts {
    param(
        [string[]]$CheckLines
    )
    # We'll look for lines like:
    #   "sphinx 4.4.0 has requirement importlib-metadata>=4.4; python_version < '3.10', but you have importlib-metadata 4.3.0."
    #   "flake8 4.0.1 has requirement importlib-metadata<4.3; python_version < '3.8', but you have importlib-metadata 4.4.0."
    #
    # Typical pattern is:
    #   "<Pkg> <Ver> has requirement <DepName><Op><Version>[; condition], but you have <DepName> <ActualVersion>."
    #
    # We'll parse out DepName, required version, and actual version, then attempt to "conda install" a version that meets the requirement.
    # This is naive because multiple packages may have contradictory needs.

    # Regex Explanation:
    #   ^(?<Package>[^ ]+)\s+        # package name
    #   (?<PkgVer>[^\s]+)\s+         # package version
    #   has requirement\s+
    #   (?<Dep>[^<>=]+)              # dependency name
    #   (?<Comparison>[<>=]+)\s*     # <, <=, >=, or =
    #   (?<ReqVer>[0-9A-Za-z\.\-]+)  # required version (like 4.4, 3.2.1, etc.)
    #   .*but you have\s+
    #   (?<Dep2>[^ ]+)\s+
    #   (?<ActualVer>[^\s]+)
    #
    $conflictRegex = "^(?<Package>[^ ]+)\s+(?<PkgVer>[^\s]+)\s+has requirement\s+(?<Dep>[^<>=]+)(?<Comparison><=?|>=?|=)\s*(?<ReqVer>[0-9A-Za-z\.\-]+).*but you have\s+(?<Dep2>[^ ]+)\s+(?<ActualVer>[^\s]+)"

    $foundConflict = $false
    foreach ($line in $CheckLines) {
        $m = [regex]::Match($line, $conflictRegex)
        if ($m.Success) {
            $foundConflict = $true

            $depName       = $m.Groups["Dep"].Value
            $comparison    = $m.Groups["Comparison"].Value
            $requiredVer   = $m.Groups["ReqVer"].Value
            $actualVer     = $m.Groups["ActualVer"].Value

            Write-Host "`nVersion conflict detected:"
            Write-Host "Line: $line"
            Write-Host " - $depName $comparison $requiredVer, but currently $depName $actualVer"

            # We'll guess a direct fix strategy:
            # If ">= X", let's try to install exactly X (or maybe a higher version)
            # If "< X", let's try to install the version just below X (this is naive!)
            # If "= X", let's try to install exactly X

            # In real life, you might parse PyPI or Conda to find the best matching version. We'll just attempt the stated version or a small trick for "< X".
            $fixVersion = $requiredVer  # default guess

            if ($comparison -eq "<") {
                # e.g. "importlib-metadata < 4.3"
                # We'll try "4.2" or "4.2.999" or something. Let's do a naive approach:
                # If requiredVer = 4.3, we'll guess 4.2.999 to ensure we are below 4.3.
                $split = $requiredVer.Split(".")
                if ($split.Count -gt 0) {
                    # Subtract 1 from the last part or do something naive
                    $major = [int]$split[0]
                    $minor = 0
                    $patch = 0
                    if ($split.Count -ge 2) { $minor = [int]$split[1] }
                    if ($split.Count -ge 3) { $patch = [int]$split[2] }

                    if ($patch -ge 1) {
                        # simpler approach: patch--
                        $patch--
                    }
                    elseif ($minor -ge 1) {
                        $minor--
                        $patch = 999
                    }
                    else {
                        if ($major -ge 1) {
                            $major--
                            $minor = 999
                            $patch = 999
                        }
                    }
                    $fixVersion = "$major.$minor.$patch"
                }
            }
            elseif ($comparison -eq "<=") {
                # if requirement is "importlib-metadata <= 4.3"
                # We'll just try 4.3 exactly
                $fixVersion = $requiredVer
            }
            elseif ($comparison -eq ">") {
                # naive approach: bump requiredVer by 1 patch
                # e.g. "importlib-metadata > 4.3"
                $split2 = $requiredVer.Split(".")
                if ($split2.Count -gt 0) {
                    $major = [int]$split2[0]
                    $minor = 0
                    $patch = 0
                    if ($split2.Count -ge 2) { $minor = [int]$split2[1] }
                    if ($split2.Count -ge 3) { $patch = [int]$split2[2] }
                    $patch++
                    $fixVersion = "$major.$minor.$patch"
                }
            }
            elseif ($comparison -eq ">=") {
                # Just take the requiredVer as is (or we can attempt to plus one patch to be safe).
                $fixVersion = $requiredVer
            }
            # If it's "=" we do exactly that version.

            Write-Host "Attempting to fix by installing: $depName=$fixVersion"
            conda install -n $EnvName -y "$($depName)=$($fixVersion)"
        }
    }
    return $foundConflict
}


for ($round = 1; $round -le $MaxRounds; $round++) {
    Write-Host "`n=== Round $round of $MaxRounds ==="
    # 1) pip check
    $lines = Run-PipCheck

    # Show the output
    foreach ($ln in $lines) { Write-Host $ln }

    # 2) Try to fix missing packages
    $missingFixed = Install-MissingPackages -CheckLines $lines

    # 3) Try to fix version conflicts
    $conflictFixed = Fix-VersionConflicts -CheckLines $lines

    # 4) If we fixed something (missing or conflict), do a 'conda update --all'
    if ($missingFixed -or $conflictFixed) {
        Write-Host "`nAttempting conda update --all to unify versions..."
        conda update -n $EnvName --all -y
    }
    else {
        # Nothing found to fix => break out
        Write-Host "`nNo missing packages or conflicts found to fix. Stopping."
        break
    }
}

Write-Host "`n===== Final pip check ====="
$finalCheck = Run-PipCheck
$finalCheck | ForEach-Object { Write-Host $_ }

Write-Host "`nAll done. If you still see unsolved version conflicts above, you must fix them manually (e.g., remove a package)."
