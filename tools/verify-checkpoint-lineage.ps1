param(
    [string]$Dotnet = 'dotnet',
    [string]$HistoricalDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'orss-checkpoint-lineage-01d6787')
)
$ErrorActionPreference = 'Stop'
$revision = '01d678730ccba53f81cd7d64f2037c6c686d0594'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$historical = [IO.Path]::GetFullPath($HistoricalDirectory)
if ($historical.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/') -or
    $historical.StartsWith($root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use a separate historical directory outside the current source checkout.'
}
if (!(Test-Path -LiteralPath $historical)) {
    & git -C $root worktree add --detach $historical $revision
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the pinned historical worktree.' }
}
$actual = & git -C $historical rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $actual -ne $revision) { throw 'Historical directory is not the pinned upstream revision.' }
$changes = & git -C $historical status --porcelain --untracked-files=no
if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Historical tracked source must be unchanged.' }
$file = 'tests/OkiRomSim.Tests/data/sim-checkpoints.txt'
$old = [IO.File]::ReadAllText((Join-Path $historical $file)).Replace("`r`n", "`n")
$current = [IO.File]::ReadAllText((Join-Path $root $file)).Replace("`r`n", "`n")
if ($old -cne $current) { throw 'The historical checkpoint file was changed.' }
Push-Location $historical
try {
    & $Dotnet run --project tests/OkiRomSim.Tests -c Release -- --only p30,p13,roms
    if ($LASTEXITCODE -ne 0) { throw 'Historical checkpoint verification failed.' }
} finally { Pop-Location }
Write-Host 'All original checkpoint comparisons passed on the unchanged historical simulator.'
Write-Host "Historical worktree retained for review: $historical"
