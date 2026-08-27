[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Label
    )

    if ($Actual -ne $Expected) {
        throw "$Label mismatch. Expected '$Expected', got '$Actual'."
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workerPath = Join-Path $repositoryRoot 'agent\ident-db-agent\IdentWorker.ps1'
$tempRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp-agent-lifecycle'))
$allowedPrefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '.tmp'))
if (-not $tempRoot.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Temporary test directory must stay inside test/.tmp*.'
}

$portProbe = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()

$backendJob = $null
$worker = $null
try {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'robot') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tempRoot 'commands') | Out-Null

    $fakeRobot = @'
param(
    [string]$Mode,
    [string]$ConfigPath,
    [string]$TaskFile,
    [int]$MaxTasks,
    [int]$MinUserIdleSeconds,
    [switch]$Execute
)
Add-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'robot-executions.txt') -Value 'run'
exit 0
'@
    Set-Content `
        -LiteralPath (Join-Path $tempRoot 'robot\Start-IdentRobot.ps1') `
        -Value $fakeRobot `
        -Encoding UTF8

    $robotConfig = @{
        workflow = @{
            allowUnsafeExecution = $true
            confirmBeforeEachStep = $false
            successCondition = @{
                type = 'elementMissing'
                selector = 'saveButton'
                timeoutSeconds = 1
            }
            steps = @(
                @{
                    name = 'save'
                    action = 'click'
                    selector = 'saveButton'
                }
            )
        }
        selectors = @{
            saveButton = @{
                name = 'Save'
                automationId = ''
                className = ''
                controlType = ''
            }
        }
    }
    $robotConfig |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $tempRoot 'robot\config.local.json') -Encoding UTF8

    $encryptedSecret = ConvertFrom-SecureString (ConvertTo-SecureString 'test-key' -AsPlainText -Force)
    @{
        version = 2
        sqlPasswordDpapi = $encryptedSecret
        agentApiKeyDpapi = $encryptedSecret
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $tempRoot 'secrets.json') -Encoding UTF8
    @{
        doctorsSql = ''
        branchesSql = ''
        intervalsSql = ''
    } |
        ConvertTo-Json |
        Set-Content -LiteralPath (Join-Path $tempRoot 'mapping.json') -Encoding UTF8
    @{
        generatedAt = (Get-Date).ToString('o')
        server = '127.0.0.1'
        database = 'IDENT'
        summary = @{ tables = 1; columns = 1 }
        tables = @(
            @{
                schema = 'dbo'
                name = 'Doctors'
                type = 'BASE TABLE'
                columns = @(
                    @{ position = 1; name = 'Id'; type = 'int'; nullable = $false }
                )
            }
        )
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $tempRoot 'schema.json') -Encoding UTF8

    $config = [ordered]@{
        version = 2
        agent = @{ id = 'robot-lifecycle'; version = '2.9.0-test' }
        features = @{ scheduleEnabled = $false; robotEnabled = $true }
        robot = @{ minUserIdleSeconds = 60 }
        intervals = @{ heartbeatSeconds = 30; scheduleSeconds = 60; schemaSeconds = 300; robotSeconds = 15 }
        sql = @{
            server = '127.0.0.1'
            instanceName = ''
            port = 1
            database = ''
            user = 'readonly_user'
            encrypt = $false
            trustServerCertificate = $true
            connectTimeoutSeconds = 1
            commandTimeoutSeconds = 1
        }
        backend = @{ baseUrl = "http://127.0.0.1:$port"; timeoutSeconds = 2 }
        paths = @{
            secrets = 'secrets.json'
            mapping = 'mapping.json'
            schemaOutput = 'schema.json'
            log = 'logs\agent.log'
            pushResult = 'result.json'
            runtimeState = 'state.json'
            commandDirectory = 'commands'
            robotConfig = 'robot\config.local.json'
            robotReceipts = 'receipts.json'
        }
    }
    $config |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath (Join-Path $tempRoot 'config.json') -Encoding UTF8

    $backendCode = @'
const http = require("http");
const port = Number(process.argv[2]);
let claims = 0;
let completes = 0;
let fails = 0;
let completed = false;
const record = {
  id: "task-1",
  fingerprint: "fp-1",
  status: "robot_processing",
  ticket: {
    Id: "task-1",
    ClientPhone: "+79990000000",
    ClientFullName: "Test Patient",
    PlanStart: "2026-08-01T10:00:00+03:00",
    DoctorName: "Doctor"
  }
};
const send = (res, status, body) => {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(text)
  });
  res.end(text);
};
const server = http.createServer((req, res) => {
  req.resume();
  req.on("end", () => {
    if (req.url === "/api/agent/heartbeat") {
      return send(res, 200, {
        desired: {
          scheduleEnabled: false,
          robotEnabled: true,
          mappingRevision: "2026-07-30T15:30:00.000Z",
          scheduleMapping: {
            doctorsSql: "SELECT Id, Name FROM dbo.Doctors",
            branchesSql: "SELECT Id, Name FROM dbo.Branches",
            intervalsSql: "SELECT DoctorId, BranchId, StartDateTime, LengthInMinutes, IsBusy FROM dbo.Schedule",
            servicesSql: "SELECT Id, Name, Price FROM dbo.ServiceItems",
            notes: ["remote test mapping"]
          }
        }
      });
    }
    if (req.url === "/api/agent/schema") {
      return send(res, 200, { summary: { tables: 1, columns: 1 } });
    }
    if (req.url === "/api/robot/tasks/claim") {
      claims += 1;
      return send(res, 200, { record: completed ? null : record });
    }
    if (req.url === "/api/robot/tasks/complete") {
      completes += 1;
      if (completes === 1) {
        return send(res, 500, { error: "simulated lost acknowledgement" });
      }
      completed = true;
      return send(res, 200, { record: { ...record, status: "robot_completed" } });
    }
    if (req.url === "/api/robot/tasks/fail") {
      fails += 1;
      return send(res, 200, { record: { ...record, status: "robot_failed" } });
    }
    if (req.url === "/status") {
      return send(res, 200, { claims, completes, fails, completed });
    }
    if (req.url === "/shutdown") {
      send(res, 200, { ok: true });
      return server.close();
    }
    return send(res, 404, { error: "not found" });
  });
});
server.listen(port, "127.0.0.1");
'@
    $backendCodeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($backendCode))
    $backendJob = Start-Job -ScriptBlock {
        param($CodeBase64, $Port)
        & node -e 'eval(Buffer.from(process.argv[1],String.fromCharCode(98,97,115,101,54,52)).toString())' $CodeBase64 $Port
    } -ArgumentList $backendCodeBase64, $port

    $ready = $false
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$port/status" -TimeoutSec 1)
            $ready = $true
            break
        }
        catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $ready) {
        $backendOutput = Receive-Job -Job $backendJob -Keep -ErrorAction SilentlyContinue | Out-String
        $backendErrors = @($backendJob.ChildJobs[0].Error | ForEach-Object { $_.ToString() }) -join ' | '
        $backendReason = [string]$backendJob.ChildJobs[0].JobStateInfo.Reason
        throw "Fake backend did not start. State=$($backendJob.State). Reason=$backendReason Errors=$backendErrors Output=$($backendOutput.Trim())"
    }

    $previousTestIdle = $env:CODE9_IDENT_TEST_IDLE_SECONDS
    $previousTestDesktop = $env:CODE9_IDENT_TEST_INTERACTIVE_DESKTOP
    $env:CODE9_IDENT_TEST_IDLE_SECONDS = '600'
    $env:CODE9_IDENT_TEST_INTERACTIVE_DESKTOP = '1'
    $worker = Start-Process powershell.exe -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $workerPath,
        '-ConfigPath',
        (Join-Path $tempRoot 'config.json')
    ) -WindowStyle Hidden -PassThru
    $env:CODE9_IDENT_TEST_IDLE_SECONDS = $previousTestIdle
    $env:CODE9_IDENT_TEST_INTERACTIVE_DESKTOP = $previousTestDesktop

    $status = $null
    for ($attempt = 0; $attempt -lt 28; $attempt++) {
        Start-Sleep -Seconds 1
        $status = Invoke-RestMethod -Uri "http://127.0.0.1:$port/status" -TimeoutSec 1
        if ([bool]$status.completed) {
            break
        }
    }

    $executionPath = Join-Path $tempRoot 'robot-executions.txt'
    $executionCount = if (Test-Path -LiteralPath $executionPath) {
        @(Get-Content -LiteralPath $executionPath).Count
    } else {
        0
    }
    $state = Get-Content -LiteralPath (Join-Path $tempRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $appliedMapping = Get-Content -LiteralPath (Join-Path $tempRoot 'mapping.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    Write-Host "Robot executions: $executionCount"
    Write-Host "Claims/completes/fails: $($status.claims)/$($status.completes)/$($status.fails)"
    Write-Host "Server completed: $($status.completed)"
    Write-Host "Worker robot state: $($state.robot.state)"
    Write-Host "Worker robot error: $($state.robot.lastError)"

    Assert-Equal -Actual $executionCount -Expected 1 -Label 'Robot execution count'
    Assert-Equal -Actual ([int]$status.completes) -Expected 2 -Label 'Complete request count'
    Assert-Equal -Actual ([int]$status.fails) -Expected 0 -Label 'Fail request count'
    Assert-Equal -Actual ([bool]$status.completed) -Expected $true -Label 'Recovered completion'
    Assert-Equal -Actual ([string]$state.robot.state) -Expected 'idle' -Label 'Final robot state'
    Assert-Equal -Actual ([string]$state.schema.state) -Expected 'ok' -Label 'Schema upload state'
    Assert-Equal -Actual ([int]$state.schema.tables) -Expected 1 -Label 'Uploaded schema table count'
    Assert-Equal -Actual ([string]$state.schedule.mappingRevision) -Expected '2026-07-30T15:30:00.000Z' -Label 'Remote mapping revision'
    Assert-Equal -Actual ([string]$appliedMapping.doctorsSql) -Expected 'SELECT Id, Name FROM dbo.Doctors' -Label 'Remote doctors SQL'
    Assert-Equal -Actual ([string]$appliedMapping.intervalsSql) -Expected 'SELECT DoctorId, BranchId, StartDateTime, LengthInMinutes, IsBusy FROM dbo.Schedule' -Label 'Remote intervals SQL'
    Assert-Equal -Actual ([string]$appliedMapping.servicesSql) -Expected 'SELECT Id, Name, Price FROM dbo.ServiceItems' -Label 'Remote services SQL'
    Assert-Equal -Actual (Test-Path -LiteralPath (Join-Path $tempRoot 'receipts.json')) -Expected $true -Label 'Receipt file'

    Write-Host 'IDENT WORKER LIFECYCLE TEST OK' -ForegroundColor Green
}
finally {
    if ($null -ne $worker -and -not $worker.HasExited) {
        Stop-Process -Id $worker.Id -Force
    }
    if ($null -ne $backendJob) {
        try {
            [void](Invoke-RestMethod -Uri "http://127.0.0.1:$port/shutdown" -TimeoutSec 1)
        }
        catch {
        }
        [void](Wait-Job -Job $backendJob -Timeout 3)
        Stop-Job -Job $backendJob -ErrorAction SilentlyContinue
        Remove-Job -Job $backendJob -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
