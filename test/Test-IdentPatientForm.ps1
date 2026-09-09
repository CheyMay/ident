[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repo 'robot\ident-rpa\IdentPatientForm.ps1')
. (Join-Path $PSScriptRoot 'fixtures\ident-patient-form.ps1')
function Assert-True([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Node([object[]]$Rows,[string]$Path) { return @($Rows | Where-Object path -eq $Path)[0] }
function Reject-Form([object[]]$Rows,[string]$Message) {
    $form=Get-IdentPatientFormBindings $Rows
    Assert-True (-not $form.Ok -and $form.Fields.Count -eq 0 -and -not $form.ReadyForInput) $Message
}
function Reject-Context([scriptblock]$Action) {
    $rejected=$false
    try { & $Action } catch { $rejected=$true; Assert-True ($_.Exception.Message -notmatch 'Fixture|2099|09:45') 'Context error leaked appointment data.' }
    Assert-True $rejected 'Wrong booking context accepted.'
}

foreach ($expanded in @($false,$true)) {
    foreach ($scale in @(0.8,1,1.25,1.5,2)) {
        $rows=@(New-IdentPatientFormFixture -Expanded:$expanded -Scale $scale -OffsetX -2200 -OffsetY 30)
        $form=Get-IdentPatientFormBindings $rows
        Assert-True ($form.Ok -and $form.Fields.Count -eq 6) 'Supported form fields not found.'
        Assert-True ($form.Fields.patientFirstNameInput.Path -eq '0/4' -and $form.Fields.patientMiddleNameInput.Path -eq '0/5') 'Name parts were conflated.'
        $expectedComment=if($expanded){'0/36/5/0'}else{'0/15/5/0'}
        Assert-True ($form.Fields.commentInput.Path -eq $expectedComment) 'Patient note/referral/address selected as appointment comment.'
        Assert-True ($form.Appointment.DurationMinutes -eq 45 -and $form.Appointment.Date -eq '2099-09-20') 'Title context lost.'
        Assert-True (-not $form.ReadyForInput -and -not $form.ReadyForUnattendedExecution) 'Passive discovery enabled input.'
        [array]::Reverse($rows)
        Assert-True ((Get-IdentPatientFormBindings $rows).Ok) 'Discovery depends on input array order.'
    }
}

# Paths are freshly discovered, not a saved index map.
$rows=@(New-IdentPatientFormFixture -Expanded)
$rewrite=@{'0/1'='0/101';'0/3'='0/103';'0/4'='0/104';'0/5'='0/105';'0/6'='0/106';'0/12'='0/112';'0/13'='0/113'}
foreach($row in $rows){if($rewrite.ContainsKey($row.path)){$row.path=$rewrite[$row.path]};$row.path=$row.path -replace '^0/36(?=/|$)','0/136'}
$form=Get-IdentPatientFormBindings $rows
Assert-True ($form.Ok -and $form.Fields.patientFirstNameInput.Path -eq '0/104' -and $form.Fields.commentInput.Path -eq '0/136/5/0') 'Cached tree indices were required.'

foreach($path in @('0','0/3','0/4','0/5','0/6','0/12','0/13','0/36','0/36/3','0/36/5','0/36/5/0')) {
    foreach($property in @('isOffscreen','isEnabled','bounds')) {
        $rows=@(New-IdentPatientFormFixture -Expanded); $node=Node $rows $path
        switch($property){'isOffscreen'{$node.isOffscreen=$true};'isEnabled'{$node.isEnabled=$false};'bounds'{$node.bounds=''}}
        Reject-Form $rows "Unavailable field was accepted: $path $property"
    }
}
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/4').bounds='379,272,293,70'
Reject-Form $rows 'Unexpected name field dimensions accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/13').bounds='-9000,231,212,30'
Reject-Form $rows 'Off-viewport field accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/4').patterns=@()
Reject-Form $rows 'Non-writable name candidate accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/4').automationId='UnrelatedField'
Reject-Form $rows 'Unrelated name field accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/13').rootName='Other patient form'
Reject-Form $rows 'Mixed window data accepted.'
$rows=@(New-IdentPatientFormFixture); $extra=(Node $rows '0/3').PSObject.Copy(); $extra.path='0/99'
Reject-Form @($rows+$extra) 'Duplicate surname accepted.'
$rows=@(New-IdentPatientFormFixture); $extra=(Node $rows '0/13').PSObject.Copy(); $extra.path='0/99'
Reject-Form @($rows+$extra) 'Duplicate phone accepted.'
$rows=@(New-IdentPatientFormFixture); $extra=(Node $rows '0/4').PSObject.Copy(); $extra.path='0/99'
Reject-Form @($rows+$extra) 'Ambiguous name candidate accepted.'
$rows=@(New-IdentPatientFormFixture); $extra=(Node $rows '0/15/5/0').PSObject.Copy(); $extra.path='0/15/5/1'
Reject-Form @($rows+$extra) 'Duplicate appointment comment accepted.'
$rows=@(New-IdentPatientFormFixture); $extra=(Node $rows '0/15/3').PSObject.Copy(); $extra.path='0/15/99'
Reject-Form @($rows+$extra) 'Duplicate interval anchor accepted.'
$rows=@(New-IdentPatientFormFixture); Reject-Form @($rows+$rows[1]) 'Duplicate path accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0/15/3').name='09:00 - 09:30'
Reject-Form $rows 'Time label/title mismatch accepted.'
$rows=@(New-IdentPatientFormFixture); (Node $rows '0').name='Calendar'
Reject-Form $rows 'Non-appointment root accepted.'
Reject-Form @() 'Empty tree accepted.'
Reject-Form @([pscustomobject]@{}) 'Malformed tree accepted.'
Reject-Form @((1..257)|ForEach-Object{[pscustomobject]@{}}) 'Oversized tree accepted.'

$form=Get-IdentPatientFormBindings @(New-IdentPatientFormFixture)
$start=[DateTimeOffset]'2099-09-20T09:00:00+05:00'; $end=$start.AddMinutes(45)
Assert-IdentPatientFormContext $form 'Fixture D. A.' $start $end
Reject-Context { Assert-IdentPatientFormContext $form 'Other D. A.' $start $end }
Reject-Context { Assert-IdentPatientFormContext $form '' $start $end }
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' ($start.AddDays(1)) ($end.AddDays(1)) }
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' $start ($start.AddMinutes(30)) }
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' ($start.ToOffset([timespan]::FromHours(3))) ($end.ToOffset([timespan]::FromHours(3))) }
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' ($start.AddSeconds(1)) $end }
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' ($start.AddTicks(1)) $end }
$form.Appointment.End='15:00'; $form.Appointment.DurationMinutes=360
Assert-IdentPatientFormContext $form 'Fixture D. A.' $start ($start.AddHours(6))
$form.Appointment.End='15:15'; $form.Appointment.DurationMinutes=375
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' $start ($start.AddMinutes(375)) }
$form.Appointment.Start='09:05'; $form.Appointment.End='09:50'; $form.Appointment.DurationMinutes=45
Reject-Context { Assert-IdentPatientFormContext $form 'Fixture D. A.' ($start.AddMinutes(5)) ($start.AddMinutes(50)) }
$badTitle=(New-IdentPatientFormFixture)[0].name -replace '20 ','31 ' -replace '09:45','25:45'
Assert-True ($null -eq (ConvertFrom-IdentAppointmentTitle $badTitle)) 'Invalid date/time accepted.'
Write-Host 'IDENT PATIENT FORM OK: six candidate roles, compact/expanded, moving/scaled windows, fresh paths, ambiguous/missing/foreign/hidden targets rejected, strict appointment context, no input.'
