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
$originalNativeCapture = (Get-Item Function:\Invoke-NativeCapture).ScriptBlock

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

& {
    function Get-CimInstance {
        param($ClassName, $Property)
        Assert-Equal $ClassName 'Win32_Processor' 'Architecture uses Windows processor metadata'
        Assert-Equal $Property 'Architecture' 'Only processor architecture is requested'
        return $processorFixture
    }
    $processorFixture = @([pscustomobject]@{ Architecture = 9 }, [pscustomobject]@{ Architecture = 9 })
    Assert-Equal (Get-WindowsArchitecture) 'X64' 'Multiple x64 processors are supported'
    $oldArchitecture = $env:PROCESSOR_ARCHITECTURE
    try {
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $processorFixture = @([pscustomobject]@{ Architecture = 12 })
        Assert-Equal (Get-WindowsArchitecture) 'Arm64' 'Native ARM64 detection ignores an emulated process environment'
    } finally {
        $env:PROCESSOR_ARCHITECTURE = $oldArchitecture
    }
    foreach ($processorFixture in @(
        @(), @([pscustomobject]@{ Architecture = $null }),
        @([pscustomobject]@{ Architecture = 0 }), @([pscustomobject]@{ Architecture = 99 }),
        @([pscustomobject]@{ Architecture = 9 }, [pscustomobject]@{ Architecture = 12 })
    )) {
        Assert-Fails { Get-WindowsArchitecture } 'Unable to detect a supported x64/ARM64'
    }
    function Get-CimInstance { throw 'offline CIM unavailable' }
    Assert-Fails { Get-WindowsArchitecture } 'offline CIM unavailable'
}

& {
    $nativeArchitecture = 12
    $hypervisorPresent = $false
    function Get-CimInstance {
        param($ClassName, $Property, $Filter)
        switch ($ClassName) {
            'Win32_OptionalFeature' {
                Assert-Equal $Filter "Name='VirtualMachinePlatform'" 'Only Virtual Machine Platform is checked'
                return [pscustomobject]@{ InstallState = 1 }
            }
            'Win32_ComputerSystem' { return [pscustomobject]@{ HypervisorPresent = $hypervisorPresent } }
            'Win32_Processor' {
                return [pscustomobject]@{
                    Architecture = $nativeArchitecture
                    VirtualizationFirmwareEnabled = $false
                }
            }
            default { throw "Unexpected CIM class: $ClassName" }
        }
    }
    function Start-Process { throw 'Offline workspace checks must not enable Windows features' }
    Assert-Equal (Ensure-WorkspaceFeature).RestartNeeded $true 'ARM64 does not rely on x86 firmware fields'
    $nativeArchitecture = 9
    Assert-Fails { Ensure-WorkspaceFeature } 'Hardware virtualization is not reported as enabled'
    $hypervisorPresent = $true
    Assert-Equal (Ensure-WorkspaceFeature).RestartNeeded $false 'Running x64 hypervisor needs no restart'
    $nativeArchitecture = 12
    Assert-Equal (Ensure-WorkspaceFeature).RestartNeeded $false 'Running ARM64 hypervisor needs no restart'
}

& {
    $claims = @{ tid = '22222222-2222-2222-2222-222222222222'; aud = 'https://azure-api.net/aigateway';
        scp = 'Data.All'; exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $validToken = 'header.' + $payload + '.signature'
    $credentialSettings = [pscustomobject]@{ TenantId = $claims.tid }
    function Get-GatewayTokenResult {
        if ($script:offlineSignIns -gt 0) { return [pscustomobject]@{ ExitCode = 0; Output = $validToken } }
        return [pscustomobject]@{ ExitCode = 1; Output = "AADSTS${code}: offline sign-in required" }
    }
    function Start-EntraSignIn { $script:offlineSignIns++ }
    foreach ($code in @('65001', '50076')) {
        $script:offlineSignIns = 0
        Assert-Equal (Get-EntraCredential -Settings $credentialSettings -Context interactive).token $validToken 'Interactive consent/MFA recovers once'
        Assert-Equal $script:offlineSignIns 1 'Exactly one interactive sign-in'
        $script:offlineSignIns = 0
        Assert-Fails { Get-EntraCredential -Settings $credentialSettings -Context background } 'Gateway token acquisition failed'
        Assert-Equal $script:offlineSignIns 0 'Background helper never opens sign-in'
    }
    $code = '700016'
    $script:offlineSignIns = 0
    Assert-Fails { Get-EntraCredential -Settings $credentialSettings -Context interactive } 'Gateway token acquisition failed'
    Assert-Equal $script:offlineSignIns 0 'Nonrecoverable failures do not open sign-in'
}

& {
    $previousCache = $env:AZURE_CONFIG_DIR
    $expectedCache = Join-Path ([IO.Path]::GetTempPath()) 'offline saved Azure cache'
    $credentialSettings = [pscustomobject]@{
        TenantId = '22222222-2222-2222-2222-222222222222'; AzureCliPath = 'offline-az'; AzureConfigDir = $expectedCache
    }
    function Invoke-NativeCapture {
        param($FilePath, $Arguments)
        Assert-Equal $env:AZURE_CONFIG_DIR $expectedCache 'Token uses saved Azure cache'
        return [pscustomobject]@{ ExitCode = 0; Output = 'offline-token' }
    }
    function Start-Process {
        Assert-Equal $env:AZURE_CONFIG_DIR $expectedCache 'Sign-in child inherits saved Azure cache'
        return [pscustomobject]@{ ExitCode = 0 }
    }
    try {
        $env:AZURE_CONFIG_DIR = 'offline inherited cache'
        Assert-Equal (Get-GatewayTokenResult -Settings $credentialSettings).Output 'offline-token' 'Token lookup succeeds'
        Assert-Equal $env:AZURE_CONFIG_DIR 'offline inherited cache' 'Token lookup restores caller environment'
        Start-EntraSignIn -Settings $credentialSettings
        Assert-Equal $env:AZURE_CONFIG_DIR 'offline inherited cache' 'Sign-in restores caller environment'
        Assert-Fails {
            Invoke-WithAzureConfig -Settings $credentialSettings -Action { throw 'offline Azure failure' }
        } 'offline Azure failure'
        Assert-Equal $env:AZURE_CONFIG_DIR 'offline inherited cache' 'Failed commands restore caller environment'
        foreach ($invalidCache in @('relative-cache', '\root-relative', '', $null, 123)) {
            $credentialSettings.AzureConfigDir = $invalidCache
            Assert-Fails { Get-GatewayTokenResult -Settings $credentialSettings } 'must be an absolute path'
        }
        $credentialSettings.PSObject.Properties.Remove('AzureConfigDir')
        Assert-Equal (Invoke-WithAzureConfig -Settings $credentialSettings -Action { $env:AZURE_CONFIG_DIR }) `
            'offline inherited cache' 'Older helper settings retain inherited cache behavior'
    } finally {
        $env:AZURE_CONFIG_DIR = $previousCache
    }
}

& {
    $currentPackage = [pscustomobject]@{ Version = '6.6395.0'; PackageFullName = 'offline-current-msix' }
    $oldPackage = [pscustomobject]@{ Version = '1.8000.0'; PackageFullName = 'offline-old-msix' }
    $cases = @(
        @{ Name = 'Healthy rerun'; Packages = @($currentPackage); Calls = 0 },
        @{ Name = 'First installation'; Packages = @($null, $currentPackage); Calls = 1 },
        @{ Name = 'Normal update'; Packages = @($oldPackage, $currentPackage); Calls = 1 },
        @{ Name = 'Existing non-MSIX installation'; Packages = @($null, $null, $currentPackage); Calls = 2 },
        @{ Name = 'Old MSIX not updated'; Packages = @($oldPackage, $oldPackage, $currentPackage); Calls = 2 },
        @{ Name = 'Missing registration after repair'; Packages = @($null, $null, $null); Calls = 2;
            Failure = 'MSIX is not registered' },
        @{ Name = 'Old version after repair'; Packages = @($oldPackage, $oldPackage, $oldPackage); Calls = 2;
            Failure = 'version 1.8555.0.0 or newer is required' },
        @{ Name = 'Installer failure'; Packages = @($null); Calls = 1; FailAt = 1;
            Failure = 'offline installer failure' },
        @{ Name = 'Repair installer failure'; Packages = @($null, $null); Calls = 2; FailAt = 2;
            Failure = 'offline installer failure' }
    )
    function Get-ClaudePackage { return $case.Packages[$installCalls.Count] }
    function Get-WinGetPath { return 'offline-winget' }
    function Invoke-NativeCapture {
        param($FilePath, $Arguments)
        Assert-Equal $FilePath 'offline-winget' 'Desktop uses the mocked installer'
        Assert-Equal ($Arguments -contains 'Anthropic.Claude') $true 'Repair targets only Claude Desktop'
        Assert-Equal $Arguments[[Array]::IndexOf($Arguments, '--installer-type') + 1] 'msix' 'MSIX is explicitly selected'
        Assert-Equal $Arguments[[Array]::IndexOf($Arguments, '--architecture') + 1] `
            $architecture.ToLowerInvariant() 'Installer uses the native architecture'
        Assert-Equal ($Arguments -contains '--force') ($installCalls.Count -eq 1) 'Only the bounded repair is forced'
        $installCalls.Add([pscustomobject]@{ Arguments = @($Arguments) })
        if ($case.FailAt -eq $installCalls.Count) {
            return [pscustomobject]@{ ExitCode = 1603; Output = 'offline installer failure' }
        }
        return [pscustomobject]@{ ExitCode = 0x8A15002B; Output = 'Already installed; no applicable update' }
    }
    foreach ($architecture in @('X64', 'Arm64')) {
        foreach ($case in $cases) {
            $installCalls = New-Object 'Collections.Generic.List[object]'
            if ($case.Failure) {
                Assert-Fails { Ensure-ClaudeDesktop -Architecture $architecture } $case.Failure
            } else {
                Assert-Equal (Ensure-ClaudeDesktop -Architecture $architecture).PackageFullName `
                    $currentPackage.PackageFullName "$($case.Name): returns the verified MSIX"
                if ($case.Calls -eq 2) {
                    Assert-Equal (Ensure-ClaudeDesktop -Architecture $architecture).PackageFullName `
                        $currentPackage.PackageFullName 'Repaired installation is reused on rerun'
                }
            }
            Assert-Equal $installCalls.Count $case.Calls "$($case.Name): installation attempts are bounded"
        }
    }
}

$script:root = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/demo/providers/Microsoft.ApiManagement/aigateways/example'
$script:scope = "$root/workspaces/default"
$script:hostUrl = 'https://example.ai.gateway.azure.com'
$settings = [pscustomobject]@{
    TenantId = '22222222-2222-2222-2222-222222222222'
    GatewayBaseUrl = "$hostUrl/default/models/anthropic"
    AzureCliPath = 'az'
    AzureConfigDir = Join-Path ([IO.Path]::GetTempPath()) 'offline catalog cache'
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
    Assert-Equal $env:AZURE_CONFIG_DIR $settings.AzureConfigDir 'Catalog uses saved Azure cache'
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
    $claims = @{ tid = $settings.TenantId; aud = 'https://azure-api.net/aigateway';
        scp = 'Data.All'; exp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600 }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $helperToken = 'header.' + $payload + '.signature'
    $fakeCli = Join-Path $temp 'offline azure.cmd'
    $fakeCommand = "@echo off`r`nif not `"%AZURE_CONFIG_DIR%`"==`"$($settings.AzureConfigDir)`" exit /b 19`r`necho $helperToken`r`nexit /b 0`r`n"
    [IO.File]::WriteAllText($fakeCli, $fakeCommand, [Text.Encoding]::ASCII)
    $helperSettings = [pscustomobject]@{
        TenantId = $settings.TenantId; GatewayBaseUrl = $settings.GatewayBaseUrl;
        AzureCliPath = $fakeCli; AzureConfigDir = $settings.AzureConfigDir; ConfigId = $settings.ConfigId
    }
    $helpers = Install-GatewayHelpers -Settings $helperSettings -InstallRoot (Join-Path $temp 'helpers with spaces') `
        -ScriptPath (Join-Path $repo 'onboard-claude-gateway.ps1')
    $previousExecutionPolicy = $env:PSExecutionPolicyPreference
    try {
        foreach ($executionPolicy in @('Restricted', 'RemoteSigned')) {
            $env:PSExecutionPolicyPreference = $executionPolicy
            $desktopResult = & $originalNativeCapture -FilePath $helpers.Desktop -Arguments @()
            Assert-Equal $desktopResult.ExitCode 0 "Desktop helper executes with inherited $executionPolicy policy"
            Assert-Equal ($desktopResult.Output | ConvertFrom-Json).token $helperToken 'Desktop helper returns JSON only'
            $codeResult = & $originalNativeCapture -FilePath $helpers.Code -Arguments @()
            Assert-Equal $codeResult.ExitCode 0 "Code helper executes with inherited $executionPolicy policy"
            Assert-Equal $codeResult.Output $helperToken 'Code helper returns only the token'
            Assert-Equal $env:PSExecutionPolicyPreference $executionPolicy 'Helpers do not change the caller policy'
        }
    } finally {
        $env:PSExecutionPolicyPreference = $previousExecutionPolicy
    }
    $desktopDir = Join-Path $temp 'desktop'
    Install-DesktopConfiguration -Settings $settings -InstallRoot $installRoot `
        -HelperPath 'C:\helpers\token.cmd' -ConfigDirectory $desktopDir | Out-Null
    $desktop = Read-JsonSettings -Path (Join-Path $desktopDir ($settings.ConfigId + '.json'))
    Assert-Equal ($desktop.inferenceModels.name -join ',') ($settings.Models -join ',') 'Desktop model list'
    $desktop | Add-Member inferenceCredentialHelperWindows 'C:\old-helper.cmd'
    $desktop | Add-Member inferenceCredentialHelperArgs @('--old-argument')
    $desktop | Add-Member inferenceCustomHeaders ([pscustomobject]@{ 'X-Routing' = 'preserved' })
    $desktopPath = Join-Path $desktopDir ($settings.ConfigId + '.json')
    Write-JsonFile -Path $desktopPath -Value $desktop
    Install-DesktopConfiguration -Settings $settings -InstallRoot $installRoot `
        -HelperPath 'C:\helpers\new-token.cmd' -ConfigDirectory $desktopDir | Out-Null
    $desktop = Read-JsonSettings -Path $desktopPath
    Assert-Equal $desktop.inferenceCredentialHelperWindows $null 'Stale Windows helper override removed'
    Assert-Equal $desktop.inferenceCredentialHelperArgs $null 'Old helper arguments removed'
    Assert-Equal $desktop.inferenceCredentialHelper 'C:\helpers\new-token.cmd' 'New helper is the effective Windows helper'
    Assert-Equal $desktop.inferenceCustomHeaders.'X-Routing' 'preserved' 'Routing headers preserved'
    foreach ($header in @('Authorization', 'API-Key', 'x-api-key')) {
        $desktop.inferenceCustomHeaders | Add-Member -NotePropertyName $header -NotePropertyValue 'offline-credential'
        Write-JsonFile -Path $desktopPath -Value $desktop
        $beforeHeaders = [Convert]::ToBase64String([IO.File]::ReadAllBytes($desktopPath))
        Assert-Fails {
            Install-DesktopConfiguration -Settings $settings -InstallRoot $installRoot `
                -HelperPath 'C:\helpers\new-token.cmd' -ConfigDirectory $desktopDir
        } 'Resolve credential headers'
        Assert-Equal ([Convert]::ToBase64String([IO.File]::ReadAllBytes($desktopPath))) $beforeHeaders 'Conflicting Desktop settings are not modified'
        $desktop.inferenceCustomHeaders.PSObject.Properties.Remove($header)
    }
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
& {
    $flowRoot = Join-Path ([IO.Path]::GetTempPath()) ('claude-onboarding-flows-' + [Guid]::NewGuid())
    $oldProfile = $env:USERPROFILE
    $oldAppData = $env:APPDATA
    $oldLocalAppData = $env:LOCALAPPDATA
    $oldAzureCache = $env:AZURE_CONFIG_DIR
    $oldTerminal = $env:TERM_PROGRAM
    function Get-CimInstance {
        param($ClassName, $Property, $Filter)
        switch ($ClassName) {
            'Win32_OperatingSystem' { return [pscustomobject]@{ BuildNumber = 22631 } }
            'Win32_Processor' { return [pscustomobject]@{ Architecture = 12 } }
            'Win32_OptionalFeature' { return [pscustomobject]@{ InstallState = 1 } }
            'Win32_ComputerSystem' { return [pscustomobject]@{ HypervisorPresent = $true } }
            default { throw "Unexpected CIM request: $ClassName" }
        }
    }
    function Assert-NoManagedInferencePolicy {}
    function Assert-NoManagedCodePolicy {}
    function Ensure-AzureCli { return 'offline-az' }
    function Get-EntraCredential {
        param($Settings, $Context)
        Assert-Equal $Settings.AzureConfigDir $expectedCache 'Onboarding records the correct Azure cache'
        return @{ token = 'offline-token' }
    }
    function Get-GatewayModelCatalog {
        return [pscustomobject]@{ Alias = 'provider/claude-sonnet-5'; ModelNames = @('claude-sonnet-5') }
    }
    function Ensure-ClaudeDesktop { return [pscustomobject]@{ PackageFullName = 'offline-package'; PackageFamilyName = 'offline-family' } }
    function Get-AppxPackageManifest {
        return [pscustomobject]@{ Package = [pscustomobject]@{ Applications = [pscustomobject]@{
            Application = @([pscustomobject]@{ Executable = 'Claude.exe'; Id = 'Claude' })
        } } }
    }
    function Ensure-CodeClient { param($Name); return "C:\offline\$Name.exe" }
    function Ensure-ClaudeCodeExtension {}
    function Wait-ForClaudeToClose {}
    function Wait-ForCodeClientsToClose {}
    function Start-Process {
        param($FilePath, $ArgumentList)
        Assert-Equal $FilePath 'explorer.exe' 'Only the final Desktop launch is requested'
    }
    function Install-WinGetPackage { throw 'Offline flows must never install software' }
    function Invoke-WebRequest { throw 'Offline flows must never call a model or management endpoint' }
    function Invoke-NativeCapture { throw 'Offline flows must never launch Azure CLI' }
    try {
        $env:TERM_PROGRAM = $null
        foreach ($selection in @('Desktop', 'CLI', 'VSCode', 'All')) {
            $flowHome = Join-Path $flowRoot $selection
            $env:USERPROFILE = $flowHome
            $env:APPDATA = Join-Path $flowHome 'AppData\Roaming'
            $env:LOCALAPPDATA = Join-Path $flowHome 'AppData\Local'
            $expectedCache = if ($selection -eq 'Desktop') { Join-Path $flowHome '.azure' } else { Join-Path $flowHome 'custom Azure cache' }
            $env:AZURE_CONFIG_DIR = if ($selection -eq 'Desktop') { $null } else { $expectedCache }
            $clients = @(Resolve-OnboardingClients -Selection $selection)
            $configId = $null
            foreach ($run in @(1, 2)) {
                $exitCode = Start-DeveloperOnboarding -Tenant ([Guid]'22222222-2222-2222-2222-222222222222') `
                    -BaseUrl 'https://example.ai.gateway.azure.com' -SourceScript (Join-Path $repo 'onboard-claude-gateway.ps1') `
                    -Clients $clients 6>$null
                Assert-Equal $exitCode 0 "$selection setup/rerun succeeds"
                $savedPath = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'ClaudeGatewayEntra') -Filter 'gateway-settings.json' -Recurse)
                Assert-Equal $savedPath.Count 1 'One helper configuration per tenant and endpoint'
                $saved = Read-JsonSettings -Path $savedPath[0].FullName
                Assert-Equal $saved.AzureConfigDir $expectedCache 'Helper persists default/custom Azure cache'
                if ($configId) { Assert-Equal $saved.ConfigId $configId 'Rerun retains existing configuration ID' }
                $configId = $saved.ConfigId
                if ($clients -contains 'Desktop') {
                    $meta = Read-DesktopMetadata -Path (Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary\_meta.json')
                    Assert-Equal $meta.entries.Count 1 'Rerun does not duplicate Desktop configuration'
                    Assert-Equal $meta.appliedId $configId 'Expected Desktop configuration is active'
                }
                $codePath = Join-Path $flowHome '.claude\settings.json'
                Assert-Equal (Test-Path -LiteralPath $codePath) ($selection -ne 'Desktop') 'Desktop-only leaves Code settings untouched'
                if ($selection -ne 'Desktop') {
                    Assert-Equal (Read-JsonSettings -Path $codePath).availableModels[0] 'provider/claude-sonnet-5' 'Code flow saves discovered model'
                }
            }
        }
    } finally {
        $env:USERPROFILE = $oldProfile
        $env:APPDATA = $oldAppData
        $env:LOCALAPPDATA = $oldLocalAppData
        $env:AZURE_CONFIG_DIR = $oldAzureCache
        $env:TERM_PROGRAM = $oldTerminal
        if (Test-Path -LiteralPath $flowRoot) { Remove-Item -LiteralPath $flowRoot -Recurse -Force }
    }
}
Write-Output 'Windows authentication, cache, discovery, configuration, rollback, and setup/rerun flow checks passed.'
