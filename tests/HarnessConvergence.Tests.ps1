BeforeAll {
    $script:projectRoot = Split-Path -Parent $PSScriptRoot
    $script:matrixPath = Join-Path $projectRoot 'adapters\projects\adapter-matrix.v0.2.json'
    $script:matrixSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\adapter-matrix.schema.json'
    $script:providerPath = Join-Path $projectRoot 'adapters\openai-agents-sdk-worker.v0.2.json'
    $script:providerSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\provider-worker-manifest.schema.json'
    $script:registryPath = Join-Path $projectRoot 'generated\project_registry.json'
    $script:sourceRegistryPath = '<projects-root>\10-知识库\00-系统\项目注册表.md'
    $script:checklistPath = Join-Path $projectRoot 'config\upgate_checklist.json'
    $script:governanceModule = Join-Path $projectRoot 'src\HermesUpgradeGovernance.psm1'

    function Read-TestJson([string]$Path) {
        Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 100
    }
}

Describe 'Harness four-project downstream convergence' {
    It 'binds the matrix to the generated four-project Registry projection' {
        $matrixText = Get-Content -LiteralPath $matrixPath -Raw
        $matrixText | Test-Json -SchemaFile $matrixSchema | Should -BeTrue
        $matrix = $matrixText | ConvertFrom-Json -Depth 100
        $registry = Read-TestJson $registryPath

        $matrix.business_project_count | Should -Be 4
        $matrix.runtime_root | Should -Be 'runtime'
        @($matrix.projects.id) | Should -Be @('novel_workbench', 'ai_content', 'content_audit', 'data_collection')
        @($matrix.projects.name) | Should -Be @('小说', 'AI内容创作', '内容审计', '数据收集')
        @($registry.projects.id) | Should -Be @($matrix.projects.id)
        @($registry.projects.name) | Should -Be @($matrix.projects.name)
        @($matrix.projects.id) | Should -Not -Contain 'video_workbench'
    }

    It 'closes the project-local runtime and active artifact hashes' {
        $matrix = Read-TestJson $matrixPath
        $providerText = Get-Content -LiteralPath $providerPath -Raw
        $providerText | Test-Json -SchemaFile $providerSchema | Should -BeTrue
        $provider = $providerText | ConvertFrom-Json -Depth 100

        $provider.runtime_root | Should -Be 'runtime'
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $matrix.schema_registry_ref.path)).Hash | Should -Be $matrix.schema_registry_ref.sha256
        (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $projectRoot $matrix.provider_worker_manifest.path)).Hash | Should -Be $matrix.provider_worker_manifest.sha256
        (Get-FileHash -Algorithm SHA256 -LiteralPath $matrixSchema).Hash | Should -Be $matrix.schema_identity.sha256
    }

    It 'passes the governance audit without writing an audit receipt' {
        Import-Module $governanceModule -Force
        $audit = Invoke-HermesUpgradeGovernance `
            -Action Audit `
            -ProjectRoot $projectRoot `
            -RuntimeRoot (Join-Path $projectRoot 'runtime') `
            -ProjectRegistryPath $sourceRegistryPath `
            -GeneratedRegistryPath $registryPath `
            -ChecklistPath $checklistPath `
            -MatrixPath $matrixPath `
            -NoWrite

        $audit.passed | Should -BeTrue
        $audit.project_bindings | Should -Be 4
        $audit.artifact_hash_matches | Should -Be 2
        $audit.schema_registry_entries_verified | Should -Be 11
        $audit.gate_checks_passed | Should -Be 8
        $audit.audit_path | Should -BeNullOrEmpty
    }

    It 'creates a valid four-project Agent OS plan in an isolated runtime' {
        $runner = Join-Path $projectRoot 'runner\agent_os_planner.ps1'
        $schema = Join-Path $projectRoot 'schemas\agent_os_plan.schema.json'
        $runtime = Join-Path $TestDrive 'agent-os-plans'
        $initialized = & $runner -Action Initialize -Objective '验证四项目 Agent OS 规划边界' -RuntimeRoot $runtime -AsJson | ConvertFrom-Json -Depth 100
        $advanced = & $runner -Action Advance -RuntimeRoot $runtime -RunPath $initialized.run_path -AsJson | ConvertFrom-Json -Depth 100
        $planText = Get-Content -LiteralPath $initialized.plan_path -Raw
        $plan = $planText | ConvertFrom-Json -Depth 100

        $planText | Test-Json -SchemaFile $schema | Should -BeTrue
        @($plan.constraints.business_projects) | Should -Be @('小说', 'AI内容创作', '内容审计', '数据收集')
        $initialized.state | Should -Be 'draft'
        $advanced.state | Should -Be 'waiting_for_approval'
        $advanced.valid | Should -BeTrue
    }
}
