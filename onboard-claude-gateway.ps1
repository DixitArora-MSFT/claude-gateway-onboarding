#requires -Version 5.1
<#
.SYNOPSIS
Sets up Claude clients to use an Azure AI Gateway with Entra authentication.
.DESCRIPTION
Run without -Credential for onboarding. Desktop uses -Credential through the
generated CMD wrapper to retrieve JSON. CLI and VS Code use -CodeCredential
to retrieve a plain token without running setup or opening sign-in.
Setup does not send inference requests unless -VerifyModels is supplied.
.EXAMPLE
powershell.exe -NoProfile -File .\onboard-claude-gateway.ps1
#>
[CmdletBinding()]
param(
    [switch]$Credential,
    [switch]$CodeCredential,
    [ValidateSet('Desktop', 'CLI', 'VSCode', 'All')]
    [string]$Client,
    [Guid]$TenantId = [Guid]::Empty,
    [string]$GatewayBaseUrl,
    [switch]$VerifyModels
)

$ErrorActionPreference = 'Stop'

function Resolve-OnboardingClients {
    param([string]$Selection)

    if (-not $Selection) {
        $Selection = Read-Host 'Choose client: Desktop (default), CLI, VSCode, or All'
        if ([string]::IsNullOrWhiteSpace($Selection)) {
            $Selection = 'Desktop'
        }
    }
    switch ($Selection.Trim()) {
        'Desktop' { return @('Desktop') }
        'CLI' { return @('CLI') }
        'VSCode' { return @('VSCode') }
        'All' { return @('Desktop', 'CLI', 'VSCode') }
        default { throw 'Choose Desktop, CLI, VSCode, or All.' }
    }
}

function Resolve-OnboardingInputs {
    param(
        [Guid]$Tenant,
        [string]$BaseUrl
    )

    if ($Tenant -eq [Guid]::Empty) {
        $Tenant = [Guid](Read-Host 'Enter the customer gateway Directory (tenant) ID')
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        $BaseUrl = Read-Host 'Enter the gateway runtime URL from AI Gateway Home'
    }
    return [pscustomobject]@{
        TenantId = $Tenant
        GatewayBaseUrl = $BaseUrl.Trim()
    }
}

function Resolve-GatewayBaseUrl {
    param([string]$BaseUrl)

    $uri = [Uri]$BaseUrl.Trim()
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
        $uri.Host -notmatch '^[a-z0-9.-]+\.ai\.gateway\.azure\.com$' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        ($uri.AbsolutePath.TrimEnd('/') -and $uri.AbsolutePath.TrimEnd('/') -notlike '*/models/anthropic')) {
        throw 'Use the dedicated AI Gateway HTTPS runtime URL or Anthropic base URL on port 443, with no credentials, query, or fragment.'
    }
    $resolved = $uri.AbsoluteUri.TrimEnd('/')
    if (-not $uri.AbsolutePath.Trim('/')) { $resolved += '/default/models/anthropic' }
    return $resolved
}

function Resolve-CodeModelMapping {
    param([object[]]$Catalog)

    $mapping = [ordered]@{}
    foreach ($family in @('Opus', 'Sonnet', 'Haiku')) {
        $pattern = '(?i)(^|[._-])' + $family + '($|[._-])'
        $match = $Catalog | Where-Object { @($_.ModelNames | Where-Object { $_ -match $pattern }).Count } |
            Select-Object -First 1
        if ($match) {
            $mapping[$family] = $match.Alias
        }
    }
    return $mapping
}

function Invoke-GatewayCatalogRequest {
    param([string]$Uri, [string]$Token, $Body)

    $target = [Uri]$Uri
    if ($target.Scheme -ne 'https' -or $target.Host -ne 'management.azure.com' -or
        $target.Port -ne 443 -or $target.UserInfo -or $target.Fragment) {
        throw 'The gateway catalog returned an invalid Azure management URL.'
    }
    $arguments = @{
        Uri = $Uri; UseBasicParsing = $true; TimeoutSec = 30; MaximumRedirection = 0
        Headers = @{ Authorization = "Bearer $Token" }
        Method = 'Get'
    }
    if ($null -ne $Body) {
        $arguments.Method = 'Post'
        $arguments.ContentType = 'application/json'
        $arguments.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        $response = Invoke-WebRequest @arguments
        $document = $response.Content | ConvertFrom-Json
        if ($document -isnot [pscustomobject]) { throw 'The gateway catalog returned an invalid object.' }
        return $document
    }
    catch {
        throw ('Cannot read the AI Gateway catalog. Your account needs gateway catalog read access ' +
            'as well as AI Gateway Models User permission. No models were guessed. ' + $_.Exception.Message)
    }
}

function Get-GatewayCatalogItems {
    param([string]$Uri, [string]$Token, [string]$Scope)

    $seen = New-Object 'Collections.Generic.HashSet[string]'
    while ($Uri) {
        if (-not ([Uri]$Uri).AbsolutePath.StartsWith($Scope + '/', [StringComparison]::OrdinalIgnoreCase) -or
            -not $seen.Add($Uri)) {
            throw 'The gateway catalog returned an invalid or repeated pagination URL.'
        }
        $page = Invoke-GatewayCatalogRequest -Uri $Uri -Token $Token
        if ($null -eq $page.value -or $page.value -isnot [Array] -or
            @($page.value | Where-Object { $_ -isnot [pscustomobject] }).Count) {
            throw 'The gateway catalog returned an invalid list response.'
        }
        $page.value
        $Uri = $page.nextLink
    }
}

function Test-GatewayModelInvocation {
    param([object[]]$Permissions)

    foreach ($permission in $Permissions) {
        if ($permission -isnot [pscustomobject]) { throw 'The gateway returned invalid model permissions.' }
        foreach ($field in @('dataActions', 'notDataActions')) {
            $value = $permission.$field
            if ($null -ne $value -and ($value -isnot [Array] -or
                @($value | Where-Object { $_ -isnot [string] }).Count)) {
                throw 'The gateway returned invalid model permissions.'
            }
        }
        foreach ($action in @(
            'Microsoft.ApiManagement/service/workspaces/models/invoke/action',
            'Microsoft.ApiManagement/aigateways/models/invoke/action'
        )) {
            $allowed = @($permission.dataActions | Where-Object { $action -like $_ }).Count -gt 0
            $excluded = @($permission.notDataActions | Where-Object { $action -like $_ }).Count -gt 0
            if ($allowed -and -not $excluded) { return $true }
        }
    }
    return $false
}

function Get-GatewayModelCatalog {
    param($Settings)

    $result = Invoke-NativeCapture -FilePath $Settings.AzureCliPath -Arguments @(
        'account', 'get-access-token', '--tenant', $Settings.TenantId,
        '--resource', 'https://management.azure.com', '--query', 'accessToken',
        '--output', 'tsv', '--only-show-errors'
    )
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        throw 'Cannot acquire an Azure management token for automatic model discovery. Check sign-in and gateway catalog read access.'
    }
    $token = $result.Output
    $endpoint = [Uri]$Settings.GatewayBaseUrl
    $hostUrl = $endpoint.GetLeftPart([UriPartial]::Authority)
    $query = "Resources | where type in~ ('microsoft.apimanagement/aigateways', 'microsoft.apimanagement/service')" +
        " | where tostring(properties.gatewayUrl) =~ '$hostUrl' or tostring(properties.frontend.defaultHostname) =~ '$($endpoint.Host)'" +
        ' | project id'
    $lookup = Invoke-GatewayCatalogRequest -Token $token `
        -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
        -Body @{ query = $query; options = @{ resultFormat = 'objectArray'; allowPartialScopes = $true; '$top' = 2 } }
    if (@($lookup.data).Count -ne 1 -or -not $lookup.data[0].id) {
        throw 'Cannot uniquely find this gateway from its URL. Check the URL and gateway read access, or allow time for Azure Resource Graph indexing.'
    }
    $root = [string]$lookup.data[0].id
    if ($root -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/?#]+/providers/Microsoft\.ApiManagement/(aigateways|service)/[^/?#]+$') {
        throw 'Discovery returned an invalid gateway resource ID.'
    }
    $version = '2025-09-01-preview'
    $gateway = Invoke-GatewayCatalogRequest -Token $token -Uri "https://management.azure.com${root}?api-version=$version"
    if (([string]$gateway.properties.gatewayUrl).TrimEnd('/') -ne $hostUrl -and
        $gateway.properties.frontend.defaultHostname -ne $endpoint.Host) {
        throw 'The current gateway hostname does not match the supplied URL. Azure Resource Graph might still be indexing a change.'
    }
    $workspace = $endpoint.AbsolutePath.TrimEnd('/').Split('/')[-3]
    $scope = "$root/workspaces/$workspace"
    $aliases = @(Get-GatewayCatalogItems -Token $token -Scope $scope `
        -Uri "https://management.azure.com$scope/aliases?api-version=$version")
    $seenAliases = New-Object 'Collections.Generic.HashSet[string]'
    $models = @{}
    $catalog = @()
    foreach ($entry in $aliases) {
        if ($entry.properties -isnot [pscustomobject] -or $entry.properties.supportedEndpoints -isnot [Array] -or
            @($entry.properties.supportedEndpoints | Where-Object { $_ -isnot [string] }).Count) {
            throw 'The gateway returned invalid alias endpoint metadata.'
        }
        if (@($entry.properties.supportedEndpoints) -cnotcontains '/anthropic/v1/messages') { continue }
        $alias = [string]$entry.properties.aliasName
        if ($alias -cnotmatch '^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$' -or
            -not $seenAliases.Add($alias) -or
            -not ([string]$entry.id).StartsWith("$scope/aliases/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The gateway returned an invalid or duplicate callable alias.'
        }
        $permissions = @(Get-GatewayCatalogItems -Token $token -Scope $scope `
            -Uri "https://management.azure.com$($entry.id)/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
        if (-not (Test-GatewayModelInvocation -Permissions $permissions)) { continue }
        $names = @()
        if ($entry.properties.backendModels -isnot [Array] -or -not $entry.properties.backendModels.Count) {
            throw 'A published gateway alias has no valid backend model list.'
        }
        foreach ($backend in @($entry.properties.backendModels)) {
            $id = [string]$backend.resourceId
            if (-not $id.StartsWith("$scope/modelProviders/", [StringComparison]::OrdinalIgnoreCase) -or
                $id.Substring($scope.Length) -notmatch '^/modelProviders/[^/?#]+/models/[^/?#]+$') {
                throw 'The gateway alias contains an invalid backend model reference.'
            }
            if (-not $models.ContainsKey($id)) {
                $model = Invoke-GatewayCatalogRequest -Token $token -Uri "https://management.azure.com${id}?api-version=$version"
                if ($model.properties.deployment.modelName -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($model.properties.deployment.modelName)) {
                    throw 'A gateway backend is missing its model identity; discovery cannot safely classify it.'
                }
                $models[$id] = [string]$model.properties.deployment.modelName
            }
            $names += $models[$id]
        }
        if (-not $names.Count) { throw 'A published gateway alias has no backend model.' }
        if (@($names | Where-Object { $_ -notmatch '(?i)^claude([._-]|$)' }).Count) { continue }
        $catalog += [pscustomobject]@{ Alias = $alias; ModelNames = $names }
    }
    if (-not $catalog.Count) {
        throw 'No permitted Claude models were found. Check published Anthropic aliases and your AI Gateway Models User assignments.'
    }
    return $catalog
}

function Invoke-NativeCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    $lines = & $command.Source @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) {
        throw "Could not start executable: $FilePath"
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($lines | Out-String).Trim()
    }
}

function Get-AzureCliPath {
    $command = Get-Command az -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            $candidate = Join-Path $root 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    return $null
}

function Get-ClaudePackage {
    $packages = @(Get-AppxPackage -Name Claude | Where-Object {
        $_.PackageFamilyName -eq 'Claude_pzs8sxrjxfjjc' -and -not $_.IsFramework
    } | Sort-Object { [Version]$_.Version } -Descending)
    if ($packages.Count) {
        return $packages[0]
    }
    return $null
}

function Get-WinGetPath {
    $command = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    Write-Host 'Installing the missing Windows Package Manager using Microsoft.WinGet.Client...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
    }
    if (-not (Get-Module -Name Microsoft.WinGet.Client -ListAvailable)) {
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope CurrentUser -Force
    }
    Import-Module Microsoft.WinGet.Client
    Repair-WinGetPackageManager | Out-Null
    $command = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return $command.Source
    }

    $candidate = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    throw 'Windows Package Manager could not be installed. Ask IT to check App Installer and installation policy.'
}

function Install-WinGetPackage {
    param(
        [string]$PackageId,
        [string[]]$AdditionalArguments
    )

    $winget = Get-WinGetPath
    Write-Host "Installing $PackageId automatically. Windows may display a required UAC prompt."
    $arguments = @(
        'install', '--id', $PackageId, '--exact', '--source', 'winget',
        '--silent', '--accept-source-agreements', '--accept-package-agreements',
        '--disable-interactivity'
    ) + $AdditionalArguments
    $result = Invoke-NativeCapture -FilePath $winget -Arguments $arguments
    if ($result.ExitCode -in @(3010, 0x8A150109, 0x8A15010A)) {
        throw "Installation of $PackageId requires a Windows restart. Save work, restart manually, and rerun onboarding."
    }
    if ($result.ExitCode -in @(0x8A15002B, 0x8A150061, 0x8A15010D)) {
        Write-Host "$PackageId is already installed or has no applicable update. Checking the installed version before continuing."
    } elseif ($result.ExitCode -ne 0) {
        throw "Installation of $PackageId failed (exit $($result.ExitCode)): $($result.Output)"
    }
}

function Ensure-AzureCli {
    param(
        [string]$Architecture,
        [int]$WindowsBuild
    )

    $path = Get-AzureCliPath
    if (-not $path) {
        $installerArchitecture = 'x64'
        if ($Architecture -eq 'Arm64' -and $WindowsBuild -lt 22000) {
            $installerArchitecture = 'x86'
        }
        Install-WinGetPackage -PackageId Microsoft.AzureCLI -AdditionalArguments @('--architecture', $installerArchitecture)
        $path = Get-AzureCliPath
    }
    if (-not $path) {
        throw 'Azure CLI installation did not produce a usable executable.'
    }

    $help = Invoke-NativeCapture -FilePath $path -Arguments @('login', '--help')
    if ($help.ExitCode -ne 0 -or $help.Output -notmatch '--skip-subscription-discovery') {
        Install-WinGetPackage -PackageId Microsoft.AzureCLI
        $path = Get-AzureCliPath
        if (-not $path) {
            throw 'Azure CLI is missing after the update. Ask IT to check the installation.'
        }
        $help = Invoke-NativeCapture -FilePath $path -Arguments @('login', '--help')
        if ($help.ExitCode -ne 0 -or $help.Output -notmatch '--skip-subscription-discovery') {
            throw 'Azure CLI does not support the required tenant-only login. Ask IT to update it.'
        }
    }
    return $path
}

function Ensure-ClaudeDesktop {
    param([string]$Architecture)

    $package = Get-ClaudePackage
    if (-not $package -or [Version]$package.Version -lt [Version]'1.8555.0.0') {
        Install-WinGetPackage -PackageId Anthropic.Claude -AdditionalArguments @(
            '--installer-type', 'msix', '--architecture', $Architecture.ToLowerInvariant()
        )
        $package = Get-ClaudePackage
    }
    if (-not $package) {
        throw 'Claude Desktop MSIX is not registered for this Windows account after installation.'
    }
    if ([Version]$package.Version -lt [Version]'1.8555.0.0') {
        throw 'Claude Desktop MSIX version 1.8555.0.0 or newer is required. Ask IT to check the update.'
    }
    return $package
}

function Get-CodeClientPath {
    param([ValidateSet('claude', 'code')][string]$Name, [Version]$Minimum)

    $candidates = @(Get-Command $Name -CommandType Application -All -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Source })
    $candidates += if ($Name -eq 'claude') {
        @(
            (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\claude.exe')
        )
    } else {
        @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
            (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd')
        )
    }
    foreach ($path in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            if (-not $Minimum -or (Test-CodeClientVersion -Path $path -Minimum $Minimum)) {
                return $path
            }
        }
    }
    return $null
}

function Test-CodeClientVersion {
    param([string]$Path, [Version]$Minimum)

    $result = Invoke-NativeCapture -FilePath $Path -Arguments @('--version')
    return $result.ExitCode -eq 0 -and $result.Output -match '(?m)^(\d+\.\d+\.\d+)' -and [Version]$Matches[1] -ge $Minimum
}

function Ensure-CodeClient {
    param([ValidateSet('claude', 'code')][string]$Name, [string]$Architecture)

    $minimum = if ($Name -eq 'claude') { [Version]'2.1.246' } else { [Version]'1.94.0' }
    $path = Get-CodeClientPath -Name $Name -Minimum $minimum
    if (-not $path -or -not (Test-CodeClientVersion -Path $path -Minimum $minimum)) {
        $packageId = if ($Name -eq 'claude') { 'Anthropic.ClaudeCode' } else { 'Microsoft.VisualStudioCode' }
        Install-WinGetPackage -PackageId $packageId -AdditionalArguments @('--architecture', $Architecture.ToLowerInvariant())
        $path = Get-CodeClientPath -Name $Name -Minimum $minimum
    }
    if (-not $path -or -not (Test-CodeClientVersion -Path $path -Minimum $minimum)) {
        throw "$Name version $minimum or newer is required. Ask IT to check the installation."
    }
    return $path
}

function Ensure-ClaudeCodeExtension {
    param([string]$CodePath)

    $result = Invoke-NativeCapture -FilePath $CodePath -Arguments @('--list-extensions', '--show-versions')
    if ($result.ExitCode -ne 0) {
        throw "Cannot list VS Code extensions: $($result.Output)"
    }
    if ($result.Output -notmatch '(?im)^anthropic\.claude-code@(\d+\.\d+\.\d+)\s*$' -or [Version]$Matches[1] -lt [Version]'2.1.246') {
        $result = Invoke-NativeCapture -FilePath $CodePath -Arguments @('--install-extension', 'anthropic.claude-code', '--force')
        if ($result.ExitCode -ne 0) {
            throw "Claude Code extension installation failed: $($result.Output)"
        }
        $result = Invoke-NativeCapture -FilePath $CodePath -Arguments @('--list-extensions', '--show-versions')
    }
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch '(?im)^anthropic\.claude-code@(\d+\.\d+\.\d+)\s*$' -or
        [Version]$Matches[1] -lt [Version]'2.1.246') {
        throw 'Claude Code extension version 2.1.246 or newer is required in the default local VS Code profile.'
    }
}

function Ensure-WorkspaceFeature {
    $feature = @(Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'")
    if ($feature.Count -ne 1) {
        throw 'Cannot determine Virtual Machine Platform state. Ask IT to check Windows optional features.'
    }

    $hypervisor = (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    # ARM64 firmware capabilities are not reliably represented by these x86 WMI fields.
    if (-not $hypervisor -and $architecture -ne 'Arm64') {
        $processors = @(Get-CimInstance -ClassName Win32_Processor)
        if ($processors.Count -eq 0 -or @($processors | Where-Object { $_.VirtualizationFirmwareEnabled -ne $true }).Count) {
            throw 'Hardware virtualization is not reported as enabled. IT must enable/support virtualization; a PowerShell installer cannot change firmware safely.'
        }
    }
    if ($feature[0].InstallState -eq 1) {
        return [pscustomobject]@{ RestartNeeded = -not $hypervisor }
    }

    Write-Host 'Enabling Virtual Machine Platform. Windows administrator approval may be required; no restart will be performed.'
    $resultFile = [IO.Path]::GetTempFileName()
    $escapedResult = $resultFile.Replace("'", "''")
    $command = @'
$ErrorActionPreference = 'Stop'
try {
    $feature = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform
    if ($feature.State -eq 'EnablePending') {
        $restartNeeded = $true
    } elseif ($feature.State -eq 'Enabled') {
        $restartNeeded = $false
    } else {
        $result = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart
        $restartNeeded = [bool]$result.RestartNeeded
    }
    @{ Success = $true; RestartNeeded = $restartNeeded } | ConvertTo-Json | Set-Content -LiteralPath '__RESULT_FILE__' -Encoding UTF8
    exit 0
} catch {
    @{ Success = $false; Error = $_.Exception.Message } | ConvertTo-Json | Set-Content -LiteralPath '__RESULT_FILE__' -Encoding UTF8
    exit 1
}
'@
    $command = $command.Replace('__RESULT_FILE__', $escapedResult)
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Verb RunAs -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) -Wait -PassThru
        $result = Get-Content -LiteralPath $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($process.ExitCode -ne 0 -or -not $result.Success) {
            throw "Virtual Machine Platform could not be enabled: $($result.Error)"
        }
        return [pscustomobject]@{ RestartNeeded = [bool]$result.RestartNeeded -or -not $hypervisor }
    }
    finally {
        if (Test-Path -LiteralPath $resultFile) {
            Remove-Item -LiteralPath $resultFile -Force
        }
    }
}

function Get-GatewayTokenResult {
    param($Settings)

    Invoke-NativeCapture -FilePath $Settings.AzureCliPath -Arguments @(
        'account', 'get-access-token', '--tenant', $Settings.TenantId,
        '--scope', 'https://azure-api.net/aigateway/Data.All',
        '--query', 'accessToken', '--output', 'tsv', '--only-show-errors'
    )
}

function Start-EntraSignIn {
    param($Settings)

    $cli = $Settings.AzureCliPath.Replace("'", "''")
    $tenant = ([Guid]$Settings.TenantId).ToString()
    [Console]::Error.WriteLine('Complete Microsoft sign-in in the Azure CLI window that opens.')
    $command = "`$global:LASTEXITCODE = `$null; & '$cli' login --tenant $tenant --allow-no-subscriptions --skip-subscription-discovery --scope https://azure-api.net/aigateway/Data.All --output none; if (`$null -eq `$global:LASTEXITCODE) { exit 1 }; exit `$global:LASTEXITCODE"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) -WindowStyle Normal -PassThru -Wait
    if ($process.ExitCode -ne 0) {
        throw "Entra sign-in was cancelled or failed (exit $($process.ExitCode))."
    }
}

function Get-EntraCredential {
    param(
        $Settings,
        [string]$Context
    )

    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $result = Get-GatewayTokenResult -Settings $Settings
        if ($result.ExitCode -ne 0) {
            $needsSignIn = $result.Output -match '(?i)AADSTS(?:50058|50076|50079|50173|70043|700082|700084|70008)\b|interaction_required|please run[^\r\n]*az login|not logged in|tenant[^\r\n]*not found in cloud'
            if ($needsSignIn -and $Context -eq 'interactive' -and $attempt -eq 0) {
                Start-EntraSignIn -Settings $Settings
                continue
            }
            throw ("Gateway token acquisition failed: " + $result.Output + ' Start a new Desktop session for sign-in, or ask your administrator to check consent and Entra policy.')
        }

        $token = $result.Output
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw 'Azure CLI returned an empty token.'
        }

        $parts = $token.Split('.')
        if ($parts.Length -ne 3) {
            throw 'Azure CLI did not return a JWT access token.'
        }

        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        $payload = $payload.PadRight($payload.Length + ((4 - $payload.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json

        if ($claims.tid -ne $Settings.TenantId) {
            throw 'Wrong Entra tenant in the returned token.'
        }
        if ($claims.aud -ne 'https://azure-api.net/aigateway') {
            throw 'Wrong gateway token audience.'
        }
        if (([string]$claims.scp -split ' ') -notcontains 'Data.All') {
            throw 'Required Data.All scope is missing.'
        }
        if ([long]$claims.exp -le ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 240)) {
            if ($Context -eq 'interactive' -and $attempt -eq 0) {
                Start-EntraSignIn -Settings $Settings
                continue
            }
            throw 'Gateway token expires too soon. Start a new session to sign in again.'
        }
        return @{ token = $token }
    }
    throw 'No valid gateway token was obtained after sign-in.'
}

function Test-GatewayModels {
    param(
        $Settings,
        [string]$Token
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($model in $Settings.Models) {
        $body = @{
            model = $model
            max_tokens = 16
            messages = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
        } | ConvertTo-Json -Depth 5 -Compress
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Method Post `
                -Uri ($Settings.GatewayBaseUrl.TrimEnd('/') + '/v1/messages') `
                -Headers @{ Authorization = "Bearer $Token"; 'anthropic-version' = '2023-06-01' } `
                -ContentType 'application/json' -Body $body -MaximumRedirection 0 -TimeoutSec 120
        }
        catch {
            throw "Gateway access test failed for $model. Verify AI Gateway Models User, alias availability, consent, and gateway quotas. $($_.Exception.Message)"
        }
        $message = $response.Content | ConvertFrom-Json
        if ([int]$response.StatusCode -ne 200 -or $message.type -ne 'message' -or @($message.content).Count -eq 0) {
            throw "Gateway returned an invalid inference response for $model."
        }
        Write-Host "Verified Entra inference: $model (HTTP 200, no API key)."
    }
}

function Assert-NoManagedInferencePolicy {
    $behaviorOnlyKeys = @(
        'disableAutoUpdates', 'autoUpdaterEnforcementHours', 'updateViaUpdatesHost',
        'relaunchEnforcementHours', 'configRecheckIntervalMinutes',
        'egressProxyUrl', 'egressProxyPacUrl'
    )
    foreach ($path in @('HKLM:\SOFTWARE\Policies\Claude', 'HKCU:\SOFTWARE\Policies\Claude')) {
        if (Test-Path -LiteralPath $path) {
            $key = Get-Item -LiteralPath $path
            $names = @($key.GetValueNames())
            if (@($names | Where-Object { $_ -notin $behaviorOnlyKeys }).Count) {
                throw "Existing managed Claude configuration at $path must be updated by IT; this script will not override it."
            }
        }
    }
}

function Wait-ForClaudeToClose {
    param($Package)

    $sessionId = (Get-Process -Id $PID).SessionId
    $root = $Package.InstallLocation.TrimEnd('\') + '\'
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    $notified = $false
    do {
        $processes = @(Get-Process -Name Claude -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -eq $sessionId -and $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
        })
        if (-not $processes.Count) {
            return
        }
        if (-not $notified) {
            Write-Host 'Save your work and fully quit Claude Desktop (including the tray icon). Onboarding will continue automatically; no process will be forcibly terminated.'
            $notified = $true
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Claude Desktop is still running. Quit it and rerun onboarding so it cannot overwrite the new settings.'
}

function Write-JsonFile {
    param(
        [string]$Path,
        $Value
    )

    $text = $Value | ConvertTo-Json -Depth 100
    Write-AtomicFile -Path $Path -Bytes ([Text.Encoding]::UTF8.GetBytes($text))
}

function Write-AtomicFile {
    param([string]$Path, [byte[]]$Bytes)

    $temporaryPath = $Path + '.' + [Guid]::NewGuid().ToString() + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $Bytes)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temporaryPath, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Invoke-ConfigurationUpdate {
    param([string[]]$Paths, [scriptblock]$Action)

    $snapshots = @($Paths | Select-Object -Unique | ForEach-Object {
        $exists = Test-Path -LiteralPath $_ -PathType Leaf
        if (-not $exists -and (Test-Path -LiteralPath $_)) {
            throw "A configuration file path is occupied by a directory: $_"
        }
        [pscustomobject]@{
            Path = $_
            Existed = $exists
            Bytes = $(if ($exists) { ,([IO.File]::ReadAllBytes($_)) } else { $null })
        }
    })
    try {
        & $Action
    }
    catch {
        $failure = $_
        $rollbackFailures = @()
        [array]::Reverse($snapshots)
        foreach ($snapshot in $snapshots) {
            try {
                if ($snapshot.Existed) {
                    $unchanged = (Test-Path -LiteralPath $snapshot.Path -PathType Leaf) -and
                        [Convert]::ToBase64String([IO.File]::ReadAllBytes($snapshot.Path)) -ceq
                        [Convert]::ToBase64String([byte[]]$snapshot.Bytes)
                    if (-not $unchanged) {
                        Write-AtomicFile -Path $snapshot.Path -Bytes $snapshot.Bytes
                    }
                } elseif (Test-Path -LiteralPath $snapshot.Path -PathType Leaf) {
                    Remove-Item -LiteralPath $snapshot.Path -Force
                }
            }
            catch {
                $rollbackFailures += $snapshot.Path
            }
        }
        if ($rollbackFailures.Count) {
            throw ("Configuration update failed: " + $failure.Exception.Message +
                ". Restore failed for: " + ($rollbackFailures -join ', ') + '. Ask IT to restore the saved backups.')
        }
        throw ("Configuration update failed; previous helper and client files were restored. " + $failure.Exception.Message)
    }
}

function Get-ModelLabel {
    param([string]$Model)

    if ($Model.EndsWith('/claude-opus-5')) {
        return 'Claude Opus 5'
    }
    if ($Model.EndsWith('/claude-opus-4-5')) {
        return 'Claude Opus 4.5'
    }
    return $Model
}

function Install-GatewayHelpers {
    param(
        $Settings,
        [string]$InstallRoot,
        [string]$ScriptPath
    )

    [IO.Directory]::CreateDirectory($InstallRoot) | Out-Null
    $installedScript = Join-Path $InstallRoot 'onboard-claude-gateway.ps1'
    if (-not [string]::Equals([IO.Path]::GetFullPath($ScriptPath), $installedScript, [StringComparison]::OrdinalIgnoreCase)) {
        Write-AtomicFile -Path $installedScript -Bytes ([IO.File]::ReadAllBytes($ScriptPath))
    }
    $wrapper = @'
@echo off
setlocal DisableDelayedExpansion
set "PSModulePath=%SystemRoot%\System32\WindowsPowerShell\v1.0\Modules"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -File "%~dp0onboard-claude-gateway.ps1" -Credential
exit /b %errorlevel%
'@
    $helperPath = Join-Path $InstallRoot 'credential-helper.cmd'
    Write-AtomicFile -Path $helperPath -Bytes ([Text.Encoding]::ASCII.GetBytes($wrapper))
    $codeHelperPath = Join-Path $InstallRoot 'code-credential-helper.cmd'
    Write-AtomicFile -Path $codeHelperPath -Bytes ([Text.Encoding]::ASCII.GetBytes($wrapper.Replace(' -Credential', ' -CodeCredential')))
    Write-JsonFile -Path (Join-Path $InstallRoot 'gateway-settings.json') -Value $Settings
    return [pscustomobject]@{ Desktop = $helperPath; Code = $codeHelperPath }
}

function Install-DesktopConfiguration {
    param($Settings, [string]$InstallRoot, [string]$HelperPath, [string]$ConfigDirectory)

    [IO.Directory]::CreateDirectory($ConfigDirectory) | Out-Null
    $configPath = Join-Path $ConfigDirectory ($Settings.ConfigId + '.json')
    $config = Read-JsonSettings -Path $configPath
    $gatewayValues = [ordered]@{
        inferenceProvider = 'gateway'
        inferenceGatewayBaseUrl = $Settings.GatewayBaseUrl
        inferenceGatewayAuthScheme = 'bearer'
        inferenceCredentialKind = 'helper-script'
        inferenceCredentialHelper = $helperPath
        inferenceCredentialHelperTtlSec = 180
        inferenceCredentialHelperTimeoutSec = 300
        modelDiscoveryEnabled = $false
        modelPrefer1mContext = $false
        inferenceModels = @($Settings.Models | ForEach-Object {
            @{ name = $_; labelOverride = (Get-ModelLabel -Model $_) }
        })
    }
    foreach ($entry in $gatewayValues.GetEnumerator()) {
        $config | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
    }
    $metaPath = Join-Path $ConfigDirectory '_meta.json'
    $meta = [pscustomobject]@{ appliedId = $null; entries = @() }
    if (Test-Path -LiteralPath $metaPath) {
        $meta = Read-DesktopMetadata -Path $metaPath
        $backupDirectory = Join-Path $InstallRoot 'backups'
        [IO.Directory]::CreateDirectory($backupDirectory) | Out-Null
        Copy-Item -LiteralPath $metaPath -Destination (Join-Path $backupDirectory ("_meta-" + [Guid]::NewGuid().ToString() + '.json'))
    }
    Backup-SettingsFile -Path $configPath -InstallRoot $InstallRoot
    Write-JsonFile -Path $configPath -Value $config
    $meta.entries = @($meta.entries | Where-Object { $_.id -ne $Settings.ConfigId }) + @(
        [pscustomobject]@{ id = $Settings.ConfigId; name = ('AI Gateway - Entra (' + ([Uri]$Settings.GatewayBaseUrl).Host + ')') }
    )
    $meta.appliedId = $Settings.ConfigId
    Write-JsonFile -Path $metaPath -Value $meta
    return $helperPath
}

function Read-DesktopMetadata {
    param([string]$Path)

    $meta = Read-JsonSettings -Path $Path
    if (-not $meta.PSObject.Properties['entries'] -or -not $meta.PSObject.Properties['appliedId'] -or
        $meta.entries -isnot [array] -or @($meta.entries | Where-Object {
            $null -eq $_ -or -not $_.id -or -not $_.name
        }).Count) {
        throw 'Existing Desktop configuration metadata has an unsupported shape; nothing will replace it.'
    }
    return $meta
}

function Read-JsonSettings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        if (Test-Path -LiteralPath $Path) {
            throw "A settings file path is occupied by a directory: $Path"
        }
        return [pscustomobject]@{}
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($null -eq $text) { $text = '' }
    # Keep strings intact while removing JSONC comments and trailing commas.
    $pattern = '"(?:\\.|[^"\\])*"|//[^\r\n]*|/\*[\s\S]*?\*/'
    $text = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value.StartsWith('"')) { return $match.Value }
        return [regex]::Replace($match.Value, '[^\r\n]', ' ')
    })
    $text = [regex]::Replace($text, '"(?:\\.|[^"\\])*"|,\s*(?=[}\]])', [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if ($match.Value.StartsWith('"')) { return $match.Value }
        return ''
    })
    if ([string]::IsNullOrWhiteSpace($text)) {
        return [pscustomobject]@{}
    }
    $settings = $text | ConvertFrom-Json
    if ($null -eq $settings -or $settings.GetType() -ne [System.Management.Automation.PSCustomObject]) {
        throw "Settings must contain a JSON object: $Path"
    }
    return $settings
}

function Backup-SettingsFile {
    param([string]$Path, [string]$InstallRoot)

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $directory = Join-Path $InstallRoot 'backups'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        $name = (Split-Path $Path -Leaf) + '.' + [Guid]::NewGuid().ToString() + '.bak'
        Copy-Item -LiteralPath $Path -Destination (Join-Path $directory $name)
    }
}

function Get-CodeGatewayEnvironment {
    param($Settings)

    $environment = [ordered]@{
        ANTHROPIC_BASE_URL = $Settings.GatewayBaseUrl
        CLAUDE_CODE_API_KEY_HELPER_TTL_MS = '180000'
    }
    foreach ($family in @('Opus', 'Sonnet', 'Haiku')) {
        if ($Settings.ModelMapping.$family) {
            $environment["ANTHROPIC_DEFAULT_$($family.ToUpperInvariant())_MODEL"] = $Settings.ModelMapping.$family
        }
    }
    return $environment
}

function Test-CodeProviderEnabled {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value.Trim() -notin @('0', 'false')
}

function Assert-CodeSettingsCompatible {
    param($Settings, [string]$Source)

    if ($Settings.PSObject.Properties['env'] -and
        ($null -eq $Settings.env -or $Settings.env.GetType() -ne [System.Management.Automation.PSCustomObject])) {
        throw "The env setting must be a JSON object: $Source"
    }
    $credentialHeaderPattern = '(?im)^\s*(Authorization|api-key|x-api-key)\s*:'
    if ($Settings.env.ANTHROPIC_CUSTOM_HEADERS -match $credentialHeaderPattern) {
        throw "Credential headers in $Source conflict with the Entra helper. Resolve them before onboarding."
    }
    foreach ($scope in @('Process', 'User', 'Machine')) {
        if ([Environment]::GetEnvironmentVariable('ANTHROPIC_CUSTOM_HEADERS', $scope) -match $credentialHeaderPattern) {
            throw "Credential headers in the $scope environment conflict with the Entra helper. Resolve them before onboarding."
        }
    }
    foreach ($name in @(
        'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
        'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
        'CLAUDE_CODE_USE_MANTLE', 'CLAUDE_CODE_USE_ANTHROPIC_AWS', 'CLAUDE_CONFIG_DIR'
    )) {
        $isProviderSwitch = $name -like 'CLAUDE_CODE_USE_*'
        $value = $Settings.env.$name
        if ($value -and (-not $isProviderSwitch -or (Test-CodeProviderEnabled -Value $value))) {
            throw "Conflicting $name in $Source. Remove or resolve it before gateway onboarding; existing credentials will not be deleted."
        }
        foreach ($scope in @('Process', 'User', 'Machine')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if ($value -and (-not $isProviderSwitch -or (Test-CodeProviderEnabled -Value $value))) {
                throw "Conflicting $name in the $scope environment. Resolve it before gateway onboarding."
            }
        }
    }
}

function Assert-NoManagedCodePolicy {
    $directory = Join-Path $env:ProgramFiles 'ClaudeCode'
    $fragments = Join-Path $directory 'managed-settings.d'
    if ((Test-Path -LiteralPath (Join-Path $directory 'managed-settings.json')) -or (
        (Test-Path -LiteralPath $fragments) -and @(Get-ChildItem -LiteralPath $fragments -Filter '*.json' -File).Count
    )) {
        throw 'Managed Claude Code settings must be updated by IT; onboarding will not override them.'
    }
    foreach ($path in @('HKLM:\SOFTWARE\Policies\ClaudeCode', 'HKCU:\SOFTWARE\Policies\ClaudeCode')) {
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).GetValueNames() -contains 'Settings') {
            throw "Managed Claude Code settings at $path must be updated by IT."
        }
    }
}

function Install-CodeConfiguration {
    param($Settings, [string]$InstallRoot, [string]$HelperPath)

    $directory = Join-Path $env:USERPROFILE '.claude'
    $path = Join-Path $directory 'settings.json'
    $config = Read-JsonSettings -Path $path
    Assert-CodeSettingsCompatible -Settings $config -Source $path
    if (-not $config.PSObject.Properties['env']) {
        $config | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($family in @('OPUS', 'SONNET', 'HAIKU')) {
        $config.env.PSObject.Properties.Remove("ANTHROPIC_DEFAULT_${family}_MODEL")
    }
    foreach ($entry in (Get-CodeGatewayEnvironment -Settings $Settings).GetEnumerator()) {
        $config.env | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
    }
    $config.env.PSObject.Properties.Remove('ANTHROPIC_MODEL')
    if ($HelperPath -match '["%!\r\n]') {
        throw 'The helper path contains characters unsupported by a CMD helper command.'
    }
    $config | Add-Member -NotePropertyName apiKeyHelper -NotePropertyValue ('"' + $HelperPath + '"') -Force
    $config | Add-Member -NotePropertyName model -NotePropertyValue $Settings.Models[0] -Force
    $config | Add-Member -NotePropertyName availableModels -NotePropertyValue @($Settings.Models) -Force
    $config | Add-Member -NotePropertyName enforceAvailableModels -NotePropertyValue $true -Force
    $config | Add-Member -NotePropertyName modelPicker -NotePropertyValue ([pscustomobject]@{
        replaceBuiltInOptions = $true
        options = @($Settings.Models | ForEach-Object { [pscustomobject]@{ model = $_; label = $_ } })
    }) -Force
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Backup-SettingsFile -Path $path -InstallRoot $InstallRoot
    Write-JsonFile -Path $path -Value $config
    $saved = Read-JsonSettings -Path $path
    if ($saved.apiKeyHelper -ne $config.apiKeyHelper -or $saved.env.ANTHROPIC_BASE_URL -ne $Settings.GatewayBaseUrl) {
        throw 'Saved Claude Code configuration did not match the onboarding settings.'
    }
}

function Install-VSCodeConfiguration {
    param($Settings, [string]$InstallRoot)

    $directory = Join-Path $env:APPDATA 'Code\User'
    $path = Join-Path $directory 'settings.json'
    $config = Read-JsonSettings -Path $path
    $variables = @($config.'claudeCode.environmentVariables' | Where-Object { $null -ne $_ })
    $environment = [pscustomobject]@{}
    foreach ($variable in $variables) {
        if (-not $variable.name -or $variable.value -isnot [string]) {
            throw 'VS Code Claude environment entries must have a name and a string value.'
        }
        $environment | Add-Member -NotePropertyName $variable.name -NotePropertyValue $variable.value -Force
    }
    Assert-CodeSettingsCompatible -Settings ([pscustomobject]@{ env = $environment }) -Source $path
    $gatewayEnvironment = Get-CodeGatewayEnvironment -Settings $Settings
    $owned = @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
        'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL')
    $variables = @($variables | Where-Object { $_.name -notin $owned -and -not $gatewayEnvironment.Contains($_.name) })
    $variables += @($gatewayEnvironment.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ name = $_.Key; value = $_.Value }
    })
    $config | Add-Member -NotePropertyName 'claudeCode.environmentVariables' -NotePropertyValue $variables -Force
    $config | Add-Member -NotePropertyName 'claudeCode.disableLoginPrompt' -NotePropertyValue $true -Force
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Backup-SettingsFile -Path $path -InstallRoot $InstallRoot
    Write-JsonFile -Path $path -Value $config
    $saved = Read-JsonSettings -Path $path
    if ($saved.'claudeCode.disableLoginPrompt' -ne $true -or
        @($saved.'claudeCode.environmentVariables' | Where-Object {
            $_.name -eq 'ANTHROPIC_BASE_URL' -and $_.value -eq $Settings.GatewayBaseUrl
        }).Count -ne 1) {
        throw 'Saved VS Code configuration did not match the onboarding settings.'
    }
}

function Wait-ForCodeClientsToClose {
    param([string]$CliPath, [switch]$VSCode)

    $sessionId = (Get-Process -Id $PID).SessionId
    $deadline = [DateTime]::UtcNow.AddMinutes(5)
    $notified = $false
    do {
        $processes = @(Get-Process -Name claude, Code -ErrorAction SilentlyContinue | Where-Object {
            $_.SessionId -eq $sessionId -and (
                ($CliPath -and $_.Path -eq $CliPath) -or ($VSCode -and $_.ProcessName -eq 'Code')
            )
        })
        if (-not $processes.Count) { return }
        if (-not $notified) {
            Write-Host 'Save work, exit Claude Code CLI sessions, and fully quit VS Code if selected. Setup will continue automatically; no process will be terminated.'
            $notified = $true
        }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'A selected Code client is still running. Close it and rerun onboarding.'
}

function Read-HelperSettings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Gateway settings are missing. Run the onboarding script first.'
    }

    $settings = Read-JsonSettings -Path $Path
    if (-not $settings.AzureCliPath -or -not (Test-Path -LiteralPath $settings.AzureCliPath -PathType Leaf)) {
        throw 'Azure CLI is missing at the installed helper path. Rerun onboarding.'
    }
    $parsedTenant = [Guid]$settings.TenantId
    if ($parsedTenant -eq [Guid]::Empty) {
        throw 'Gateway settings contain an empty tenant ID.'
    }
    return $settings
}

function Start-DeveloperOnboarding {
    param(
        [Guid]$Tenant,
        [string]$BaseUrl,
        [string]$SourceScript,
        [string[]]$Clients = @('Desktop'),
        [switch]$VerifyModels
    )

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Run this script with Windows powershell.exe, not PowerShell 7 pwsh.exe.'
    }
    if (-not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit Windows PowerShell, not Windows PowerShell (x86). Open Windows PowerShell from the Start menu.'
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    if ([int]$os.BuildNumber -lt 19041 -or $architecture -notin @('X64', 'Arm64')) {
        throw 'Claude workspace requires Windows build 19041 or newer and an x64/ARM64 computer.'
    }
    if ($Tenant -eq [Guid]::Empty) {
        throw 'A valid gateway tenant ID is required.'
    }
    if (-not $Clients.Count -or @($Clients | Where-Object { $_ -notin @('Desktop', 'CLI', 'VSCode') }).Count) {
        throw 'Select Desktop, CLI, VSCode, or All through the client selection.'
    }

    $BaseUrl = Resolve-GatewayBaseUrl -BaseUrl $BaseUrl
    $useDesktop = $Clients -contains 'Desktop'
    $useCLI = $Clients -contains 'CLI'
    $useVSCode = $Clients -contains 'VSCode'
    $useCode = $useCLI -or $useVSCode
    if ($useDesktop) {
        Assert-NoManagedInferencePolicy
    }
    if ($useCode) {
        Assert-NoManagedCodePolicy
        $codeSettingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'
        Assert-CodeSettingsCompatible -Settings (Read-JsonSettings -Path $codeSettingsPath) -Source $codeSettingsPath
    }
    if ($useVSCode) {
        $vsSettings = Read-JsonSettings -Path (Join-Path $env:APPDATA 'Code\User\settings.json')
        $vsEnvironment = [pscustomobject]@{}
        foreach ($variable in $vsSettings.'claudeCode.environmentVariables') {
            if (-not $variable.name -or $variable.value -isnot [string]) {
                throw 'VS Code Claude environment entries must have a name and a string value.'
            }
            $vsEnvironment | Add-Member -NotePropertyName $variable.name -NotePropertyValue $variable.value -Force
        }
        Assert-CodeSettingsCompatible -Settings ([pscustomobject]@{ env = $vsEnvironment }) -Source 'VS Code settings'
    }
    $hashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $hashAlgorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Tenant.ToString() + '|' + $BaseUrl.TrimEnd('/')))
        $folderName = ([BitConverter]::ToString($hash).Replace('-', '').Substring(0, 12)).ToLowerInvariant()
    }
    finally {
        $hashAlgorithm.Dispose()
    }

    $installRoot = Join-Path $env:LOCALAPPDATA ('ClaudeGatewayEntra\' + $folderName)
    $settingsPath = Join-Path $installRoot 'gateway-settings.json'
    $configId = [Guid]::NewGuid().ToString()
    if (Test-Path -LiteralPath $settingsPath) {
        $previousSettings = Read-JsonSettings -Path $settingsPath
        $configId = ([Guid]$previousSettings.ConfigId).ToString()
        if ($configId -eq [Guid]::Empty.ToString()) {
            throw 'Existing onboarding configuration ID is invalid.'
        }
    }
    if ($useCode -and (Join-Path $installRoot 'code-credential-helper.cmd') -match '["%!\r\n]') {
        throw 'The helper path contains characters unsupported by a CMD helper command. Ask IT for a supported Windows profile path.'
    }
    $configDirectory = Join-Path $env:LOCALAPPDATA 'Claude-3p\configLibrary'
    if ($useDesktop) {
        $metaPath = Join-Path $configDirectory '_meta.json'
        if (Test-Path -LiteralPath $metaPath) {
            Read-DesktopMetadata -Path $metaPath | Out-Null
        }
        Read-JsonSettings -Path (Join-Path $configDirectory ($configId + '.json')) | Out-Null
    }

    if ($useVSCode -and $env:TERM_PROGRAM -eq 'vscode') {
        throw 'Run onboarding in a separate Windows PowerShell window, not the VS Code terminal. Setup needs VS Code closed.'
    }
    Write-Host 'Checking and installing developer prerequisites...'
    $azureCli = Ensure-AzureCli -Architecture $architecture -WindowsBuild ([int]$os.BuildNumber)
    $settings = [pscustomobject]@{
        TenantId = $Tenant.ToString()
        GatewayBaseUrl = $BaseUrl.TrimEnd('/')
        Models = @()
        ModelMapping = $null
        AzureCliPath = $azureCli
        ConfigId = $configId
    }
    Write-Host 'Checking your Entra sign-in. Complete Microsoft sign-in if prompted.'
    $credential = Get-EntraCredential -Settings $settings -Context interactive
    Write-Host 'Discovering your permitted Claude models from AI Gateway...'
    $catalog = @(Get-GatewayModelCatalog -Settings $settings)
    $settings.Models = @($catalog | ForEach-Object { $_.Alias })
    $settings.ModelMapping = Resolve-CodeModelMapping -Catalog $catalog
    Write-Host ('Discovered models: ' + ($settings.Models -join ', '))
    if ($useCode) {
        foreach ($scope in @('Process', 'User', 'Machine')) {
            foreach ($name in @('ANTHROPIC_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL',
                'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL')) {
                $modelOverride = [Environment]::GetEnvironmentVariable($name, $scope)
                if ($modelOverride) {
                    if ($modelOverride -cnotin $settings.Models) {
                        throw "Conflicting $name in the $scope environment. It is not in your discovered gateway model list."
                    }
                    if ($name -eq 'ANTHROPIC_MODEL') {
                        Write-Host "ANTHROPIC_MODEL in the $scope environment overrides the saved default. Clear that model pin if you want /model choices to persist."
                    }
                }
            }
        }
    }
    if ($VerifyModels) {
        Test-GatewayModels -Settings $settings -Token $credential.token
    } else {
        Write-Host 'Published models and RBAC were checked without inference. Backend inference and quotas remain unverified; use -VerifyModels for one small request per model.'
    }
    $credential = $null
    $workspace = [pscustomobject]@{ RestartNeeded = $false }
    if ($useDesktop) {
        $package = Ensure-ClaudeDesktop -Architecture $architecture
        $workspace = Ensure-WorkspaceFeature
        $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
        $applications = @($manifest.Package.Applications.Application | Where-Object {
            $_.Executable -match '(?i)(^|\\)Claude\.exe$'
        })
        if ($applications.Count -ne 1) {
            throw 'Claude package does not expose exactly one main Desktop application. Ask IT to check the MSIX installation.'
        }
        $appId = $package.PackageFamilyName + '!' + $applications[0].Id
    }
    $cliPath = $null
    if ($useCLI) {
        $cliPath = Ensure-CodeClient -Name claude -Architecture $architecture
    }
    if ($useVSCode) {
        $codePath = Ensure-CodeClient -Name code -Architecture $architecture
        Ensure-ClaudeCodeExtension -CodePath $codePath
    }
    if ($useDesktop) {
        Wait-ForClaudeToClose -Package $package
    }
    if ($useCode) {
        Wait-ForCodeClientsToClose -CliPath $cliPath -VSCode:$useVSCode
    }
    $configurationPaths = @('onboard-claude-gateway.ps1', 'credential-helper.cmd', 'code-credential-helper.cmd', 'gateway-settings.json' |
        ForEach-Object { Join-Path $installRoot $_ })
    if ($useDesktop) {
        $configurationPaths += (Join-Path $configDirectory '_meta.json'), (Join-Path $configDirectory ($configId + '.json'))
    }
    if ($useCode) {
        $configurationPaths += $codeSettingsPath
    }
    if ($useVSCode) {
        $configurationPaths += (Join-Path $env:APPDATA 'Code\User\settings.json')
    }
    Invoke-ConfigurationUpdate -Paths $configurationPaths -Action {
        $helpers = Install-GatewayHelpers -Settings $settings -InstallRoot $installRoot -ScriptPath $SourceScript
        if ($useDesktop) {
            $helperPath = Install-DesktopConfiguration -Settings $settings -InstallRoot $installRoot `
                -HelperPath $helpers.Desktop -ConfigDirectory $configDirectory
            $meta = Read-DesktopMetadata -Path (Join-Path $configDirectory '_meta.json')
            $saved = Read-JsonSettings -Path (Join-Path $configDirectory ($meta.appliedId + '.json'))
            if ($meta.appliedId -ne $configId -or $saved.inferenceGatewayAuthScheme -ne 'bearer' -or
                $saved.inferenceCredentialHelper -ne $helperPath -or $saved.inferenceModels.Count -ne $settings.Models.Count) {
                throw 'Saved Desktop configuration did not match the onboarding settings.'
            }
        }
        if ($useCode) {
            Install-CodeConfiguration -Settings $settings -InstallRoot $installRoot -HelperPath $helpers.Code
        }
        if ($useVSCode) {
            Install-VSCodeConfiguration -Settings $settings -InstallRoot $installRoot
        }
    }
    if ($useCode) {
        Write-Host 'Claude Code shared settings saved. CLI and VS Code use the same gateway; project or managed settings may take precedence.'
    }
    if ($useVSCode) {
        Write-Host 'VS Code extension configured. Reopen VS Code in your own trusted project; use Ctrl+Shift+P > Claude Code: Open in Side Bar.'
        Write-Host 'If the command is missing, check the default profile, extension enabled state, and Restricted Mode. Workspace trust was not changed.'
    }
    Write-Host "Entra helper and selected client settings saved for this Windows account: $installRoot"
    if ($useCLI) {
        Write-Host 'Open a new Windows PowerShell window in your project and run the detected supported Claude Code installation:'
        Write-Host ("& '" + $cliPath.Replace("'", "''") + "'")
        Write-Host 'Check /status and send a message. If sign-in expires, rerun onboarding to sign in again.'
    }
    if ($workspace.RestartNeeded) {
        Write-Warning 'Virtual Machine Platform needs Windows to restart. Save work and restart manually, then open Claude Desktop. This script will not restart Windows.'
        return 3010
    }
    if (-not $useDesktop) {
        return 0
    }
    try {
        Start-Process -FilePath explorer.exe -ArgumentList ('shell:AppsFolder\' + $appId) | Out-Null
    }
    catch {
        throw ('Client settings were saved, but Desktop could not be opened. Open Claude Desktop manually. ' + $_.Exception.Message)
    }
    Write-Host 'Claude Desktop launch requested with the configured Entra gateway. Send a message to finish the Desktop conversation check.'
    return 0
}

try {
    if ($Credential -and $CodeCredential) {
        throw 'Use either -Credential or -CodeCredential, not both.'
    }
    if ($Credential -or $CodeCredential) {
        $settings = Read-HelperSettings -Path (Join-Path $PSScriptRoot 'gateway-settings.json')
        if ($CodeCredential) {
            $result = Get-EntraCredential -Settings $settings -Context background
            [Console]::Out.WriteLine($result.token)
        } else {
            $result = Get-EntraCredential -Settings $settings -Context $env:CLAUDE_HELPER_CONTEXT
            [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
        }
        exit 0
    }
    $clients = @(Resolve-OnboardingClients -Selection $Client)
    $inputs = Resolve-OnboardingInputs -Tenant $TenantId -BaseUrl $GatewayBaseUrl
    $exitCode = Start-DeveloperOnboarding -Tenant $inputs.TenantId -BaseUrl $inputs.GatewayBaseUrl `
        -SourceScript $PSCommandPath -Clients $clients -VerifyModels:$VerifyModels
    exit $exitCode
}
catch {
    [Console]::Error.WriteLine(('Claude gateway ' + $(if ($Credential -or $CodeCredential) { 'credential helper' } else { 'onboarding' }) + ' failed: ' + $_.Exception.Message))
    if ($CodeCredential) {
        [Console]::Error.WriteLine('If your Entra sign-in expired, rerun onboarding with your client, tenant, and gateway URL to sign in again.')
    }
    exit 1
}
