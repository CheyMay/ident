function ConvertTo-IdentFormRectangle {
    param([string]$Text)
    if ($Text -notmatch '^(-?\d{1,6}),(-?\d{1,6}),(\d{1,6}),(\d{1,6})$') { return $null }
    $x = [int]$Matches[1]; $y = [int]$Matches[2]; $width = [int]$Matches[3]; $height = [int]$Matches[4]
    if ($width -lt 2 -or $height -lt 2 -or $width -gt 20000 -or $height -gt 20000) { return $null }
    return [pscustomobject]@{ X=$x; Y=$y; Width=$width; Height=$height; Right=($x+$width); Bottom=($y+$height); CenterY=($y+$height/2.0) }
}

function Test-IdentFormContained {
    param([object]$Inner, [object]$Outer)
    return $null -ne $Inner -and $null -ne $Outer -and $Inner.X -ge $Outer.X -and
        $Inner.Y -ge $Outer.Y -and $Inner.Right -le $Outer.Right -and $Inner.Bottom -le $Outer.Bottom
}

function ConvertFrom-IdentAppointmentTitle {
    param([string]$Title)
    $prefix = '(?:\u041d\u043e\u0432\u044b\u0439 \u043f\u0440\u0438[\u0435\u0451]\u043c|New appointment)'
    if ($Title -notmatch ('^' + $prefix + ' - (?<doctor>[^|\r\n]+?) - (?<date>\d{1,2} [\p{L}.]+ \d{4}) \| (?<start>\d{2}:\d{2}) - (?<end>\d{2}:\d{2})$')) { return $null }
    $doctor=$Matches.doctor.Trim(); $dateText=$Matches.date; $startText=$Matches.start; $endText=$Matches.end
    $date=[datetime]::MinValue; $start=[timespan]::Zero; $end=[timespan]::Zero
    $culture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU').Clone()
    # IDENT uses the observed "sen" Cyrillic abbreviation rather than .NET's standard September token.
    $months=$culture.DateTimeFormat.AbbreviatedMonthNames
    $months[8]=[regex]::Unescape('\u0441\u0435\u043d')
    $culture.DateTimeFormat.AbbreviatedMonthNames=$months
    $culture.DateTimeFormat.AbbreviatedMonthGenitiveNames=$months
    if (-not [datetime]::TryParseExact($dateText, [string[]]@('d MMM yyyy','dd MMM yyyy','d MMMM yyyy','dd MMMM yyyy'),
        $culture, [Globalization.DateTimeStyles]::None, [ref]$date) -or
        -not [timespan]::TryParseExact($startText, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture, [ref]$start) -or
        -not [timespan]::TryParseExact($endText, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture, [ref]$end) -or
        $end -le $start -or -not $doctor) { return $null }
    return [pscustomobject]@{
        DoctorCaption=$doctor; Date=$date.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture); Start=$startText; End=$endText
        DurationMinutes=[int]($end-$start).TotalMinutes
    }
}

function Get-IdentPatientFormBindings {
    param([object[]]$Rows)
    # Candidate discovery only. Paths and geometry from a scan never authorize input or saving.
    $result=[ordered]@{ Ok=$false; SchemaVersion=1; ErrorCode='unsupported_form'; Fields=[ordered]@{}; Appointment=$null;
        Layout=''; ReadyForInput=$false; ReadyForUnattendedExecution=$false }
    try {
        if ($null -eq $Rows -or $Rows.Count -lt 10 -or $Rows.Count -gt 256) { return [pscustomobject]$result }
        $roots=@($Rows | Where-Object { $_.path -match '^\d+$' })
        if ($roots.Count -ne 1 -or $roots[0].controlType -ne 'ControlType.Window' -or
            $roots[0].className -ne 'Window' -or $roots[0].isOffscreen -or -not $roots[0].isEnabled) { return [pscustomobject]$result }
        $root=$roots[0]; $rootBounds=ConvertTo-IdentFormRectangle $root.bounds
        $appointment=ConvertFrom-IdentAppointmentTitle $root.name
        if ($null -eq $rootBounds -or $null -eq $appointment) { return [pscustomobject]$result }
        $result.ErrorCode='invalid_tree'
        $nodes=@{}; $rects=@{}
        foreach ($row in $Rows) {
            if ($row.path -notmatch ('^'+[regex]::Escape($root.path)+'(?:/\d+)*$') -or
                $row.rootName -cne $root.name -or $nodes.ContainsKey([string]$row.path)) { return [pscustomobject]$result }
            $nodes[[string]$row.path]=$row
            $bounds=ConvertTo-IdentFormRectangle $row.bounds
            if (-not $row.isOffscreen -and $row.isEnabled -and (Test-IdentFormContained $bounds $rootBounds)) {
                $rects[[string]$row.path]=$bounds
            }
        }
        foreach ($row in $Rows) {
            if ($row.path -ne $root.path -and -not $nodes.ContainsKey(($row.path -replace '/\d+$',''))) { return [pscustomobject]$result }
        }
        $directPattern='^'+[regex]::Escape($root.path)+'/\d+$'
        $edits=@($Rows | Where-Object {
            $_.controlType -eq 'ControlType.Edit' -and $_.className -eq 'TextBox' -and $rects.ContainsKey([string]$_.path) -and
            $_.patterns -contains 'ValuePatternIdentifiers.Pattern'
        })
        $direct=@($edits | Where-Object { $_.path -match $directPattern })
        $result.ErrorCode='form_anchors'
        $surname=@($direct | Where-Object { $_.automationId -ceq '_surnameTextBox' })
        $birth=@($direct | Where-Object { $_.automationId -ceq 'MaskedTextBox' })
        $time=@($Rows | Where-Object { $_.automationId -ceq '_receptionTimeTextBlock' })
        if ($surname.Count -ne 1 -or $birth.Count -ne 1 -or $time.Count -ne 1 -or
            $time[0].controlType -ne 'ControlType.Text' -or -not $rects.ContainsKey([string]$time[0].path)) { return [pscustomobject]$result }
        $time=$time[0]; $panelPath=$time.path -replace '/\d+$',''; $panel=$nodes[$panelPath]
        if ($panel.controlType -ne 'ControlType.Pane' -or $panel.className -ne 'ScrollViewer' -or
            $panel.path -notmatch $directPattern -or -not $rects.ContainsKey([string]$panel.path) -or
            $time.name -cne ($appointment.Start+' - '+$appointment.End)) { return [pscustomobject]$result }
        $surname=$surname[0]; $birth=$birth[0]
        $s=$rects[$surname.path]; $b=$rects[$birth.path]; $p=$rects[$panel.path]; $t=$rects[$time.path]
        if ($s.Right -ge $b.X -or $b.Right -ge $p.X -or -not (Test-IdentFormContained $t $p) -or
            $s.Y - $b.Y -lt $s.Height*0.8 -or $s.Y - $b.Y -gt $s.Height*2.2) { return [pscustomobject]$result }

        $result.ErrorCode='name_layout'
        $column=@($direct | Where-Object {
            $r=$rects[$_.path]
            [math]::Abs($r.X-$s.X) -le $s.Height*0.2 -and [math]::Abs($r.Width-$s.Width) -le $s.Height*0.3
        })
        $card=@($column | Where-Object {
            $r=$rects[$_.path]
            -not $_.automationId -and -not $_.name -and [math]::Abs($r.Y-$b.Y) -le $s.Height*0.25
        })
        $names=@($column | Where-Object {
            $r=$rects[$_.path]
            $r.Y -gt $s.Y -and $r.Y -le $s.Y+$s.Height*3.6
        } | Sort-Object { $rects[$_.path].Y })
        if ($card.Count -ne 1 -or $names.Count -ne 2) { return [pscustomobject]$result }
        $previous=$s
        foreach ($name in $names) {
            $r=$rects[$name.path]; $gap=$r.Y-$previous.Y
            if ($name.automationId -or $name.name -or $gap -lt $s.Height*1.05 -or $gap -gt $s.Height*1.8 -or
                [math]::Abs($r.Height-$s.Height) -gt $s.Height*0.2) { return [pscustomobject]$result }
            $previous=$r
        }

        $result.ErrorCode='phone_layout'
        $combos=@($Rows | Where-Object { $_.path -match $directPattern -and $_.automationId -ceq '_comboBox' -and
            $_.controlType -eq 'ControlType.ComboBox' -and $rects.ContainsKey([string]$_.path) })
        if ($combos.Count -ne 1) { return [pscustomobject]$result }
        $c=$rects[$combos[0].path]
        if ([math]::Abs($c.X-$b.X) -gt $s.Height*0.35 -or [math]::Abs($c.CenterY-$s.CenterY) -gt $s.Height*0.35) { return [pscustomobject]$result }
        $phones=@($direct | Where-Object {
            $r=$rects[$_.path]
            -not $_.automationId -and -not $_.name -and [math]::Abs($r.X-$c.Right) -le $s.Height*0.2 -and
            [math]::Abs($r.CenterY-$c.CenterY) -le $s.Height*0.2 -and $r.Right -lt $p.X -and $r.Width -ge $b.Width
        })
        if ($phones.Count -ne 1) { return [pscustomobject]$result }

        $result.ErrorCode='appointment_comment'
        $comments=@($edits | Where-Object {
            if ($_.automationId -cne '_textBox' -or $_.path -notmatch ('^'+[regex]::Escape($panelPath)+'/\d+/\d+$')) { return $false }
            $parentPath=$_.path -replace '/\d+$',''; $parent=$nodes[$parentPath]
            $r=$rects[$_.path]
            $parent.controlType -eq 'ControlType.Edit' -and -not $parent.automationId -and $rects.ContainsKey($parentPath) -and
            $parent.bounds -ceq $_.bounds -and (Test-IdentFormContained $r $p) -and
            $r.Y -ge $t.Bottom -and $r.Y-$t.Bottom -le $s.Height*1.5 -and $r.Width -ge $p.Width*0.65
        })
        if ($comments.Count -ne 1) { return [pscustomobject]$result }
        $selected=[ordered]@{
            patientLastNameInput=$surname; patientFirstNameInput=$names[0]; patientMiddleNameInput=$names[1]
            patientPhoneInput=$phones[0]; patientBirthDateInput=$birth; commentInput=$comments[0]
        }
        $seen=@{}; $fields=[ordered]@{}
        foreach ($role in $selected.Keys) {
            $row=$selected[$role]
            if ($seen.ContainsKey([string]$row.path)) { return [pscustomobject]$result }
            $seen[[string]$row.path]=$true
            $fields[$role]=[pscustomobject]@{ Path=[string]$row.path; AutomationId=[string]$row.automationId; ControlType='ControlType.Edit' }
        }
        $result.Fields=$fields; $result.Appointment=$appointment
        $result.Layout=if (@($Rows | Where-Object { $_.controlType -eq 'ControlType.Text' -and $_.name -ceq 'E-mail' }).Count -eq 1) { 'expanded' } else { 'compact' }
        $result.Ok=$true; $result.ErrorCode=''
    }
    catch { $result.ErrorCode='invalid_tree'; $result.Fields=[ordered]@{}; $result.Appointment=$null }
    return [pscustomobject]$result
}

function Assert-IdentPatientFormContext {
    param([object]$Form, [string]$ExpectedDoctorCaption, [DateTimeOffset]$ExpectedStart, [DateTimeOffset]$ExpectedEnd)
    if (-not $Form.Ok -or [string]::IsNullOrWhiteSpace($ExpectedDoctorCaption)) { throw 'IDENT_FORM_CONTEXT_UNAVAILABLE' }
    # Compare clinic wall-clock values; an abbreviated caption must be explicitly mapped, never guessed from a full name.
    if ($Form.Appointment.DoctorCaption -cne $ExpectedDoctorCaption -or
        $Form.Appointment.Date -cne $ExpectedStart.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -or
        $ExpectedStart.Date -ne $ExpectedEnd.Date -or $ExpectedStart.Offset -ne $ExpectedEnd.Offset -or
        $Form.Appointment.Start -cne $ExpectedStart.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) -or
        $Form.Appointment.End -cne $ExpectedEnd.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) -or
        $ExpectedStart.Ticks % [timespan]::TicksPerMinute -ne 0 -or $ExpectedEnd.Ticks % [timespan]::TicksPerMinute -ne 0 -or
        $ExpectedStart.Minute % 15 -ne 0 -or $ExpectedEnd.Minute % 15 -ne 0 -or
        ($ExpectedEnd-$ExpectedStart).TotalMinutes -lt 15 -or ($ExpectedEnd-$ExpectedStart).TotalMinutes -gt 360) { throw 'IDENT_FORM_CONTEXT_MISMATCH' }
}
