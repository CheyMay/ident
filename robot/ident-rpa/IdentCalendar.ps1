function ConvertFrom-IdentCalendarDate {
    param([string]$Text)
    $textValue=$Text.Trim()
    # A full visible date is mandatory; never borrow a missing year from the request or PC clock.
    if ($textValue -notmatch '^(?<date>\d{1,2}(?:\.\d{2}\.| [\p{L}.]+ )\d{4})(?:[ ,]+\(?[\p{L}]+\)?)?$') { return $null }
    $dateText=$Matches.date
    $culture=[Globalization.CultureInfo]::GetCultureInfo('ru-RU').Clone()
    $months=$culture.DateTimeFormat.AbbreviatedMonthNames
    $months[8]=[regex]::Unescape('\u0441\u0435\u043d')
    $culture.DateTimeFormat.AbbreviatedMonthNames=$months
    $culture.DateTimeFormat.AbbreviatedMonthGenitiveNames=$months
    $date=[datetime]::MinValue
    if (-not [datetime]::TryParseExact($dateText,[string[]]@('d.MM.yyyy','dd.MM.yyyy','d MMM yyyy','dd MMM yyyy','d MMMM yyyy','dd MMMM yyyy'),
        $culture,[Globalization.DateTimeStyles]::None,[ref]$date)) { return $null }
    return $date.ToString('yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
}

function New-IdentCalendarRequest {
    param([object]$Request,[DateTimeOffset]$Now=[DateTimeOffset]::Now)
    try {
        if ($Request.schemaVersion -cne 1 -or $Request.purpose -cne 'ident-calendar-check' -or
            $Request.doctorCaption -isnot [string] -or $Request.doctorCaption.Length -gt 120 -or
            $Request.doctorCaption.Trim().Length -lt 3 -or $Request.doctorCaption -match '[\x00-\x1f]') { throw 'invalid' }
        $dates=@()
        foreach($value in @($Request.planStart,$Request.planEnd)) {
            if ($value -isnot [string] -or $value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00(?:Z|[+-]\d{2}:\d{2})$') { throw 'invalid' }
            $parsed=[DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParseExact($value,"yyyy-MM-dd'T'HH:mm:ssK",[Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None,[ref]$parsed)) { throw 'invalid' }
            $dates+= $parsed
        }
        $start=$dates[0]; $end=$dates[1]; $duration=($end-$start).TotalMinutes
        if ($start -le $Now -or $end.Date -ne $start.Date -or $end.Offset -ne $start.Offset -or
            $duration -lt 15 -or $duration -gt 360 -or $duration % 15 -ne 0 -or
            $start.Minute % 15 -ne 0 -or $end.Minute % 15 -ne 0) { throw 'invalid' }
        $doctorId=0; $branchId=0; $availability=$false
        foreach($field in @('doctorId','branchId')) {
            if ($Request.PSObject.Properties.Name -contains $field) {
                $value=$Request.$field
                if ($value -isnot [int] -and $value -isnot [long]) { throw 'invalid' }
                if ($value -lt 0 -or $value -gt [int]::MaxValue) { throw 'invalid' }
                if ($field -eq 'doctorId') { $doctorId=[int]$value } else { $branchId=[int]$value }
            }
        }
        if ($Request.PSObject.Properties.Name -contains 'checkAvailability') {
            if ($Request.checkAvailability -isnot [bool]) { throw 'invalid' }
            $availability=$Request.checkAvailability
        }
        return [pscustomobject]@{ DoctorCaption=$Request.doctorCaption.Trim(); Start=$start; End=$end;
            DoctorId=$doctorId; BranchId=$branchId; CheckAvailability=$availability;
            Date=$start.ToString('yyyy-MM-dd'); StartMinute=[int]$start.TimeOfDay.TotalMinutes;
            EndMinute=[int]$end.TimeOfDay.TotalMinutes; DurationMinutes=[int]$duration }
    } catch { throw 'CALENDAR_INVALID_REQUEST' }
}

function Get-IdentCalendarDigest {
    param([object]$Value)
    $serialized=ConvertTo-Json -InputObject $Value -Depth 6 -Compress
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($serialized)))).Replace('-','') }
    finally { $sha.Dispose() }
}

function New-IdentCalendarPlan {
    param([object[]]$Rows,[object]$Request)
    $result=[ordered]@{ Ok=$false; ErrorCode='CALENDAR_INVALID_TREE'; SchemaVersion=1; ReadOnly=$true;
        ReadyForInput=$false; ReadyForUnattendedExecution=$false; AvailabilityVerified=$false;
        GridPath=''; Date=''; DoctorCaption=''; DurationMinutes=0; Selection=$null; Fingerprint='';
        ContextParts=$null; PathParts=$null; TargetAnchors=$null; LabelCount=0 }
    try {
        if ($null -eq $Rows -or $Rows.Count -lt 8 -or $Rows.Count -gt 5000) { return [pscustomobject]$result }
        $nodes=@{}
        foreach($row in $Rows) {
            if ($row.path -notmatch '^\d+(?:/\d+)*$' -or $nodes.ContainsKey([string]$row.path)) { return [pscustomobject]$result }
            $nodes[[string]$row.path]=$row
        }
        $result.ErrorCode='CALENDAR_GRID_AMBIGUOUS'
        $grids=@($Rows | Where-Object { $_.automationId -ceq 'cttGrid' -and $_.className -ceq 'TimeTableGridControl' -and
            $_.controlType -ceq 'ControlType.Custom' -and -not $_.isOffscreen -and $_.isEnabled })
        if ($grids.Count -ne 1) { return [pscustomobject]$result }
        $grid=$grids[0]; $viewport=ConvertTo-IdentFormRectangle $grid.bounds
        if ($null -eq $viewport) { return [pscustomobject]$result }
        $prefix='^'+[regex]::Escape($grid.path)+'/'
        $children=@($Rows | Where-Object { $_.path -match $prefix })
        foreach($row in $children) {
            if ($row.rootName -cne $grid.rootName -or -not $nodes.ContainsKey(($row.path -replace '/\d+$',''))) {
                $result.ErrorCode='CALENDAR_INVALID_TREE'; return [pscustomobject]$result
            }
        }
        $texts=@($children | Where-Object { $_.path -match ($prefix+'\d+$') -and
            $_.className -ceq 'TextBlock' -and $_.controlType -ceq 'ControlType.Text' } | ForEach-Object {
            $rect=ConvertTo-IdentFormRectangle $_.bounds
            if ($null -ne $rect) { [pscustomobject]@{ Row=$_; Rect=$rect;
                Visible=($_.isEnabled -and -not $_.isOffscreen -and (Test-IdentFormContained $rect $viewport)) } }
        })
        $result.ErrorCode='CALENDAR_COLUMNS_AMBIGUOUS'
        $chairs=@($texts | Where-Object { $_.Row.name -cmatch '^(?:\u041a\u0440\u0435\u0441\u043b\u043e|Chair)\s+\S' } | Sort-Object { $_.Rect.X })
        if ($chairs.Count -eq 0 -or $chairs.Count -gt 40) { return [pscustomobject]$result }
        $previous=$null
        foreach($chair in $chairs) {
            if (-not $chair.Visible -or $chair.Rect.Width -lt 50 -or
                [math]::Abs($chair.Rect.Y-$chairs[0].Rect.Y) -gt 2 -or
                ($null -ne $previous -and $chair.Rect.X -le $previous.Rect.Right)) { return [pscustomobject]$result }
            $previous=$chair
        }
        $left=$chairs[0].Rect.X; $right=$chairs[-1].Rect.Right
        $result.ErrorCode='CALENDAR_DATE_UNREADABLE'
        $dateHeaders=@($texts | Where-Object { $_.Visible -and $_.Rect.Bottom -lt $chairs[0].Rect.Y -and
            [math]::Abs($_.Rect.X-$left) -le 2 -and [math]::Abs($_.Rect.Right-$right) -le 2 })
        if ($dateHeaders.Count -ne 1) { return [pscustomobject]$result }
        $date=ConvertFrom-IdentCalendarDate $dateHeaders[0].Row.name
        if ($null -eq $date) { return [pscustomobject]$result }
        $result.ErrorCode='CALENDAR_WRONG_DATE'
        if ($date -cne $Request.Date) { return [pscustomobject]$result }

        # Each row has matching left/right time labels. Offscreen=false alone is not evidence of visibility.
        $result.ErrorCode='CALENDAR_TIME_AXIS'
        $labels=@($texts | Where-Object { $_.Row.name -cmatch '^\d{2}:\d{2}$' -and $_.Rect.Y -gt $chairs[0].Rect.Bottom })
        $times=[Collections.Generic.List[object]]::new()
        foreach($group in @($labels | Group-Object { $_.Row.name })) {
            $pair=@($group.Group | Sort-Object { $_.Rect.X })
            $time=[timespan]::Zero
            if ($pair.Count -ne 2 -or -not [timespan]::TryParseExact([string]$group.Name,'hh\:mm',
                [Globalization.CultureInfo]::InvariantCulture,[ref]$time) -or
                $pair[0].Rect.Right -ge $left -or $pair[1].Rect.X -le $right -or
                [math]::Abs($pair[0].Rect.Y-$pair[1].Rect.Y) -gt 2 -or
                [math]::Abs($pair[0].Rect.Height-$pair[1].Rect.Height) -gt 2) { return [pscustomobject]$result }
            $times.Add([pscustomobject]@{ Minute=[int]$time.TotalMinutes; Y=$pair[0].Rect.CenterY;
                Top=$pair[0].Rect.Y; Bottom=$pair[0].Rect.Bottom; Pair=$pair;
                Visible=($pair[0].Visible -and $pair[1].Visible) })
        }
        $axis=@($times.ToArray() | Sort-Object Minute)
        if ($axis.Count -lt 2) { return [pscustomobject]$result }
        for($i=1;$i -lt $axis.Count;$i++) {
            $delta=$axis[$i].Minute-$axis[$i-1].Minute
            if ($delta -notin @(15,30) -or $axis[$i].Top -le $axis[$i-1].Bottom) { return [pscustomobject]$result }
        }
        $result.ErrorCode='CALENDAR_SCROLL_REQUIRED'
        if ($Request.StartMinute -lt $axis[0].Minute -or $Request.EndMinute -gt $axis[-1].Minute) { return [pscustomobject]$result }
        $start=@($axis | Where-Object { $_.Minute -eq $Request.StartMinute })
        $end=@($axis | Where-Object { $_.Minute -eq $Request.EndMinute })
        $result.ErrorCode='CALENDAR_SPLIT_REQUIRED'
        if ($start.Count -ne 1 -or $end.Count -ne 1) { return [pscustomobject]$result }
        $selected=@($axis | Where-Object { $_.Minute -ge $Request.StartMinute -and $_.Minute -lt $Request.EndMinute })
        $result.ErrorCode='CALENDAR_SCROLL_REQUIRED'
        if (-not $end[0].Visible -or @($selected | Where-Object { -not $_.Visible }).Count -gt 0) { return [pscustomobject]$result }

        $result.ErrorCode='CALENDAR_DOCTOR_AMBIGUOUS'
        $columns=[Collections.Generic.List[object]]::new()
        foreach($chair in $chairs) {
            $headers=@($texts | Where-Object { $_.Row.name -and $_.Rect.Y -gt $chair.Rect.Bottom -and
                [math]::Abs($_.Rect.X-$chair.Rect.X) -le 2 -and [math]::Abs($_.Rect.Width-$chair.Rect.Width) -le 2 } |
                Sort-Object { $_.Rect.Y })
            $before=@($headers | Where-Object { $_.Rect.Bottom -lt $start[0].Top })
            if ($before.Count -eq 0) { continue }
            $header=$before[-1]
            if ($header.Row.name.Trim() -cne $Request.DoctorCaption) { continue }
            if (-not $header.Visible) { return [pscustomobject]$result }
            $columns.Add([pscustomobject]@{ Chair=$chair; Header=$header; Headers=$headers })
        }
        if ($columns.Count -ne 1) { return [pscustomobject]$result }
        $column=$columns[0]
        # A repeated header or irregular gap between rows may denote a change of shift.
        $result.ErrorCode='CALENDAR_SHIFT_BOUNDARY'
        if (@($column.Headers | Where-Object { $_.Rect.Y -ge $start[0].Top -and $_.Rect.Y -lt $end[0].Top }).Count -gt 0) {
            return [pscustomobject]$result
        }
        $anchors=@($selected)+@($end[0]); $scale=$null
        for($i=1;$i -lt $anchors.Count;$i++) {
            $ratio=($anchors[$i].Y-$anchors[$i-1].Y)/($anchors[$i].Minute-$anchors[$i-1].Minute)
            if ($ratio -lt 0.5 -or $ratio -gt 20 -or ($null -ne $scale -and [math]::Abs($ratio-$scale) -gt 0.05)) {
                return [pscustomobject]$result
            }
            $scale=$ratio
        }
        $result.Ok=$true; $result.ErrorCode=''; $result.GridPath=$grid.path; $result.Date=$date
        $result.DoctorCaption=$Request.DoctorCaption; $result.DurationMinutes=$Request.DurationMinutes
        $result.Selection=[pscustomobject]@{ X=[int][math]::Floor($column.Chair.Rect.X+$column.Chair.Rect.Width/2);
            StartY=[int][math]::Floor($selected[0].Y); LastY=[int][math]::Floor($selected[-1].Y);
            SlotCount=$selected.Count; RequiresDrag=($selected.Count -gt 1); ChairPath=$column.Chair.Row.path; ChairCaption=[string]$column.Chair.Row.name;
            DoctorPath=$column.Header.Row.path; StartPath=$selected[0].Pair[0].Row.path; EndPath=$end[0].Pair[0].Row.path }
        # Local comparison only; includes viewport and all grid rows, not a durable permission to click.
        $fingerprintRows=@($grid)+@($children | Sort-Object path)
        $result.Fingerprint=Get-IdentCalendarDigest @($fingerprintRows | Select-Object path,name,automationId,className,controlType,bounds,isEnabled,isOffscreen)
        # Opening a popup can change incidental grid/scrollbar state. Keep every direct text label,
        # including unrelated/offscreen labels, and the exact input geometry in the transition proof.
        $labelRows=@($children | Where-Object { $_.path -match ($prefix+'\d+$') -and
            $_.className -ceq 'TextBlock' -and $_.controlType -ceq 'ControlType.Text' } | Sort-Object path |
            Select-Object path,name,automationId,className,controlType,bounds,isEnabled,isOffscreen)
        # Tree indices locate a node within one scan; they are not its cross-scan identity.
        # Sort complete semantic records ordinally and preserve duplicates/counts.
        $labelCounts=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
        $labelProperties=@('name','automationId','className','controlType','bounds','isEnabled','isOffscreen')
        [string[]]$labelContent=@($labelRows | ForEach-Object {
            $record=$_ | Select-Object -Property $labelProperties | ConvertTo-Json -Compress
            if ($labelCounts.ContainsKey($record)) { $labelCounts[$record]++ } else { $labelCounts[$record]=1 }
            $record
        })
        [Array]::Sort($labelContent,[StringComparer]::Ordinal)
        # After the click, prove the selected context, not unrelated appointments or popup text.
        $definitions=[Collections.Generic.List[object]]::new()
        $definitions.Add([pscustomobject]@{ Role='date'; Row=$dateHeaders[0].Row })
        $definitions.Add([pscustomobject]@{ Role='chair'; Row=$column.Chair.Row })
        $definitions.Add([pscustomobject]@{ Role='doctor'; Row=$column.Header.Row })
        foreach($anchor in $anchors) {
            for($side=0;$side -lt 2;$side++) {
                $definitions.Add([pscustomobject]@{ Role=('time_'+$anchor.Minute+'_'+$side); Row=$anchor.Pair[$side].Row })
            }
        }
        $targetAnchors=[Collections.Generic.List[object]]::new()
        foreach($definition in @($definitions.ToArray() | Sort-Object Role)) {
            $node=$definition.Row | Select-Object -Property $labelProperties
            $key=$node | ConvertTo-Json -Compress
            if (-not $labelCounts.ContainsKey($key) -or $labelCounts[$key] -ne 1) { throw 'ambiguous_target_anchor' }
            $targetAnchors.Add([pscustomobject]@{ Role=$definition.Role; Node=$node; Occurrences=$labelCounts[$key] })
        }
        $result.TargetAnchors=$targetAnchors.ToArray()
        $result.LabelCount=$labelRows.Count
        $result.ContextParts=[ordered]@{
            Grid=(Get-IdentCalendarDigest ($grid | Select-Object path,automationId,className,controlType,bounds,isEnabled,isOffscreen))
            Labels=(Get-IdentCalendarDigest $labelContent)
            TargetLabels=(Get-IdentCalendarDigest $result.TargetAnchors)
            Selection=(Get-IdentCalendarDigest ([ordered]@{ Date=$result.Date; Doctor=$result.DoctorCaption;
                Duration=$result.DurationMinutes; Selection=($result.Selection | Select-Object X,StartY,LastY,SlotCount,RequiresDrag,ChairCaption) }))
        }
        $result.PathParts=[ordered]@{
            Labels=(Get-IdentCalendarDigest $labelRows)
            Selection=(Get-IdentCalendarDigest ($result.Selection | Select-Object ChairPath,DoctorPath,StartPath,EndPath))
        }
    } catch {
        $result.Ok=$false; $result.ErrorCode='CALENDAR_INVALID_TREE'; $result.Selection=$null; $result.Fingerprint='';
        $result.ContextParts=$null; $result.PathParts=$null; $result.TargetAnchors=$null; $result.LabelCount=0
    }
    return [pscustomobject]$result
}

function Get-IdentNewAppointmentMenuCandidate {
    param([object[]]$Rows)
    # Never select '(Continue) ... from buffer', reserve, split, or the item's duplicate Text child.
    $matchesFound=@($Rows | Where-Object { $_.controlType -ceq 'ControlType.MenuItem' -and $_.isEnabled -and
        -not $_.isOffscreen -and $_.name -cmatch '^\u0417\u0430\u043f\u0438\u0441\u0430\u0442\u044c \u043d\u0430 \u043f\u0440\u0438[\u0435\u0451]\u043c(?:\.\.\.|\u2026)$' -and
        $_.patterns -contains 'InvokePatternIdentifiers.Pattern' -and $null -ne (ConvertTo-IdentFormRectangle $_.bounds) })
    if ($matchesFound.Count -ne 1) { return $null }
    return [pscustomobject]@{ Path=$matchesFound[0].path; Name=$matchesFound[0].name; ReadyForInput=$false }
}
