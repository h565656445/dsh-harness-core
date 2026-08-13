$ErrorActionPreference = "Stop"

# Pester 5 兼容化：初始化与辅助函数移入 BeforeAll（Discovery/Run 作用域隔离），
# 候选验证经 HERMES_HARNESS_ROOT 注入真实项目根；晋级后 $PSScriptRoot 兜底，行为等价。
BeforeAll {

    $script:HarnessRoot = $env:HERMES_HARNESS_ROOT
    if (-not $script:HarnessRoot) {
        $script:HarnessRoot = Split-Path -Parent $PSScriptRoot
    }
    $projectRoot = $script:HarnessRoot
$modulePath = Join-Path $projectRoot "src\HermesHarness.psm1"
$schemaPath = Join-Path $projectRoot "schemas\task_contract.schema.json"
Import-Module $modulePath -Force

function New-TestTaskContract {
    param(
        [string]$TaskId = "task-20260717-120000-abcdef12",
        [int]$MaxAttempts = 2,
        [int]$MaxRepairs = 1,
        [bool]$RequiresApproval = $false,
        [string[]]$PendingActions = @()
    )

    return [pscustomobject]@{
        schema_version = "1.0"
        task_id = $TaskId
        created_at = "2026-07-17T12:00:00+09:00"
        state = if ($RequiresApproval) { "waiting_for_approval" } else { "routed" }
        request = [pscustomobject]@{ raw = "制作运动视频草稿" }
        goal = "制作运动视频草稿"
        understanding = [pscustomobject]@{
            domains = @("sports", "video")
            actions = @("create")
            channels = @()
            confidence = 0.75
            uncertainties = @()
            evidence = [pscustomobject]@{}
        }
        clarification_questions = @()
        route_plan = @(
            [pscustomobject]@{
                step_id = "step-1"
                project_id = "video_workbench"
                project_name = "视频剪辑工作流"
                project_root = "C:\\work\\sports"
                project_memory = "C:\\work\\sports\\00_项目记忆"
                matched_domains = @("sports", "video")
                matched_actions = @("create")
                depends_on = @()
            }
        )
        constraints = [pscustomobject]@{ duration_seconds = 90 }
        deliverables = @("项目草稿候选")
        acceptance = @("产物存在且可定位")
        authority = [pscustomobject]@{
            requires_approval = $RequiresApproval
            pending_actions = @($PendingActions)
        }
        loop_policy = [pscustomobject]@{
            max_attempts = $MaxAttempts
            max_repairs = $MaxRepairs
            no_progress_limit = 1
        }
    }
}

}

Describe "Hermes Harness public seams" {
    Context "project registry generation" {
        It "generates a traceable machine registry from the Markdown authority" {
            $sourcePath = Join-Path $TestDrive "项目注册表.md"
            $overlayPath = Join-Path $TestDrive "project_capabilities.json"
            $outputPath = Join-Path $TestDrive "project_registry.json"

            @'
| 项目 | 状态 | 根目录 | 项目记忆 | 主要目标 |
| --- | --- | --- | --- | --- |
| 视频剪辑工作流 | active | `<workspace-root>\sports` | `00_项目记忆` | 体育视频生产 |
'@ | Set-Content -LiteralPath $sourcePath -Encoding utf8

            @'
{
  "projects": {
    "视频剪辑工作流": {
      "id": "video_workbench",
      "routable": true,
      "domains": ["sports", "video"],
      "actions": ["analyze", "create"]
    }
  }
}
'@ | Set-Content -LiteralPath $overlayPath -Encoding utf8

            $registry = Update-HarnessProjectRegistry `
                -SourcePath $sourcePath `
                -CapabilitiesPath $overlayPath `
                -OutputPath $outputPath

            $registry.projects.Count | Should -Be 1
            $registry.projects[0].id | Should -Be "video_workbench"
            $registry.projects[0].root_path | Should -Be "<workspace-root>\sports"
            $registry.source_sha256 | Should -Match "^[A-F0-9]{64}$"
            $registry.capabilities_sha256 | Should -Match "^[A-F0-9]{64}$"
            Test-Path -LiteralPath $outputPath | Should -Be $true
        }
    }

    Context "task compilation and routing" {
        It "routes a clear sports video draft request and persists its contract" {
            $registryPath = Join-Path $TestDrive "project_registry.json"
            $taskTypesPath = Join-Path $TestDrive "task_types.json"
            $runtimeRoot = Join-Path $TestDrive "runtime"

            @'
{
  "schema_version": "1.0",
  "projects": [
    {
      "id": "video_workbench",
      "name": "视频剪辑工作流",
      "status": "active",
      "root_path": "C:\\work\\sports",
      "memory_path": "C:\\work\\sports\\00_项目记忆",
      "routable": true,
      "domains": ["sports", "video"],
      "actions": ["analyze", "create"]
    }
  ]
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

            @'
{
  "domains": [
    {"id": "sports", "keywords": ["比赛", "运动", "法国对西班牙"]},
    {"id": "video", "keywords": ["视频", "口播", "分镜"]}
  ],
  "actions": [
    {"id": "create", "keywords": ["制作", "生成", "草稿"]},
    {"id": "publish", "keywords": ["发布"], "side_effect": "publish"}
  ],
  "channels": [
    {"id": "short_video_platform", "keywords": ["短视频平台"]}
  ],
  "ambiguity_markers": ["那个", "那场", "优化一下", "处理一下"]
}
'@ | Set-Content -LiteralPath $taskTypesPath -Encoding utf8

            $result = New-HarnessTask `
                -Request "使用已核验资料制作法国对西班牙90秒短视频平台视频草稿" `
                -RegistryPath $registryPath `
                -TaskTypesPath $taskTypesPath `
                -RuntimeRoot $runtimeRoot

            $result.contract.state | Should -Be "routed"
            ($result.contract.understanding.domains -contains "sports") | Should -Be $true
            ($result.contract.understanding.domains -contains "video") | Should -Be $true
            $result.contract.constraints.duration_seconds | Should -Be 90
            $result.contract.route_plan[0].project_id | Should -Be "video_workbench"
            $result.contract.authority.requires_approval | Should -Be $false
            Test-Path -LiteralPath $result.contract_path | Should -Be $true
            Test-Path -LiteralPath $result.ledger_path | Should -Be $true
        }

        It "pauses an ambiguous request and emits clarification questions" {
            $registryPath = Join-Path $TestDrive "ambiguous_project_registry.json"
            $taskTypesPath = Join-Path $TestDrive "ambiguous_task_types.json"
            $runtimeRoot = Join-Path $TestDrive "ambiguous_runtime"

            @'
{
  "schema_version": "1.0",
  "projects": [
    {
      "id": "video_workbench",
      "name": "视频剪辑工作流",
      "status": "active",
      "root_path": "C:\\work\\sports",
      "memory_path": "C:\\work\\sports\\00_项目记忆",
      "routable": true,
      "domains": ["sports", "video"],
      "actions": ["analyze", "create", "optimize"]
    }
  ]
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

            @'
{
  "domains": [
    {"id": "sports", "keywords": ["比赛", "运动", "法国对西班牙"]},
    {"id": "video", "keywords": ["视频", "口播", "分镜"]}
  ],
  "actions": [
    {"id": "optimize", "keywords": ["优化"]}
  ],
  "channels": [],
  "ambiguity_markers": ["那个", "那场", "优化一下", "处理一下"]
}
'@ | Set-Content -LiteralPath $taskTypesPath -Encoding utf8

            $result = New-HarnessTask `
                -Request "帮我优化法国那场" `
                -RegistryPath $registryPath `
                -TaskTypesPath $taskTypesPath `
                -RuntimeRoot $runtimeRoot

            $result.contract.state | Should -Be "waiting_for_user"
            ($result.contract.understanding.uncertainties.Count -gt 0) | Should -Be $true
            ($result.contract.clarification_questions.Count -gt 0) | Should -Be $true
            $result.contract.route_plan.Count | Should -Be 0
        }

        It "blocks a publish side effect before any worker executes" {
            $registryPath = Join-Path $TestDrive "approval_project_registry.json"
            $taskTypesPath = Join-Path $TestDrive "approval_task_types.json"
            $runtimeRoot = Join-Path $TestDrive "approval_runtime"

            @'
{
  "schema_version": "1.0",
  "projects": [
    {
      "id": "video_workbench",
      "name": "视频剪辑工作流",
      "status": "active",
      "root_path": "C:\\work\\sports",
      "memory_path": "C:\\work\\sports\\00_项目记忆",
      "routable": true,
      "domains": ["sports", "video"],
      "actions": ["create", "publish"]
    }
  ]
}
'@ | Set-Content -LiteralPath $registryPath -Encoding utf8

            @'
{
  "domains": [
    {"id": "sports", "keywords": ["比赛", "运动", "法国对西班牙"]},
    {"id": "video", "keywords": ["视频", "口播", "分镜"]}
  ],
  "actions": [
    {"id": "create", "keywords": ["制作", "生成", "草稿"]},
    {"id": "publish", "keywords": ["发布"], "side_effect": "publish"}
  ],
  "channels": [
    {"id": "short_video_platform", "keywords": ["短视频平台"]}
  ],
  "ambiguity_markers": ["那个", "那场", "优化一下", "处理一下"]
}
'@ | Set-Content -LiteralPath $taskTypesPath -Encoding utf8

            $task = New-HarnessTask `
                -Request "发布法国对西班牙视频到短视频平台" `
                -RegistryPath $registryPath `
                -TaskTypesPath $taskTypesPath `
                -RuntimeRoot $runtimeRoot

            $loopResult = Invoke-HarnessTaskLoop `
                -Contract $task.contract `
                -Worker { throw "worker must not run before approval" } `
                -Verifier { throw "verifier must not run before approval" } `
                -LedgerPath $task.ledger_path `
                -SchemaPath $schemaPath

            $task.contract.state | Should -Be "waiting_for_approval"
            $task.contract.authority.requires_approval | Should -Be $true
            ($task.contract.authority.pending_actions -contains "publish") | Should -Be $true
            $loopResult.state | Should -Be "waiting_for_approval"
            $loopResult.attempts | Should -Be 0
        }
    }

    Context "bounded worker loop" {
        It "repairs once after verification fails and then completes" {
            $ledgerPath = Join-Path $TestDrive "loop_task_ledger.jsonl"
            $contract = New-TestTaskContract -TaskId "task-20260717-120000-aaaaaaa1"

            $result = Invoke-HarnessTaskLoop `
                -Contract $contract `
                -Worker {
                    param($currentContract, $attempt)
                    return [pscustomobject]@{
                        artifact = "draft-$attempt"
                    }
                } `
                -Verifier {
                    param($currentContract, $artifact, $attempt)
                    return [pscustomobject]@{
                        passed = ($attempt -eq 2)
                        reason = if ($attempt -eq 1) { "needs one repair" } else { "accepted" }
                    }
                } `
                -LedgerPath $ledgerPath `
                -SchemaPath $schemaPath

            $result.state | Should -Be "completed"
            $result.attempts | Should -Be 2
            $result.result.artifact | Should -Be "draft-2"

            $events = @(Get-Content -LiteralPath $ledgerPath | ForEach-Object { $_ | ConvertFrom-Json })
            ($events.state -contains "retrying") | Should -Be $true
            ($events.state -contains "completed") | Should -Be $true
        }

        It "fails after one attempt when repairs are disabled" {
            $ledgerPath = Join-Path $TestDrive "no_repair_ledger.jsonl"
            $contract = New-TestTaskContract `
                -TaskId "task-20260717-120000-aaaaaaa2" `
                -MaxAttempts 2 `
                -MaxRepairs 0

            $result = Invoke-HarnessTaskLoop `
                -Contract $contract `
                -Worker { param($currentContract, $attempt) "draft-$attempt" } `
                -Verifier { [pscustomobject]@{ passed = $false; reason = "rejected" } } `
                -LedgerPath $ledgerPath `
                -SchemaPath $schemaPath

            $result.state | Should -Be "failed"
            $result.attempts | Should -Be 1
        }

        It "closes as failed when the verifier throws" {
            $ledgerPath = Join-Path $TestDrive "verifier_error_ledger.jsonl"
            $contract = New-TestTaskContract -TaskId "task-20260717-120000-aaaaaaa3"

            $result = Invoke-HarnessTaskLoop `
                -Contract $contract `
                -Worker { "draft" } `
                -Verifier { throw "verifier unavailable" } `
                -LedgerPath $ledgerPath `
                -SchemaPath $schemaPath

            $result.state | Should -Be "failed"
            $result.attempts | Should -Be 2
            (Get-HarnessTaskState -LedgerPath $ledgerPath -TaskId $contract.task_id).state | Should -Be "failed"
        }

        It "records no progress when a repair returns the same artifact" {
            $ledgerPath = Join-Path $TestDrive "no_progress_ledger.jsonl"
            $contract = New-TestTaskContract -TaskId "task-20260717-120000-aaaaaaa4"

            $result = Invoke-HarnessTaskLoop `
                -Contract $contract `
                -Worker { "unchanged-draft" } `
                -Verifier { [pscustomobject]@{ passed = $false; reason = "rejected" } } `
                -LedgerPath $ledgerPath `
                -SchemaPath $schemaPath

            $result.state | Should -Be "failed"
            $result.attempts | Should -Be 2
            $result.verification.reason | Should -Be "no_progress_limit_reached"
        }

        It "rejects an invalid contract before dispatching a worker" {
            $ledgerPath = Join-Path $TestDrive "invalid_contract_ledger.jsonl"
            $didThrow = $false
            try {
                Invoke-HarnessTaskLoop `
                    -Contract ([pscustomobject]@{ task_id = "invalid"; state = "routed" }) `
                    -Worker { throw "worker must not run" } `
                    -Verifier { throw "verifier must not run" } `
                    -LedgerPath $ledgerPath `
                    -SchemaPath $schemaPath | Out-Null
            }
            catch {
                $didThrow = $true
            }

            $didThrow | Should -Be $true
            Test-Path -LiteralPath $ledgerPath | Should -Be $false
        }

        It "does not redispatch a terminal contract" {
            $ledgerPath = Join-Path $TestDrive "terminal_contract_ledger.jsonl"
            $contract = New-TestTaskContract -TaskId "task-20260717-120000-aaaaaaa5"
            $contract.state = "completed"
            $didThrow = $false

            try {
                Invoke-HarnessTaskLoop `
                    -Contract $contract `
                    -Worker { throw "worker must not run" } `
                    -Verifier { throw "verifier must not run" } `
                    -LedgerPath $ledgerPath `
                    -SchemaPath $schemaPath | Out-Null
            }
            catch {
                $didThrow = $true
            }

            $didThrow | Should -Be $true
            Test-Path -LiteralPath $ledgerPath | Should -Be $false
        }
    }

    Context "ledger recovery" {
        It "restores the latest state for one task without mixing other tasks" {
            $ledgerPath = Join-Path $TestDrive "recovery_task_ledger.jsonl"
            @(
                '{"timestamp":"2026-07-17T01:00:00+09:00","task_id":"task-a","state":"routed","event":"contract_created","details":{}}'
                '{"timestamp":"2026-07-17T01:00:01+09:00","task_id":"task-b","state":"completed","event":"task_completed","details":{}}'
                '{"timestamp":"2026-07-17T01:00:02+09:00","task_id":"task-a","state":"retrying","event":"repair_requested","details":{"attempt":1}}'
            ) | Set-Content -LiteralPath $ledgerPath -Encoding utf8

            $state = Get-HarnessTaskState -LedgerPath $ledgerPath -TaskId "task-a"

            $state.task_id | Should -Be "task-a"
            $state.state | Should -Be "retrying"
            $state.event | Should -Be "repair_requested"
            $state.details.attempt | Should -Be 1
        }
    }

    Context "task contract schema" {
        It "accepts a contract that satisfies the public schema" {
            $contract = [pscustomobject]@{
                schema_version = "1.0"
                task_id = "task-20260717-120000-abcdef12"
                created_at = "2026-07-17T12:00:00+09:00"
                state = "routed"
                request = [pscustomobject]@{ raw = "制作运动视频草稿" }
                goal = "制作运动视频草稿"
                understanding = [pscustomobject]@{
                    domains = @("sports", "video")
                    actions = @("create")
                    channels = @()
                    confidence = 0.75
                    uncertainties = @()
                    evidence = [pscustomobject]@{}
                }
                clarification_questions = @()
                route_plan = @(
                    [pscustomobject]@{
                        step_id = "step-1"
                        project_id = "video_workbench"
                        project_name = "视频剪辑工作流"
                        project_root = "C:\\work\\sports"
                        project_memory = "C:\\work\\sports\\00_项目记忆"
                        matched_domains = @("sports", "video")
                        matched_actions = @("create")
                        depends_on = @()
                    }
                )
                constraints = [pscustomobject]@{ duration_seconds = 90 }
                deliverables = @("项目草稿候选")
                acceptance = @("产物存在且可定位")
                authority = [pscustomobject]@{
                    requires_approval = $false
                    pending_actions = @()
                }
                loop_policy = [pscustomobject]@{
                    max_attempts = 2
                    max_repairs = 1
                    no_progress_limit = 1
                }
            }

            Test-HarnessTaskContract -Contract $contract -SchemaPath $schemaPath | Should -Be $true
        }
    }

    Context "route-only runner" {
        It "compiles a real request through the project entry point" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $runtimeRoot = Join-Path $TestDrive "runner_runtime"
            $generatedRegistryPath = Join-Path $TestDrive "runner_project_registry.json"

            $result = & $runnerPath `
                -Request "使用已核验资料制作法国对西班牙90秒短视频平台视频草稿" `
                -RuntimeRoot $runtimeRoot `
                -GeneratedRegistryPath $generatedRegistryPath

            $result.contract.state | Should -Be "routed"
            $result.contract.route_plan[0].project_id | Should -Be "ai_content"
            $result.contract.route_plan.Count | Should -Be 1
            Test-Path -LiteralPath $result.contract_path | Should -Be $true
            Test-Path -LiteralPath $generatedRegistryPath | Should -Be $true
        }

        It "fails instead of reporting success when runtime persistence is blocked" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $blockedRuntimeRoot = Join-Path $TestDrive "runtime_is_a_file"
            $generatedRegistryPath = Join-Path $TestDrive "blocked_project_registry.json"
            "not a directory" | Set-Content -LiteralPath $blockedRuntimeRoot -Encoding utf8

            $didThrow = $false
            try {
                & $runnerPath `
                    -Request "制作运动视频草稿" `
                    -RuntimeRoot $blockedRuntimeRoot `
                    -GeneratedRegistryPath $generatedRegistryPath | Out-Null
            }
            catch {
                $didThrow = $true
            }

            $didThrow | Should -Be $true
        }

        It "does not route a project that lacks the requested action" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $runtimeRoot = Join-Path $TestDrive "unsupported_action_runtime"
            $generatedRegistryPath = Join-Path $TestDrive "unsupported_action_registry.json"

            $result = & $runnerPath `
                -Request "查询并发布知识库笔记" `
                -RuntimeRoot $runtimeRoot `
                -GeneratedRegistryPath $generatedRegistryPath

            $result.contract.route_plan.Count | Should -Be 0
            $result.contract.state | Should -Be "waiting_for_user"
            $result.contract.authority.requires_approval | Should -Be $true
        }

        It "treats account or permission changes as approval-gated side effects" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $runtimeRoot = Join-Path $TestDrive "account_change_runtime"
            $generatedRegistryPath = Join-Path $TestDrive "account_change_registry.json"

            $result = & $runnerPath `
                -Request "更新网站账号权限" `
                -RuntimeRoot $runtimeRoot `
                -GeneratedRegistryPath $generatedRegistryPath

            $result.contract.authority.requires_approval | Should -Be $true
            ($result.contract.authority.pending_actions -contains "account_change") | Should -Be $true

            $permissionResult = & $runnerPath `
                -Request "调整网站权限" `
                -RuntimeRoot (Join-Path $TestDrive "permission_change_runtime") `
                -GeneratedRegistryPath (Join-Path $TestDrive "permission_change_registry.json")

            $permissionResult.contract.authority.requires_approval | Should -Be $true
            ($permissionResult.contract.authority.pending_actions -contains "account_change") | Should -Be $true
        }

        It "does not treat a read-only account description as an account change" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $result = & $runnerPath `
                -Request "查看网站账号说明" `
                -RuntimeRoot (Join-Path $TestDrive "account_read_runtime") `
                -GeneratedRegistryPath (Join-Path $TestDrive "account_read_registry.json")

            $result.contract.authority.requires_approval | Should -Be $false
            ($result.contract.authority.pending_actions -contains "account_change") | Should -Be $false
        }

        It "rejects credential material before creating runtime files" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $runtimeRoot = Join-Path $TestDrive "secret_runtime"
            $generatedRegistryPath = Join-Path $TestDrive "secret_registry.json"
            $didThrow = $false

            try {
                & $runnerPath `
                    -Request "查询知识库 api_key=sk-1234567890abcdef" `
                    -RuntimeRoot $runtimeRoot `
                    -GeneratedRegistryPath $generatedRegistryPath | Out-Null
            }
            catch {
                $didThrow = $true
            }

            $didThrow | Should -Be $true
            Test-Path -LiteralPath (Join-Path $runtimeRoot "tasks") | Should -Be $false
        }

        It "rejects Chinese passwords and bare AWS access keys before persistence" {
            $runnerPath = Join-Path $projectRoot "runner\harness_runner.ps1"
            $requests = @(
                "查询知识库 密码=very-secret-value",
                "查询知识库 AKIAIOSFODNN7EXAMPLE"
            )

            foreach ($requestText in $requests) {
                $runtimeRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
                $didThrow = $false
                try {
                    & $runnerPath `
                        -Request $requestText `
                        -RuntimeRoot $runtimeRoot `
                        -GeneratedRegistryPath (Join-Path $TestDrive "credential_registry.json") | Out-Null
                }
                catch {
                    $didThrow = $true
                }

                $didThrow | Should -Be $true
                Test-Path -LiteralPath (Join-Path $runtimeRoot "tasks") | Should -Be $false
            }
        }
    }
}
