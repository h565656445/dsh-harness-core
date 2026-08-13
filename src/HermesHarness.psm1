Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HarnessJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-HarnessJson {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null
    }

    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 -ErrorAction Stop
}

function Get-OverlayProject {
    param(
        [Parameter(Mandatory)]
        [object]$Capabilities,

        [Parameter(Mandatory)]
        [string]$ProjectName
    )

    if (-not $Capabilities.projects) {
        return $null
    }

    $property = $Capabilities.projects.PSObject.Properties |
        Where-Object { $_.Name -eq $ProjectName } |
        Select-Object -First 1

    if ($property) {
        return $property.Value
    }

    return $null
}

function ConvertFrom-HarnessProjectRegistryMarkdown {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [object]$Capabilities
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Project registry authority not found: $SourcePath"
    }

    $projects = foreach ($line in Get-Content -LiteralPath $SourcePath) {
        if ($line -notmatch '^\s*\|') {
            continue
        }

        $cells = @(
            $line.Trim().Trim('|').Split('|') |
                ForEach-Object { $_.Trim().Trim([char]0x60) }
        )

        if ($cells.Count -lt 5 -or $cells[0] -eq '项目' -or $cells[0] -match '^-+$') {
            continue
        }

        $projectName = $cells[0]
        $overlay = Get-OverlayProject -Capabilities $Capabilities -ProjectName $projectName
        $rootPath = $cells[2]
        $memoryEntry = $cells[3]
        $memoryPath = if ([System.IO.Path]::IsPathRooted($memoryEntry)) {
            $memoryEntry
        }
        else {
            Join-Path $rootPath $memoryEntry
        }

        [pscustomobject]@{
            id = if ($overlay -and $overlay.id) { $overlay.id } else { $projectName }
            name = $projectName
            status = $cells[1]
            root_path = $rootPath
            memory_path = $memoryPath
            objective = $cells[4]
            routable = [bool]($overlay -and $overlay.routable)
            domains = if ($overlay -and $overlay.domains) { @($overlay.domains) } else { @() }
            actions = if ($overlay -and $overlay.actions) { @($overlay.actions) } else { @() }
        }
    }

    return @($projects)
}

function Update-HarnessProjectRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$CapabilitiesPath,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $capabilities = Get-HarnessJson -Path $CapabilitiesPath
    $projects = ConvertFrom-HarnessProjectRegistryMarkdown `
        -SourcePath $SourcePath `
        -Capabilities $capabilities

    $registry = [pscustomobject]@{
        schema_version = '1.0'
        generated_at = (Get-Date).ToString('o')
        source_path = [System.IO.Path]::GetFullPath($SourcePath)
        source_sha256 = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
        capabilities_path = [System.IO.Path]::GetFullPath($CapabilitiesPath)
        capabilities_sha256 = (Get-FileHash -LiteralPath $CapabilitiesPath -Algorithm SHA256).Hash
        projects = @($projects)
    }

    Write-HarnessJson -Value $registry -Path $OutputPath
    return $registry
}

function Get-HarnessDimensionMatches {
    param(
        [Parameter(Mandatory)]
        [string]$Text,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Definitions
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    $evidence = [System.Collections.Generic.List[object]]::new()

    foreach ($definition in $Definitions) {
        foreach ($keyword in @($definition.keywords)) {
            if ($Text.IndexOf([string]$keyword, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                if (-not $ids.Contains([string]$definition.id)) {
                    $ids.Add([string]$definition.id)
                }
                $evidence.Add([pscustomobject]@{
                    id = [string]$definition.id
                    keyword = [string]$keyword
                })
                break
            }
        }
    }

    return [pscustomobject]@{
        ids = @($ids)
        evidence = @($evidence)
    }
}

function Resolve-HarnessUnderstanding {
    param(
        [Parameter(Mandatory)]
        [string]$Request,

        [Parameter(Mandatory)]
        [object]$TaskTypes
    )

    $domainMatches = Get-HarnessDimensionMatches -Text $Request -Definitions @($TaskTypes.domains)
    $actionMatches = Get-HarnessDimensionMatches -Text $Request -Definitions @($TaskTypes.actions)
    $channelMatches = Get-HarnessDimensionMatches -Text $Request -Definitions @($TaskTypes.channels)

    $domainIds = @($domainMatches.ids)
    $domainEvidence = @($domainMatches.evidence)
    if ($domainIds -contains 'video' -and
        $domainIds -notcontains 'sports' -and
        $domainIds -notcontains 'ai_video') {
        $domainIds += 'ai_video'
        $domainEvidence += [pscustomobject]@{
            id = 'ai_video'
            keyword = 'derived:non_sports_video'
        }
    }

    $sideEffects = foreach ($action in @($TaskTypes.actions)) {
        if ($actionMatches.ids -contains $action.id -and $action.PSObject.Properties.Name -contains 'side_effect') {
            [string]$action.side_effect
        }
    }

    $uncertainties = [System.Collections.Generic.List[string]]::new()
    if ($domainIds.Count -eq 0) {
        $uncertainties.Add('未识别到明确业务域')
    }
    if ($actionMatches.ids.Count -eq 0) {
        $uncertainties.Add('未识别到明确动作')
    }

    foreach ($marker in @($TaskTypes.ambiguity_markers)) {
        if ($Request.IndexOf([string]$marker, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $uncertainties.Add("存在模糊指代：$marker")
            break
        }
    }

    $durationSeconds = $null
    if ($Request -match '(?<duration>\d+)\s*秒') {
        $durationSeconds = [int]$Matches.duration
    }

    $confidence = 0.0
    if ($domainIds.Count -gt 0) { $confidence += 0.45 }
    if ($actionMatches.ids.Count -gt 0) { $confidence += 0.25 }
    if ($channelMatches.ids.Count -gt 0) { $confidence += 0.10 }
    if ($durationSeconds) { $confidence += 0.05 }
    if ($domainIds.Count -gt 1) { $confidence += 0.05 }

    return [pscustomobject]@{
        domains = @($domainIds)
        actions = @($actionMatches.ids)
        channels = @($channelMatches.ids)
        side_effects = @($sideEffects)
        confidence = [math]::Round([math]::Min($confidence, 1.0), 2)
        uncertainties = @($uncertainties)
        evidence = [pscustomobject]@{
            domains = @($domainEvidence)
            actions = @($actionMatches.evidence)
            channels = @($channelMatches.evidence)
        }
        duration_seconds = $durationSeconds
    }
}

function Resolve-HarnessRoutes {
    param(
        [Parameter(Mandatory)]
        [object]$Understanding,

        [Parameter(Mandatory)]
        [object]$Registry
    )

    $candidates = foreach ($project in @($Registry.projects)) {
        if ($project.status -ne 'active' -or -not $project.routable) {
            continue
        }

        $matchedDomains = @($Understanding.domains | Where-Object { @($project.domains) -contains $_ })
        if ($matchedDomains.Count -eq 0) {
            continue
        }

        $matchedActions = @($Understanding.actions | Where-Object { @($project.actions) -contains $_ })
        if (@($Understanding.actions).Count -gt 0 -and $matchedActions.Count -ne @($Understanding.actions).Count) {
            continue
        }
        [pscustomobject]@{
            project = $project
            matched_domains = $matchedDomains
            matched_actions = $matchedActions
            score = ($matchedDomains.Count * 10) + $matchedActions.Count
        }
    }

    $ordered = @($candidates | Sort-Object -Property score -Descending)
    $routes = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $ordered.Count; $index++) {
        $candidate = $ordered[$index]
        [string[]]$matchedDomains = @($candidate.matched_domains)
        [string[]]$matchedActions = @($candidate.matched_actions)
        [string[]]$dependencies = @()
        if ($index -gt 0) {
            $dependencies = @("step-$index")
        }
        $routes.Add([pscustomobject]@{
            step_id = "step-$($index + 1)"
            project_id = $candidate.project.id
            project_name = $candidate.project.name
            project_root = $candidate.project.root_path
            project_memory = $candidate.project.memory_path
            matched_domains = $matchedDomains
            matched_actions = $matchedActions
            depends_on = $dependencies
        })
    }

    return @($routes)
}

function Write-HarnessLedgerEvent {
    param(
        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        [string]$State,

        [Parameter(Mandatory)]
        [string]$Event,

        [hashtable]$Details = @{}
    )

    $parent = Split-Path -Parent $LedgerPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent -ErrorAction Stop | Out-Null
    }

    $record = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        task_id = $TaskId
        state = $State
        event = $Event
        details = $Details
    }
    Add-Content -LiteralPath $LedgerPath -Value ($record | ConvertTo-Json -Compress -Depth 10) -Encoding utf8 -ErrorAction Stop
}

function Assert-HarnessRequestSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Request
    )

    $sensitivePatterns = @(
        [pscustomobject]@{
            type = 'access key or token'
            pattern = '(?i)\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b'
        },
        [pscustomobject]@{
            type = 'named credential value'
            pattern = '(?i)(?:\bapi[-_ ]?key\b|\btoken\b|\bpassword\b|\bpasswd\b|\bcookie\b|\bauthorization\b|密码|口令|密钥|令牌|凭据)\s*[:=：]\s*\S+'
        },
        [pscustomobject]@{
            type = 'bearer token'
            pattern = '(?i)\bBearer\s+[A-Za-z0-9._~+/-]+=*'
        },
        [pscustomobject]@{
            type = 'AWS access key'
            pattern = '\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'
        }
    )

    foreach ($entry in $sensitivePatterns) {
        if ($Request -match $entry.pattern) {
            throw "Request appears to contain sensitive credential material ($($entry.type)). Remove the secret before creating a task."
        }
    }
}

function Assert-HarnessTextSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Assert-HarnessRequestSafe -Request $Text
}

function Resolve-HarnessMaterialInputs {
    param(
        [string[]]$MaterialPath = @(),

        [ValidateSet('provided', 'verified')]
        [string]$MaterialTrust = 'provided'
    )

    $paths = @($MaterialPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($paths.Count -gt 8) {
        throw 'A supervised MVP task accepts at most 8 material files.'
    }

    $allowedExtensions = @('.txt', '.md', '.json', '.yaml', '.yml', '.csv', '.srt')
    $materials = foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Task material not found: $path"
        }

        $item = Get-Item -LiteralPath $path
        if ($allowedExtensions -notcontains $item.Extension.ToLowerInvariant()) {
            throw "Unsupported task material type: $($item.Extension)"
        }
        if ($item.Length -gt 1MB) {
            throw "Task material exceeds the 1MB MVP limit: $($item.FullName)"
        }

        $content = Get-Content -Raw -LiteralPath $item.FullName
        Assert-HarnessRequestSafe -Request $content
        [pscustomobject]@{
            label = $item.Name
            source_path = $item.FullName
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            trust = $MaterialTrust
            content = $content
        }
    }

    return @($materials)
}

function New-HarnessTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Request,

        [Parameter(Mandatory)]
        [string]$RegistryPath,

        [Parameter(Mandatory)]
        [string]$TaskTypesPath,

        [Parameter(Mandatory)]
        [string]$RuntimeRoot,

        [string[]]$MaterialPath = @(),

        [ValidateSet('provided', 'verified')]
        [string]$MaterialTrust = 'provided'
    )

    Assert-HarnessRequestSafe -Request $Request
    $resolvedMaterials = @(Resolve-HarnessMaterialInputs `
        -MaterialPath $MaterialPath `
        -MaterialTrust $MaterialTrust)
    $registry = Get-HarnessJson -Path $RegistryPath
    $taskTypes = Get-HarnessJson -Path $TaskTypesPath
    $understanding = Resolve-HarnessUnderstanding -Request $Request -TaskTypes $taskTypes
    $routePlan = @(Resolve-HarnessRoutes -Understanding $understanding -Registry $registry)

    $uncertainties = [System.Collections.Generic.List[string]]::new()
    foreach ($uncertainty in @($understanding.uncertainties)) {
        $uncertainties.Add([string]$uncertainty)
    }
    if ($routePlan.Count -eq 0) {
        $uncertainties.Add('没有找到满足当前意图的已注册项目')
    }

    $clarificationQuestions = [System.Collections.Generic.List[string]]::new()
    foreach ($uncertainty in $uncertainties) {
        if ($uncertainty -eq '未识别到明确业务域') {
            $clarificationQuestions.Add('你希望处理哪个项目或业务领域？')
        }
        elseif ($uncertainty -eq '未识别到明确动作') {
            $clarificationQuestions.Add('你希望生成、分析、修改还是发布什么？')
        }
        elseif ($uncertainty -like '存在模糊指代*') {
            $clarificationQuestions.Add('你指的是哪个具体任务、文件或产物？')
        }
        elseif ($uncertainty -eq '没有找到满足当前意图的已注册项目') {
            $clarificationQuestions.Add('应使用哪个现有项目，还是先登记一项新能力？')
        }
    }

    $requiresApproval = @($understanding.side_effects).Count -gt 0
    $state = if ($uncertainties.Count -gt 0) {
        'waiting_for_user'
    }
    elseif ($requiresApproval) {
        'waiting_for_approval'
    }
    else {
        'routed'
    }

    $taskId = 'task-{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $taskDirectory = Join-Path (Join-Path $RuntimeRoot 'tasks') $taskId
    New-Item -ItemType Directory -Force -Path $taskDirectory -ErrorAction Stop | Out-Null

    $materialInputs = [System.Collections.Generic.List[object]]::new()
    if ($resolvedMaterials.Count -gt 0) {
        $materialDirectory = Join-Path $taskDirectory 'inputs'
        New-Item -ItemType Directory -Force -Path $materialDirectory -ErrorAction Stop | Out-Null
        for ($index = 0; $index -lt $resolvedMaterials.Count; $index++) {
            $material = $resolvedMaterials[$index]
            $snapshotPath = Join-Path $materialDirectory ('material-{0:D3}.txt' -f ($index + 1))
            Copy-Item -LiteralPath $material.source_path -Destination $snapshotPath -Force -ErrorAction Stop
            $snapshotHash = (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
            if ($snapshotHash -ne $material.sha256) {
                throw "Task material changed while being snapshotted: $($material.source_path)"
            }
            $materialInputs.Add([pscustomobject]@{
                label = $material.label
                source_path = $material.source_path
                snapshot_path = $snapshotPath
                sha256 = $material.sha256
                trust = $material.trust
            })
        }
    }

    $contract = [pscustomobject]@{
        schema_version = '1.1'
        task_id = $taskId
        created_at = (Get-Date).ToString('o')
        state = $state
        request = [pscustomobject]@{
            raw = $Request
        }
        goal = $Request
        inputs = [pscustomobject]@{
            materials = @($materialInputs)
        }
        understanding = [pscustomobject]@{
            domains = @($understanding.domains)
            actions = @($understanding.actions)
            channels = @($understanding.channels)
            confidence = $understanding.confidence
            uncertainties = @($uncertainties)
            evidence = $understanding.evidence
        }
        clarification_questions = @($clarificationQuestions)
        route_plan = @($routePlan)
        constraints = [pscustomobject]@{
            duration_seconds = $understanding.duration_seconds
        }
        deliverables = @('项目草稿候选', '验证结果与证据')
        acceptance = @('产物存在且可定位', '通过对应项目质量门禁', '未执行未经批准的副作用')
        authority = [pscustomobject]@{
            requires_approval = $requiresApproval
            pending_actions = @($understanding.side_effects)
        }
        loop_policy = [pscustomobject]@{
            max_attempts = 2
            max_repairs = 1
            no_progress_limit = 1
        }
    }

    $contractPath = Join-Path $taskDirectory 'contract.json'
    $inputPath = Join-Path $taskDirectory 'input.txt'
    $ledgerPath = Join-Path $RuntimeRoot 'task_ledger.jsonl'

    Write-HarnessJson -Value $contract -Path $contractPath
    @(
        '原始需求：'
        $Request
    ) | Set-Content -LiteralPath $inputPath -Encoding utf8 -ErrorAction Stop
    Write-HarnessLedgerEvent `
        -LedgerPath $ledgerPath `
        -TaskId $taskId `
        -State $state `
        -Event 'contract_created' `
        -Details @{ contract_path = $contractPath }

    return [pscustomobject]@{
        contract = $contract
        contract_path = $contractPath
        input_path = $inputPath
        ledger_path = $ledgerPath
    }
}

function Invoke-HarnessTaskLoop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [scriptblock]$Worker,

        [Parameter(Mandatory)]
        [scriptblock]$Verifier,

        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$SchemaPath,

        [string]$ContractPath,

        [ValidateSet('completed', 'waiting_for_approval')]
        [string]$SuccessState = 'completed',

        [string]$SuccessEvent = 'task_completed',

        [string]$SuccessPendingAction,

        [scriptblock]$BeforeSuccessPersistence
    )

    if (-not (Test-HarnessTaskContract -Contract $Contract -SchemaPath $SchemaPath)) {
        throw "TaskContract failed schema validation: $($Contract.task_id)"
    }

    if (@('completed', 'failed') -contains $Contract.state) {
        throw "Terminal TaskContract cannot be dispatched again: $($Contract.task_id) [$($Contract.state)]"
    }

    if ($Contract.state -eq 'waiting_for_user') {
        return [pscustomobject]@{
            task_id = $Contract.task_id
            state = 'waiting_for_user'
            attempts = 0
        }
    }

    if ($Contract.authority.requires_approval -or $Contract.state -eq 'waiting_for_approval') {
        Write-HarnessLedgerEvent `
            -LedgerPath $LedgerPath `
            -TaskId $Contract.task_id `
            -State 'waiting_for_approval' `
            -Event 'execution_blocked_by_approval_gate'

        return [pscustomobject]@{
            task_id = $Contract.task_id
            state = 'waiting_for_approval'
            attempts = 0
        }
    }

    $configuredMaxAttempts = [int]$Contract.loop_policy.max_attempts
    $maxRepairs = [int]$Contract.loop_policy.max_repairs
    $maxAttempts = [math]::Min($configuredMaxAttempts, 1 + $maxRepairs)
    if ($maxAttempts -lt 1 -or $maxAttempts -gt 2) {
        throw 'MVP loop policy requires max_attempts between 1 and 2.'
    }

    $lastResult = $null
    $lastVerification = $null
    $previousResultFingerprint = $null
    $noProgressCount = 0
    $noProgressLimit = [int]$Contract.loop_policy.no_progress_limit
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        $lastResult = $null
        $lastVerification = $null
        $workerFailed = $false
        $Contract.state = 'dispatched'
        Write-HarnessLedgerEvent `
            -LedgerPath $LedgerPath `
            -TaskId $Contract.task_id `
            -State 'dispatched' `
            -Event 'worker_dispatched' `
            -Details @{ attempt = $attempt }

        try {
            $lastResult = & $Worker $Contract $attempt
        }
        catch {
            $workerFailed = $true
            $lastVerification = [pscustomobject]@{
                passed = $false
                reason = "worker_error: $($_.Exception.Message)"
            }
        }

        if (-not $workerFailed) {
            $resultFingerprint = $lastResult | ConvertTo-Json -Compress -Depth 30
            if ($null -ne $previousResultFingerprint -and $resultFingerprint -eq $previousResultFingerprint) {
                $noProgressCount++
            }
            else {
                $noProgressCount = 0
            }
            $previousResultFingerprint = $resultFingerprint

            $Contract.state = 'evaluating'
            Write-HarnessLedgerEvent `
                -LedgerPath $LedgerPath `
                -TaskId $Contract.task_id `
                -State 'evaluating' `
                -Event 'verification_started' `
                -Details @{ attempt = $attempt }

            if ($noProgressCount -ge $noProgressLimit) {
                $lastVerification = [pscustomobject]@{
                    passed = $false
                    reason = 'no_progress_limit_reached'
                }
            }
            else {
                try {
                    $lastVerification = & $Verifier $Contract $lastResult $attempt
                }
                catch {
                    $lastVerification = [pscustomobject]@{
                        passed = $false
                        reason = "verifier_error: $($_.Exception.Message)"
                    }
                }
            }
        }

        $passed = if ($lastVerification -is [bool]) {
            $lastVerification
        }
        else {
            [bool]$lastVerification.passed
        }
        $reason = if ($lastVerification -is [bool]) {
            if ($passed) { 'accepted' } else { 'rejected' }
        }
        elseif ($lastVerification.PSObject.Properties.Name -contains 'reason') {
            [string]$lastVerification.reason
        }
        else {
            'no verification reason supplied'
        }

        if ($passed) {
            if ($BeforeSuccessPersistence) {
                & $BeforeSuccessPersistence $Contract $lastResult $lastVerification $attempt
            }
            $Contract.state = $SuccessState
            if (-not [string]::IsNullOrWhiteSpace($SuccessPendingAction)) {
                $Contract.authority.requires_approval = $true
                $Contract.authority.pending_actions = @(
                    @($Contract.authority.pending_actions) + $SuccessPendingAction |
                        Select-Object -Unique
                )
            }
            if ($ContractPath) {
                Write-HarnessJson -Value $Contract -Path $ContractPath
            }
            Write-HarnessLedgerEvent `
                -LedgerPath $LedgerPath `
                -TaskId $Contract.task_id `
                -State $SuccessState `
                -Event $SuccessEvent `
                -Details @{ attempt = $attempt; reason = $reason }
            return [pscustomobject]@{
                task_id = $Contract.task_id
                state = $SuccessState
                attempts = $attempt
                result = $lastResult
                verification = $lastVerification
            }
        }

        if ($attempt -lt $maxAttempts) {
            $Contract.state = 'retrying'
            Write-HarnessLedgerEvent `
                -LedgerPath $LedgerPath `
                -TaskId $Contract.task_id `
                -State 'retrying' `
                -Event 'repair_requested' `
                -Details @{ attempt = $attempt; reason = $reason }
            continue
        }

        $Contract.state = 'failed'
        if ($ContractPath) {
            Write-HarnessJson -Value $Contract -Path $ContractPath
        }
        Write-HarnessLedgerEvent `
            -LedgerPath $LedgerPath `
            -TaskId $Contract.task_id `
            -State 'failed' `
            -Event 'task_failed' `
            -Details @{ attempt = $attempt; reason = $reason }
        return [pscustomobject]@{
            task_id = $Contract.task_id
            state = 'failed'
            attempts = $attempt
            result = $lastResult
            verification = $lastVerification
        }
    }
}

function Assert-HarnessTaskLocation {
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [string]$ContractPath,

        [Parameter(Mandatory)]
        [string]$TaskDirectory,

        [Parameter(Mandatory)]
        [string]$RuntimeRoot
    )

    $expectedTaskDirectory = [System.IO.Path]::GetFullPath(
        (Join-Path (Join-Path $RuntimeRoot 'tasks') ([string]$Contract.task_id))
    ).TrimEnd([char[]]@('\', '/'))
    $actualTaskDirectory = ([System.IO.Path]::GetFullPath($TaskDirectory)).TrimEnd([char[]]@('\', '/'))
    if (-not $actualTaskDirectory.Equals(
        $expectedTaskDirectory,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Task directory is outside the approved runtime task path: $actualTaskDirectory"
    }

    $expectedContractPath = [System.IO.Path]::GetFullPath(
        (Join-Path $actualTaskDirectory 'contract.json')
    )
    $actualContractPath = [System.IO.Path]::GetFullPath($ContractPath)
    if (-not $actualContractPath.Equals(
        $expectedContractPath,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "TaskContract path must be the contract.json inside its task directory: $actualContractPath"
    }
}

function Get-HarnessPersistedContract {
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [string]$ContractPath
    )

    $persistedContract = Get-HarnessJson -Path $ContractPath
    if ($persistedContract.task_id -ne $Contract.task_id) {
        throw 'In-memory TaskContract belongs to a different persisted task.'
    }
    return $persistedContract
}

function Assert-HarnessWorkerPackageIntegrity {
    param(
        [Parameter(Mandatory)]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$TaskDirectory,

        [Parameter(Mandatory)]
        [string]$TaskId,

        [Parameter(Mandatory)]
        [string]$ExpectedPackageSha256
    )

    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
        throw "Prepared Worker package not found: $PackagePath"
    }

    $actualPackageHash = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash
    if ($actualPackageHash -ne $ExpectedPackageSha256) {
        throw 'Prepared Worker package hash does not match the Ledger anchor.'
    }
    $package = Get-HarnessJson -Path $PackagePath
    if ($package.task_id -ne $TaskId) {
        throw "Prepared Worker package belongs to another task: $($package.task_id)"
    }
    if ($package.prompt_relative_path -ne 'worker_prompt.txt' -or
        $package.result_schema_relative_path -ne 'worker_result.schema.json') {
        throw 'Prepared Worker package contains unexpected execution paths.'
    }

    $taskRoot = ([System.IO.Path]::GetFullPath($TaskDirectory)).TrimEnd([char[]]@('\', '/'))
    $taskPrefix = $taskRoot + [System.IO.Path]::DirectorySeparatorChar
    foreach ($file in @($package.protected_files)) {
        if ([System.IO.Path]::IsPathRooted([string]$file.relative_path)) {
            throw "Worker package contains an absolute protected path: $($file.relative_path)"
        }
        $path = [System.IO.Path]::GetFullPath(
            (Join-Path $taskRoot ([string]$file.relative_path))
        )
        if (-not $path.StartsWith($taskPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Worker package protected path escapes the task directory: $path"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Prepared Worker input is missing: $path"
        }
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$file.sha256) {
            throw "Prepared Worker input changed after inspection: $path"
        }
    }

    return $package
}

function New-HarnessCodexWorkerPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [string]$ContractPath,

        [Parameter(Mandatory)]
        [string]$TaskDirectory,

        [Parameter(Mandatory)]
        [string]$RuntimeRoot,

        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$TaskContractSchemaPath,

        [Parameter(Mandatory)]
        [string]$WorkerResultSchemaPath
    )

    if (-not (Test-HarnessTaskContract -Contract $Contract -SchemaPath $TaskContractSchemaPath)) {
        throw "TaskContract failed schema validation: $($Contract.task_id)"
    }
    Assert-HarnessTaskLocation `
        -Contract $Contract `
        -ContractPath $ContractPath `
        -TaskDirectory $TaskDirectory `
        -RuntimeRoot $RuntimeRoot
    $Contract = Get-HarnessPersistedContract -Contract $Contract -ContractPath $ContractPath
    if (-not (Test-HarnessTaskContract -Contract $Contract -SchemaPath $TaskContractSchemaPath)) {
        throw "Persisted TaskContract failed schema validation: $($Contract.task_id)"
    }
    if ($Contract.state -ne 'routed') {
        throw "Codex Worker package requires a routed contract: $($Contract.task_id) [$($Contract.state)]"
    }
    $editingRoutes = @($Contract.route_plan | Where-Object { $_.project_id -eq 'ai_content' })
    $unsupportedRoutes = @($Contract.route_plan | Where-Object { $_.project_id -ne 'ai_content' })
    if ($editingRoutes.Count -ne 1 -or $unsupportedRoutes.Count -gt 0) {
        throw 'The supervised sports Worker slice requires exactly one ai_content route.'
    }
    $route = $editingRoutes[0]
    if (@($route.matched_domains) -notcontains 'sports' -or
        @($route.matched_actions) -notcontains 'create') {
        throw 'The first supervised Worker slice requires sports + create routing evidence.'
    }
    if (-not ($Contract.PSObject.Properties.Name -contains 'inputs') -or
        @($Contract.inputs.materials).Count -eq 0) {
        throw 'Supervised sports content execution requires at least one snapshotted material.'
    }
    if (-not (Test-Path -LiteralPath $WorkerResultSchemaPath -PathType Leaf)) {
        throw "Codex Worker result schema not found: $WorkerResultSchemaPath"
    }
    foreach ($material in @($Contract.inputs.materials)) {
        if (-not (Test-Path -LiteralPath $material.snapshot_path -PathType Leaf)) {
            throw "Task material snapshot not found: $($material.snapshot_path)"
        }
        $snapshotHash = (Get-FileHash -LiteralPath $material.snapshot_path -Algorithm SHA256).Hash
        if ($snapshotHash -ne [string]$material.sha256) {
            throw "Task material snapshot hash does not match the TaskContract: $($material.snapshot_path)"
        }
    }

    $contextDirectory = Join-Path $TaskDirectory 'context'
    New-Item -ItemType Directory -Force -Path $contextDirectory -ErrorAction Stop | Out-Null
    $contextSources = @(
        [pscustomobject]@{
            source = Join-Path $route.project_root 'AGENTS.md'
            target = Join-Path $contextDirectory 'project-rules.txt'
        },
        [pscustomobject]@{
            source = Join-Path $route.project_memory '01_项目规则与关键决策.md'
            target = Join-Path $contextDirectory 'project-decisions.txt'
        },
        [pscustomobject]@{
            source = Join-Path $route.project_memory '02_当前状态.md'
            target = Join-Path $contextDirectory 'project-state.txt'
        }
    )

    foreach ($contextSource in $contextSources) {
        if (-not (Test-Path -LiteralPath $contextSource.source -PathType Leaf)) {
            throw "Required Worker context not found: $($contextSource.source)"
        }
        $content = Get-Content -Raw -LiteralPath $contextSource.source
        Assert-HarnessRequestSafe -Request $content
        $content | Set-Content -LiteralPath $contextSource.target -Encoding utf8 -ErrorAction Stop
    }

    $promptPath = Join-Path $TaskDirectory 'worker_prompt.txt'
    $prompt = @"
你是 Hermes Harness 的受监督运动内容 Worker。

任务边界：
- 读取 contract.json、context 目录与 inputs 目录。
- 只能使用 inputs 目录中的材料快照作为事实来源。
- 只生成候选草稿；不得发布、不得修改目标项目、不得修改核心规则或任何权威文件。
- 结果必须严格符合指定 JSON Schema，在 material_sha256 中列出实际使用的材料哈希，并为事实主张提供材料中的逐字 source_quote；不得编造引文。
- 若材料不足，返回 blocked 和明确 blocking_issues，不得补写未核验事实。

原始目标：$($Contract.goal)
任务编号：$($Contract.task_id)
"@
    $prompt | Set-Content -LiteralPath $promptPath -Encoding utf8 -ErrorAction Stop

    $workerSchemaSnapshotPath = Join-Path $TaskDirectory 'worker_result.schema.json'
    Copy-Item `
        -LiteralPath $WorkerResultSchemaPath `
        -Destination $workerSchemaSnapshotPath `
        -Force `
        -ErrorAction Stop

    $protectedPaths = [System.Collections.Generic.List[string]]::new()
    $protectedPaths.Add([System.IO.Path]::GetFullPath($ContractPath))
    $inputPath = Join-Path $TaskDirectory 'input.txt'
    if (Test-Path -LiteralPath $inputPath -PathType Leaf) {
        $protectedPaths.Add([System.IO.Path]::GetFullPath($inputPath))
    }
    foreach ($material in @($Contract.inputs.materials)) {
        $protectedPaths.Add([System.IO.Path]::GetFullPath([string]$material.snapshot_path))
    }
    foreach ($contextSource in $contextSources) {
        $protectedPaths.Add([System.IO.Path]::GetFullPath([string]$contextSource.target))
    }
    $protectedPaths.Add([System.IO.Path]::GetFullPath($promptPath))
    $protectedPaths.Add([System.IO.Path]::GetFullPath($workerSchemaSnapshotPath))

    $protectedFiles = foreach ($path in $protectedPaths) {
        [pscustomobject]@{
            relative_path = [System.IO.Path]::GetRelativePath($TaskDirectory, $path)
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        }
    }
    $packagePath = Join-Path $TaskDirectory 'worker_package.json'
    $package = [pscustomobject]@{
        schema_version = '1.0'
        task_id = $Contract.task_id
        created_at = (Get-Date).ToString('o')
        prompt_relative_path = 'worker_prompt.txt'
        result_schema_relative_path = 'worker_result.schema.json'
        protected_files = @($protectedFiles)
    }
    Write-HarnessJson -Value $package -Path $packagePath
    $packageSha256 = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash

    Write-HarnessLedgerEvent `
        -LedgerPath $LedgerPath `
        -TaskId $Contract.task_id `
        -State 'routed' `
        -Event 'worker_ready' `
        -Details @{
            prompt_path = $promptPath
            package_path = $packagePath
            package_sha256 = $packageSha256
        }

    return [pscustomobject]@{
        task_id = $Contract.task_id
        state = 'awaiting_worker_start'
        attempts = 0
        prompt_path = $promptPath
        task_directory = $TaskDirectory
        result_schema_path = $workerSchemaSnapshotPath
        package_path = $packagePath
        package_sha256 = $packageSha256
    }
}

function Test-HarnessCodexWorkerResult {
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [string]$WorkerResultSchemaPath
    )

    try {
        $json = $Result | ConvertTo-Json -Depth 30
        $validSchema = $json | Test-Json -SchemaFile $WorkerResultSchemaPath -ErrorAction Stop
        if (-not $validSchema) {
            return [pscustomobject]@{ passed = $false; reason = 'worker_result_schema_invalid' }
        }
    }
    catch {
        return [pscustomobject]@{
            passed = $false
            reason = "worker_result_schema_error: $($_.Exception.Message)"
        }
    }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($Result.status -ne 'candidate') {
        $reasons.Add("worker_status_$($Result.status)")
    }
    if ([string]::IsNullOrWhiteSpace([string]$Result.artifact_text)) {
        $reasons.Add('artifact_text_empty')
    }
    else {
        try {
            Assert-HarnessRequestSafe -Request ([string]$Result.artifact_text)
        }
        catch {
            $reasons.Add('artifact_contains_sensitive_credential_pattern')
        }
    }
    if (@($Result.blocking_issues).Count -gt 0) {
        $reasons.Add('blocking_issues_present')
    }
    if (-not [bool]$Result.checks.used_only_supplied_materials) {
        $reasons.Add('used_only_supplied_materials_false')
    }
    if ([bool]$Result.checks.contains_unverified_claims) {
        $reasons.Add('contains_unverified_claims')
    }
    if ([bool]$Result.checks.publish_attempted) {
        $reasons.Add('publish_attempted')
    }
    if ([bool]$Result.checks.authority_files_modified) {
        $reasons.Add('authority_files_modified')
    }

    $knownHashes = @($Contract.inputs.materials | ForEach-Object { [string]$_.sha256 })
    $materialContentByHash = @{}
    foreach ($material in @($Contract.inputs.materials)) {
        $actualHash = (Get-FileHash -LiteralPath $material.snapshot_path -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$material.sha256) {
            $reasons.Add('material_snapshot_hash_mismatch')
            continue
        }
        $materialContentByHash[[string]$material.sha256] =
            Get-Content -Raw -LiteralPath $material.snapshot_path
    }

    $reportedHashes = @($Result.material_sha256 | ForEach-Object { [string]$_ })
    if ($reportedHashes.Count -eq 0) {
        $reasons.Add('material_evidence_missing')
    }
    elseif (@($reportedHashes | Where-Object { $knownHashes -notcontains $_ }).Count -gt 0) {
        $reasons.Add('unknown_material_hash')
    }

    $evidenceHashes = [System.Collections.Generic.List[string]]::new()
    if (@($Result.evidence).Count -eq 0) {
        $reasons.Add('evidence_missing')
    }
    foreach ($evidence in @($Result.evidence)) {
        $evidenceHash = [string]$evidence.material_sha256
        if (-not $evidenceHashes.Contains($evidenceHash)) {
            $evidenceHashes.Add($evidenceHash)
        }
        if ($knownHashes -notcontains $evidenceHash) {
            $reasons.Add('unknown_evidence_material_hash')
            continue
        }
        if ($reportedHashes -notcontains $evidenceHash) {
            $reasons.Add('evidence_hash_not_declared')
        }
        $sourceQuote = [string]$evidence.source_quote
        if (-not $materialContentByHash.ContainsKey($evidenceHash) -or
            $materialContentByHash[$evidenceHash].IndexOf(
                $sourceQuote,
                [System.StringComparison]::Ordinal
            ) -lt 0) {
            $reasons.Add('evidence_quote_not_found')
        }
        $claim = [string]$evidence.claim
        if (([string]$Result.artifact_text).IndexOf(
            $claim,
            [System.StringComparison]::Ordinal
        ) -lt 0) {
            $reasons.Add('evidence_claim_not_in_artifact')
        }
        if ($sourceQuote.IndexOf($claim, [System.StringComparison]::Ordinal) -lt 0) {
            $reasons.Add('evidence_claim_not_supported_verbatim')
        }
    }
    if (@($reportedHashes | Where-Object { -not $evidenceHashes.Contains($_) }).Count -gt 0) {
        $reasons.Add('material_hash_without_evidence')
    }

    if ($null -ne $Contract.constraints.duration_seconds) {
        if ($null -eq $Result.estimated_duration_seconds) {
            $reasons.Add('duration_not_estimated')
        }
        elseif ([int]$Result.estimated_duration_seconds -gt [int]$Contract.constraints.duration_seconds) {
            $reasons.Add('duration_limit_exceeded')
        }
    }

    return [pscustomobject]@{
        passed = ($reasons.Count -eq 0)
        reason = if ($reasons.Count -eq 0) { 'accepted' } else { $reasons -join ',' }
    }
}

function Invoke-HarnessCodexCli {
    param(
        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$OutputSchemaPath,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [int]$Attempt
    )

    $codexCommand = Get-Command codex -ErrorAction Stop
    $arguments = @(
        'exec',
        '--ephemeral',
        '--ignore-user-config',
        '--skip-git-repo-check',
        '--sandbox', 'read-only',
        '--cd', $WorkingDirectory,
        '--output-schema', $OutputSchemaPath,
        '--output-last-message', $OutputPath,
        '-'
    )
    $prompt = Get-Content -Raw -LiteralPath $PromptPath
    $null = $prompt | & $codexCommand.Source @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "codex exec failed with exit code $LASTEXITCODE on attempt $Attempt"
    }
}

function Invoke-HarnessCodexTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [string]$ContractPath,

        [Parameter(Mandatory)]
        [string]$TaskDirectory,

        [Parameter(Mandatory)]
        [string]$RuntimeRoot,

        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$TaskContractSchemaPath,

        [Parameter(Mandatory)]
        [string]$WorkerResultSchemaPath,

        [switch]$Approved,

        [scriptblock]$CodexInvoker
    )

    if (-not (Test-HarnessTaskContract -Contract $Contract -SchemaPath $TaskContractSchemaPath)) {
        throw "TaskContract failed schema validation: $($Contract.task_id)"
    }
    Assert-HarnessTaskLocation `
        -Contract $Contract `
        -ContractPath $ContractPath `
        -TaskDirectory $TaskDirectory `
        -RuntimeRoot $RuntimeRoot
    $Contract = Get-HarnessPersistedContract -Contract $Contract -ContractPath $ContractPath
    if (-not (Test-HarnessTaskContract -Contract $Contract -SchemaPath $TaskContractSchemaPath)) {
        throw "Persisted TaskContract failed schema validation: $($Contract.task_id)"
    }

    $latestState = Get-HarnessTaskState -LedgerPath $LedgerPath -TaskId $Contract.task_id
    if (@('completed', 'failed') -contains $latestState.state) {
        throw "Ledger already contains a terminal state for task $($Contract.task_id): $($latestState.state)"
    }
    if ($Approved -and $latestState.state -ne 'routed') {
        throw "Interrupted Worker task cannot be redispatched automatically: $($latestState.state)"
    }

    $packagePath = Join-Path $TaskDirectory 'worker_package.json'
    $expectedPackageSha256 = if (
        $latestState.PSObject.Properties.Name -contains 'details' -and
        $latestState.details.PSObject.Properties.Name -contains 'package_sha256'
    ) {
        [string]$latestState.details.package_sha256
    }
    else {
        $null
    }
    if (-not $Approved) {
        $package = if (Test-Path -LiteralPath $packagePath -PathType Leaf) {
            if ([string]::IsNullOrWhiteSpace($expectedPackageSha256)) {
                throw 'Prepared Worker package has no Ledger hash anchor.'
            }
            $manifest = Assert-HarnessWorkerPackageIntegrity `
                -PackagePath $packagePath `
                -TaskDirectory $TaskDirectory `
                -TaskId $Contract.task_id `
                -ExpectedPackageSha256 $expectedPackageSha256
            [pscustomobject]@{
                task_id = $Contract.task_id
                state = 'awaiting_worker_start'
                attempts = 0
                prompt_path = Join-Path $TaskDirectory $manifest.prompt_relative_path
                task_directory = $TaskDirectory
                result_schema_path = Join-Path $TaskDirectory $manifest.result_schema_relative_path
                package_path = $packagePath
                package_sha256 = $expectedPackageSha256
            }
        }
        else {
            New-HarnessCodexWorkerPackage `
                -Contract $Contract `
                -ContractPath $ContractPath `
                -TaskDirectory $TaskDirectory `
                -RuntimeRoot $RuntimeRoot `
                -LedgerPath $LedgerPath `
                -TaskContractSchemaPath $TaskContractSchemaPath `
                -WorkerResultSchemaPath $WorkerResultSchemaPath
        }

        return [pscustomobject]@{
            task_id = $package.task_id
            state = $package.state
            attempts = $package.attempts
            contract_path = $ContractPath
            prompt_path = $package.prompt_path
            task_directory = $package.task_directory
            result_schema_path = $package.result_schema_path
            package_path = $package.package_path
            package_sha256 = $package.package_sha256
        }
    }

    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw 'Worker execution must resume a previously inspected package.'
    }
    if ([string]::IsNullOrWhiteSpace($expectedPackageSha256)) {
        throw 'Prepared Worker package has no Ledger hash anchor.'
    }
    $packageManifest = Assert-HarnessWorkerPackageIntegrity `
        -PackagePath $packagePath `
        -TaskDirectory $TaskDirectory `
        -TaskId $Contract.task_id `
        -ExpectedPackageSha256 $expectedPackageSha256
    $package = [pscustomobject]@{
        prompt_path = Join-Path $TaskDirectory $packageManifest.prompt_relative_path
        result_schema_path = Join-Path $TaskDirectory $packageManifest.result_schema_relative_path
    }
    $effectiveWorkerResultSchemaPath = $package.result_schema_path

    if (-not $CodexInvoker) {
        $CodexInvoker = {
            param($promptPath, $outputPath, $outputSchemaPath, $workingDirectory, $attempt)
            Invoke-HarnessCodexCli `
                -PromptPath $promptPath `
                -OutputPath $outputPath `
                -OutputSchemaPath $outputSchemaPath `
                -WorkingDirectory $workingDirectory `
                -Attempt $attempt
        }
    }

    $workerState = @{
        repair_reason = $null
        attempt_paths = [System.Collections.Generic.List[string]]::new()
    }
    $basePrompt = Get-Content -Raw -LiteralPath $package.prompt_path
    $candidateArtifactPath = Join-Path $TaskDirectory 'result.txt'
    $receiptPath = Join-Path $TaskDirectory 'execution_receipt.json'

    $loopResult = Invoke-HarnessTaskLoop `
        -Contract $Contract `
        -LedgerPath $LedgerPath `
        -SchemaPath $TaskContractSchemaPath `
        -ContractPath $ContractPath `
        -SuccessState 'waiting_for_approval' `
        -SuccessEvent 'candidate_ready_for_review' `
        -SuccessPendingAction 'content_fact_review' `
        -BeforeSuccessPersistence {
            param($currentContract, $candidate, $verification, $attempt)
            [string]$candidate.artifact_text |
                Set-Content -LiteralPath $candidateArtifactPath -Encoding utf8 -ErrorAction Stop
            $candidateReceipt = [pscustomobject]@{
                task_id = $currentContract.task_id
                state = 'waiting_for_approval'
                attempts = $attempt
                artifact_path = $candidateArtifactPath
                attempt_result_paths = @($workerState.attempt_paths)
                verification = $verification
            }
            Write-HarnessJson -Value $candidateReceipt -Path $receiptPath
        } `
        -Worker {
            param($currentContract, $attempt)

            $attemptPromptPath = if ($attempt -eq 1) {
                $package.prompt_path
            }
            else {
                Join-Path $TaskDirectory "worker_prompt.attempt-$attempt.txt"
            }
            if ($attempt -gt 1) {
                @(
                    $basePrompt
                    ''
                    '上一次验证失败，必须只修复以下问题：'
                    [string]$workerState.repair_reason
                ) | Set-Content -LiteralPath $attemptPromptPath -Encoding utf8 -ErrorAction Stop
            }

            $outputPath = Join-Path $TaskDirectory "worker_result.attempt-$attempt.json"
            $null = Assert-HarnessWorkerPackageIntegrity `
                -PackagePath $packagePath `
                -TaskDirectory $TaskDirectory `
                -TaskId $currentContract.task_id `
                -ExpectedPackageSha256 $expectedPackageSha256
            & $CodexInvoker `
                $attemptPromptPath `
                $outputPath `
                $effectiveWorkerResultSchemaPath `
                $TaskDirectory `
                $attempt
            $null = Assert-HarnessWorkerPackageIntegrity `
                -PackagePath $packagePath `
                -TaskDirectory $TaskDirectory `
                -TaskId $currentContract.task_id `
                -ExpectedPackageSha256 $expectedPackageSha256
            if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
                throw "Codex Worker did not create a result file on attempt $attempt."
            }
            $workerState.attempt_paths.Add($outputPath)
            return Get-HarnessJson -Path $outputPath
        } `
        -Verifier {
            param($currentContract, $artifact, $attempt)
            $verification = Test-HarnessCodexWorkerResult `
                -Contract $currentContract `
                -Result $artifact `
                -WorkerResultSchemaPath $effectiveWorkerResultSchemaPath
            $workerState.repair_reason = $verification.reason
            return $verification
        }

    $artifactPath = if ($loopResult.state -eq 'waiting_for_approval') {
        $candidateArtifactPath
    }
    else {
        $null
    }
    if ($loopResult.state -eq 'failed') {
        $failureReceipt = [pscustomobject]@{
            task_id = $Contract.task_id
            state = $loopResult.state
            attempts = $loopResult.attempts
            artifact_path = $null
            attempt_result_paths = @($workerState.attempt_paths)
            verification = $loopResult.verification
        }
        Write-HarnessJson -Value $failureReceipt -Path $receiptPath
    }

    return [pscustomobject]@{
        task_id = $Contract.task_id
        state = $loopResult.state
        attempts = $loopResult.attempts
        artifact_path = $artifactPath
        receipt_path = $receiptPath
        result = $loopResult.result
        verification = $loopResult.verification
    }
}

function Get-HarnessTaskState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$TaskId
    )

    if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) {
        throw "Task ledger not found: $LedgerPath"
    }

    $latest = $null
    foreach ($line in Get-Content -LiteralPath $LedgerPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $event = $line | ConvertFrom-Json
        if ($event.task_id -eq $TaskId) {
            $latest = $event
        }
    }

    if (-not $latest) {
        throw "Task not found in ledger: $TaskId"
    }

    return $latest
}

function Test-HarnessTaskContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Contract,

        [Parameter(Mandatory)]
        [string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "TaskContract schema not found: $SchemaPath"
    }

    $json = $Contract | ConvertTo-Json -Depth 30
    return $json | Test-Json -SchemaFile $SchemaPath -ErrorAction Stop
}

. (Join-Path $PSScriptRoot 'SoloCompanyAudit.ps1')

Export-ModuleMember -Function @(
    'Update-HarnessProjectRegistry',
    'New-HarnessTask',
    'Invoke-HarnessTaskLoop',
    'New-HarnessCodexWorkerPackage',
    'Invoke-HarnessCodexTask',
    'Invoke-HarnessSoloCompanyAudit',
    'Get-HarnessTaskState',
    'Test-HarnessTaskContract',
    'Assert-HarnessTextSafe'
)
