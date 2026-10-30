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
function Reset-GatewayLookupFixture {
    $script:lookupData = @([pscustomobject]@{ id = $root })
    $script:lookupPages = @{ first = [pscustomobject]@{ data = @() } }
    $script:gatewayMetadata = @{}
    $script:gatewayFailures = @{}
    $script:catalogCalls = @()
}
Reset-GatewayLookupFixture
function Invoke-GatewayCatalogRequest {
    param([string]$Uri, [string]$Token, $Body)
    Assert-Equal $Token 'offline-token' 'Token'
    $script:catalogCalls += [pscustomobject]@{ Uri = $Uri; Body = $Body }
    if ($Uri -like '*/Microsoft.ResourceGraph/resources?*') {
        if ($Body.query -like "*$hostUrl*") { return [pscustomobject]@{ data = $script:lookupData } }
        if ($Body.query -notlike '* | project id' -or $Body.query -like '*properties.*') {
            throw 'Fallback must enumerate IDs without filtering on unindexed metadata.'
        }
        $key = $Body.options['$skipToken']
        if (-not $key) { $key = 'first' }
        return $script:lookupPages[$key]
    }
    $resource = ([Uri]$Uri).AbsolutePath
    if ($script:gatewayFailures.ContainsKey($resource)) { throw $script:gatewayFailures[$resource] }
    if ($script:gatewayMetadata.ContainsKey($resource)) { return $script:gatewayMetadata[$resource] }
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
Reset-GatewayLookupFixture
$null = Get-GatewayModelCatalog -Settings $settings
Assert-Equal @($catalogCalls | Where-Object { $_.Uri -like '*/Microsoft.ResourceGraph/resources?*' }).Count `
    1 'Indexed hostname uses only the fast lookup'
foreach ($lookupMatches in @(@(), @([pscustomobject]@{ id = $root }, [pscustomobject]@{ id = "$root-other" }))) {
    Reset-GatewayLookupFixture
    $script:lookupData = $lookupMatches
    Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'uniquely find'
}
Reset-GatewayLookupFixture
$script:lookupData = @()
$script:lookupPages.first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }) }
$catalog = @(Get-GatewayModelCatalog -Settings $settings)
Assert-Equal $catalog.Count 1 'Unindexed hostname resolves from current ARM metadata'
Assert-Equal @($catalogCalls | Where-Object {
    $_.Uri -eq "https://management.azure.com${root}?api-version=2025-09-01-preview"
}).Count 1 'Matching gateway metadata is read only once'
$script:gatewayMetadata[$root] = [pscustomobject]@{
    properties = [pscustomobject]@{
        gatewayUrl = $null
        frontend = [pscustomobject]@{ defaultHostname = 'example.ai.gateway.azure.com' }
    }
}
Assert-Equal @(Get-GatewayModelCatalog -Settings $settings).Count 1 `
    'Unindexed gateway resolves from ARM defaultHostname when gatewayUrl is null'

$otherRoot = "$root-other"
Reset-GatewayLookupFixture
$script:lookupData = @()
$script:gatewayMetadata[$otherRoot] = [pscustomobject]@{
    properties = [pscustomobject]@{ gatewayUrl = 'https://other.ai.gateway.azure.com' }
}
$script:lookupPages = @{
    first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $otherRoot }); '$skipToken' = 'second'; resultTruncated = 'true' }
    second = [pscustomobject]@{ data = @([pscustomobject]@{ id = $otherRoot.ToUpperInvariant() }, [pscustomobject]@{ id = $root }) }
}
Assert-Equal @(Get-GatewayModelCatalog -Settings $settings).Count 1 'Fallback checks later pages'
Assert-Equal @($catalogCalls | Where-Object {
    $_.Uri -eq "https://management.azure.com${otherRoot}?api-version=2025-09-01-preview"
}).Count 1 'Duplicate resource IDs are read once, ignoring case'

Reset-GatewayLookupFixture
$script:lookupData = @()
$script:lookupPages.first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }) }
$script:gatewayMetadata[$root] = [pscustomobject]@{
    properties = [pscustomobject]@{ gatewayUrl = $hostUrl.ToUpperInvariant() + '/'; frontend = $null }
}
Assert-Equal @(Get-GatewayModelCatalog -Settings $settings).Count 1 'Gateway URL handles case and trailing slash'
$script:gatewayMetadata[$root] = [pscustomobject]@{
    properties = [pscustomobject]@{ gatewayUrl = 'https://wrong.ai.gateway.azure.com' }
}
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'uniquely find'
$script:gatewayMetadata[$root] = [pscustomobject]@{
    properties = [pscustomobject]@{ gatewayUrl = $null; frontend = [pscustomobject]@{ defaultHostname = $null } }
}
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'uniquely find'
$script:gatewayFailures[$root] = 'offline ARM read denied'
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'offline ARM read denied'

Reset-GatewayLookupFixture
$script:lookupData = @()
$script:gatewayMetadata[$otherRoot] = [pscustomobject]@{ properties = [pscustomobject]@{ gatewayUrl = $hostUrl } }
$script:lookupPages = @{
    first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }); '$skipToken' = 'second' }
    second = [pscustomobject]@{ data = @([pscustomobject]@{ id = $otherRoot }) }
}
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'uniquely find'
Assert-Equal @($catalogCalls | Where-Object { ([Uri]$_.Uri).AbsolutePath -eq "$scope/aliases" }).Count `
    0 'Ambiguous hostname does not read models'

foreach ($invalidId in @('https://example.org', ($root + '?redirect=other'), $null, 123)) {
    Reset-GatewayLookupFixture
    $script:lookupData = @()
    $script:lookupPages.first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $invalidId }) }
    Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'invalid gateway resource ID'
    Assert-Equal @($catalogCalls | Where-Object { $_.Uri -notlike '*/Microsoft.ResourceGraph/resources?*' }).Count `
        0 'Invalid IDs are rejected before a direct resource read'
}
foreach ($fallback in @($false, $true)) {
    Reset-GatewayLookupFixture
    if ($fallback) {
        $script:lookupData = @()
        $script:lookupPages.first = [pscustomobject]@{ data = $null }
    } else {
        $script:lookupData = $null
    }
    Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'invalid gateway list'
}
foreach ($nextToken in @('second', 123)) {
    Reset-GatewayLookupFixture
    $script:lookupData = @()
    $script:lookupPages = @{
        first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }); '$skipToken' = 'second' }
        second = [pscustomobject]@{ data = @(); '$skipToken' = $nextToken }
    }
    Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'continuation token'
}
Reset-GatewayLookupFixture
$script:lookupData = @()
$script:lookupPages.first = [pscustomobject]@{ data = @([pscustomobject]@{ id = $root }); resultTruncated = 'true' }
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'truncated'
Reset-GatewayLookupFixture
$script:gatewayMetadata[$root] = [pscustomobject]@{
    properties = [pscustomobject]@{ gatewayUrl = 'https://stale.ai.gateway.azure.com' }
}
Assert-Fails { Get-GatewayModelCatalog -Settings $settings } 'hostname does not match'
Reset-GatewayLookupFixture

$script:entries = @((New-TestAlias 0 'claude-opus-5'))
$catalog = @(Get-GatewayModelCatalog -Settings $settings)
$settings | Add-Member Models @($catalog | ForEach-Object Alias)
$settings | Add-Member ModelMapping (Resolve-CodeModelMapping -Catalog $catalog)
$temp = Join-Path ([IO.Path]::GetTempPath()) ('claude-discovery-' + [Guid]::NewGuid())
$oldProfile = $env:USERPROFILE
$oldAppData = $env:APPDATA
$script:testEnvironment = @{}
$compatibilityFunction = ($functions | Where-Object { $_.Name -eq 'Assert-CodeSettingsCompatible' }).Extent.Text
$compatibilityFunction = $compatibilityFunction.Replace(
    "[Environment]::GetEnvironmentVariable('ANTHROPIC_CUSTOM_HEADERS', `$scope)",
    '$script:testEnvironment["$scope|ANTHROPIC_CUSTOM_HEADERS"]')
$compatibilityFunction = $compatibilityFunction.Replace(
    '[Environment]::GetEnvironmentVariable($name, $scope)',
    '$script:testEnvironment["$scope|$name"]')
. ([scriptblock]::Create($compatibilityFunction))
foreach ($value in @('1', 'true', $true, '0', 'false', $false)) {
    Assert-CodeSettingsCompatible -Settings ([pscustomobject]@{
        env = [pscustomobject]@{ CLAUDE_CODE_USE_FOUNDRY = $value }
    }) -Source 'test user settings'
}
foreach ($scope in @('Process', 'User', 'Machine')) {
    $script:testEnvironment["$scope|CLAUDE_CODE_USE_FOUNDRY"] = '1'
    Assert-Fails {
        Assert-CodeSettingsCompatible -Settings ([pscustomobject]@{
            env = [pscustomobject]@{ CLAUDE_CODE_USE_FOUNDRY = '1' }
        }) -Source 'test user settings'
    } "CLAUDE_CODE_USE_FOUNDRY in the $scope environment"
    $script:testEnvironment.Clear()
}
foreach ($name in @(
    'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_MANTLE',
    'CLAUDE_CODE_USE_ANTHROPIC_AWS', 'CLAUDE_CONFIG_DIR'
)) {
    $environment = [pscustomobject]@{ CLAUDE_CODE_USE_FOUNDRY = '1' }
    $environment | Add-Member -NotePropertyName $name -NotePropertyValue 'offline-conflict'
    Assert-Fails {
        Assert-CodeSettingsCompatible -Settings ([pscustomobject]@{ env = $environment }) -Source 'test user settings'
    } "Conflicting $name"
}
try {
    $env:USERPROFILE = Join-Path $temp 'home'
    $env:APPDATA = Join-Path $temp 'appdata'
    $installRoot = Join-Path $temp 'helpers'
    $cliPath = Join-Path $env:USERPROFILE '.claude\settings.json'
    $vsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    [IO.Directory]::CreateDirectory((Split-Path $cliPath)) | Out-Null
    [IO.Directory]::CreateDirectory((Split-Path $vsPath)) | Out-Null
    '{"keepMe":true,"env":{"CLAUDE_CODE_USE_FOUNDRY":"1","KEEP_ME":"unchanged","ANTHROPIC_DEFAULT_HAIKU_MODEL":"old/haiku"}}' | Set-Content -LiteralPath $cliPath
    '{"editor.fontSize":16,"claudeCode.environmentVariables":[{"name":"CLAUDE_CODE_USE_FOUNDRY","value":"1"},{"name":"KEEP_ME","value":"unchanged"},{"name":"ANTHROPIC_DEFAULT_HAIKU_MODEL","value":"old/haiku"}]}' | Set-Content -LiteralPath $vsPath
    $originalCli = [IO.File]::ReadAllBytes($cliPath)
    $originalVSCode = [IO.File]::ReadAllBytes($vsPath)
    Assert-Fails {
        Invoke-ConfigurationUpdate -Paths @($cliPath, $vsPath) -Action {
            Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
            Install-VSCodeConfiguration -Settings $settings -InstallRoot $installRoot
            throw 'offline transaction failure'
        }
    } 'previous helper and client files were restored'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($cliPath))) `
        ([Convert]::ToBase64String($originalCli)) 'Failed migration restores original CLI settings'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($vsPath))) `
        ([Convert]::ToBase64String($originalVSCode)) 'Failed migration restores original VS Code settings'
    Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
    Install-VSCodeConfiguration -Settings $settings -InstallRoot $installRoot
    $cli = Read-JsonSettings -Path $cliPath
    $editor = Read-JsonSettings -Path $vsPath
    Assert-Equal $cli.keepMe $true 'Unrelated settings preserved'
    Assert-Equal $cli.env.CLAUDE_CODE_USE_FOUNDRY '0' 'Direct Foundry mode disabled in shared settings'
    Assert-Equal $cli.env.KEEP_ME 'unchanged' 'Unrelated CLI environment preserved'
    Assert-Equal $editor.'editor.fontSize' 16 'Unrelated VS Code settings preserved'
    $foundry = @($editor.'claudeCode.environmentVariables' | Where-Object { $_.name -eq 'CLAUDE_CODE_USE_FOUNDRY' })
    Assert-Equal $foundry.Count 1 'Exactly one VS Code Foundry switch'
    Assert-Equal $foundry[0].value '0' 'Direct Foundry mode disabled in VS Code settings'
    Assert-Equal ($editor.'claudeCode.environmentVariables' | Where-Object { $_.name -eq 'KEEP_ME' }).value `
        'unchanged' 'Unrelated VS Code environment preserved'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'backups') -Filter '*.bak')
    Assert-Equal @($backups | Where-Object {
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) -ceq [Convert]::ToBase64String($originalCli)
    }).Count 2 'Original CLI settings backed up before each migration attempt'
    Assert-Equal @($backups | Where-Object {
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) -ceq [Convert]::ToBase64String($originalVSCode)
    }).Count 2 'Original VS Code settings backed up before each migration attempt'
    Assert-Equal $cli.enforceAvailableModels $true 'Only discovered models are listed'
    Assert-Equal ($cli.availableModels -join ',') ($settings.Models -join ',') 'CLI model list'
    Assert-Equal $cli.modelPicker.replaceBuiltInOptions $true 'Built-in picker rows are replaced'
    Assert-Equal ($cli.modelPicker.options.model -join ',') ($settings.Models -join ',') 'Exact custom alias picker'
    Assert-Equal $cli.env.ANTHROPIC_DEFAULT_OPUS_MODEL $settings.Models[0] 'Opus shortcut'
    Assert-Equal $cli.env.ANTHROPIC_DEFAULT_HAIKU_MODEL $null 'Stale Haiku mapping removed'
    Assert-Equal @($editor.'claudeCode.environmentVariables' | Where-Object {
        $_.name -eq 'ANTHROPIC_DEFAULT_HAIKU_MODEL'
    }).Count 0 'Stale VS Code Haiku mapping removed'
    Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
    Install-VSCodeConfiguration -Settings $settings -InstallRoot $installRoot
    $rerun = Read-JsonSettings -Path $vsPath
    Assert-Equal @($rerun.'claudeCode.environmentVariables' | Where-Object {
        $_.name -eq 'CLAUDE_CODE_USE_FOUNDRY'
    }).Count 1 'Rerunning onboarding does not duplicate the Foundry switch'
    $conflicting = Read-JsonSettings -Path $cliPath
    $conflicting.env | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN -NotePropertyValue 'offline-existing-credential'
    Write-JsonFile -Path $cliPath -Value $conflicting
    $beforeConflict = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cliPath))
    Assert-Fails {
        Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath 'C:\helpers\token.cmd'
    } 'Conflicting ANTHROPIC_AUTH_TOKEN'
    Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($cliPath))) `
        $beforeConflict 'Existing conflicting credentials are not modified'
    $conflicting.env.PSObject.Properties.Remove('ANTHROPIC_AUTH_TOKEN')
    Write-JsonFile -Path $cliPath -Value $conflicting
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
Write-Output 'Windows discovery, RBAC, mapping, client configuration, and direct Foundry migration checks passed.'
