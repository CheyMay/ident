function New-IdentAvailabilityFixture {
    $rows=[Collections.Generic.List[object]]::new()
    for($i=0;$i -lt 12;$i++) {
        $version=[byte[]]::new(8); $version[7]=[byte]($i+1)
        $rows.Add([pscustomobject]@{
            SlotId=($i+1); SlotVersion=$version; WorkDate=[datetime]'2099-09-20';
            TimeStart=[timespan]::FromMinutes(540+30*$i); TimeEnd=[timespan]::FromMinutes(570+30*$i);
            DoctorId=10; BranchId=1; ChairId=2; ChairName='Chair B'; ChairArchived=$false;
            DoctorSurname='Sample'; DoctorFirstName='Oscar'; DoctorMiddleName='Mark'; DoctorArchived=$false;
            IsWorkingTime=$true; IsBusy=$false
        })
    }
    return [pscustomobject]@{ Source='ident-sql-live-v1'; CapturedAt=[DateTimeOffset]::UtcNow; Rows=$rows.ToArray() }
}
