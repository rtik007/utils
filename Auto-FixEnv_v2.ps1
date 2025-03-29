<#
.SYNOPSIS
  Automated script to fix dependency issues in a Conda environment.

.DESCRIPTION
  This PowerShell script automates the resolution of dependency issues by:
    1. Running `pip check` in a specified Conda environment.
    2. Detecting missing packages and installing them.
    3. Identifying version conflicts (including those with Python version conditions) and
       attempting to resolve them by uninstalling the conflicting package and installing a target version.
    4. Looping multiple rounds, where the maximum number of rounds is dynamically determined
       based on the number of conflict messages (plus a buffer) and stops early if no improvement is made.

  Additionally, when issues are fixed, the script performs:
    - A `conda update --all` to update Conda-managed packages.
    - A pip upgrade for all outdated pip packages in the environment.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Auto-FixEnv_v2.ps1 -EnvName "test_env"
  
.NOTES
  - The version resolution logic (e.g., decrementing the patch for "<" requirements) is naive.
  - Ensure that your Conda version supports `conda run`.
  - Testing in a safe environment is recommended.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$EnvName,

    [int]$MaxRounds = 5  # default maximum rounds if the heuristic produces a lower value.
)

Write-Host "=== Automated Fix Script for Conda Environment '$EnvName' ===`n"

# Function to get the Python version in the environment.
function Get-PythonVersion {
    $pyverOutput = conda run -n $EnvName python --version 2>&1
    # Expecting output like: "Python 3.8.10"
    if ($pyverOutput -match "Python\s+(?<pyver>[0-9\.]+)") {
         return [version]$matches['pyver']
    }
    Write-Host "Unable to determine Python version."
    return $null
}

# Function to check if the environment's Python version satisfies a condition string.
# Example condition: "python_version < '3.10'"
function Check-PythonCondition {
    param(
       [string]$Condition
    )
    if ($Condition -match "python_version\s*(?<op><=?|>=?|=)\s*'(?<pyver>[0-9\.]+)'") {
         $op = $matches['op']
         $condVersion = [version]$matches['pyver']
         $envVersion = Get-PythonVersion
         if (-not $envVersion) { return $false }
         switch ($op) {
             "<"  { return $envVersion -lt $condVersion }
             "<=" { return $envVersion -le $condVersion }
             ">"  { return $envVersion -gt $condVersion }
             ">=" { return $envVersion -ge $condVersion }
             "="  { return $envVersion -eq $condVersion }
             default { return $false }
         }
    }
    # If no condition is provided or recognized, assume it's compatible.
    return $true
}

# Run pip check in the environment and split output into lines.
function Run-PipCheck {
    $output = conda run -n $EnvName pip check 2>&1
    $lines  = ($output | Out-String) -split "`r?`n"
    return $lines
}

# Install any missing dependencies detected by pip check.
function Install-MissingPackages {
    param(
        [string[]]$CheckLines
    )
    # Example pattern: "tqdm 4.63.0 requires importlib-resources, which is not installed."
    $missingRegex = "(?<Pkg>[^ ]+)\s+\S+\s+requires\s+(?<MissingDep>[^,]+),\s+which\s+is\s+not\s+installed\."
    $depsToInstall = @()
    foreach ($line in $CheckLines) {
        $m = [regex]::Match($line, $missingRegex)
        if ($m.Success) {
            $needed = $m.Groups["MissingDep"].Value.Trim()
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

# Fix version conflicts by uninstalling the conflicting package and attempting to install a target version.
function Fix-VersionConflicts {
    param(
        [string[]]$CheckLines
    )
    # Regex captures an optional condition (e.g., "; python_version < '3.10'")
    $conflictRegex = "^(?<Package>[^ ]+)\s+(?<PkgVer>[^\s]+)\s+has requirement\s+(?<Dep>[^<>=]+)(?<Comparison><=?|>=?|=)\s*(?<ReqVer>[0-9A-Za-z\.\-]+)(\s*;\s*(?<Condition>[^,]+))?.*but you have\s+(?<Dep2>[^ ]+)\s+(?<ActualVer>[^\s]+)"
    
    $foundConflict = $false
    foreach ($line in $CheckLines) {
        $m = [regex]::Match($line, $conflictRegex)
        if ($m.Success) {
            $foundConflict = $true

            $depName     = $m.Groups["Dep"].Value.Trim()
            $comparison  = $m.Groups["Comparison"].Value.Trim()
            $requiredVer = $m.Groups["ReqVer"].Value.Trim()
            $actualVer   = $m.Groups["ActualVer"].Value.Trim()
            $condition   = $m.Groups["Condition"].Value.Trim()

            Write-Host "`nVersion conflict detected:"
            Write-Host "Line: $line"
            Write-Host " - $depName $comparison $requiredVer, but currently $depName $actualVer"
            if ($condition) {
                Write-Host " - Condition: $condition"
                $isCompatible = Check-PythonCondition -Condition $condition
                if (-not $isCompatible) {
                    Write-Host "   Skipping fix as the condition '$condition' is not met by the environment's Python version."
                    continue
                }
            }

            # Determine the target version to install.
            $fixVersion = $requiredVer  # default
            if ($comparison -eq "<") {
                # For example, if required is "< 4.3", try a version just below 4.3.
                $split = $requiredVer.Split(".")
                if ($split.Count -gt 0) {
                    $major = [int]$split[0]
                    $minor = 0
                    $patch = 0
                    if ($split.Count -ge 2) { $minor = [int]$split[1] }
                    if ($split.Count -ge 3) { $patch = [int]$split[2] }
                    if ($patch -ge 1) {
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
                $fixVersion = $requiredVer
            }
            elseif ($comparison -eq ">") {
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
                $fixVersion = $requiredVer
            }

            # Uninstall the conflicting package using pip uninstall.
            Write-Host "Uninstalling conflicting package $depName..."
            conda run -n $EnvName pip uninstall -y $depName

            # Attempt to install the target (lower) version.
            Write-Host "Attempting to fix by installing: $depName=$fixVersion"
            conda install -n $EnvName -y "$depName=$fixVersion"
        }
    }
    return $foundConflict
}

# Function to upgrade all outdated pip packages in the environment.
function Update-PipAll {
    Write-Host "`nFetching list of outdated pip packages..."
    # List outdated packages using pip in the Conda environment.
    $outdatedList = conda run -n $EnvName pip list --outdated --format=freeze 2>&1 | Out-String
    # Split the output into lines and use an explicit regex match.
    $outdatedPackages = $outdatedList -split "`r?`n" | ForEach-Object {
         $line = $_.Trim()
         if ([string]::IsNullOrEmpty($line)) { return }
         $match = [regex]::Match($line, "^(?<pkg>[^=]+)==")
         if ($match.Success) {
             return $match.Groups["pkg"].Value.Trim()
         }
    }
    if ($outdatedPackages -and $outdatedPackages.Count -gt 0) {
        foreach ($pkg in $outdatedPackages) {
             if (![string]::IsNullOrEmpty($pkg)) {
                 Write-Host "Upgrading package: $pkg"
                 conda run -n $EnvName pip install --upgrade $pkg
             }
        }
    }
    else {
         Write-Host "No outdated pip packages found."
    }
}

# Function to count conflict messages in the pip check output.
function Count-Conflicts {
    param (
        [string[]]$CheckLines
    )
    $conflictLines = $CheckLines | Where-Object { $_ -match "has requirement" }
    return $conflictLines.Count
}

# Get initial conflict count and set dynamic maximum rounds.
$initialLines = Run-PipCheck
$initialConflictCount = Count-Conflicts -CheckLines $initialLines
$bufferRounds = 2
$dynamicMaxRounds = $initialConflictCount + $bufferRounds

# Ensure a minimum number of rounds if needed.
if ($dynamicMaxRounds -lt $MaxRounds) {
    $dynamicMaxRounds = $MaxRounds
}

Write-Host "Detected $initialConflictCount conflicts. Setting maximum rounds to $dynamicMaxRounds."

$previousConflictCount = [int]::MaxValue

# Main loop: use dynamic stopping conditions based on conflict count improvements.
for ($round = 1; $round -le $dynamicMaxRounds; $round++) {
    Write-Host "`n=== Round $round of $dynamicMaxRounds ==="
    
    $lines = Run-PipCheck
    $currentConflictCount = Count-Conflicts -CheckLines $lines
    Write-Host "Current conflict count: $currentConflictCount"
    
    # Stop if there are no conflicts.
    if ($currentConflictCount -eq 0) {
         Write-Host "No conflicts detected, stopping execution."
         break
    }
    
    # Stop if no improvement is detected compared to the previous round.
    if ($currentConflictCount -ge $previousConflictCount) {
         Write-Host "No improvement in conflict count detected (previous: $previousConflictCount, current: $currentConflictCount), stopping execution."
         break
    }
    
    $previousConflictCount = $currentConflictCount

    $missingFixed = Install-MissingPackages -CheckLines $lines
    $conflictFixed = Fix-VersionConflicts -CheckLines $lines
    
    if ($missingFixed -or $conflictFixed) {
        Write-Host "`nUpdating packages..."
        conda update -n $EnvName --all -y

        Write-Host "`nAttempting pip upgrade for all outdated packages..."
        Update-PipAll
    }
    else {
        Write-Host "`nNo missing packages or conflicts found to fix. Stopping."
        break
    }
}

Write-Host "`n===== Final pip check ====="
$finalCheck = Run-PipCheck
$finalCheck | ForEach-Object { Write-Host $_ }

Write-Host "`nAll done. If you still see unsolved version conflicts above, you must fix them manually (e.g., remove a package)."
