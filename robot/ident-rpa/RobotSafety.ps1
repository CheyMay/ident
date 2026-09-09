function Enter-RobotInteractionLease {
    param([string]$Directory, [switch]$Training)
    $path = Join-Path $Directory 'interaction.lock'
    try {
        if (-not (Test-Path -LiteralPath $path)) {
            $created = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
            $created.Dispose()
        }
        # Worker and its child share read leases; observation owns an exclusive writer.
        if ($Training) {
            return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        return [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    catch [IO.IOException] { return $null }
}

function Get-BookingNameFields {
    param([object]$Config)
    $mode = if ($Config.workflow.PSObject.Properties.Name -contains 'patientNameMode') {
        [string]$Config.workflow.patientNameMode
    } else { 'full' }
    if ($mode -notin @('full', 'split')) { throw 'Unknown patientNameMode. Use full or split.' }
    $fullFields = @('ticket.ClientFullName')
    $splitFields = @('ticket.ClientSurname', 'ticket.ClientName', 'ticket.ClientPatronymic')
    $expected = if ($mode -eq 'split') { $splitFields } else { $fullFields }
    $forbidden = if ($mode -eq 'split') { $fullFields } else { $splitFields }
    foreach ($step in @($Config.workflow.steps)) {
        if ($step.PSObject.Properties.Name -contains 'valueFrom' -and [string]$step.valueFrom -in $forbidden) {
            throw 'Patient name representations must not be mixed in a workflow.'
        }
    }
    return $expected
}

function New-SplitNameCandidate {
    param([object]$Config, [object[]]$NameParts)
    $candidate = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $candidate.workflow | Add-Member -NotePropertyName patientNameMode -NotePropertyValue 'split' -Force
    $fields = @('ClientSurname', 'ClientName', 'ClientPatronymic')
    $roles = @('patientLastNameInput', 'patientFirstNameInput', 'patientMiddleNameInput')
    $steps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($step in @($candidate.workflow.steps)) {
        if ($step.PSObject.Properties.Name -contains 'valueFrom' -and $step.valueFrom -eq 'ticket.ClientFullName') {
            for ($i = 0; $i -lt 3; $i++) {
                $steps.Add([pscustomobject]@{ name = "set_$($fields[$i])"; action = 'setText'; selector = $roles[$i]; valueFrom = "ticket.$($fields[$i])" })
            }
        } else { $steps.Add($step) }
    }
    $candidate.workflow.steps = $steps.ToArray()
    foreach ($role in $roles) {
        $match = @($NameParts | Where-Object { $_.Name -eq $role -and $_.Ok })
        $selector = if ($match.Count -eq 1) { $match[0].Selector } else {
            [pscustomobject]@{ name = ''; automationId = ''; className = ''; controlType = '' }
        }
        $candidate.selectors | Add-Member -NotePropertyName $role -NotePropertyValue $selector -Force
    }
    $candidate.selectors.PSObject.Properties.Remove('patientNameInput')
    $candidate.workflow.allowUnsafeExecution = $false
    return $candidate
}
