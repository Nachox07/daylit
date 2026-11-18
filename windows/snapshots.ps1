# Renders the UI snapshots with a built Daylit.exe and compares them with the baselines in
# windows/tests/Snapshots. CI runs it on every build and on every release, so the two cannot drift.
#   windows/snapshots.ps1 <Daylit.exe> <output folder> [-Record]
# With -Record it only renders (new baselines; see CONTRIBUTING.md).
param(
    [Parameter(Mandatory)][string]$Exe,
    [Parameter(Mandatory)][string]$Out,
    [switch]$Record
)
& $Exe --render-snapshots $Out | Out-String
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not $Record) {
    & $Exe --compare-snapshots (Join-Path $PSScriptRoot 'tests/Snapshots') $Out | Out-String
    exit $LASTEXITCODE
}
