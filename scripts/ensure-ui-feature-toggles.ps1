#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates BuildingManagement, VendorManagement, and ShowPriorityBadges on Octopus project cmdemo1-ui, or flips one environment.

.DESCRIPTION
    The toggles live on project cmdemo1-ui (Projects-981) in space cmdemo1-demo (Spaces-355). The API is
    /featuretoggles. The project UI may label the same screen Feature Flags. Provider 1.20.0 has no feature-toggle
    resource, so octopus-apply does not create them and does not put a flipped environment back. This script is the create.

    This script speaks the rules targeting model only (see https://octopus.com/docs/feature-flags/upgrading-to-rules
    and https://octopus.com/docs/api/feature-flags). It does not run the project upgrade. A project that still
    stores legacy targeting (RolloutPercentage and related fields) is refused on write: upgrade in Octopus first.
    Ensure never sends RolloutPercentage or other legacy targeting fields to an upgraded project.

    The published rules create/modify body still uses DeploymentEnvironmentId, IsEnabled, and Phases per
    environment, and DefaultIsEnabled on modify. The planner keeps those wire names out of Copy-EnvironmentConfig,
    Get-UiFeatureTogglePlan, and Format-UiFeatureTogglePlan (Enabled / DefaultEnabled / Phases instead) and maps
    at New-FeatureToggleBody. Phases for the repo defaults are an empty list (environment on, no rules = everyone;
    environment off = switch off). Nested rule/condition shapes are not exercised here and are not verified beyond
    that empty-Phases case.

    Ensure (the default) creates a missing toggle at that flag's environment defaults (BuildingManagement and
    VendorManagement: tdd on, uat off, prod off; ShowPriorityBadges: tdd, uat, and prod on) and the flag default
    off. A toggle that already exists is left as it was, including a later flip, except an environment that is
    missing from it is added at that flag's default. -ResetDefaults puts each flag's three environments and the
    flag default back to that flag's defaults, so it does not turn BuildingManagement or VendorManagement off in
    uat or prod when those rows already match their defaults, and it keeps ShowPriorityBadges on in all three.
    -Action Set flips one named toggle in one environment and leaves the others. -Action Show only reads.
    -WhatIf with no Octopus credential prints the create and does not call Octopus.

    The credential is OCTOPUS_API_KEY, or OCTOPUS_ACCESS_TOKEN from OctopusDeploy/login. It is read from the
    environment only, never from an argument. Nothing here prints it. The client identifier
    (Octopus.FeatureFlags.ClientIdentifier, with deprecated alias Octopus.FeatureToggles.ClientIdentifier) is not
    read and not written here: scripts/update-deployable.ps1 writes it onto the ui container app.

    Runbook: docs/ops/ui-feature-toggles.md.

.PARAMETER Action
    Ensure (create missing, do not reset a flip), Set (one environment of one toggle), or Show (read).

.PARAMETER Name
    For Set: BuildingManagement, VendorManagement, or ShowPriorityBadges.

.PARAMETER Environment
    For Set: tdd, uat, or prod.

.PARAMETER Enabled
    For Set: true or false. Also on, off, 1, 0, and the text $true or $false. A bash command that
    passes those characters literally still selects a value. $true and $false from PowerShell still work.

.PARAMETER Enable
    For Set: turn that environment on. Same as -Enabled:true. Do not combine with -Enabled or -Disable.

.PARAMETER Disable
    For Set: turn that environment off. Same as -Enabled:false. Do not combine with -Enabled or -Enable.

.PARAMETER ResetDefaults
    With Ensure: each flag's environment defaults and flag default off. Phases already stored on an environment stay.

.PARAMETER LoadOnly
    Defines the functions and stops, for scripts/test-ui-feature-toggles.ps1.

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -WhatIf

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name BuildingManagement -Environment tdd -Enabled:false

    The colon form works in bash and in pwsh. -Action Show reads the row back.

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name VendorManagement -Environment uat -Disable

.EXAMPLE
    pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Ensure', 'Set', 'Show')]
    [string] $Action = 'Ensure',

    [string] $Name,

    [string] $Environment,

    [object] $Enabled,

    [switch] $Enable,

    [switch] $Disable,

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
# Captured while this file is the executing script. A function called from the test file still finds system.json.
$script:UiFeatureToggleScriptRoot = $PSScriptRoot
# Legacy environment targeting fields. Never copied into a plan and never sent on a rules write.
# IsEnabled / DefaultIsEnabled stay on the Octopus wire (docs) but are not plan-side property names.
$script:UiFeatureToggleLegacyEnvironmentFields = @(
    'RolloutPercentage'
    'ClientRolloutPercentage'
    'TenantRolloutPercentage'
    'IncludedTenants'
    'ExcludedTenants'
    'IncludedTenantTags'
    'ExcludedTenantTags'
    'MinimumVersion'
    'Segments'
    'IsEnabled'
    'Links'
)

function Get-UiFeatureToggleEnvironmentNames {
    @('tdd', 'uat', 'prod')
}

function Get-UiFeatureToggleDefaults {
    param(
        [Parameter(Mandatory)]
        $Spec
    )
    if ($Spec -is [System.Collections.IDictionary]) {
        if (-not $Spec.Contains('Defaults') -or $null -eq $Spec['Defaults']) {
            throw "Toggle '$($Spec['Name'])' has no Defaults."
        }
        return $Spec['Defaults']
    }
    $property = $Spec.PSObject.Properties['Defaults']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "Toggle '$($Spec.Name)' has no Defaults."
    }
    return $property.Value
}

function Get-UiFeatureToggleSpecs {
    @(
        @{
            Name        = 'BuildingManagement'
            Slug        = 'BuildingManagement'
            Description = 'Buildings and Rooms admin (/admin/buildings) and the building-room summary reads. On: the nav link, the page, and those reads. Off: hidden, and those reads are rejected. Work order building text and the Open by Building report stay.'
            Defaults    = [ordered]@{
                tdd  = $true
                uat  = $false
                prod = $false
            }
        }
        @{
            Name        = 'VendorManagement'
            Slug        = 'VendorManagement'
            Description = 'Vendor directory on Teams and Vendors, vendor commands and queries, and the MCP vendor tools. On: that section and those calls. Off: hidden, and those calls are rejected. Waiting on a vendor, and the teams portion of the page, stay.'
            Defaults    = [ordered]@{
                tdd  = $true
                uat  = $false
                prod = $false
            }
        }
        @{
            Name        = 'ShowPriorityBadges'
            Slug        = 'showprioritybadges'
            Description = 'High priority badge on the work order search list and board. On: a High-priority work order shows the badge. Off: the badge is hidden. Search and the board stay.'
            Defaults    = [ordered]@{
                tdd  = $true
                uat  = $true
                prod = $true
            }
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

function ConvertTo-UiFeatureToggleEnabled([object] $Value) {
    # pwsh -File hands the script text. Bash does not treat $false as a Boolean: an unquoted $false
    # disappears, and a quoted one arrives as the characters $false. true/false/on/off/1/0 and those
    # two tokens are the same choice as a PowerShell $true or $false. The value is not echoed: a
    # pasted credential must not land in the error.
    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64]) {
        $number = [long]$Value
        if ($number -eq 1) { return $true }
        if ($number -eq 0) { return $false }
        throw 'Enabled must be true, false, on, off, 1, or 0. -Enable and -Disable take no value.'
    }
    $text = ([string]$Value).Trim()
    if ($text -match '^(?i:\$true|true|on|1)$') { return $true }
    if ($text -match '^(?i:\$false|false|off|0)$') { return $false }
    throw 'Enabled must be true, false, on, off, 1, or 0. A shell may pass the text $true or $false. -Enable and -Disable take no value.'
}

function Resolve-UiFeatureToggleEnabled {
    param(
        [object] $Enabled,
        [switch] $HasEnabled,
        [switch] $Enable,
        [switch] $Disable
    )
    if ($Enable -and $Disable) { throw 'Pass -Enable or -Disable, not both.' }
    if ($HasEnabled -and ($Enable -or $Disable)) { throw 'Pass -Enabled or -Enable/-Disable, not both.' }
    if ($Enable) { return $true }
    if ($Disable) { return $false }
    if (-not $HasEnabled) { return $null }
    return ConvertTo-UiFeatureToggleEnabled $Enabled
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

function Get-UiFeatureToggleEnvironmentEnabled($Configured) {
    if ($null -eq $Configured) { return $false }
    $value = Get-NoteProperty $Configured 'Enabled'
    if ($null -eq $value) { $value = Get-NoteProperty $Configured 'IsEnabled' }
    if ($null -eq $value) { return $false }
    return ConvertTo-Boolean $value
}

function Test-UiFeatureToggleLegacyEnvironmentField([string] $PropertyName) {
    return $PropertyName -in $script:UiFeatureToggleLegacyEnvironmentFields
}

function Get-UiFeatureToggleTargetingModel($Toggle) {
    # null (create) and projects with no flags yet use rules. Legacy is detected from stored
    # RolloutPercentage / related fields, or from Phases that lack a Rules property while legacy fields exist.
    if ($null -eq $Toggle) { return 'rules' }
    $hasLegacyField = $false
    $hasRulesPhase = $false
    foreach ($configured in (ConvertTo-ObjectList (Get-NoteProperty $Toggle 'Environments'))) {
        if ($null -eq $configured) { continue }
        $names = if ($configured -is [System.Collections.IDictionary]) {
            @($configured.Keys)
        } else {
            @($configured.PSObject.Properties.Name)
        }
        foreach ($propertyName in $names) {
            if ($propertyName -eq 'IsEnabled' -or $propertyName -eq 'Links' -or $propertyName -eq 'DeploymentEnvironmentId' -or $propertyName -eq 'Phases' -or $propertyName -eq 'Enabled') { continue }
            if (Test-UiFeatureToggleLegacyEnvironmentField ([string]$propertyName)) {
                $hasLegacyField = $true
            }
        }
        foreach ($phase in (ConvertTo-ObjectList (Get-NoteProperty $configured 'Phases'))) {
            if ($null -eq $phase) { continue }
            if ($null -ne (Get-NoteProperty $phase 'Rules')) { $hasRulesPhase = $true }
        }
    }
    if ($hasLegacyField -and -not $hasRulesPhase) { return 'legacy' }
    if ($hasRulesPhase) { return 'rules' }
    if ($hasLegacyField) { return 'legacy' }
    return 'rules'
}

function Assert-UiFeatureToggleRulesWritable($Toggle, [string] $ToggleName) {
    $model = Get-UiFeatureToggleTargetingModel $Toggle
    if ($model -eq 'legacy') {
        throw "Toggle '$ToggleName' on $($script:UiFeatureToggleProjectSlug) still uses legacy feature-flag targeting. Upgrade the project to rules in Octopus before running this script (docs/ops/ui-feature-toggles.md). This script does not run the upgrade and will not write legacy fields."
    }
}

function Assert-UiFeatureToggleRulesPayload($Body) {
    # Guards a rules write: never send legacy targeting fields. IsEnabled / DefaultIsEnabled remain on the
    # published rules wire (https://octopus.com/docs/api/feature-flags).
    $json = if ($Body -is [string]) { $Body } else { ConvertTo-OctopusJson $Body }
    foreach ($legacyName in @(
            'RolloutPercentage'
            'ClientRolloutPercentage'
            'TenantRolloutPercentage'
            'IncludedTenants'
            'ExcludedTenants'
            'IncludedTenantTags'
            'ExcludedTenantTags'
            'MinimumVersion'
            'Segments'
        )) {
        if ($json -match [regex]::Escape('"' + $legacyName + '"')) {
            throw "Rules payload must not contain legacy field '$legacyName'."
        }
    }
}

function Copy-EnvironmentConfig($Existing, [string] $Id, [bool] $Enabled) {
    # Plan-side environment row: DeploymentEnvironmentId, Enabled, Phases. Does not carry IsEnabled,
    # RolloutPercentage, DefaultIsEnabled, or other legacy targeting fields.
    $copy = [ordered]@{}
    if ($null -ne $Existing) {
        $names = if ($Existing -is [System.Collections.IDictionary]) {
            @($Existing.Keys)
        } else {
            @($Existing.PSObject.Properties.Name)
        }
        foreach ($propertyName in $names) {
            if (Test-UiFeatureToggleLegacyEnvironmentField ([string]$propertyName)) { continue }
            if ($propertyName -in @('Enabled', 'DeploymentEnvironmentId')) { continue }
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
    $copy['Enabled'] = $Enabled
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

    $defaults = Get-UiFeatureToggleDefaults $Spec
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
            if ($force -and (Get-UiFeatureToggleEnvironmentEnabled $byId[$id]) -ne $desired) {
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
    $defaultEnabled = $false
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
        if ($null -eq $currentDefaultValue) { $currentDefaultValue = Get-NoteProperty $Current 'DefaultEnabled' }
        $currentDefault = if ($null -eq $currentDefaultValue) { $false } else { ConvertTo-Boolean $currentDefaultValue }
        $defaultEnabled = $currentDefault
        if ($Mode -eq 'ResetDefaults' -and $currentDefault) {
            $changeDefault = $true
            $defaultEnabled = $false
            $changed = $true
        }
        $action = if ($changed) { 'update' } else { 'none' }
    }

    $environments = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $orderedIds) {
        $configured = $byId[$id]
        $environments.Add((Copy-EnvironmentConfig $configured $id (Get-UiFeatureToggleEnvironmentEnabled $configured)))
    }

    [pscustomobject]@{
        Action         = $action
        Name           = [string]$Spec.Name
        RequestedSlug  = [string]$Spec.Slug
        Description    = $description
        DefaultEnabled = [bool]$defaultEnabled
        ChangeDefault  = [bool]$changeDefault
        Environments   = $environments
    }
}

function Format-UiFeatureTogglePlan($Plan, $IdToName) {
    $parts = foreach ($configured in $Plan.Environments) {
        $id = [string]$configured.DeploymentEnvironmentId
        $label = if ($IdToName.Contains($id)) { [string]$IdToName[$id] } else { $id }
        $state = if (Get-UiFeatureToggleEnvironmentEnabled $configured) { 'on' } else { 'off' }
        "$label=$state"
    }
    $defaultState = if ($Plan.DefaultEnabled) { 'on' } else { 'off' }
    "$($Plan.Name): $($Plan.Action) default=$defaultState $($parts -join ' ')"
}

function Get-OfflineEnsurePlans {
    $ids = @{}
    foreach ($environmentName in (Get-UiFeatureToggleEnvironmentNames)) { $ids[$environmentName] = $environmentName }
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
    foreach ($environmentName in (Get-UiFeatureToggleEnvironmentNames)) {
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
            throw "Octopus answered 404 for feature toggles on $($script:UiFeatureToggleProjectSlug). Create BuildingManagement, VendorManagement, and ShowPriorityBadges in the project UI (docs/ops/ui-feature-toggles.md). $($lastError.Detail)"
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
    # Published rules environment shape: DeploymentEnvironmentId, IsEnabled, Phases (required).
    # https://octopus.com/docs/api/feature-flags — Phases item schema beyond an empty list is not verified here.
    $phases = ConvertTo-PhaseList (Get-NoteProperty $Configured 'Phases')
    $wire = [ordered]@{
        DeploymentEnvironmentId = [string](Get-NoteProperty $Configured 'DeploymentEnvironmentId')
        IsEnabled               = Get-UiFeatureToggleEnvironmentEnabled $Configured
        Phases                  = $phases
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
    # Rules create: Name, ProjectId, SpaceId, Environments (DeploymentEnvironmentId, IsEnabled, Phases).
    # Rules modify also sends DefaultIsEnabled and Slug. Map plan DefaultEnabled → DefaultIsEnabled here only.
    $environments = New-FeatureToggleEnvironmentWires $Plan.Environments
    if ($null -eq $Existing) {
        $create = [ordered]@{
            Name         = [string]$Spec.Name
            ProjectId    = [string]$ProjectId
            SpaceId      = [string]$SpaceId
            Environments = $environments
        }
        Assert-UiFeatureToggleRulesPayload $create
        return $create
    }
    $defaultEnabled = if ($null -ne (Get-NoteProperty $Plan 'DefaultEnabled')) {
        [bool]$Plan.DefaultEnabled
    } else {
        [bool](Get-NoteProperty $Plan 'DefaultIsEnabled')
    }
    $body = [ordered]@{
        Id               = [string](Get-NoteProperty $Existing 'Id')
        Name             = [string](Get-NoteProperty $Existing 'Name')
        ProjectId        = [string]$ProjectId
        SpaceId          = [string]$SpaceId
        DefaultIsEnabled = $defaultEnabled
        Environments     = $environments
    }
    $slug = Get-NoteProperty $Existing 'Slug'
    if ($slug) { $body['Slug'] = [string]$slug }
    $description = [string]$Plan.Description
    if (-not [string]::IsNullOrWhiteSpace($description)) { $body['Description'] = $description }
    Assert-UiFeatureToggleRulesPayload $body
    return $body
}

function Test-DefaultIsOff($Flag) {
    $value = Get-NoteProperty $Flag 'DefaultIsEnabled'
    if ($null -eq $value) { $value = Get-NoteProperty $Flag 'DefaultEnabled' }
    return $null -ne $value -and -not (ConvertTo-Boolean $value)
}

function Invoke-UiFeatureToggleCommand {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [ValidateSet('Ensure', 'Set', 'Show')]
        [string] $Action = 'Ensure',

        [string] $Name,

        [string] $Environment,

        [object] $Enabled,

        [switch] $Enable,

        [switch] $Disable,

        [switch] $ResetDefaults
    )

    if ($Action -eq 'Ensure') {
        if ($PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Environment') -or $PSBoundParameters.ContainsKey('Enabled') -or $Enable -or $Disable) {
            throw 'Ensure takes no -Name, -Environment, -Enabled, -Enable, or -Disable. Use -Action Set to flip one environment, or -ResetDefaults to restore each flag''s defaults.'
        }
    }
    if ($Action -eq 'Show') {
        if ($ResetDefaults -or $PSBoundParameters.ContainsKey('Name') -or $PSBoundParameters.ContainsKey('Environment') -or $PSBoundParameters.ContainsKey('Enabled') -or $Enable -or $Disable) {
            throw 'Show only reads. It takes no -Name, -Environment, -Enabled, -Enable, -Disable, or -ResetDefaults.'
        }
    }
    if ($Action -eq 'Set') {
        if ($ResetDefaults) { throw 'Set and -ResetDefaults exclude each other.' }
        $Enabled = Resolve-UiFeatureToggleEnabled -Enabled $Enabled -HasEnabled:$PSBoundParameters.ContainsKey('Enabled') -Enable:$Enable -Disable:$Disable
        if (-not $Name -or -not $Environment -or $null -eq $Enabled) { throw 'Set needs -Name, -Environment, and a value (-Enabled true or false, or -Enable / -Disable).' }
    }

    $systemPath = Join-Path $script:UiFeatureToggleScriptRoot '..' 'system.json'
    $system = Get-Content -LiteralPath $systemPath -Raw | ConvertFrom-Json
    Assert-UiFeatureToggleSystem $system

    if ($WhatIfPreference -and $Action -eq 'Ensure' -and -not (Test-OctopusCredential)) {
        foreach ($plan in Get-OfflineEnsurePlans) {
            $labels = @{}
            foreach ($environmentName in (Get-UiFeatureToggleEnvironmentNames)) { $labels[$environmentName] = $environmentName }
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
    $environmentNames = @(Get-UiFeatureToggleEnvironmentNames)
    foreach ($octopusEnvironment in @(Invoke-Octopus -Method Get -Uri "$url/api/$space/environments/all")) {
        $environmentName = [string]$octopusEnvironment.Name
        if ($environmentName -in $environmentNames) {
            $environmentIds[$environmentName] = [string]$octopusEnvironment.Id
            $idToName[[string]$octopusEnvironment.Id] = $environmentName
        }
    }
    foreach ($environmentName in $environmentNames) {
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
            foreach ($environmentName in (Get-UiFeatureToggleEnvironmentNames)) {
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

        # Writes speak rules only. Refuse when the stored toggle (or any sibling, on create) is still legacy.
        if ($null -ne $current) {
            Assert-UiFeatureToggleRulesWritable $current $spec.Name
        } else {
            foreach ($existingToggle in (ConvertTo-ObjectList $toggles)) {
                if ($null -eq $existingToggle) { continue }
                $existingResource = Get-UiFeatureToggleResource $base $existingToggle
                Assert-UiFeatureToggleRulesWritable $existingResource ([string](Get-NoteProperty $existingResource 'Name'))
            }
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
                $createdEnvironments = if ($null -ne (Get-NoteProperty $created 'Environments')) {
                    Get-NoteProperty $created 'Environments'
                } else {
                    $plan.Environments
                }
                $defaultPlanEnvironments = [System.Collections.Generic.List[object]]::new()
                foreach ($configured in (ConvertTo-ObjectList $createdEnvironments)) {
                    if ($null -eq $configured) { continue }
                    $defaultPlanEnvironments.Add((Copy-EnvironmentConfig $configured ([string](Get-NoteProperty $configured 'DeploymentEnvironmentId')) (Get-UiFeatureToggleEnvironmentEnabled $configured)))
                }
                $defaultPlan = [pscustomobject]@{
                    Description    = if ([string]::IsNullOrWhiteSpace([string](Get-NoteProperty $created 'Description'))) { [string]$plan.Description } else { [string](Get-NoteProperty $created 'Description') }
                    DefaultEnabled = $false
                    Environments   = $defaultPlanEnvironments
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
}

if ($LoadOnly) { return }

Invoke-UiFeatureToggleCommand @PSBoundParameters
