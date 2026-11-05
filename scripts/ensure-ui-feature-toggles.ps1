#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates BuildingManagement and VendorManagement on Octopus project cmdemo1-ui, or flips one environment.

.DESCRIPTION
    The toggles live on project cmdemo1-ui (Projects-981) in space cmdemo1-demo (Spaces-355). The API is
    /featuretoggles. The project UI may label the same screen Feature Flags. Provider 1.20.0 has no feature-toggle
    resource, so octopus-apply does not create them and does not put a flipped environment back. This script is the create.

    Ensure (the default) creates a missing toggle with tdd on, uat off, prod off, and the flag default off. A
    toggle that already exists is left as it was, including a later flip, except an environment that is missing
    from it is added at that default. -ResetDefaults puts the three environments and the flag default back.
    -Action Set flips one named toggle in one environment and leaves the others. -Action Show only reads.
    -WhatIf with no Octopus credential prints the create and does not call Octopus.

    The credential is OCTOPUS_API_KEY, or OCTOPUS_ACCESS_TOKEN from OctopusDeploy/login. It is read from the
    environment only, never from an argument. Nothing here prints it. The client identifier
    (Octopus.FeatureToggles.ClientIdentifier) is not read and not written here: scripts/update-deployable.ps1
    writes it onto the ui container app. The app evaluates the toggle only after cmdemo1-workorders issue 1466.

    Runbook: docs/ops/ui-feature-toggles.md.

.PARAMETER Action
    Ensure (create missing, do not reset a flip), Set (one environment of one toggle), or Show (read).

.PARAMETER Name
    For Set: BuildingManagement or VendorManagement.

.PARAMETER Environment
    For Set: tdd, uat, or prod.

.PARAMETER Enabled
    For Set: $true or $false.

.PARAMETER ResetDefaults
    With Ensure: tdd on, uat off, prod off, flag default off. Phases already stored on an environment stay.

.PARAMETER LoadOnly
    Defines the functions and stops, for scripts/test-ui-feature-toggles.ps1.

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -WhatIf

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name VendorManagement -Environment uat -Enabled $true

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Ensure', 'Set', 'Show')]
    [string] $Action = 'Ensure',

    [string] $Name,

    [string] $Environment,

    [Nullable[bool]] $Enabled,

    [switch] $ResetDefaults,

    [switch] $LoadOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# The issue's target. system.json is checked against these before any write.
$script:UiFeatureToggleSpaceId = 'Spaces-355'
$script:UiFeatureToggleProjectId = 'Projects-981'
$script:UiFeatureToggleProjectSlug = 'cmdemo1-ui'

function Get-UiFeatureToggleDefaults {
    [ordered]@{
        tdd  = $true
        uat  = $false
        prod = $false
    }
}

function Get-UiFeatureToggleSpecs {
    @(
        @{
            Name        = 'BuildingManagement'
            Slug        = 'BuildingManagement'
            Description = 'Buildings and Rooms admin (/admin/buildings) and the building-room summary reads. On: the nav link, the page, and those reads. Off: hidden, and those reads are rejected. Work order building text and the Open by Building report stay.'
        }
        @{
            Name        = 'VendorManagement'
            Slug        = 'VendorManagement'
            Description = 'Vendor directory on Teams and Vendors, vendor commands and queries, and the MCP vendor tools. On: that section and those calls. Off: hidden, and those calls are rejected. Waiting on a vendor, and the teams portion of the page, stay.'
        }
    )
}

function ConvertTo-ObjectList($Value) {
    if ($null -eq $Value) { return @() }
    return @($Value)
}

function Get-NoteProperty($Object, [string] $PropertyName) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($PropertyName)) { return $Object[$PropertyName] }
        return $null
    }
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-PhaseList($Phases) {
    # return ,$list keeps an empty list and a one-item list intact. A bare return unrolls them.
    $list = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Phases) {
        $base = $Phases
        if ($Phases -is [psobject] -and $null -ne $Phases.PSObject.BaseObject -and $Phases.PSObject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) {
            $base = $Phases.PSObject.BaseObject
        }
        if ($base -is [string] -or -not ($base -is [System.Collections.IEnumerable])) {
            $list.Add($base)
        } else {
            foreach ($phase in $base) {
                if ($null -ne $phase) { $list.Add($phase) }
            }
        }
    }
    return ,$list
}

function ConvertTo-Boolean([object] $Value) {
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        if ($Value -eq 'true') { return $true }
        if ($Value -eq 'false') { return $false }
    }
    return [bool]$Value
}

function ConvertTo-ClrValue($Value) {
    if ($null -eq $Value) { return $null }
    # PowerShell wraps values. System.Text.Json then walks the wrapper (Members, SyncRoot) and cycles.
    # return ,$base does not unroll a list or a hashtable. Write-Output -NoEnumerate still unrolls a hashtable.
    $base = $Value
    if ($Value -is [psobject]) {
        $candidate = $Value.PSObject.BaseObject
        if ($null -ne $candidate -and $candidate -isnot [System.Management.Automation.PSCustomObject]) {
            $base = $candidate
        }
    }
    return ,$base
}

function ConvertTo-JsonValue($Value) {
    if ($null -eq $Value) { return $null }
    $base = ConvertTo-ClrValue $Value
    if ($null -eq $base) { return $null }
    if ($base -is [string] -or $base -is [ValueType]) { return $base }
    if ($base -is [System.Collections.IDictionary]) {
        $dict = [System.Collections.Generic.Dictionary[string, object]]::new()
        foreach ($key in @($base.Keys)) {
            $dict[[string]$key] = ConvertTo-ClrValue (ConvertTo-JsonValue $base[$key])
        }
        return ,$dict
    }
    if ($base -is [System.Collections.IEnumerable]) {
        $list = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $base) { $list.Add((ConvertTo-ClrValue (ConvertTo-JsonValue $item))) }
        return ,$list
    }
    if ($Value -is [psobject]) {
        $dict = [System.Collections.Generic.Dictionary[string, object]]::new()
        foreach ($property in $Value.PSObject.Properties) {
            $dict[$property.Name] = ConvertTo-ClrValue (ConvertTo-JsonValue $property.Value)
        }
        return ,$dict
    }
    return $base
}

function ConvertTo-OctopusJson($Value) {
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $raw = ConvertTo-ClrValue (ConvertTo-JsonValue $Value)
    return [System.Text.Json.JsonSerializer]::Serialize($raw, $options)
}

function Copy-EnvironmentConfig($Existing, [string] $Id, [bool] $IsEnabled) {
    $copy = [ordered]@{}
    if ($null -ne $Existing) {
        $names = if ($Existing -is [System.Collections.IDictionary]) {
            @($Existing.Keys)
        } else {
            @($Existing.PSObject.Properties.Name)
        }
        foreach ($propertyName in $names) {
            if ($propertyName -in @('IsEnabled', 'Links')) { continue }
            $propertyValue = if ($Existing -is [System.Collections.IDictionary]) { $Existing[$propertyName] } else { $Existing.$propertyName }
            if ($propertyName -eq 'Phases') {
                $copy[$propertyName] = ConvertTo-PhaseList $propertyValue
            } else {
                $copy[$propertyName] = $propertyValue
            }
        }
    }
    if (-not $copy.Contains('Phases') -or $null -eq $copy['Phases']) { $copy['Phases'] = ConvertTo-PhaseList $null }
    $copy['DeploymentEnvironmentId'] = $Id
    $copy['IsEnabled'] = $IsEnabled
    return $copy
}

function Get-UiFeatureTogglePlan {
    param(
        [Parameter(Mandatory)] [hashtable] $Spec,
        [AllowNull()] $Current,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $EnvironmentIds,
        [Parameter(Mandatory)] [ValidateSet('Ensure', 'ResetDefaults', 'Set')] [string] $Mode,
        [string] $EnvironmentName,
        [Nullable[bool]] $EnvironmentEnabled
    )

    if ($Mode -eq 'Set') {
        if (-not $EnvironmentName) { throw 'Set needs an environment name.' }
        if ($null -eq $EnvironmentEnabled) { throw 'Set needs an enabled value.' }
        if (-not $EnvironmentIds.Contains($EnvironmentName)) { throw "No Octopus environment named '$EnvironmentName'." }
    }

    $defaults = Get-UiFeatureToggleDefaults
    $force = $Mode -eq 'ResetDefaults' -or $Mode -eq 'Set'
    $names = [System.Collections.Generic.List[string]]::new()
    if ($Mode -eq 'Set') {
        $names.Add($EnvironmentName)
    } else {
        foreach ($defaultName in $defaults.Keys) { $names.Add([string]$defaultName) }
    }

    $byId = @{}
    $orderedIds = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Current) {
        foreach ($configured in (ConvertTo-ObjectList (Get-NoteProperty $Current 'Environments'))) {
            if ($null -eq $configured) { continue }
            $configuredId = [string](Get-NoteProperty $configured 'DeploymentEnvironmentId')
            $byId[$configuredId] = $configured
            $orderedIds.Add($configuredId)
        }
    }

    $changed = $false
    foreach ($environmentName in $names) {
        if (-not $EnvironmentIds.Contains($environmentName)) { throw "No Octopus environment named '$environmentName'." }
        $id = [string]$EnvironmentIds[$environmentName]
        $desired = if ($Mode -eq 'Set') { [bool]$EnvironmentEnabled } else { [bool]$defaults[$environmentName] }
        if ($byId.ContainsKey($id)) {
            if ($force -and (ConvertTo-Boolean $byId[$id].IsEnabled) -ne $desired) {
                $byId[$id] = Copy-EnvironmentConfig $byId[$id] $id $desired
                $changed = $true
            }
        } else {
            $byId[$id] = Copy-EnvironmentConfig $null $id $desired
            $orderedIds.Add($id)
            $changed = $true
        }
    }

    $description = [string]$Spec.Description
    $changeDefault = $false
    $defaultIsEnabled = $false
    if ($null -eq $Current) {
        $action = 'create'
        $changeDefault = $true
    } else {
        $currentDescription = [string](Get-NoteProperty $Current 'Description')
        if (-not [string]::IsNullOrWhiteSpace($currentDescription)) {
            $description = $currentDescription
        } elseif ($description -ne $currentDescription) {
            $changed = $true
        }
        $currentDefaultValue = Get-NoteProperty $Current 'DefaultIsEnabled'
        $currentDefault = if ($null -eq $currentDefaultValue) { $false } else { ConvertTo-Boolean $currentDefaultValue }
        $defaultIsEnabled = $currentDefault
        if ($Mode -eq 'ResetDefaults' -and $currentDefault) {
            $changeDefault = $true
            $defaultIsEnabled = $false
            $changed = $true
        }
        $action = if ($changed) { 'update' } else { 'none' }
    }

    $environments = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $orderedIds) {
        $configured = $byId[$id]
        $environments.Add((Copy-EnvironmentConfig $configured $id (ConvertTo-Boolean (Get-NoteProperty $configured 'IsEnabled'))))
    }

    [pscustomobject]@{
        Action           = $action
        Name             = [string]$Spec.Name
        RequestedSlug    = [string]$Spec.Slug
        Description      = $description
        DefaultIsEnabled = [bool]$defaultIsEnabled
        ChangeDefault    = [bool]$changeDefault
        Environments     = $environments
    }
}

function Format-UiFeatureTogglePlan($Plan, $IdToName) {
    $parts = foreach ($configured in $Plan.Environments) {
        $id = [string]$configured.DeploymentEnvironmentId
        $label = if ($IdToName.Contains($id)) { [string]$IdToName[$id] } else { $id }
        $state = if (ConvertTo-Boolean $configured.IsEnabled) { 'on' } else { 'off' }
        "$label=$state"
    }
    $defaultState = if ($Plan.DefaultIsEnabled) { 'on' } else { 'off' }
    "$($Plan.Name): $($Plan.Action) default=$defaultState $($parts -join ' ')"
}

function Get-OfflineEnsurePlans {
    $ids = @{}
    foreach ($environmentName in (Get-UiFeatureToggleDefaults).Keys) { $ids[$environmentName] = $environmentName }
    foreach ($spec in Get-UiFeatureToggleSpecs) {
        Get-UiFeatureTogglePlan -Spec $spec -Current $null -EnvironmentIds $ids -Mode Ensure
    }
}

function Select-UiFeatureToggleSpecs([string] $ActionName, [string] $ToggleName) {
    $specs = @(Get-UiFeatureToggleSpecs)
    if ($ActionName -ne 'Set') { return $specs }
    $chosen = @($specs | Where-Object { $_.Name -eq $ToggleName -or $_.Slug -eq $ToggleName })
    if ($chosen.Count -ne 1) {
        $known = ($specs | ForEach-Object { $_.Name }) -join ', '
        throw "No toggle '$ToggleName'. Expected one of: $known."
    }
    return $chosen
}

function Find-UiFeatureToggle($Items, [string] $ToggleName, [string] $Slug) {
    $matches = @(ConvertTo-ObjectList $Items | Where-Object { $null -ne $_ -and ($_.Name -eq $ToggleName -or $_.Slug -eq $Slug) })
    if ($matches.Count -gt 1) { throw "More than one feature toggle matches $ToggleName ($Slug)." }
    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

function Get-UiFeatureToggleCollectionUri([string] $ProjectBase) {
    return "$ProjectBase/featuretoggles"
}

function Get-UiFeatureToggleItemUri([string] $ProjectBase, [string] $ToggleId) {
    return "$ProjectBase/featuretoggles/$ToggleId"
}

function Get-UiFeatureToggleListUri([string] $ProjectBase, [int] $Skip, [int] $Take) {
    return "$(Get-UiFeatureToggleCollectionUri $ProjectBase)?skip=$Skip&take=$Take"
}

function Assert-UiFeatureToggleSystem($System) {
    if ([string]$System.octopus.spaceId -ne $script:UiFeatureToggleSpaceId) {
        throw "This script is for space $($script:UiFeatureToggleSpaceId) (cmdemo1-demo). system.json says '$($System.octopus.spaceId)'."
    }
    if ("$($System.system.slug)-ui" -ne $script:UiFeatureToggleProjectSlug) {
        throw "This script is for project $($script:UiFeatureToggleProjectSlug). system.json slug '$($System.system.slug)' does not name it."
    }
    $names = @($System.environments | ForEach-Object { [string]$_.name })
    foreach ($environmentName in (Get-UiFeatureToggleDefaults).Keys) {
        if ($environmentName -notin $names) { throw "system.json has no environment '$environmentName'." }
    }
    $ui = @($System.deployables | Where-Object { $_.name -eq 'ui' -and -not [bool](Get-NoteProperty $_ 'retired') })
    if ($ui.Count -ne 1) { throw "system.json has no active deployable 'ui'." }
}

function Test-OctopusCredential {
    return [bool]($env:OCTOPUS_API_KEY -or $env:OCTOPUS_ACCESS_TOKEN)
}

function Get-OctopusHeaders {
    if ($env:OCTOPUS_API_KEY) { return @{ 'X-Octopus-ApiKey' = $env:OCTOPUS_API_KEY } }
    if ($env:OCTOPUS_ACCESS_TOKEN) { return @{ Authorization = "Bearer $env:OCTOPUS_ACCESS_TOKEN" } }
    throw 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY. The value stays in the environment; do not pass it as an argument.'
}

function Protect-OctopusDetail([string] $Detail) {
    if ([string]::IsNullOrEmpty($Detail)) { return '' }
    $text = $Detail -replace 'API-[A-Za-z0-9]+', 'API-[redacted]'
    $text = $text -replace 'Bearer\s+\S+', 'Bearer [redacted]'
    if ($text.Length -gt 500) { return $text.Substring(0, 500) }
    return $text
}

function Get-OctopusError($ErrorRecord) {
    $status = 0
    if ($ErrorRecord.Exception.Response) {
        $status = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    $detail = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $detail = [string]$ErrorRecord.ErrorDetails.Message
    } elseif ($ErrorRecord.Exception.Message) {
        $detail = [string]$ErrorRecord.Exception.Message
    }
    [pscustomobject]@{ Status = $status; Detail = (Protect-OctopusDetail $detail) }
}

function Invoke-Octopus {
    param(
        [string] $Method,
        [string] $Uri,
        $Body
    )
    $headers = Get-OctopusHeaders
    $call = @{ Uri = $Uri; Headers = $headers; Method = $Method }
    # $Body stays untyped. A typed [string] plus `return Invoke-RestMethod` wraps a JSON array in an extra
    # Object[], so the environment list is one value whose Name is "tdd uat prod".
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $call.Body = $Body
        $call.ContentType = 'application/json'
    }
    $response = Invoke-RestMethod @call
    return $response
}

function Get-UiFeatureToggleList([string] $ProjectBase) {
    $skip = 0
    $all = [System.Collections.Generic.List[object]]::new()
    while ($true) {
        $page = Invoke-Octopus -Method Get -Uri (Get-UiFeatureToggleListUri $ProjectBase $skip 100)
        if ($page -is [System.Array]) {
            foreach ($item in $page) { if ($null -ne $item) { $all.Add($item) } }
            break
        }
        $itemsValue = $null
        if ($page.PSObject.Properties['Items']) { $itemsValue = $page.Items }
        $items = @(ConvertTo-ObjectList $itemsValue)
        foreach ($item in $items) { if ($null -ne $item) { $all.Add($item) } }
        $skip += @($items | Where-Object { $null -ne $_ }).Count
        $total = 0
        if ($page.PSObject.Properties['TotalResults'] -and $null -ne $page.TotalResults) {
            $total = [int]$page.TotalResults
        }
        if ($skip -ge $total -or @($items | Where-Object { $null -ne $_ }).Count -eq 0) { break }
    }
    return ,$all
}

function Get-ProjectFeatureToggles([string] $Base) {
    try {
        return Get-UiFeatureToggleList -ProjectBase $Base
    } catch {
        $lastError = Get-OctopusError $_
        if ($lastError.Status -eq 404) {
            throw "Octopus answered 404 for feature toggles on $($script:UiFeatureToggleProjectSlug). Create BuildingManagement and VendorManagement in the project UI (docs/ops/ui-feature-toggles.md). $($lastError.Detail)"
        }
        if ($lastError.Status -eq 403) {
            throw "Octopus refused to read feature toggles (403). $($lastError.Detail)"
        }
        throw "Octopus feature toggles ($($lastError.Status)): $($lastError.Detail)"
    }
}

function Get-UiFeatureToggleResource([string] $ProjectBase, $Summary) {
    $id = [string](Get-NoteProperty $Summary 'Id')
    if (-not $id) { return $Summary }
    return Invoke-Octopus -Method Get -Uri (Get-UiFeatureToggleItemUri $ProjectBase $id)
}

function ConvertTo-FeatureToggleEnvironmentWire($Configured) {
    $wire = [ordered]@{
        DeploymentEnvironmentId = [string](Get-NoteProperty $Configured 'DeploymentEnvironmentId')
        IsEnabled               = ConvertTo-Boolean (Get-NoteProperty $Configured 'IsEnabled')
    }
    $names = if ($Configured -is [System.Collections.IDictionary]) {
        @($Configured.Keys)
    } else {
        @($Configured.PSObject.Properties.Name)
    }
    foreach ($propertyName in $names) {
        if ($propertyName -in @('DeploymentEnvironmentId', 'IsEnabled', 'Links', 'Phases')) { continue }
        $propertyValue = Get-NoteProperty $Configured $propertyName
        if ($null -ne $propertyValue) { $wire[$propertyName] = $propertyValue }
    }
    return $wire
}

function New-FeatureToggleEnvironmentWires($Environments) {
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($configured in @(ConvertTo-ObjectList $Environments)) {
        if ($null -eq $configured) { continue }
        $list.Add((ConvertTo-FeatureToggleEnvironmentWire $configured))
    }
    return ,$list
}

function New-FeatureToggleBody($ProjectId, $SpaceId, $Spec, $Plan, $Existing) {
    # CreateFeatureToggleCommand is Name, ProjectId, SpaceId, and Environments of DeploymentEnvironmentId
    # plus IsEnabled. Slug and DefaultIsEnabled belong on the resource and on the modify.
    $environments = New-FeatureToggleEnvironmentWires $Plan.Environments
    if ($null -eq $Existing) {
        return [ordered]@{
            Name         = [string]$Spec.Name
            ProjectId    = [string]$ProjectId
            SpaceId      = [string]$SpaceId
            Environments = $environments
        }
    }
    $body = [ordered]@{
        Id               = [string](Get-NoteProperty $Existing 'Id')
        Name             = [string](Get-NoteProperty $Existing 'Name')
        ProjectId        = [string]$ProjectId
        SpaceId          = [string]$SpaceId
        DefaultIsEnabled = [bool]$Plan.DefaultIsEnabled
        Environments     = $environments
    }
    $slug = Get-NoteProperty $Existing 'Slug'
    if ($slug) { $body['Slug'] = [string]$slug }
    $description = [string]$Plan.Description
    if (-not [string]::IsNullOrWhiteSpace($description)) { $body['Description'] = $description }
    return $body
}

function Test-DefaultIsOff($Flag) {
    $value = Get-NoteProperty $Flag 'DefaultIsEnabled'
    return $null -ne $value -and -not (ConvertTo-Boolean $value)
}

if ($LoadOnly) { return }

if ($Action -eq 'Ensure') {
    if ($PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Environment') -or $PSBoundParameters.ContainsKey('Enabled')) {
        throw 'Ensure takes no -Name, -Environment, or -Enabled. Use -Action Set to flip one environment, or -ResetDefaults to restore tdd on and uat and prod off.'
    }
}
if ($Action -eq 'Show') {
    if ($ResetDefaults -or $PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Environment') -or $PSBoundParameters.ContainsKey('Enabled')) {
        throw 'Show only reads. It takes no -Name, -Environment, -Enabled, or -ResetDefaults.'
    }
}
if ($Action -eq 'Set') {
    if ($ResetDefaults) { throw 'Set and -ResetDefaults exclude each other.' }
    if (-not $Name -or -not $Environment -or $null -eq $Enabled) { throw 'Set needs -Name, -Environment, and -Enabled.' }
}

$systemPath = Join-Path $PSScriptRoot '..' 'system.json'
$system = Get-Content -LiteralPath $systemPath -Raw | ConvertFrom-Json
Assert-UiFeatureToggleSystem $system

if ($WhatIfPreference -and $Action -eq 'Ensure' -and -not (Test-OctopusCredential)) {
    foreach ($plan in Get-OfflineEnsurePlans) {
        $labels = @{}
        foreach ($environmentName in (Get-UiFeatureToggleDefaults).Keys) { $labels[$environmentName] = $environmentName }
        Write-Host (Format-UiFeatureTogglePlan -Plan $plan -IdToName $labels)
    }
    Write-Host 'WhatIf only: no Octopus credential, so Octopus was not called. This is the create the script would send, not a diff against the space.'
    return
}
if (-not (Test-OctopusCredential)) {
    throw 'no Octopus credential: OCTOPUS_ACCESS_TOKEN (OctopusDeploy/login) or OCTOPUS_API_KEY. The value stays in the environment; do not pass it as an argument.'
}

$url = [string]$system.octopus.url
$space = [string]$system.octopus.spaceId
$project = Invoke-Octopus -Method Get -Uri "$url/api/$space/projects/$($script:UiFeatureToggleProjectSlug)"
if ([string]$project.Id -ne $script:UiFeatureToggleProjectId) {
    throw "Project $($script:UiFeatureToggleProjectSlug) is $($project.Id), not $($script:UiFeatureToggleProjectId). Nothing was written."
}

$environmentIds = @{}
$idToName = @{}
foreach ($octopusEnvironment in @(Invoke-Octopus -Method Get -Uri "$url/api/$space/environments/all")) {
    $environmentName = [string]$octopusEnvironment.Name
    if ($environmentName -in @(Get-UiFeatureToggleDefaults).Keys) {
        $environmentIds[$environmentName] = [string]$octopusEnvironment.Id
        $idToName[[string]$octopusEnvironment.Id] = $environmentName
    }
}
foreach ($environmentName in (Get-UiFeatureToggleDefaults).Keys) {
    if (-not $environmentIds.Contains($environmentName)) { throw "Octopus space $space has no environment '$environmentName'." }
}

$base = "$url/api/$space/projects/$($project.Id)"
$toggles = Get-ProjectFeatureToggles $base
$mode = if ($Action -eq 'Set') { 'Set' } elseif ($ResetDefaults) { 'ResetDefaults' } else { 'Ensure' }

foreach ($spec in @(Select-UiFeatureToggleSpecs $Action $Name)) {
    $current = Find-UiFeatureToggle $toggles $spec.Name $spec.Slug
    if ($null -ne $current) { $current = Get-UiFeatureToggleResource $base $current }
    if ($Action -eq 'Show') {
        if ($null -eq $current) {
            Write-Host "$($spec.Name): missing"
            continue
        }
        $slug = [string](Get-NoteProperty $current 'Slug')
        $slugNote = if ($slug -and $slug -cne $spec.Slug) { " (requested slug $($spec.Slug))" } else { '' }
        $defaultState = if (Test-DefaultIsOff $current) { 'off' } else { 'on' }
        Write-Host "$($spec.Name): slug=$slug$slugNote default=$defaultState id=$($current.Id)"
        $seen = @{}
        foreach ($configured in (ConvertTo-ObjectList (Get-NoteProperty $current 'Environments'))) {
            if ($null -eq $configured) { continue }
            $configuredId = [string](Get-NoteProperty $configured 'DeploymentEnvironmentId')
            $label = if ($idToName.Contains($configuredId)) { $idToName[$configuredId] } else { $configuredId }
            $seen[$label] = $true
            $state = if (ConvertTo-Boolean (Get-NoteProperty $configured 'IsEnabled')) { 'on' } else { 'off' }
            Write-Host "  $label $state"
        }
        foreach ($environmentName in (Get-UiFeatureToggleDefaults).Keys) {
            if (-not $seen.Contains($environmentName)) { Write-Host "  $environmentName not configured (evaluates the flag default)" }
        }
        continue
    }

    if ($Action -eq 'Set' -and $null -eq $current) {
        throw "Toggle '$($spec.Name)' is not on $($script:UiFeatureToggleProjectSlug). Run Ensure first (docs/ops/ui-feature-toggles.md)."
    }

    $plan = Get-UiFeatureTogglePlan -Spec $spec -Current $current -EnvironmentIds $environmentIds -Mode $mode -EnvironmentName $Environment -EnvironmentEnabled $Enabled
    $line = Format-UiFeatureTogglePlan -Plan $plan -IdToName $idToName
    if ($plan.Action -eq 'none') {
        Write-Host $line
        if ($null -ne $current -and (Get-NoteProperty $current 'Slug') -and [string]$current.Slug -cne $spec.Slug) {
            Write-Host "NOTE: $($spec.Name) evaluation key (slug) is '$($current.Slug)', not '$($spec.Slug)'."
        }
        continue
    }
    if (-not $PSCmdlet.ShouldProcess($spec.Name, $plan.Action)) {
        Write-Host $line
        continue
    }

    if ($plan.Action -eq 'create') {
        $body = New-FeatureToggleBody $project.Id $space $spec $plan $null
        $json = ConvertTo-OctopusJson $body
        try {
            $created = Invoke-Octopus -Method Post -Uri (Get-UiFeatureToggleCollectionUri $base) -Body $json
        } catch {
            $createError = Get-OctopusError $_
            if ($createError.Status -eq 404) {
                throw "Octopus answered 404 creating a feature toggle. Create the toggles in the project UI (docs/ops/ui-feature-toggles.md). $($createError.Detail)"
            }
            if ($createError.Status -eq 403) {
                throw "Octopus refused to create feature toggles (403). The credential can read the project and cannot edit its feature toggles. $($createError.Detail)"
            }
            throw "Octopus feature toggles ($($createError.Status)): $($createError.Detail)"
        }
        if ($null -eq $created -or -not (Get-NoteProperty $created 'Id')) {
            $toggles = Get-ProjectFeatureToggles $base
            $created = Find-UiFeatureToggle $toggles $spec.Name $spec.Slug
            if ($null -ne $created) { $created = Get-UiFeatureToggleResource $base $created }
        }
        if ($null -eq $created) { throw "Created $($spec.Name) but could not read it back." }
        $current = $created
        if (-not (Test-DefaultIsOff $created)) {
            $defaultPlan = [pscustomobject]@{
                Description      = if ([string]::IsNullOrWhiteSpace([string](Get-NoteProperty $created 'Description'))) { [string]$plan.Description } else { [string](Get-NoteProperty $created 'Description') }
                DefaultIsEnabled = $false
                Environments     = if ($null -ne (Get-NoteProperty $created 'Environments')) { Get-NoteProperty $created 'Environments' } else { $plan.Environments }
            }
            $current = Invoke-Octopus -Method Put -Uri (Get-UiFeatureToggleItemUri $base $created.Id) -Body (ConvertTo-OctopusJson (New-FeatureToggleBody $project.Id $space $spec $defaultPlan $created))
        }
    } else {
        $current = Invoke-Octopus -Method Put -Uri (Get-UiFeatureToggleItemUri $base $current.Id) -Body (ConvertTo-OctopusJson (New-FeatureToggleBody $project.Id $space $spec $plan $current))
    }

    Write-Host $line
    if ([string](Get-NoteProperty $current 'Slug') -and [string]$current.Slug -cne $spec.Slug) {
        Write-Host "NOTE: $($spec.Name) evaluation key (slug) is '$($current.Slug)', not '$($spec.Slug)'. The app evaluates the slug."
    }
}

if ($Action -eq 'Show') { return }
