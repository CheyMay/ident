param([switch]$LibraryOnly)
if (-not $LibraryOnly) { throw 'Library mode required.' }
function Get-AgentContext($Path) {
    return [pscustomobject]@{ Config=[pscustomobject]@{ sql=[pscustomobject]@{ commandTimeoutSeconds=30; connectTimeoutSeconds=30 } } }
}
function Assert-ReadOnlySql($Sql,$Label) { return $Sql }
function Invoke-SqlQuery($Context,$Query,[System.Data.SqlClient.SqlParameter[]]$Parameters) {
    if ($Parameters.Count -ne 1 -or $Parameters[0].ParameterName -cne '@WorkDate' -or
        $Parameters[0].SqlDbType -ne [System.Data.SqlDbType]::Date -or $Parameters[0].Value -ne [datetime]'2099-09-20' -or
        $Query -cne (Get-IdentAvailabilitySql) -or $Context.Config.sql.commandTimeoutSeconds -ne 5) { throw 'Query contract mismatch.' }
    $snapshot=New-IdentAvailabilityFixture
    $table=[System.Data.DataTable]::new()
    foreach($property in $snapshot.Rows[0].PSObject.Properties) {
        $null=$table.Columns.Add($property.Name,$property.Value.GetType())
    }
    foreach($row in $snapshot.Rows) {
        $item=$table.NewRow()
        foreach($property in $row.PSObject.Properties) { $item[$property.Name]=$property.Value }
        $table.Rows.Add($item)
    }
    return ,$table
}
