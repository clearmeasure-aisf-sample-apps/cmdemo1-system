#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Fails unless a GHCR container image tag is pullable anonymously (issue #737).

.DESCRIPTION
    GitHub's REST API has no endpoint to change a package's visibility. After publish-test-runner pushes
    the acceptance-test worker image, this script checks that an anonymous GHCR pull token and the image
    manifest for the tag succeed. When they do not, it exits non-zero and prints the exact package-settings
    URL an org owner must visit to set the package Public. Uses no secrets or tokens.

.PARAMETER Image
    Image reference as owner/name:tag or ghcr.io/owner/name:tag (from images/test-runner/image.txt / system.yml).

.PARAMETER MaxAttempts
    How many times to retry while GHCR indexing catches up after a push. Default 6 (same budget as the old
    visibility PUT loop).

.PARAMETER LoadOnly
    Define the functions and return (scripts/test-test-runner.ps1).

.EXAMPLE
    pwsh -NoProfile -File scripts/assert-ghcr-anonymous-pull.ps1 `
      -Image clearmeasure-aisf-sample-apps/cmdemo1-test-runner:v1.61.0-dotnet10
#>
[CmdletBinding()]
param(
    [string] $Image = '',
    [int] $MaxAttempts = 6,
    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

function ConvertTo-GhcrImageParts {
    param([Parameter(Mandatory)] [string] $Image)

    $ref = $Image.Trim()
    if ($ref.StartsWith('ghcr.io/', [StringComparison]::OrdinalIgnoreCase)) {
        $ref = $ref.Substring('ghcr.io/'.Length)
    }
    if ($ref -notmatch '^(?<owner>[A-Za-z0-9_.-]+)/(?<name>[A-Za-z0-9_.-]+):(?<tag>[A-Za-z0-9_.-]+)$') {
        throw "Image '$Image' is not owner/name:tag (optional ghcr.io/ prefix)."
    }
    return [ordered] @{
        Owner      = [string] $Matches['owner']
        Name       = [string] $Matches['name']
        Tag        = [string] $Matches['tag']
        Repository = "$($Matches['owner'])/$($Matches['name'])"
    }
}

function Get-GhcrAnonymousTokenUri {
    param([Parameter(Mandatory)] [string] $Repository)
    return "https://ghcr.io/token?scope=repository:${Repository}:pull"
}

function Get-GhcrManifestUri {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $Tag
    )
    return "https://ghcr.io/v2/${Repository}/manifests/${Tag}"
}

function Get-GhcrPackageSettingsUri {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $PackageName
    )
    return "https://github.com/orgs/${Owner}/packages/container/${PackageName}/settings"
}

function Get-GhcrAnonymousPullGuidance {
    param(
        [Parameter(Mandatory)] [string] $Owner,
        [Parameter(Mandatory)] [string] $PackageName,
        [Parameter(Mandatory)] [string] $Detail
    )
    $settings = Get-GhcrPackageSettingsUri -Owner $Owner -PackageName $PackageName
    return @(
        "$PackageName is not anonymously pullable on GHCR ($Detail)."
        'An org owner must set the package to Public once at:'
        $settings
        "GitHub's REST API cannot change package visibility."
    ) -join [Environment]::NewLine
}

# Interprets one anonymous token + manifest probe. Ok=true when both succeed; otherwise Reason names the failure.
function Resolve-GhcrAnonymousPullProbe {
    param(
        [Parameter(Mandatory)] [int] $TokenStatus,
        [AllowNull()] [string] $TokenBody,
        [AllowNull()] [Nullable[int]] $ManifestStatus
    )

    if ($TokenStatus -ne 200) {
        return [ordered] @{ Ok = $false; Reason = "anonymous token HTTP $TokenStatus" }
    }
    $token = $null
    try {
        $parsed = $TokenBody | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $parsed -and $parsed.PSObject.Properties.Name -contains 'token') {
            $token = [string] $parsed.token
        }
    }
    catch {
        return [ordered] @{ Ok = $false; Reason = 'anonymous token response was not JSON with a token' }
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        return [ordered] @{ Ok = $false; Reason = 'anonymous token response had no token' }
    }
    # ManifestStatus $null: token step only (caller fetches the manifest next).
    if ($null -eq $ManifestStatus) {
        return [ordered] @{ Ok = $true; Reason = ''; Token = $token }
    }
    if ([int] $ManifestStatus -ne 200) {
        return [ordered] @{ Ok = $false; Reason = "manifest HTTP $ManifestStatus"; Token = $token }
    }
    return [ordered] @{ Ok = $true; Reason = ''; Token = $token }
}

# One HTTP answer for the injectable GetHttp: @{ StatusCode = int; Body = string }.
function Invoke-GhcrAnonymousPullHttp {
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [hashtable] $Headers = @{}
    )
    $answer = Invoke-WebRequest -Uri $Uri -Method Get -Headers $Headers -TimeoutSec 60 -SkipHttpErrorCheck
    return [ordered] @{
        StatusCode = [int] $answer.StatusCode
        Body       = [string] $answer.Content
    }
}

function Assert-GhcrAnonymousPull {
    param(
        [Parameter(Mandatory)] [string] $Image,
        [int] $MaxAttempts = 6,
        # Returns @{ StatusCode; Body } for a URI (and optional headers). Tests inject a fake.
        $GetHttp = ${function:Invoke-GhcrAnonymousPullHttp},
        # Delay between attempts; tests inject a no-op.
        $Wait = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
    )

    if ($MaxAttempts -lt 1) { throw 'MaxAttempts must be at least 1.' }
    $parts = ConvertTo-GhcrImageParts -Image $Image
    $tokenUri = Get-GhcrAnonymousTokenUri -Repository $parts.Repository
    $manifestUri = Get-GhcrManifestUri -Repository $parts.Repository -Tag $parts.Tag
    $lastReason = 'no attempt ran'

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $tokenAnswer = & $GetHttp -Uri ([uri] $tokenUri)
        $tokenStatus = [int] $tokenAnswer.StatusCode
        $tokenBody = [string] $tokenAnswer.Body
        $probe = Resolve-GhcrAnonymousPullProbe -TokenStatus $tokenStatus -TokenBody $tokenBody -ManifestStatus $null
        if (-not $probe.Ok) {
            $lastReason = [string] $probe.Reason
        }
        else {
            $manifestHeaders = @{
                Authorization = "Bearer $($probe.Token)"
                Accept        = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'
            }
            $manifestAnswer = & $GetHttp -Uri ([uri] $manifestUri) -Headers $manifestHeaders
            $probe = Resolve-GhcrAnonymousPullProbe `
                -TokenStatus $tokenStatus `
                -TokenBody $tokenBody `
                -ManifestStatus ([int] $manifestAnswer.StatusCode)
            if ($probe.Ok) {
                Write-Host "Anonymous GHCR pull ok for $($parts.Repository):$($parts.Tag)"
                return
            }
            $lastReason = [string] $probe.Reason
        }

        if ($attempt -lt $MaxAttempts) {
            $delay = $attempt * 5
            Write-Host "anonymous GHCR pull attempt $attempt failed ($lastReason); waiting ${delay}s..."
            & $Wait -Seconds $delay
        }
    }

    $message = Get-GhcrAnonymousPullGuidance -Owner $parts.Owner -PackageName $parts.Name -Detail $lastReason
    Write-Host $message
    throw $message
}

if ($LoadOnly) { return }

if (-not $Image) { throw 'Image is required (owner/name:tag or ghcr.io/owner/name:tag).' }
Assert-GhcrAnonymousPull -Image $Image -MaxAttempts $MaxAttempts
