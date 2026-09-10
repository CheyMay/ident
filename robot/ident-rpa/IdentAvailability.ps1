function Get-IdentAvailabilitySql {
    # Fixed, parameterized, patient-free query against the captured dbo schema.
    # Keep nonworking/unassigned rows: filtering them out could turn an unsafe gap into free time.
    return @'
SELECT TOP (5001)
  tt.ID AS SlotId, tt.RowVersion AS SlotVersion, tt.DateOfWork AS WorkDate,
  tm.TimeStartValue AS TimeStart, tm.TimeEndValue AS TimeEnd,
  tt.ID_Staffs AS DoctorId, a.ID_OwnCompanies AS BranchId, a.ID AS ChairId,
  a.NameArmchair AS ChairName, a.Archive AS ChairArchived,
  s.Surname AS DoctorSurname, s.Name AS DoctorFirstName, s.Patronymic AS DoctorMiddleName,
  s.Archive AS DoctorArchived,
  tt.IsWorkingTime,
  CAST(CASE WHEN tt.ID_Receptions IS NOT NULL OR tt.ID_TimeReserves IS NOT NULL THEN 1 ELSE 0 END AS bit) AS IsBusy
FROM dbo.CurrentTimeTable tt
LEFT JOIN dbo.Times tm ON tm.ID = tt.ID_Times
LEFT JOIN dbo.Armchairs a ON a.ID = tt.ID_Armchairs
LEFT JOIN dbo.StaffsView s ON s.ID = tt.ID_Staffs
WHERE tt.DateOfWork = @WorkDate AND tt.IsHeaderCell = 0
ORDER BY tt.ID
OPTION (MAXDOP 1)
'@
}

function Get-IdentAvailabilitySnapshot {
    param([string]$AgentDirectory,[object]$Request)
    try {
        # Isolate the existing agent's helper functions/preferences from the UI robot's scope.
        return & {
            param($directory,$wanted)
            . (Join-Path $directory 'IdentAgent.ps1') -LibraryOnly
            $context=Get-AgentContext (Join-Path $directory 'config.local.json')
            $context.Config.sql.commandTimeoutSeconds=5
            $context.Config.sql.connectTimeoutSeconds=5
            $sql=Assert-ReadOnlySql (Get-IdentAvailabilitySql) 'robotAvailability'
            $dateParameter=[System.Data.SqlClient.SqlParameter]::new('@WorkDate',[System.Data.SqlDbType]::Date)
            $dateParameter.Value=$wanted.Start.Date
            $capturedAt=[DateTimeOffset]::UtcNow
            $table=Invoke-SqlQuery -Context $context -Query $sql -Parameters @($dateParameter)
            try {
                if ($table.Rows.Count -gt 5000) { throw 'AVAILABILITY_TOO_LARGE' }
                $rows=@($table.Rows | ForEach-Object {
                    $row=$_; $item=[ordered]@{}
                    foreach($column in $table.Columns) {
                        $value=$row[$column.ColumnName]
                        if ($value -is [DBNull]) { $item[$column.ColumnName]=$null }
                        else { $item[$column.ColumnName]=$value }
                    }
                    [pscustomobject]$item
                })
                return [pscustomobject]@{ Source='ident-sql-live-v1'; CapturedAt=$capturedAt; Rows=$rows }
            } finally { $table.Dispose() }
        } $AgentDirectory $Request
    } catch {
        if ($_.Exception.Message -ceq 'AVAILABILITY_TOO_LARGE') { throw 'AVAILABILITY_TOO_LARGE' }
        # SQL/provider errors can contain configuration. No connection strings or raw errors leave this adapter.
        throw 'AVAILABILITY_QUERY_FAILED'
    }
}

function ConvertTo-IdentAvailabilityId {
    param([object]$Value,[switch]$Nullable)
    if ($Nullable -and $null -eq $Value) { return 0 }
    if ($Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [int32] -and $Value -isnot [int64]) { throw 'invalid' }
    if ([long]$Value -le 0 -or [long]$Value -gt [int]::MaxValue) { throw 'invalid' }
    return [int]$Value
}

function ConvertTo-IdentAvailabilityText {
    param([object]$Value,[switch]$Optional)
    if ($Optional -and $null -eq $Value) { return '' }
    if ($Value -isnot [string] -or $Value.Length -gt 400 -or $Value -match '[\x00-\x1f]') { throw 'invalid' }
    $clean=$Value.Trim().Normalize([Text.NormalizationForm]::FormC)
    if (-not $Optional -and -not $clean) { throw 'invalid' }
    return $clean
}

function Get-IdentAvailabilityProof {
    param([object]$Snapshot,[object]$Request,[object]$CalendarPlan,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    $result=[ordered]@{ Ok=$false; ErrorCode='AVAILABILITY_INVALID_DATA'; AvailabilityVerified=$false;
        ReadyForInput=$false; ReadyForUnattendedExecution=$false; DoctorId=0; BranchId=0; ChairId=0; SlotCount=0; Fingerprint='' }
    try {
        if (-not $CalendarPlan.Ok -or $CalendarPlan.Date -cne $Request.Date -or $CalendarPlan.DoctorCaption -cne $Request.DoctorCaption -or
            $CalendarPlan.DurationMinutes -ne $Request.DurationMinutes -or $Snapshot.Source -cne 'ident-sql-live-v1') { return [pscustomobject]$result }
        $result.ErrorCode='AVAILABILITY_STALE'
        if ($Snapshot.CapturedAt -isnot [DateTimeOffset] -or $Snapshot.CapturedAt -gt $Now -or
            ($Now-$Snapshot.CapturedAt).TotalSeconds -gt 15 -or $Request.Start -le $Now) { return [pscustomobject]$result }
        $result.ErrorCode='AVAILABILITY_INVALID_DATA'
        if ($null -eq $Snapshot.Rows -or $Snapshot.Rows.Count -gt 5000) { return [pscustomobject]$result }
        $slots=[Collections.Generic.List[object]]::new(); $ids=@{}; $doctors=@{}; $chairs=@{}
        foreach($row in $Snapshot.Rows) {
            $id=ConvertTo-IdentAvailabilityId $row.SlotId
            $doctor=ConvertTo-IdentAvailabilityId $row.DoctorId -Nullable
            $branch=ConvertTo-IdentAvailabilityId $row.BranchId
            $chair=ConvertTo-IdentAvailabilityId $row.ChairId
            $chairName=ConvertTo-IdentAvailabilityText $row.ChairName
            if ($ids.ContainsKey($id) -or $row.WorkDate -isnot [datetime] -or $row.WorkDate.TimeOfDay -ne [timespan]::Zero -or
                $row.WorkDate.ToString('yyyy-MM-dd') -cne $Request.Date -or $row.TimeStart -isnot [timespan] -or
                $row.TimeEnd -isnot [timespan] -or $row.TimeStart -lt [timespan]::Zero -or $row.TimeEnd.TotalHours -ge 24 -or
                $row.TimeEnd -le $row.TimeStart -or $row.TimeStart.TotalMinutes % 15 -ne 0 -or $row.TimeEnd.TotalMinutes % 15 -ne 0 -or
                $row.IsWorkingTime -isnot [bool] -or $row.IsBusy -isnot [bool] -or $row.ChairArchived -isnot [bool] -or
                $row.SlotVersion -isnot [byte[]] -or $row.SlotVersion.Length -ne 8) { return [pscustomobject]$result }
            $ids[$id]=$true
            $caption=''; $fullName=''; $archived=$true
            if ($doctor -gt 0) {
                $surname=ConvertTo-IdentAvailabilityText $row.DoctorSurname
                $first=ConvertTo-IdentAvailabilityText $row.DoctorFirstName
                $middle=ConvertTo-IdentAvailabilityText $row.DoctorMiddleName -Optional
                if ($row.DoctorArchived -isnot [bool] -or $first -notmatch '^\p{L}' -or ($middle -and $middle -notmatch '^\p{L}')) { return [pscustomobject]$result }
                $archived=$row.DoctorArchived
                $caption=$surname+' '+$first.Substring(0,1)+'.'
                if ($middle) { $caption+=' '+$middle.Substring(0,1)+'.' }
                $fullName=(@($surname,$first,$middle) | Where-Object { $_ }) -join ' '
                $doctorKey=@($fullName,[string]$archived) -join '|'
                if ($doctors.ContainsKey($doctor) -and $doctors[$doctor] -cne $doctorKey) { return [pscustomobject]$result }
                $doctors[$doctor]=$doctorKey
            }
            $chairKey=@($branch,$chairName,[string]$row.ChairArchived) -join '|'
            if ($chairs.ContainsKey($chair) -and $chairs[$chair] -cne $chairKey) { return [pscustomobject]$result }
            $chairs[$chair]=$chairKey
            $slots.Add([pscustomobject]@{ SlotId=$id; Version=([BitConverter]::ToString($row.SlotVersion)).Replace('-','');
                DoctorId=$doctor; BranchId=$branch; ChairId=$chair; ChairName=$chairName; DoctorCaption=$caption; DoctorName=$fullName;
                DoctorArchived=$archived; ChairArchived=$row.ChairArchived; IsWorkingTime=$row.IsWorkingTime; IsBusy=$row.IsBusy;
                StartMinute=[int]$row.TimeStart.TotalMinutes; EndMinute=[int]$row.TimeEnd.TotalMinutes })
        }
        $result.ErrorCode='AVAILABILITY_IDENTITY_AMBIGUOUS'
        $chairCaption=[string]$CalendarPlan.Selection.ChairCaption
        $chairNames=@($chairCaption)
        if ($chairCaption -cmatch '^(?:\u041a\u0440\u0435\u0441\u043b\u043e|Chair) "(?<name>[^"\r\n]+)"$') { $chairNames+= $Matches.name }
        $matching=@($slots.ToArray() | Where-Object { $_.DoctorCaption -ceq $Request.DoctorCaption -and $chairNames -ccontains $_.ChairName } |
            Group-Object { '{0}/{1}/{2}' -f $_.DoctorId,$_.BranchId,$_.ChairId })
        if ($matching.Count -ne 1) { return [pscustomobject]$result }
        $identity=$matching[0].Group[0]
        if ($Request.PSObject.Properties.Name -contains 'DoctorId' -and $Request.DoctorId -gt 0 -and $Request.DoctorId -ne $identity.DoctorId) {
            $result.ErrorCode='AVAILABILITY_WRONG_DOCTOR'; return [pscustomobject]$result
        }
        if ($Request.PSObject.Properties.Name -contains 'BranchId' -and $Request.BranchId -gt 0 -and $Request.BranchId -ne $identity.BranchId) {
            $result.ErrorCode='AVAILABILITY_WRONG_BRANCH'; return [pscustomobject]$result
        }
        $overlap=@($slots.ToArray() | Where-Object { $_.ChairId -eq $identity.ChairId -and
            $_.StartMinute -lt $Request.EndMinute -and $_.EndMinute -gt $Request.StartMinute } | Sort-Object StartMinute,EndMinute,SlotId)
        $cursor=$Request.StartMinute
        foreach($slot in $overlap) {
            $result.ErrorCode='AVAILABILITY_BUSY'
            if ($slot.IsBusy) { return [pscustomobject]$result }
            $result.ErrorCode='AVAILABILITY_NOT_WORKING'
            if (-not $slot.IsWorkingTime -or $slot.ChairArchived -or $slot.DoctorArchived) { return [pscustomobject]$result }
            $result.ErrorCode='AVAILABILITY_WRONG_DOCTOR'
            if ($slot.DoctorId -ne $identity.DoctorId) { return [pscustomobject]$result }
            $result.ErrorCode='AVAILABILITY_SPLIT_REQUIRED'
            if ($slot.StartMinute -lt $Request.StartMinute -or $slot.EndMinute -gt $Request.EndMinute) { return [pscustomobject]$result }
            $result.ErrorCode='AVAILABILITY_CONFLICT'
            if ($slot.StartMinute -lt $cursor) { return [pscustomobject]$result }
            $result.ErrorCode='AVAILABILITY_GAP'
            if ($slot.StartMinute -ne $cursor) { return [pscustomobject]$result }
            $cursor=$slot.EndMinute
        }
        $result.ErrorCode='AVAILABILITY_GAP'
        if ($overlap.Count -eq 0 -or $cursor -ne $Request.EndMinute) { return [pscustomobject]$result }
        $fingerprint=[pscustomobject]@{ Date=$Request.Date; Start=$Request.StartMinute; End=$Request.EndMinute;
            Slots=@($slots.ToArray() | Sort-Object SlotId) } | ConvertTo-Json -Depth 5 -Compress
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $result.Fingerprint=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprint)))).Replace('-','') }
        finally { $sha.Dispose() }
        $result.Ok=$true; $result.ErrorCode=''; $result.AvailabilityVerified=$true
        $result.DoctorId=$identity.DoctorId; $result.BranchId=$identity.BranchId; $result.ChairId=$identity.ChairId; $result.SlotCount=$overlap.Count
    } catch { $result.Ok=$false; $result.ErrorCode='AVAILABILITY_INVALID_DATA'; $result.AvailabilityVerified=$false; $result.Fingerprint='' }
    return [pscustomobject]$result
}
