[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Request,

    [string]$RuntimeRoot,

    [string]$GeneratedRegistryPath,

    [string]$RegistrySourcePath,

    [string]$CapabilitiesPath,

    [string]$TaskTypesPath,

    [string]$SchemaPath,

    [ValidateSet('RouteOnly', 'Supervised')]
    [string]$ExecutionMode = 'RouteOnly',

    [string[]]$MaterialPath = @(),

    [ValidateSet('provided', 'verified')]
    [string]$MaterialTrust = 'provided',

    [string]$WorkerResultSchemaPath,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$vaultRoot = Split-Path -Parent (Split-Path -Parent $projectRoot)

if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path $projectRoot 'runtime'
}
if (-not $GeneratedRegistryPath) {
    $GeneratedRegistryPath = Join-Path $projectRoot 'generated\project_registry.json'
}
if (-not $RegistrySourcePath) {
    $RegistrySourcePath = Join-Path $vaultRoot '00-系统\项目注册表.md'
}
if (-not $CapabilitiesPath) {
    $CapabilitiesPath = Join-Path $projectRoot 'config\project_capabilities.json'
}
if (-not $TaskTypesPath) {
    $TaskTypesPath = Join-Path $projectRoot 'config\task_types.json'
}
if (-not $SchemaPath) {
    $SchemaPath = Join-Path $projectRoot 'schemas\task_contract.schema.json'
}
if (-not $WorkerResultSchemaPath) {
    $WorkerResultSchemaPath = Join-Path $projectRoot 'schemas\codex_worker_result.schema.json'
}
if ($ExecutionMode -eq 'Supervised' -and @($MaterialPath).Count -eq 0) {
    throw 'Supervised execution requires at least one -MaterialPath.'
}

Import-Module (Join-Path $projectRoot 'src\HermesHarness.psm1') -Force

$null = Update-HarnessProjectRegistry `
    -SourcePath $RegistrySourcePath `
    -CapabilitiesPath $CapabilitiesPath `
    -OutputPath $GeneratedRegistryPath

$result = New-HarnessTask `
    -Request $Request `
    -RegistryPath $GeneratedRegistryPath `
    -TaskTypesPath $TaskTypesPath `
    -RuntimeRoot $RuntimeRoot `
    -MaterialPath $MaterialPath `
    -MaterialTrust $MaterialTrust

if (-not (Test-HarnessTaskContract -Contract $result.contract -SchemaPath $SchemaPath)) {
    throw "Generated TaskContract failed schema validation: $($result.contract_path)"
}

$finalResult = if ($ExecutionMode -eq 'Supervised') {
    Invoke-HarnessCodexTask `
        -Contract $result.contract `
        -ContractPath $result.contract_path `
        -TaskDirectory (Split-Path -Parent $result.contract_path) `
        -RuntimeRoot $RuntimeRoot `
        -LedgerPath $result.ledger_path `
        -TaskContractSchemaPath $SchemaPath `
        -WorkerResultSchemaPath $WorkerResultSchemaPath
}
else {
    $result
}

if ($AsJson) {
    return $finalResult | ConvertTo-Json -Depth 30
}

return $finalResult
