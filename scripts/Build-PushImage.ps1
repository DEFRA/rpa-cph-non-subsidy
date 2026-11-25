<#
.SYNOPSIS
Builds the container image, scans it, pushes it to Azure Container Registry and emits the immutable digest.
.DESCRIPTION
Tags: <Version> and sha-<short commit>. 'latest' is never pushed: deployments reference the digest.
The identity running this script needs AcrPush on the registry only. The runtime identity (AcrPull) is a
different principal. No registry admin user or stored credential is used.
Modes:
  Docker    Build locally, optionally scan with Trivy, push with 'docker push'.
  AcrBuild  Build in the registry with 'az acr build' (no local Docker daemon needed, no pre-push scan).
.EXAMPLE
.\scripts\Build-PushImage.ps1 -RegistryName acrexample -Repository cph-nonsubsidy -Version 2026.11.17.1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]{5,50}$')] [string] $RegistryName,
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]+([._/-][a-z0-9]+)*$')] [string] $Repository,
    [Parameter(Mandatory)] [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$')] [string] $Version,
    [ValidateSet('Docker', 'AcrBuild')] [string] $Mode = 'Docker',
    [switch] $SkipScan,
    [string] $NuGetSource,
    [string] $DigestFile = (Join-Path $PSScriptRoot '..\image-digest.txt')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$context = Resolve-Path (Join-Path $PSScriptRoot '..')

function Invoke-Native([string] $Description, [scriptblock] $Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

$commit = (git -C $context rev-parse --short=12 HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $commit) { $commit = 'unknown' }
$created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$server = "$RegistryName.azurecr.io"
$versionTag = "${server}/${Repository}:$Version"
$commitTag = "${server}/${Repository}:sha-$commit"

$buildArgs = @('--build-arg', "BUILD_VERSION=$Version", '--build-arg', "VCS_REF=$commit", '--build-arg', "BUILD_DATE=$created")
if ($NuGetSource) { $buildArgs += @('--build-arg', "NUGET_SOURCE=$NuGetSource") }

if ($Mode -eq 'AcrBuild') {
    Invoke-Native 'az acr build' {
        az acr build --registry $RegistryName --image "${Repository}:$Version" --image "${Repository}:sha-$commit" `
            --file Dockerfile @buildArgs $context
    }
} else {
    Invoke-Native 'docker build' { docker build --pull -t $versionTag -t $commitTag @buildArgs $context }

    if (-not $SkipScan) {
        # Fixable HIGH/CRITICAL findings block the push. Needs the Docker socket or an installed trivy.
        if (Get-Command trivy -ErrorAction SilentlyContinue) {
            Invoke-Native 'trivy scan' { trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed $versionTag }
        } else {
            Invoke-Native 'trivy (container) scan' {
                docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:latest image `
                    --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed $versionTag
            }
        }
    }

    Invoke-Native 'az acr login' { az acr login --name $RegistryName }
    Invoke-Native 'docker push (version)' { docker push $versionTag }
    Invoke-Native 'docker push (commit)' { docker push $commitTag }
}

$digest = az acr repository show --name $RegistryName --image "${Repository}:$Version" --query digest --output tsv
if ($LASTEXITCODE -ne 0 -or $digest -cnotmatch '^sha256:[0-9a-f]{64}$') { throw "Could not resolve a registry digest for ${Repository}:$Version." }

Set-Content -LiteralPath $DigestFile -Value $digest -NoNewline
Write-Host "Pushed ${server}/${Repository}:$Version (and sha-$commit)"
Write-Host "Digest: $digest"

# Azure DevOps output variable and GitHub-style output, harmless when run locally.
Write-Host "##vso[task.setvariable variable=imageDigest;isOutput=true]$digest"
if ($env:GITHUB_OUTPUT) { "digest=$digest" | Add-Content -LiteralPath $env:GITHUB_OUTPUT }
