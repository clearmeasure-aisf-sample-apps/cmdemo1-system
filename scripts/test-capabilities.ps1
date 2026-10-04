#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Proves the capabilities of this system: one read-only check per capability, against GitHub, Octopus and Azure.

.DESCRIPTION
    The nightly workflow "capabilities" runs it as the system's own identities (environment "capabilities": the plan
    identity in Azure, the system's service account in Octopus); the operator runs the same file through the kit's
    test-capabilities.ps1. It changes nothing. Each check names the capability it proves (CAP-NNN in the kit's
    docs/capabilities.md); a failed check fails the run, and the workflow opens an issue labelled "capability".

    Octopus: OCTOPUS_API_KEY when set (the operator), otherwise OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login). GitHub: gh
    with GH_TOKEN or its own login. Azure: the current az login.
#>
[CmdletBinding()]
param(
    [string] $Root = (Split-Path -Parent $PSScriptRoot),
    [string[]] $Only = @(),
    [switch] $ListChecks,
    # Only wait until no Octopus task runs, then stop (the workflow waits before it signs in to Azure; see capabilities.yml).
    [switch] $WaitOnly,
    [int] $WaitMinutes = 90
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

# pwsh -File passes "CAP-001,CAP-002" as one string.
$Only = @($Only | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
if (-not $ListChecks) {
    $system = Get-Content -LiteralPath (Join-Path $Root 'system.json') -Raw | ConvertFrom-Json -AsHashtable
    $slug = [string] $system.system.slug
    $org = [string] $system.system.githubOrg
    $systemRepo = "$org/$($system.system.repository)"
    $deployable = [string] $system.deployables[0].name
    $appRepo = "$org/$($system.deployables[0].repository)"
    $systemProject = "$slug-system"
    $deployableProject = "$slug-$deployable"
    $space = [string] $system.octopus.spaceId
    $environments = @($system.environments | ForEach-Object { [string] $_.name })
    $first = $environments[0]
    # The first app runs as a container app, or on App Service (deployables[].hosting "appservice"): the checks of
    # the artifact, the size, the idle cost and the placement ask the hosting it has.
    $onAppService = $system.deployables[0]['hosting'] -eq 'appservice'
}

function Write-Pass { param([string] $Message) Write-Host "PASS $Message" }
function Write-Fail { param([string] $Message) Write-Host "FAIL $Message" }
function Invoke-Octopus([string] $Path) {
    $headers = if ($env:OCTOPUS_API_KEY) { @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } } else { @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    Invoke-RestMethod -Uri "$($system.octopus.url)$Path" -Headers $headers
}
function Get-RepoFile([string] $Repo, [string] $Path) {
    $content = gh api "repos/$Repo/contents/$Path" --jq .content
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String((($content -join '') -replace '\s', '')))
}
function Get-RequiredCheck([string] $Repo) {
    $id = gh api "repos/$Repo/rulesets" --jq '.[] | select(.name=="default-branch") | .id'
    @(gh api "repos/$Repo/rulesets/$id" --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks[].context')
}
function Get-Project([string] $Slug) { Invoke-Octopus "/api/$space/projects/$Slug" }
function Get-ProcessStep([string] $Slug) { @((Invoke-Octopus "/api/$space/projects/$((Get-Project $Slug).Id)/deploymentprocesses").Steps) }
function Get-EnvironmentId([string] $Name) { @((Invoke-Octopus "/api/$space/environments?partialName=$Name&take=100").Items | Where-Object Name -eq $Name)[0].Id }
# A capability whose precondition does not exist yet (no app deployment, no prod-tier environment, a runbook not due
# yet) is skipped with the reason, not failed: a new system's first builds run every check. Only facts skip a check;
# once the precondition exists, the check proves or fails.
class CheckSkipped : System.Exception {
    CheckSkipped([string] $Message) : base($Message) {}
}
function Skip-Check([string] $Reason) { throw [CheckSkipped]::new($Reason) }
function Find-LastDeployment([string] $Slug, [string] $Environment) {
    # The latest successful deployment of a project to an environment, or $null when there is none yet.
    $project = Get-Project $Slug
    $deployment = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $Environment)&take=10").Items |
            Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' }) | Select-Object -First 1
    if (-not $deployment) { return $null }
    $deployment | Add-Member -NotePropertyName Log -NotePropertyValue (Invoke-Octopus "/api/tasks/$($deployment.TaskId)/raw") -PassThru |
        Add-Member -NotePropertyName Version -NotePropertyValue (Invoke-Octopus "/api/$space/releases/$($deployment.ReleaseId)").Version -PassThru
}
function Get-LastDeployment([string] $Slug, [string] $Environment) {
    $deployment = Find-LastDeployment $Slug $Environment
    if (-not $deployment) { Skip-Check "no successful $Slug deployment in $Environment yet" }
    $deployment
}
function Get-ProdEnvironment {
    $prod = @($environments | Where-Object { (Get-Group $_) -eq $system.azure.resourceGroups.prod })
    if ($prod.Count -eq 0) { Skip-Check 'no prod-tier environment yet' }
    $prod
}
function Assert-AppRepository {
    $PSNativeCommandUseErrorActionPreference = $false
    gh api "repos/$appRepo" --jq .id *> $null
    $exists = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $exists) { Skip-Check "app repository $appRepo does not exist yet" }
}
function Get-SystemAge {
    # Days since the system's first release: a runbook on a schedule cannot have run before its first due date.
    $project = Get-Project $systemProject
    $releases = @((Invoke-Octopus "/api/$space/projects/$($project.Id)/releases?take=1000").Items)
    if ($releases.Count -eq 0) { return 0 }
    ([datetimeoffset]::UtcNow - [datetimeoffset] $releases[-1].Assembled).TotalDays
}
function Get-NoisyDeployment {
    # No broken windows: the deployment each environment runs now, per project, logged no Error or Warning line and did
    # not end SuccessWithWarning. Current deployments rather than the last N: a fixed warning stops counting once the
    # environment is redeployed, without deployments made only to push it out of a window.
    foreach ($project in $systemProject, $deployableProject) {
        foreach ($e in $environments) {
            $deployment = Find-LastDeployment $project $e
            if (-not $deployment) { continue }
            $details = Invoke-Octopus "/api/tasks/$($deployment.TaskId)/details?verbose=false"
            $warned = @($details.ActivityLogs[0].Children | Where-Object { $_.Status -eq 'SuccessWithWarning' })
            $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match '^\S+\s+(Error|Warning)\s+\|' })
            if ($warned.Count -gt 0 -or $lines.Count -gt 0) { "$project $($deployment.Version) in $e" }
        }
    }
}
function Get-Group([string] $Environment) {
    $tier = @($system.environments | Where-Object name -eq $Environment)[0].tier
    [string] $system.azure.resourceGroups[$tier]
}
function Get-App([string] $Environment) {
    # By the name the stack reports: a shared or moved Container Apps environment gives the app a suffix.
    $name = ([string] (az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.deployables.value[?name=='$deployable'].containerApp | [0]" --output tsv)).Trim()
    if (-not $name) { throw "stack-$slug-$Environment lists no container app for $deployable (a failed or unfinished apply?)" }
    az containerapp show --name $name --resource-group (Get-Group $Environment) --output json | ConvertFrom-Json -AsHashtable
}
function Get-Site([string] $Environment) {
    # The App Service web app of the first deployable, by the name the stack reports, with its plan's SKU.
    $entry = az stack group show --name "stack-$slug-$Environment" --resource-group (Get-Group $Environment) --query "outputs.deployables.value[?name=='$deployable'] | [0]" --output json | ConvertFrom-Json -AsHashtable
    if (-not $entry -or -not $entry['webApp']) { throw "stack-$slug-$Environment lists no web app for $deployable (a failed or unfinished apply?)" }
    $site = az webapp show --name $entry.webApp --resource-group (Get-Group $Environment) --query '{name: name, location: location, plan: appServicePlanId}' --output json | ConvertFrom-Json -AsHashtable
    $site.url = [string] $entry.url
    $site.sku = az appservice plan show --ids $site.plan --query '{name: sku.name, tier: sku.tier}' --output json | ConvertFrom-Json -AsHashtable
    $site
}
function Get-DeployedPackage([string] $Environment) {
    # The version of the app package (the zip in the Octopus built-in feed) the environment's current release deploys.
    $deployment = Get-LastDeployment $deployableProject $Environment
    $release = Invoke-Octopus "/api/$space/releases/$($deployment.ReleaseId)"
    $package = @($release.SelectedPackages | Where-Object { $_.ActionName -eq 'Update deployable' })[0]
    @{ release = [string] $release.Version; package = [string] $package.Version }
}
function Get-RoleName([string] $Group, [string] $PrincipalId) {
    # Assignments at, above and below the group that name the principal; role names from their definitions.
    $subscription = [string] $system.azure.subscriptionId
    $uri = "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=assignedTo('$PrincipalId')"
    foreach ($assignment in @((az rest --method get --url $uri --output json | ConvertFrom-Json -AsHashtable).value)) {
        $definition = ($assignment.properties.roleDefinitionId -split '/')[-1]
        [string] (az rest --method get --url "https://management.azure.com/subscriptions/$subscription/resourceGroups/$Group/providers/Microsoft.Authorization/roleDefinitions/$($definition)?api-version=2022-04-01" --query properties.roleName --output tsv)
    }
}
function Get-RecentRun([string] $Runbook, [int] $Days) {
    $runs = @((Invoke-Octopus "/api/$space/tasks?name=RunbookRun&take=100").Items |
            Where-Object { $_.Description -like "*$Runbook*" -and $_.State -eq 'Success' -and [datetimeoffset] $_.CompletedTime -gt [datetimeoffset]::UtcNow.AddDays(-$Days) })
    if ($runs.Count -eq 0 -and (Get-SystemAge) -lt $Days) { Skip-Check "the system is younger than $Days days: $Runbook is not due yet" }
    $runs
}
function Assert-That([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$checks = [ordered] @{
    'CAP-001' = { $rules = gh api "repos/$systemRepo/rulesets" --jq '[.[] | select(.name=="default-branch" and .enforcement=="active")] | length'; Assert-That ([int] $rules -eq 1) 'no active default-branch ruleset'; 'ruleset default-branch active' }
    'CAP-002' = { Assert-That ((Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'preview-environment\.ps1') 'env-checks has no preview'; 'env-checks previews every environment' }
    'CAP-003' = { Assert-AppRepository; $s = Get-RequiredCheck $systemRepo; $a = Get-RequiredCheck $appRepo; Assert-That ($s -contains 'env-checks' -and $a -contains 'Build result') "required: $s / $a"; "system: $($s -join ', '); app: $($a -join ', ')" }
    'CAP-004' = {
        $checked = @(foreach ($e in $environments) {
                $deployment = Find-LastDeployment $deployableProject $e
                if (-not $deployment) { continue }
                $pinned = (Get-RepoFile $systemRepo "environments/$e/versions.json" | ConvertFrom-Json -AsHashtable)[$deployable]
                Assert-That ($pinned -eq $deployment.Version) "$e pins $pinned, Octopus deployed $($deployment.Version)"
                $e
            })
        if ($checked.Count -eq 0) { Skip-Check "no successful $deployableProject deployment yet" }
        "versions.json equals the deployed release in $($checked -join ', ')"
    }
    'CAP-005' = { $step = @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Revert pin'); Assert-That ($step.Count -eq 1 -and $step[0].Condition -eq 'Failure') 'no Revert pin on failure'; 'Revert pin runs on failure' }
    'CAP-010' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'Build result') 'Build result not required'; 'Build result required on the app' }
    'CAP-011' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the current deployment of every project and environment logged no warning or error' }
    'CAP-012' = { Assert-That ((Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'head\.repo\.full_name == github\.repository') 'preview runs for forks'; 'the credentialed preview runs only for branches of the repository' }
    'CAP-013' = {
        $v = (Get-LastDeployment $deployableProject $first).Version
        if ($onAppService) {
            # The build stamps the version into the app, which reports it; the release's package carries the same number.
            $running = [string] (Invoke-RestMethod -Uri "$((Get-Site $first).url)/_version" -TimeoutSec 120).version
            Assert-That ($running -eq $v -or $running.StartsWith("$v+")) "$first runs $running for release $v"
            Assert-That ((Get-DeployedPackage $first).package -eq $v) "release $v deploys package $((Get-DeployedPackage $first).package)"
            return "release $v = package version = the version the app reports in $first"
        }
        $image = [string] (Get-App $first).properties.template.containers[0].image; Assert-That ($image.EndsWith(":$v")) "$first runs $image for release $v"; "release $v = image tag in $first"
    }
    'CAP-014' = {
        $files = @(gh api "repos/$systemRepo/contents/scripts" --jq '.[].name' | Where-Object { $_ -like '*.ps1' })
        foreach ($f in $files) { $t = Get-RepoFile $systemRepo "scripts/$f"; Assert-That ($t -match "ErrorActionPreference = 'Stop'" -and $t -match 'PSNativeCommandUseErrorActionPreference = \$true') "$f lacks the preamble" }
        "$($files.Count) step scripts stop on errors"
    }
    'CAP-020' = {
        if ($onAppService) {
            # One zip per version in the built-in feed; every environment's release deploys the package of its own number.
            $shown = foreach ($e in $environments) { if (-not (Find-LastDeployment $deployableProject $e)) { continue }; $p = Get-DeployedPackage $e; Assert-That ($p.release -eq $p.package) "$e runs release $($p.release) with package $($p.package)"; "$e $($p.package)" }
            if (-not $shown) { Skip-Check "no successful $deployableProject deployment yet" }
            return "one package per version: $($shown -join ', ')"
        }
        $byVersion = @{}
        foreach ($e in $environments) { $img = [string] (Get-App $e).properties.template.containers[0].image; $v = $img.Split(':')[-1]; if ($byVersion.ContainsKey($v)) { Assert-That ($byVersion[$v] -eq $img) "$v differs: $($byVersion[$v]) / $img" } else { $byVersion[$v] = $img } }
        "one image per version across $($environments -join ', ')"
    }
    'CAP-021' = {
        if ($onAppService) {
            # The package feed keeps the first upload of a version: the release workflow pushes with IgnoreIfExists only.
            Assert-AppRepository
            $modes = @([regex]::Matches((Get-RepoFile $appRepo '.github/workflows/release.yml'), 'overwrite_mode:\s*(\S+)') | ForEach-Object { $_.Groups[1].Value })
            Assert-That ($modes.Count -gt 0 -and @($modes | Where-Object { $_ -ne 'IgnoreIfExists' }).Count -eq 0) "release.yml pushes with $($modes -join ', ')"
            return "release.yml never replaces a pushed package ($($modes.Count) pushes, IgnoreIfExists)"
        }
        $v = (Get-LastDeployment $deployableProject $first).Version; $w = az acr repository show --name $system.azure.registry.name --image "$($slug)/${deployable}:$v" --query 'changeableAttributes.writeEnabled' --output tsv; Assert-That ($w -eq 'false') "$v is writable"; "$($slug)/${deployable}:$v is write-locked"
    }
    'CAP-030' = { $l = @((Invoke-Octopus "/api/$space/lifecycles?partialName=$($slug)-lifecycle&take=100").Items | Where-Object { $_.Name -eq "$($slug)-lifecycle" })[0]; Assert-That (@($l.Phases[0].AutomaticDeploymentTargets).Count -eq 1 -and @($l.Phases | Select-Object -Skip 1 | Where-Object { $_.AutomaticDeploymentTargets.Count -gt 0 }).Count -eq 0) 'lifecycle phases wrong'; "first phase automatic, $($l.Phases.Count - 1) by promotion" }
    'CAP-031' = { foreach ($e in $environments) { Assert-That ([bool] (Get-EnvironmentId $e)) "$e missing in Octopus"; az stack group show --name "stack-$($slug)-$e" --resource-group (Get-Group $e) --query name --output tsv | Out-Null }; "$($environments.Count) environments in Octopus and Azure" }
    'CAP-032' = { foreach ($e in $environments) { $st = az stack group show --name "stack-$($slug)-$e" --resource-group (Get-Group $e) --query '{p: provisioningState, d: denySettings.mode}' --output json | ConvertFrom-Json; Assert-That ($st.p -eq 'succeeded' -and $st.d -eq 'denyWriteAndDelete') "$e stack $($st.p) $($st.d)" }; 'every stack succeeded, deny write and delete' }
    'CAP-033' = {
        if ($onAppService) {
            # App Service: every environment's app runs on the Free plan of its tier; there is no size to declare.
            foreach ($e in $environments) { $s = Get-Site $e; Assert-That ($s.sku.name -eq 'F1') "$e runs on $($s.sku.name), the template declares F1" }
            return 'every app runs on the plan size the template declares (F1)'
        }
        foreach ($entry in $system.environments) { $want = if ($entry.ContainsKey('appCpu')) { [double] $entry.appCpu } else { 0.5 }; $got = [double] (Get-App $entry.name).properties.template.containers[0].resources.cpu; Assert-That ($want -eq $got) "$($entry.name) has $got vCPU, system.json $want" }; 'app sizes follow system.json'
    }
    'CAP-034' = { $n = @(Get-ProcessStep $deployableProject | ForEach-Object Name); Assert-That ($n.IndexOf('Migrate database') -lt $n.IndexOf('Update deployable')) 'Update before Migrate'; 'Migrate database before Update deployable' }
    'CAP-035' = { foreach ($f in 'update-deployable.ps1', 'verify-environment.ps1') { Assert-That ((Get-RepoFile $systemRepo "scripts/$f") -match 'Get-RevisionProblem') "$f does not fail fast" }; 'Update and Verify fail fast on a revision that cannot start' }
    'CAP-036' = { Assert-That (@(Get-ProcessStep $systemProject | Where-Object Name -eq 'Verify environment').Count -eq 1 -and @(Get-ProcessStep $deployableProject | Where-Object Name -eq 'Verify deployable').Count -eq 1) 'a verify step is missing'; 'both projects end with a verify step' }
    'CAP-037' = {
        $project = Get-Project $deployableProject
        $versions = @((Invoke-Octopus "/api/$space/deployments?projects=$($project.Id)&environments=$(Get-EnvironmentId $first)&take=30").Items |
                Where-Object { (Invoke-Octopus "/api/tasks/$($_.TaskId)").State -eq 'Success' } |
                ForEach-Object { [version] (Invoke-Octopus "/api/$space/releases/$($_.ReleaseId)").Version })
        if (@($versions | Select-Object -Unique).Count -lt 2) { Skip-Check "fewer than two releases deployed in $first" }
        $rolledBack = $false; for ($i = 0; $i -lt $versions.Count - 1; $i++) { if ($versions[$i] -lt $versions[$i + 1]) { $rolledBack = $true } }
        Assert-That $rolledBack "no successful redeployment of an older release in $first"; "an older release was redeployed successfully in $first (test-rollback.ps1)"
    }
    'CAP-038' = {
        foreach ($slug in $systemProject, $deployableProject) { $s = @(Get-ProcessStep $slug)[0]; Assert-That ($s.Name -eq 'Sign-off' -and $s.Actions[0].ActionType -eq 'Octopus.Manual') "$slug does not start with Sign-off" }
        Assert-That ((Get-RepoFile $systemRepo 'octopus/projects.tf') -match 'octopusdeploy_project_deployment_freeze') 'no freeze support'; 'Sign-off first in both projects; freezes from system.json'
    }
    'CAP-039' = {
        if ($onAppService) {
            foreach ($e in $environments) { $s = Get-Site $e; Assert-That ($s.sku.tier -eq 'Free') "$e runs on the $($s.sku.tier) tier" }
            return 'every app runs on a Free plan'
        }
        foreach ($e in $environments) { $a = Get-App $e; Assert-That ($a.properties.template.scale.minReplicas -eq 0) "$e has min replicas $($a.properties.template.scale.minReplicas)" }; 'every app scales to zero'
    }
    'CAP-040' = { $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'Acceptance tests passed') "the last deployment to $first ran no passing acceptance tests"; "$($d.Version) passed the acceptance tests in $first" }
    'CAP-041' = { $d = Get-LastDeployment $deployableProject $first; Assert-That ($d.Log -match 'test data was reloaded') 'no ZDataLoader'; "test data reloaded after $($d.Version)" }
    'CAP-042' = { $d = Get-LastDeployment $deployableProject $first; $m = [regex]::Match($d.Log, 'effective parallelism ([\d.]+)'); Assert-That $m.Success 'no parallelism reported'; "effective parallelism $($m.Groups[1].Value)" }
    'CAP-043' = { $d = Get-LastDeployment $deployableProject $first; $a = @((Invoke-Octopus "/api/$space/artifacts?regarding=$($d.TaskId)").Items | Where-Object Filename -like '*.trx'); Assert-That ($a.Count -ge 1) 'no TRX artifact'; "$($a[0].Filename)" }
    'CAP-044' = {
        # Every current deployment that ran the availability probe logged no downtime.
        $measured = 0
        foreach ($project in $systemProject, $deployableProject) {
            foreach ($e in $environments) {
                $deployment = Find-LastDeployment $project $e
                if (-not $deployment) { continue }
                $lines = @($deployment.Log -split "`n" | Where-Object { $_ -match 'Availability of ' })
                if ($lines.Count -eq 0) { continue }
                $down = @($lines | Where-Object { $_ -match 'downtime period' })
                if ($down.Count -gt 0) { throw "$project $($deployment.Version) in ${e}: $($down[0])" }
                $measured++
            }
        }
        if ($measured -eq 0) { Skip-Check 'no current deployment has run the availability probe yet' }
        "$measured current deployments measured, no downtime"
    }
    'CAP-045' = {
        # Every environment's apps run where system.json places them: region and Container Apps environment.
        if ($onAppService) {
            foreach ($e in $environments) { $actual = (([string] (Get-Site $e).location) -replace '\s', '').ToLowerInvariant(); Assert-That ($actual -eq [string] $system.system.location) "$e runs in $actual; system.json places it in $($system.system.location)" }
            return "every environment's apps run where system.json places them"
        }
        foreach ($entry in $system.environments) {
            $e = [string] $entry.name
            $app = Get-App $e
            $hostName = if ($entry.ContainsKey('sharesAppEnvironmentWith')) { [string] $entry.sharesAppEnvironmentWith } else { $e }
            $hostEntry = @($system.environments | Where-Object { $_.name -eq $hostName })[0]
            $region = if ($hostEntry.ContainsKey('appLocation')) { [string] $hostEntry.appLocation } else { [string] $system.system.location }
            $actual = (([string] $app.location) -replace '\s', '').ToLowerInvariant()
            Assert-That ($actual -eq $region) "$e runs in $($app.location); system.json places it in $region"
            $managed = ([string] $app.properties.environmentId -split '/')[-1]
            Assert-That ($managed -like "cae-$slug-$hostName*") "$e runs in $managed; system.json places it in the Container Apps environment of $hostName"
        }
        "every environment's apps run where system.json places them"
    }
    'CAP-051' = {
        $ids = $system.azure.identities
        $expect = @(
            @{ id = $ids.plan.principalId; role = 'Reader'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.acrPush.principalId; role = 'AcrPush'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.deploy.nonprod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.nonprod },
            @{ id = $ids.deploy.prod.principalId; role = 'Owner'; group = $system.azure.resourceGroups.prod })
        foreach ($x in $expect) { $roles = @(Get-RoleName -Group $x.group -PrincipalId $x.id); Assert-That ($roles -contains $x.role -and $roles -notcontains 'Contributor') "$($x.id): $($roles -join ', ')" }
        'plan Reader, push AcrPush, deploy Owner of its group only'
    }
    'CAP-052' = { $prod = @(Get-ProdEnvironment); Assert-That ($prod.Count -ge 1) 'no prod-tier environment'; "$($prod -join ', ') in $($system.azure.resourceGroups.prod) with id-$($slug)-deploy-prod" }
    'CAP-053' = { $u = az account show --query user.type --output tsv; $me = Invoke-Octopus '/api/users/me'; Assert-That ($u -eq 'servicePrincipal' -and $me.IsService) "az $u, Octopus service $($me.IsService)"; "az as a service principal, Octopus as $($me.Username)" }
    'CAP-055' = { Assert-AppRepository; Assert-That ((Get-RequiredCheck $appRepo) -contains 'secret-scan' -and (Get-RepoFile $systemRepo '.github/workflows/env-checks.yml') -match 'gitleaks') 'secret scanning not enforced'; 'gitleaks in env-checks and the required check secret-scan' }
    'CAP-056' = { $r = Get-RecentRun 'Rotate SQL password' 35; Assert-That ($r.Count -ge 1) 'no successful rotation in 35 days'; "rotated $($r[0].CompletedTime)" }
    'CAP-060' = { $r = Get-RecentRun 'Restore test' 8; Assert-That ($r.Count -ge 1) 'no successful restore test in 8 days'; "restore test passed $($r[0].CompletedTime)" }
    'CAP-061' = { $prod = @(Get-ProdEnvironment)[0]; $d = Get-LastDeployment $deployableProject $prod; Assert-That ($d.Log -match 'Restore point before') "no restore point in the last $prod deployment"; "restore point recorded before $($d.Version) in $prod" }
    'CAP-070' = {
        # Telemetry is proven where it comes from: the environment's OpenTelemetry agent sends to Application Insights,
        # and requests recorded by that agent (SDK "otelc-...") arrived in the last 30 days.
        $on = @($system.environments | Where-Object { @($_.capabilities) -contains 'telemetry' } | ForEach-Object { [string] $_.name })
        if ($on.Count -eq 0) { Skip-Check 'no environment has capability telemetry yet' }
        if ($onAppService) { Skip-Check 'the OpenTelemetry agent is a Container Apps feature; the first app runs on App Service' }
        foreach ($e in $on) {
            $managedEnvironment = [string] (Get-App $e).properties.environmentId
            $otel = (az rest --method get --url "https://management.azure.com${managedEnvironment}?api-version=2024-10-02-preview" --output json | ConvertFrom-Json -AsHashtable).properties.openTelemetryConfiguration
            Assert-That ($otel -and @($otel.tracesConfiguration.destinations) -contains 'appInsights') "no OpenTelemetry agent to Application Insights in $e"
            $component = "/subscriptions/$($system.azure.subscriptionId)/resourceGroups/$(Get-Group $e)/providers/Microsoft.Insights/components/appi-$slug-$e"
            $body = @{ query = "requests | where sdkVersion startswith 'otelc' | summarize count()"; timespan = 'P30D' } | ConvertTo-Json -Compress
            $count = [int] (az rest --method post --url "https://management.azure.com$component/query?api-version=2018-04-20" --body $body --query 'tables[0].rows[0][0]' --output tsv)
            Assert-That ($count -gt 0) "no OpenTelemetry requests in appi-$slug-$e in 30 days"
        }
        "OpenTelemetry agent to Application Insights in $($on -join ', '), requests arriving"
    }
    'CAP-071' = { $noisy = @(Get-NoisyDeployment); Assert-That ($noisy.Count -eq 0) "warnings in: $($noisy -join '; ')"; 'the logs of every current deployment are clean' }
    'CAP-080' = { $files = @(gh api "repos/$systemRepo/contents/docs/architecture" --jq '.[].name'); $missing = @($files | Where-Object { $_ -like '*.puml' -and $files -notcontains ($_ -replace '\.puml$', '.png') }); Assert-That ($missing.Count -eq 0 -and $files.Count -gt 0) "not rendered: $missing"; "$(@($files | Where-Object { $_ -like '*.png' }).Count) diagrams rendered" }
    'CAP-081' = {
        $build = Get-RepoFile $systemRepo '.github/workflows/system.yml'; $nightly = Get-RepoFile $systemRepo '.github/workflows/capabilities.yml'
        Assert-That ($build -match 'uses: \./\.github/workflows/capabilities\.yml' -and $nightly -match 'schedule:') 'the checks do not run with every system build and nightly'
        "$($checks.Count) checks, after every system build and nightly"
    }
}


if ($ListChecks) {
    $checks.Keys
    return
}
# Checks compare Git, Octopus and Azure; in the middle of a deployment or runbook run they differ by design, so the
# run waits until the space is quiet.
$deadline = [datetimeoffset]::UtcNow.AddMinutes($WaitMinutes)
while (@((Invoke-Octopus "/api/$space/tasks?states=Executing,Queued,Cancelling&take=10").Items).Count -gt 0) {
    if ([datetimeoffset]::UtcNow -gt $deadline) {
        if ($WaitOnly) { Write-Host "Octopus is still busy after $WaitMinutes minutes; the checks wait on."; exit 0 }
        Write-Fail "the space did not become quiet in $WaitMinutes minutes"
        exit 1
    }
    Write-Host 'Waiting for running Octopus tasks to finish.'
    Start-Sleep -Seconds 60
}
if ($WaitOnly) {
    Write-Host 'Octopus is quiet.'
    exit 0
}
# @(...) around the whole if: a single -Only ID would otherwise become a string, which has no Count in strict mode.
$ids = @(if ($Only) { $Only } else { $checks.Keys })
$failed = 0
$skipped = 0
foreach ($id in $ids) {
    if (-not $checks.Contains($id)) { Write-Fail "${id}: no check"; $failed++; continue }
    try { Write-Pass "${id}: $(& $checks[$id])" }
    catch [CheckSkipped] { Write-Host "SKIP ${id}: $($_.Exception.Message)"; $skipped++ }
    catch { Write-Fail "${id}: $($_.Exception.Message)"; $failed++ }
}
$skippedNote = if ($skipped -gt 0) { " ($skipped skipped: their preconditions do not exist yet)" } else { '' }
if ($failed -gt 0) {
    Write-Host "$failed of $($ids.Count) capabilities failed$skippedNote."
    exit 1
}
Write-Host "All $($ids.Count - $skipped) checked capabilities are proven$skippedNote."
