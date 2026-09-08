[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'robot\ident-rpa\Start-IdentRobot.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in @('Format-Bounds', 'Get-UiTreeRows', 'Export-UiTree')) {
    $node = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Set-Item -Path "Function:$name" -Value $node.Body.GetScriptBlock()
}

$form = New-Object System.Windows.Forms.Form
$output = Join-Path $env:TEMP ('ident-ui-scan-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    if (@(Get-UiTreeRows -Roots @() -MaxDepth 0).Count -ne 0) { throw 'Empty scan must be empty.' }
    # Create a hidden test-only HWND, without interacting with the user's apps.
    $form.Text = 'IDENT scan regression fixture'
    $element = [System.Windows.Automation.AutomationElement]::FromHandle($form.Handle)
    $rows = @(Export-UiTree -Roots @($element) -MaxDepth 0 -OutputPath $output)
    if ($rows.Count -ne 1 -or $rows[0].name -ne $form.Text) { throw 'Scan must preserve the fixture root.' }
    if (-not $rows[0].Contains('patterns') -or -not $rows[0].Contains('rootName')) { throw 'Missing scan metadata.' }
    $json = Get-Content -LiteralPath $output -Raw -Encoding UTF8
    if (-not $json.TrimStart().StartsWith('[')) { throw 'Single-row export must remain a JSON array.' }
    if (@($json | ConvertFrom-Json).Count -ne 1) { throw 'Exported row was lost.' }
    $rows = @(Export-UiTree -Roots @($element, $element) -MaxDepth 0 -OutputPath $output)
    if ($rows.Count -ne 2 -or $rows[1].path -ne '1') { throw 'Multiple roots were lost.' }
    $null = Export-UiTree -Roots @() -MaxDepth 0 -OutputPath $output
    if ((Get-Content -LiteralPath $output -Raw) -notmatch '^\s*\[\s*\]\s*$') { throw 'Empty export must be a JSON array.' }
    Write-Host 'IDENT UI SCAN REGRESSION OK'
}
finally {
    $form.Dispose()
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
}
