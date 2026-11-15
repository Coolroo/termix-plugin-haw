# Runs the parse check of every .ps1 under vmctl/hyperv and the Pester 5 tests.
# Pester 5 comes from the PowerShell Gallery when it is not there.
# Exit code: the number of failed tests plus the files that do not parse.
param([string]$Path = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$have = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.5' -and $_.Version.Major -eq 5 }
if (-not $have) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
'Pester ' + (Get-Module Pester).Version

$bad = 0
foreach ($f in Get-ChildItem -Path (Split-Path -Parent $Path) -Recurse -Filter *.ps1) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors.Count) { $bad++; 'PARSE FAIL ' + $f.Name + ': ' + ($errors | ForEach-Object { $_.Message }) -join '; ' }
    else { 'PARSE OK   ' + $f.Name }
}

$cfg = New-PesterConfiguration
$cfg.Run.Path = $Path
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Normal'
$r = Invoke-Pester -Configuration $cfg
'TOTAL passed {0}, failed {1}, skipped {2}; files that do not parse: {3}' -f $r.PassedCount, $r.FailedCount, $r.SkippedCount, $bad
exit ($r.FailedCount + $bad)
