$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $repo 'onboard-claude-gateway.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$functions = $ast.EndBlock.Statements | Where-Object {
    $_ -is [Management.Automation.Language.FunctionDefinitionAst]
}
. ([scriptblock]::Create(($functions | ForEach-Object { $_.Extent.Text }) -join "`n"))
$originalRequest = (Get-Item Function:\Invoke-GatewayCatalogRequest).ScriptBlock

function Assert-Equal($Actual, $Expected, $Message) {
    if ($Actual -cne $Expected) { throw "$Message`: expected '$Expected', got '$Actual'." }
}
function Assert-Fails([scriptblock]$Action, [string]$Message) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_.Exception.Message }
    if (-not $failure -or $failure -notlike "*$Message*") {
        throw "Expected failure containing '$Message', got '$failure'."
    }
}

$script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/demo/providers/Microsoft.ApiManagement/aigateways/example'
$script:scope = "$root/workspaces/default"
$script:hostUrl = 'https://example.ai.gateway.azure.com'
$settings = [pscustomobject]@{
    TenantId = '22222222-2222-2222-2222-222222222222'
    GatewayBaseUrl = "$hostUrl/default/models/anthropic"
    AzureCliPath = 'az'
}
foreach ($url in @($hostUrl, "$hostUrl/", $settings.GatewayBaseUrl, ($settings.GatewayBaseUrl + '/'))) {
    Assert-Equal (Resolve-GatewayBaseUrl $url) $settings.GatewayBaseUrl 'Runtime URL normalization'
}
foreach ($url in @('http://example.ai.gateway.azure.com', ($hostUrl + '?secret=value'),
    ($hostUrl + '/unexpected'), 'https://example.org')) {
    Assert-Fails { Resolve-GatewayBaseUrl $url } 'dedicated AI Gateway'
}
function New-TestAlias([int]$Number, [string]$Model, [string]$Alias, [bool]$Allowed = $true,
    [string]$Endpoint = '/anthropic/v1/messages') {
    if (-not $Alias) { $Alias = "provider/$Model" }
    [pscustomobject]@{
        id = "$scope/aliases/alias-$Number"
        properties = [pscustomobject]@{
            aliasName = $Alias
            supportedEndpoints = @($Endpoint)
            backendModels = @([pscustomobject]@{ resourceId = "$scope/modelProviders/provider/models/backend-$Number" })
        }
        Model = $Model
        Allowed = $Allowed
    }
}
function Invoke-NativeCapture {
    param($FilePath, $Arguments)
    if ($Arguments -notcontains 'https://management.azure.com' -or $Arguments -notcontains $settings.TenantId) {
        throw 'Discovery must request an Azure management token in the supplied tenant.'
    }
    [pscustomobject]@{ ExitCode = 0; Output = 'offline-token' }
}
function Invoke-GatewayCatalogRequest {
    param([string]$Uri, [string]$Token, $Body)
    Assert-Equal $Token 'offline-token' 'Token'
    if ($Uri -like '*/Microsoft.ResourceGraph/resources?*') {
        if ($Body.query -notlike "*$hostUrl*") { throw 'Lookup must use the supplied host.' }
        return [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }) }
    }
    if ($Uri -eq "https://management.azure.com${root}?api-version=2025-09-01-preview") {
        return [pscustomobject]@{ properties = [pscustomobject]@{
            frontend = [pscustomobject]@{ defaultHostname = 'example.ai.gateway.azure.com' }
        } }
    }
    if (([Uri]$Uri).AbsolutePath -eq "$scope/aliases") {
        return [pscustomobject]@{ value = @($script:entries) }
    }
    foreach ($entry in $script:entries) {
        if ($Uri -like "https://management.azure.com$($entry.id)/providers/Microsoft.Authorization/permissions?*") {
            return [pscustomobject]@{ value = @([pscustomobject]@{
                actions = @('*')
                dataActions = @($(if ($entry.Allowed) { 'Microsoft.ApiManagement/aigateways/models/*' }))
                notDataActions = @()
            }) }
        }
        if ($Uri -like "https://management.azure.com$($entry.properties.backendModels[0].resourceId)?*") {
            return [pscustomobject]@{ properties = [pscustomobject]@{
                deployment = [pscustomobject]@{ modelName = $entry.Model }
            } }
        }
    }
    throw "Unexpected request: $Uri"
}

$modelNames = @('claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5')
foreach ($count in @(1, 2, 3)) {
    $script:entries = @(for ($i = 0; $i -lt $count; $i++) { New-TestAlias $i $modelNames[$i] })
    $catalog = @(Get-GatewayModelCatalog -Settings $settings)
    Assert-Equal $catalog.Count $count 'Exact discovered model count'
    Assert-Equal (($catalog | ForEach-Object Alias) -join ',') `
        (($entries | ForEach-Object { $_.properties.aliasName }) -join ',') 'Exact discovered model list'
    $mapping = Resolve-CodeModelMapping -Catalog $catalog
    Assert-Equal $mapping.Count $count 'Only available families are mapped'
}
$script:entries = @(
    (New-TestAlias 0 'claude-opus-4-5'),
    (New-TestAlias 1 'claude-opus-5'),
    (New-TestAlias 2 'claude-sonnet-5' '' $false),
    (New-TestAlias 3 'gpt-example' '' $true '/openai/v1/chat/completions'),
    (New-TestAlias 4 'another-vendor-model')
)
$catalog = @(Get-GatewayModelCatalog -Settings $settings)
Assert-Equal $catalog.Count 2 'Only permitted Claude aliases are included'
$mapping = Resolve-CodeModelMapping -Catalog $catalog
Assert-Equal $mapping.Count 1 'Two Opus models must not invent Sonnet or Haiku'
Assert-Equal $mapping.Opus 'provider/claude-opus-4-5' 'First family match'
$script:entries = @((New-TestAlias 0 'claude-sonnet-5' 'Team-Approved'))
$custom = @(Get-GatewayModelCatalog -Settings $settings)
Assert-Equal (Resolve-CodeModelMapping -Catalog $custom).Sonnet 'Team-Approved' 'Custom alias uses backend model metadata'
$script:entries = @((New-TestAlias 0 'claude-opus-5' '' $false))
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'No permitted Claude'
$script:entries = @((New-TestAlias 0 'claude-opus-5'), (New-TestAlias 1 'claude-opus-5'))
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'duplicate'
$script:entries = @((New-TestAlias 0 '' 'provider/unknown'))
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'model identity'
$excluded = [pscustomobject]@{
    dataActions = @('Microsoft.ApiManagement/aigateways/models/*')
    notDataActions = @('Microsoft.ApiManagement/aigateways/models/*')
}
Assert-Equal (Test-GatewayModelInvocation -Permissions @($excluded)) $false 'Excluded data action'
Assert-Equal (Test-GatewayModelInvocation -Permissions @([pscustomobject]@{actions=@('*')})) $false 'Reader/Owner alone is not invocation'
Assert-Equal (Test-GatewayModelInvocation -Permissions @($excluded, [pscustomobject]@{
    dataActions=@('Microsoft.ApiManagement/service/workspaces/models/*')
})) $true 'Additive role assignments'
Assert-Fails { & $originalRequest -Uri "https://example.org$scope/aliases" -Token 'offline-token' } 'invalid Azure management URL'

$script:entries = @((New-TestAlias 0 'claude-opus-5'))
$catalog = @(Get-GatewayModelCatalog -Settings $settings)
$settings | Add-Member Models @($catalog | ForEach-Object Alias)
$settings | Add-Member ModelMapping (Resolve-CodeModelMapping -Catalog $catalog)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-discovery-' + [Guid]::NewGuid())
$oldProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
function Assert-CodeSettingsCompatible {}
try {
    $env:USERPROFILE = Join-Path $temp 'home'
    $env:APPDATA = Join-Path $temp 'appdata'
    $installRoot = Join-Path $temp 'helpers'
    $cliPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    $vsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    [IO.Directory]::CreateDirectory((Split-Path $cliPath)) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path $vsPath)) | Out-Null
    '{"keepMe":true,"env":{"ANTHROPIC_DEFAULT_HAIKU_MODEL":"old/haiku"}}' | Set-Content -LiteralPath $cliPath
    '{"claudeCode.environmentVariables":[{"name":"ANTHROPIC_DEFAULT_HAIKU_MODEL","value":"old/haiku"}]}' | Set-Content -LiteralPath $vsPath
    Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
    Install-VSCodeConfiguration -Settings $settings -InstallRoot $installRoot
    $cli = Read-JsonSettings -Path $cliPath
    $editor = Read-JsonSettings -Path $vsPath
    Assert-Equal $cli.keepMe $true 'Unrelated settings preserved'
    Assert-Equal $cli.enforceAvailableModels $true 'Only discovered models are listed'
    Assert-Equal ($cli.availableModels -join ',') ($settings.Models -join ',') 'CLI model list'
    Assert-Equal $cli.modelPicker.replaceBuiltInOptions $true 'Built-in picker rows are replaced'
    Assert-Equal ($cli.modelPicker.options.model -join ',') ($settings.Models -join ',') 'Exact custom alias picker'
    Assert-Equal $cli.env.ANTHROPIC_DEFAULT_OPUS_MODEL $settings.Models[0] 'Opus shortcut'
    Assert-Equal $cli.env.ANTHROPIC_DEFAULT_HAIKU_MODEL $null 'Stale Haiku mapping removed'
    Assert-Equal @($editor.'claudeCode.environmentVariables' | Where-Object {
        $_.name -eq 'ANTHROPIC_DEFAULT_HAIKU_MODEL'
    }).Count 0 'Stale VS Code Haiku mapping removed'
    $settings | Add-Member ConfigId ([Guid]::NewGuid().ToString())
    $desktopDir = Join-Path $temp 'desktop'
    Install-DesktopConfiguration -Settings $settings -InstallRoot $installRoot `
        -HelperPath 'C:\helpers\token.cmd' -ConfigDirectory $desktopDir | Out-Null
    $desktop = Read-JsonSettings -Path (Join-Path $desktopDir ($settings.ConfigId + '.json'))
    Assert-Equal ($desktop.inferenceModels.name -join ',') ($settings.Models -join ',') 'Desktop model list'
    $settings.Models = @('provider/claude-opus-4-5', 'provider/claude-opus-5')
    $settings.ModelMapping = [ordered]@{ Opus = $settings.Models[0] }
    Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
    $cli = Read-JsonSettings -Path $cliPath
    Assert-Equal ($cli.modelPicker.options.model -join ',') ($settings.Models -join ',') 'Both same-family aliases are picker entries'
}
finally {
    $env:USERPROFILE = $oldProfile
    $env:APPDATA = $oldAppData
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
Write-Output 'Windows automatic discovery, RBAC filtering, model mapping, and client configuration checks passed.'
