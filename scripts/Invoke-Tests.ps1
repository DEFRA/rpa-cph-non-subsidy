<#
.SYNOPSIS
Runs the application test suites by category and writes a TRX file plus a Markdown summary per run.
.DESCRIPTION
Categories (from the existing tests): Unit, Integration, Browser (Playwright end-to-end, needs Edge or Chrome),
plus the SQL Server provider tests which are tagged Integration in the Domain project.
Tests are hermetic: they use in-memory hosts, SQLite and a stub identity provider, so they need no Azure access.
Post-deployment checks against a live site are in Test-Deployment.ps1.
.EXAMPLE
.\scripts\Invoke-Tests.ps1 -Suite All
.\scripts\Invoke-Tests.ps1 -Suite Unit,Integration -SkipBrowser
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Unit', 'Integration', 'Browser')] [string[]] $Suite = 'All',
    [switch] $SkipBrowser,
    [string] $Configuration = 'Release',
    [string] $ResultsDirectory = (Join-Path $PSScriptRoot '..\reports\test-results')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$solution = Resolve-Path (Join-Path $PSScriptRoot '..\RPA.CPH.NonSubsidy.Domain\RPA.CPH.NonSubsidy.sln')
New-Item -ItemType Directory -Force $ResultsDirectory | Out-Null
$ResultsDirectory = Resolve-Path $ResultsDirectory

if ($Suite -contains 'All') { $Suite = @('Unit', 'Integration', 'Browser') }
if ($SkipBrowser) { $Suite = $Suite | Where-Object { $_ -ne 'Browser' } }

# MSTest and NUnit both honour the TestCategory/Category filter property.
$filters = @{ Unit = 'TestCategory=Unit|Category=Unit'; Integration = 'TestCategory=Integration|Category=Integration'; Browser = 'TestCategory=Browser' }

dotnet build $solution -c $Configuration --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$rows = @()
foreach ($name in $Suite) {
    # LogFilePrefix makes the file name unique per test assembly so projects do not overwrite each other.
    Get-ChildItem $ResultsDirectory -Filter "$($name.ToLower())_*.trx" -ErrorAction SilentlyContinue | Remove-Item -Force
    dotnet test $solution -c $Configuration --no-build --nologo --filter $filters[$name] `
        --logger "trx;LogFilePrefix=$($name.ToLower())" --results-directory $ResultsDirectory | Out-Host
    $exit = $LASTEXITCODE
    $total = 0; $passed = 0; $failed = 0
    foreach ($file in Get-ChildItem $ResultsDirectory -Filter "$($name.ToLower())_*.trx") {
        [xml] $xml = Get-Content $file.FullName
        $counters = $xml.TestRun.ResultSummary.Counters
        $total += [int] $counters.total; $passed += [int] $counters.passed; $failed += [int] $counters.failed
    }
    $rows += [pscustomobject]@{
        Suite = $name
        Total = $total
        Passed = $passed
        Failed = $failed
        Result = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
    }
}

$summary = Join-Path $ResultsDirectory 'summary.md'
$lines = @('# Test execution summary', '', "Run: $((Get-Date).ToUniversalTime().ToString('u'))  Configuration: $Configuration", '',
    '| Suite | Total | Passed | Failed | Result |', '|---|---|---|---|---|')
$lines += $rows | ForEach-Object { "| $($_.Suite) | $($_.Total) | $($_.Passed) | $($_.Failed) | $($_.Result) |" }
Set-Content $summary $lines
$rows | Format-Table -AutoSize | Out-Host

if ($rows | Where-Object Result -eq 'FAIL') { exit 1 }
