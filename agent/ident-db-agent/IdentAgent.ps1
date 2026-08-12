[CmdletBinding(DefaultParameterSetName = 'TestConnection')]
param(
    [string]$ConfigPath = '',

    [Parameter(ParameterSetName = 'DiscoverInstances')]
    [switch]$DiscoverInstances,

    [Parameter(ParameterSetName = 'TestConnection')]
    [switch]$TestConnection,

    [Parameter(ParameterSetName = 'ExportSchema')]
    [switch]$ExportSchema,

    [Parameter(ParameterSetName = 'Preview')]
    [switch]$Preview,

    [Parameter(ParameterSetName = 'Push')]
    [switch]$Push,

    [Parameter(ParameterSetName = 'AutoConfigureSql')]
    [switch]$AutoConfigureSql,

    [switch]$NonInteractive,

    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "== $Message ==" -ForegroundColor Cyan
}

function Resolve-AgentPath {
    param(
        [string]$BaseDirectory,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'A required file path is empty.'
    }
    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "JSON file is empty: $Path"
    }
    return $raw | ConvertFrom-Json
}

function Get-PlainTextSecret {
    param([string]$EncryptedValue)

    if ([string]::IsNullOrWhiteSpace($EncryptedValue)) {
        return ''
    }

    $secure = ConvertTo-SecureString -String $EncryptedValue
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-AgentContext {
    param([string]$Path)

    $resolvedConfigPath = [IO.Path]::GetFullPath($Path)
    $baseDirectory = Split-Path -Parent $resolvedConfigPath
    $config = Read-JsonFile -Path $resolvedConfigPath
    $secretsPath = Resolve-AgentPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.secrets)
    $mappingPath = Resolve-AgentPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.mapping)
    $schemaPath = Resolve-AgentPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.schemaOutput)
    $logPath = Resolve-AgentPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.log)
    $resultPath = if ($config.paths.PSObject.Properties.Name -contains 'pushResult') {
        Resolve-AgentPath -BaseDirectory $baseDirectory -Value ([string]$config.paths.pushResult)
    } else {
        Join-Path $baseDirectory 'last-push-result.json'
    }
    $secrets = Read-JsonFile -Path $secretsPath

    return [pscustomobject]@{
        ConfigPath = $resolvedConfigPath
        BaseDirectory = $baseDirectory
        Config = $config
        Secrets = $secrets
        MappingPath = $mappingPath
        SchemaPath = $schemaPath
        LogPath = $logPath
        ResultPath = $resultPath
    }
}

function Write-AgentLog {
    param(
        [pscustomobject]$Context,
        [string]$Level,
        [string]$Event,
        [hashtable]$Data = @{}
    )

    $directory = Split-Path -Parent $Context.LogPath
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $entry = [ordered]@{
        timestamp = (Get-Date).ToString('o')
        level = $Level
        event = $Event
        data = $Data
    }
    Add-Content -LiteralPath $Context.LogPath -Value ($entry | ConvertTo-Json -Compress -Depth 8) -Encoding UTF8
}

function Get-SqlDataSource {
    param([pscustomobject]$SqlConfig)

    if (
        $SqlConfig.PSObject.Properties.Name -contains 'dataSource' -and
        -not [string]::IsNullOrWhiteSpace([string]$SqlConfig.dataSource)
    ) {
        return [string]$SqlConfig.dataSource
    }

    $server = [string]$SqlConfig.server
    $instanceName = [string]$SqlConfig.instanceName
    $port = 0
    [void][int]::TryParse([string]$SqlConfig.port, [ref]$port)

    if ($port -gt 0) {
        return "tcp:$server,$port"
    }
    if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
        return "$server\$instanceName"
    }
    return $server
}

function Get-SqlConnectionString {
    param(
        [pscustomobject]$Context,
        [switch]$UseMaster
    )

    $sql = $Context.Config.sql
    $password = Get-PlainTextSecret -EncryptedValue ([string]$Context.Secrets.sqlPasswordDpapi)
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw 'SQL password is not configured. Run 1-Setup.cmd again.'
    }

    $database = [string]$sql.database
    if ($UseMaster -or [string]::IsNullOrWhiteSpace($database)) {
        $database = 'master'
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = Get-SqlDataSource -SqlConfig $sql
    $builder['Initial Catalog'] = $database
    $builder['User ID'] = [string]$sql.user
    $builder['Password'] = $password
    $builder['Integrated Security'] = $false
    $builder['Application Name'] = 'Code9 IDENT Schedule Agent'
    $builder['Connect Timeout'] = [int]$sql.connectTimeoutSeconds
    $builder['Encrypt'] = [bool]$sql.encrypt
    $builder['TrustServerCertificate'] = [bool]$sql.trustServerCertificate
    $builder['Pooling'] = $false
    return $builder.ConnectionString
}

function Invoke-SqlQuery {
    param(
        [pscustomobject]$Context,
        [string]$Query,
        [switch]$UseMaster
    )

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = Get-SqlConnectionString -Context $Context -UseMaster:$UseMaster
    $command = $connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = [int]$Context.Config.sql.commandTimeoutSeconds
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable

    try {
        $connection.Open()
        [void]$adapter.Fill($table)
        return ,$table
    }
    finally {
        $adapter.Dispose()
        $command.Dispose()
        $connection.Dispose()
    }
}

function Find-SqlBrowserInstances {
    param(
        [string]$Server,
        [int]$TimeoutMilliseconds = 3500
    )

    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = $TimeoutMilliseconds
    try {
        $client.Connect($Server, 1434)
        $request = [byte[]](3)
        [void]$client.Send($request, $request.Length)
        $remote = New-Object System.Net.IPEndPoint ([Net.IPAddress]::Any), 0
        $response = $client.Receive([ref]$remote)
        if ($response.Length -le 3) {
            return @()
        }

        $payload = [Text.Encoding]::ASCII.GetString($response, 3, $response.Length - 3).Trim([char]0)
        $records = @($payload -split ';;' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $instances = @()
        foreach ($record in $records) {
            $parts = @($record -split ';')
            $item = [ordered]@{}
            for ($index = 0; $index + 1 -lt $parts.Count; $index += 2) {
                if (-not [string]::IsNullOrWhiteSpace($parts[$index])) {
                    $item[$parts[$index]] = $parts[$index + 1]
                }
            }
            if ($item.Count -gt 0) {
                $instances += [pscustomobject]$item
            }
        }
        return $instances
    }
    catch [System.Net.Sockets.SocketException] {
        return @()
    }
    finally {
        $client.Close()
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function ConvertTo-SqlEndpoint {
    param(
        [string]$DataSource,
        [string]$Source
    )

    $value = $DataSource.Trim().Trim('"').Trim("'")
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '(?i)\|DataDirectory\||LocalDB') {
        return $null
    }

    if ($value -match '(?i)^np:(?<pipe>.+)$') {
        $pipe = [string]$Matches.pipe
        $pipeServer = ''
        if ($pipe -match '^\\\\(?<server>[^\\]+)\\') {
            $pipeServer = [string]$Matches.server
        }
        return [pscustomobject]@{
            Server = $pipeServer
            InstanceName = ''
            Port = 0
            DataSource = "np:$pipe"
            Source = $Source
        }
    }
    if ($value -match '(?i)^tcp:(?<server>[^,]+),(?<port>\d+)$') {
        return [pscustomobject]@{
            Server = [string]$Matches.server
            InstanceName = ''
            Port = [int]$Matches.port
            DataSource = "tcp:$([string]$Matches.server),$([int]$Matches.port)"
            Source = $Source
        }
    }
    if ($value -match '^(?<server>[^,\\]+),(?<port>\d+)$') {
        return [pscustomobject]@{
            Server = [string]$Matches.server
            InstanceName = ''
            Port = [int]$Matches.port
            DataSource = "tcp:$([string]$Matches.server),$([int]$Matches.port)"
            Source = $Source
        }
    }
    if ($value -match '^(?<server>[^\\]+)\\(?<instance>[^\\]+)$') {
        return [pscustomobject]@{
            Server = [string]$Matches.server
            InstanceName = [string]$Matches.instance
            Port = 0
            DataSource = $value
            Source = $Source
        }
    }

    return [pscustomobject]@{
        Server = $value
        InstanceName = ''
        Port = 0
        DataSource = $value
        Source = $Source
    }
}

function Get-IdentConfigurationFiles {
    $roots = @()
    $identProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '(?i)ident' -or $_.MainWindowTitle -match '(?i)ident'
    })
    foreach ($process in $identProcesses) {
        try {
            if (-not [string]::IsNullOrWhiteSpace([string]$process.Path)) {
                $roots += Split-Path -Parent ([string]$process.Path)
            }
        }
        catch {}
    }

    foreach ($path in @(
        (Join-Path $env:ProgramData 'IDENT'),
        (Join-Path $env:ProgramData 'Dent-IT'),
        (Join-Path $env:APPDATA 'IDENT'),
        (Join-Path $env:LOCALAPPDATA 'IDENT')
    )) {
        if (Test-Path -LiteralPath $path) {
            $roots += $path
        }
    }

    $files = @()
    foreach ($root in @($roots | Sort-Object -Unique)) {
        try {
            $files += Get-ChildItem `
                -LiteralPath $root `
                -Recurse `
                -File `
                -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Length -le 2097152 -and
                    $_.Extension -match '(?i)^\.(config|ini|xml|json|txt)$'
                } |
                Select-Object -First 250
        }
        catch {}
    }

    return @($files | Sort-Object FullName -Unique)
}

function Find-IdentConfigurationEndpoints {
    $endpoints = @()
    $files = @(Get-IdentConfigurationFiles)

    $patterns = @(
        '(?i)(?:data\s+source|server|network\s+address)\s*=\s*(?<value>[^;\r\n"<]+)',
        '(?i)"(?:dataSource|server|sqlServer|serverName|host)"\s*:\s*"(?<value>[^"]+)"'
    )
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            foreach ($pattern in $patterns) {
                foreach ($match in [regex]::Matches($content, $pattern)) {
                    $endpoint = ConvertTo-SqlEndpoint `
                        -DataSource ([string]$match.Groups['value'].Value) `
                        -Source "IDENT config $($file.Name)"
                    if ($null -ne $endpoint) {
                        $endpoints += $endpoint
                    }
                }
            }
        }
        catch {}
    }
    return $endpoints
}

function Get-DatabaseNamesFromConfigurationText {
    param(
        [string]$Content,
        [string]$Source = 'configuration'
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    $patterns = @(
        "(?i)(?:initial\s+catalog|database)\s*=\s*[`"']?(?<value>[^;`"'\r\n<>]+)",
        "(?i)`"(?:database|databaseName|initialCatalog|catalog)`"\s*:\s*`"(?<value>[^`"]+)`"",
        '(?i)<(?:database|databaseName|initialCatalog|catalog)>\s*(?<value>[^<]+)\s*</'
    )
    $systemDatabases = @('master', 'model', 'msdb', 'tempdb')
    $result = @()
    $seen = @{}
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Content, $pattern)) {
            $value = ([string]$match.Groups['value'].Value).Trim()
            if (
                [string]::IsNullOrWhiteSpace($value) -or
                $value.Length -gt 128 -or
                $value -in $systemDatabases -or
                $value -match '[;\r\n\x00-\x1f=]' -or
                $value -match '^(?i:true|false|null|none|default|localhost)$'
            ) {
                continue
            }
            $key = $value.ToLowerInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $seen[$key] = $true
            $result += [pscustomobject]@{
                Name = $value
                Source = $Source
            }
        }
    }
    return $result
}

function Get-IdentDatabaseCandidates {
    param([pscustomobject]$Context)

    $candidates = @()
    $configuredDatabase = [string]$Context.Config.sql.database
    if (-not [string]::IsNullOrWhiteSpace($configuredDatabase)) {
        $candidates += [pscustomobject]@{
            Name = $configuredDatabase.Trim()
            Source = 'saved configuration'
        }
    }

    foreach ($file in @(Get-IdentConfigurationFiles)) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            $candidates += @(Get-DatabaseNamesFromConfigurationText `
                -Content $content `
                -Source "IDENT config $($file.Name)")
        }
        catch {}
    }

    $unique = @{}
    $result = @()
    foreach ($candidate in $candidates) {
        $name = [string]$candidate.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        $key = $name.ToLowerInvariant()
        if ($unique.ContainsKey($key)) {
            continue
        }
        $unique[$key] = $true
        $result += $candidate
        if ($result.Count -ge 12) {
            break
        }
    }
    return $result
}

function Find-SqlClientAliasEndpoints {
    $endpoints = @()
    foreach ($registryPath in @(
        'HKCU:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
        'HKLM:\SOFTWARE\Microsoft\MSSQLServer\Client\ConnectTo',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\MSSQLServer\Client\ConnectTo'
    )) {
        try {
            $item = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
            foreach ($property in $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
                $value = [string]$property.Value
                $dataSource = ''
                if ($value -match '(?i)^DBMSSOCN,(?<server>[^,]+),(?<port>\d+)$') {
                    $dataSource = "tcp:$([string]$Matches.server),$([int]$Matches.port)"
                }
                elseif ($value -match '(?i)^DBNMPNTW,(?<pipe>.+)$') {
                    $dataSource = "np:$([string]$Matches.pipe)"
                }
                elseif (-not [string]::IsNullOrWhiteSpace($value)) {
                    $dataSource = $value
                }
                $endpoint = ConvertTo-SqlEndpoint -DataSource $dataSource -Source "SQL client alias $($property.Name)"
                if ($null -ne $endpoint) {
                    $endpoints += $endpoint
                }
            }
        }
        catch {}
    }
    return $endpoints
}

function Find-LocalSqlEndpoints {
    $endpoints = @()
    try {
        foreach ($service in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^MSSQL(\$|SERVER$)' })) {
            $dataSource = if ($service.Name -eq 'MSSQLSERVER') {
                $env:COMPUTERNAME
            }
            else {
                "$env:COMPUTERNAME\$($service.Name.Substring(6))"
            }
            $endpoint = ConvertTo-SqlEndpoint -DataSource $dataSource -Source "local SQL service $($service.Name)"
            if ($null -ne $endpoint) {
                $endpoints += $endpoint
            }
        }
    }
    catch {}
    return $endpoints
}

function Find-IdentSqlConnections {
    param([string[]]$PreferredServers = @())

    $connections = @()
    try {
        $allConnections = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue)
        $identProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -match '(?i)ident' -or $_.MainWindowTitle -match '(?i)ident'
        })
        $identProcessIds = @($identProcesses | ForEach-Object { [int]$_.Id })
        foreach ($connection in $allConnections) {
            $remoteAddress = [string]$connection.RemoteAddress
            $remotePort = [int]$connection.RemotePort
            if (
                [string]::IsNullOrWhiteSpace($remoteAddress) -or
                $remotePort -le 0 -or
                $remotePort -in @(53, 80, 443, 445, 3389)
            ) {
                continue
            }
            $isIdentProcess = [int]$connection.OwningProcess -in $identProcessIds
            $isPreferredServer = @($PreferredServers | Where-Object { $_ -ieq $remoteAddress }).Count -gt 0
            if (-not $isIdentProcess -and -not $isPreferredServer) {
                continue
            }
            $processName = ''
            try {
                $processName = [string](Get-Process -Id $connection.OwningProcess -ErrorAction Stop).ProcessName
            }
            catch {}
            $connections += [pscustomobject]@{
                Server = $remoteAddress
                Port = $remotePort
                ProcessName = $processName
                Source = $(if ($isIdentProcess) { "IDENT process $processName" } else { "active connection to $remoteAddress" })
            }
        }
    }
    catch {}
    return @($connections | Sort-Object Server, Port -Unique)
}

function Get-SqlEndpointCandidates {
    param([pscustomobject]$Context)

    $server = [string]$Context.Config.sql.server
    $configuredPort = [int]$Context.Config.sql.port
    $configuredInstance = [string]$Context.Config.sql.instanceName
    $candidates = @()

    $configuredDataSource = Get-SqlDataSource -SqlConfig $Context.Config.sql
    $configuredEndpoint = ConvertTo-SqlEndpoint -DataSource $configuredDataSource -Source 'saved configuration'
    if ($null -ne $configuredEndpoint) {
        $candidates += $configuredEndpoint
    }

    $configurationEndpoints = @(Find-IdentConfigurationEndpoints)
    $aliasEndpoints = @(Find-SqlClientAliasEndpoints)
    $localEndpoints = @(Find-LocalSqlEndpoints)
    $candidates += $configurationEndpoints
    $candidates += $aliasEndpoints
    $candidates += $localEndpoints

    $servers = @($server)
    $servers += @($configurationEndpoints | ForEach-Object { [string]$_.Server })
    $servers += @($aliasEndpoints | ForEach-Object { [string]$_.Server })
    $servers = @($servers | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    foreach ($connection in @(Find-IdentSqlConnections -PreferredServers $servers)) {
        $candidates += [pscustomobject]@{
            Server = [string]$connection.Server
            InstanceName = ''
            Port = [int]$connection.Port
            DataSource = "tcp:$($connection.Server),$($connection.Port)"
            Source = [string]$connection.Source
        }
    }

    foreach ($browserServer in $servers) {
        foreach ($instance in @(Find-SqlBrowserInstances -Server $browserServer)) {
            $instanceName = [string](Get-ObjectPropertyValue -Object $instance -Names @('InstanceName'))
            $tcpText = [string](Get-ObjectPropertyValue -Object $instance -Names @('tcp'))
            $namedPipe = [string](Get-ObjectPropertyValue -Object $instance -Names @('np'))
            $tcpPort = 0
            [void][int]::TryParse($tcpText, [ref]$tcpPort)
            if ($tcpPort -gt 0) {
                $candidates += [pscustomobject]@{
                    Server = $browserServer
                    InstanceName = $instanceName
                    Port = $tcpPort
                    DataSource = "tcp:$browserServer,$tcpPort"
                    Source = 'SQL Browser TCP'
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($namedPipe)) {
                $pipeDataSource = if ($namedPipe.StartsWith('\\')) {
                    "np:$namedPipe"
                }
                else {
                    "np:\\$browserServer\$($namedPipe.TrimStart('\'))"
                }
                $pipeEndpoint = ConvertTo-SqlEndpoint -DataSource $pipeDataSource -Source 'SQL Browser named pipe'
                if ($null -ne $pipeEndpoint) {
                    $pipeEndpoint.InstanceName = $instanceName
                    $candidates += $pipeEndpoint
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
                $candidates += [pscustomobject]@{
                    Server = $browserServer
                    InstanceName = $instanceName
                    Port = 0
                    DataSource = "$browserServer\$instanceName"
                    Source = 'SQL Browser instance'
                }
            }
        }
    }

    if ($configuredPort -gt 0) {
        $candidates += ConvertTo-SqlEndpoint -DataSource "tcp:$server,$configuredPort" -Source 'saved TCP port'
    }
    if (-not [string]::IsNullOrWhiteSpace($configuredInstance)) {
        $candidates += ConvertTo-SqlEndpoint -DataSource "$server\$configuredInstance" -Source 'saved SQL instance'
    }
    foreach ($candidateServer in $servers) {
        $candidates += ConvertTo-SqlEndpoint -DataSource $candidateServer -Source 'server default protocol'
        $candidates += ConvertTo-SqlEndpoint -DataSource "tcp:$candidateServer,1433" -Source 'standard SQL port'
    }

    $unique = @{}
    $result = @()
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate -or [string]::IsNullOrWhiteSpace([string]$candidate.DataSource)) {
            continue
        }
        $key = ([string]$candidate.DataSource).ToLowerInvariant()
        if ($unique.ContainsKey($key)) {
            continue
        }
        $unique[$key] = $true
        $result += $candidate
        if ($result.Count -ge 20) {
            break
        }
    }
    return $result
}

function Get-NestedSqlErrorNumber {
    param([object]$Exception)

    $current = $Exception
    for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth++) {
        $numberProperty = $current.PSObject.Properties | Where-Object { $_.Name -eq 'Number' } | Select-Object -First 1
        if ($null -ne $numberProperty) {
            $number = 0
            if ([int]::TryParse([string]$numberProperty.Value, [ref]$number)) {
                return $number
            }
        }
        $innerProperty = $current.PSObject.Properties | Where-Object { $_.Name -eq 'InnerException' } | Select-Object -First 1
        if ($null -eq $innerProperty -or $null -eq $innerProperty.Value) {
            break
        }
        $current = $innerProperty.Value
    }
    return 0
}

function Test-SqlEndpoint {
    param(
        [pscustomobject]$Context,
        [pscustomobject]$Endpoint,
        [object[]]$DatabaseCandidates = @()
    )

    $password = Get-PlainTextSecret -EncryptedValue ([string]$Context.Secrets.sqlPasswordDpapi)
    $catalogs = @('master')
    $catalogs += @($DatabaseCandidates | ForEach-Object { [string]$_.Name })
    $catalogs = @($catalogs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    $errors = @()

    for ($catalogIndex = 0; $catalogIndex -lt $catalogs.Count; $catalogIndex++) {
        $catalog = [string]$catalogs[$catalogIndex]
        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $builder['Data Source'] = [string]$Endpoint.DataSource
        $builder['Initial Catalog'] = $catalog
        $builder['User ID'] = [string]$Context.Config.sql.user
        $builder['Password'] = $password
        $builder['Integrated Security'] = $false
        $builder['Application Name'] = 'Code9 IDENT SQL Discovery'
        $builder['Connect Timeout'] = [Math]::Min(4, [int]$Context.Config.sql.connectTimeoutSeconds)
        $builder['Encrypt'] = [bool]$Context.Config.sql.encrypt
        $builder['TrustServerCertificate'] = [bool]$Context.Config.sql.trustServerCertificate
        $builder['Pooling'] = $false

        $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
        $serverCommand = $connection.CreateCommand()
        $serverCommand.CommandText = @'
SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS InstanceName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    DB_NAME() AS CurrentDatabase;
'@
        $serverCommand.CommandTimeout = 10
        try {
            $connection.Open()
            $reader = $serverCommand.ExecuteReader()
            $serverInfo = $null
            $currentDatabase = $catalog
            if ($reader.Read()) {
                $serverInfo = [pscustomobject]@{
                    ServerName = [string]$reader['ServerName']
                    InstanceName = if ($reader['InstanceName'] -is [DBNull]) { '' } else { [string]$reader['InstanceName'] }
                    ProductVersion = [string]$reader['ProductVersion']
                }
                if ($reader['CurrentDatabase'] -isnot [DBNull]) {
                    $currentDatabase = [string]$reader['CurrentDatabase']
                }
            }
            $reader.Close()

            $databases = @($currentDatabase)
            $databaseCommand = $connection.CreateCommand()
            $databaseCommand.CommandText = @'
SELECT name AS DatabaseName
FROM sys.databases
WHERE HAS_DBACCESS(name) = 1
ORDER BY name;
'@
            $databaseCommand.CommandTimeout = 10
            try {
                $databaseReader = $databaseCommand.ExecuteReader()
                while ($databaseReader.Read()) {
                    $databases += [string]$databaseReader['DatabaseName']
                }
                $databaseReader.Close()
            }
            catch {}
            finally {
                $databaseCommand.Dispose()
            }

            return [pscustomobject]@{
                Endpoint = $Endpoint
                Server = $serverInfo
                Databases = @($databases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
                ConnectedCatalog = $currentDatabase
            }
        }
        catch {
            $message = [string]$_.Exception.Message
            $errors += "${catalog}: $message"
            $sqlErrorNumber = Get-NestedSqlErrorNumber -Exception $_.Exception
            $isCatalogOrLoginError = $sqlErrorNumber -in @(18456, 4060) -or $message -match '(?i)(login failed|cannot open database)'
            if ($catalogIndex -eq 0 -and -not $isCatalogOrLoginError) {
                break
            }
        }
        finally {
            $serverCommand.Dispose()
            $connection.Dispose()
        }
    }

    if ($errors.Count -eq 0) {
        throw 'SQL connection failed without a diagnostic message.'
    }
    throw (@($errors | Select-Object -Last 4) -join ' | ')
}

function Get-DatabaseFingerprint {
    param(
        [pscustomobject]$Context,
        [pscustomobject]$Endpoint,
        [string]$Database
    )

    $password = Get-PlainTextSecret -EncryptedValue ([string]$Context.Secrets.sqlPasswordDpapi)
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = [string]$Endpoint.DataSource
    $builder['Initial Catalog'] = $Database
    $builder['User ID'] = [string]$Context.Config.sql.user
    $builder['Password'] = $password
    $builder['Integrated Security'] = $false
    $builder['Application Name'] = 'Code9 IDENT Database Discovery'
    $builder['Connect Timeout'] = [Math]::Min(4, [int]$Context.Config.sql.connectTimeoutSeconds)
    $builder['Encrypt'] = [bool]$Context.Config.sql.encrypt
    $builder['TrustServerCertificate'] = [bool]$Context.Config.sql.trustServerCertificate
    $builder['Pooling'] = $false

    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $command = $connection.CreateCommand()
    $command.CommandText = @'
SELECT
    COUNT(*) AS TableCount,
    COALESCE(SUM(CASE
        WHEN LOWER(TABLE_NAME) LIKE '%doctor%'
          OR LOWER(TABLE_NAME) LIKE '%patient%'
          OR LOWER(TABLE_NAME) LIKE '%schedule%'
          OR LOWER(TABLE_NAME) LIKE '%appointment%'
          OR LOWER(TABLE_NAME) LIKE '%reception%'
          OR LOWER(TABLE_NAME) LIKE '%employee%'
          OR LOWER(TABLE_NAME) LIKE '%clinic%'
          OR LOWER(TABLE_NAME) LIKE '%branch%'
          OR LOWER(TABLE_NAME) LIKE '%timetable%'
          OR LOWER(TABLE_NAME) LIKE '%visit%'
        THEN 1 ELSE 0 END), 0) AS DomainMatches
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_TYPE IN ('BASE TABLE', 'VIEW');
'@
    $command.CommandTimeout = 15
    try {
        $connection.Open()
        $reader = $command.ExecuteReader()
        if (-not $reader.Read()) {
            return [pscustomobject]@{
                Name = $Database
                TableCount = 0
                DomainMatches = 0
                StrongNameMatch = ($Database -match '(?i)ident')
                Score = 0
            }
        }
        $tableCount = [int]$reader['TableCount']
        $domainMatches = [int]$reader['DomainMatches']
        $nameScore = if ($Database -match '(?i)ident') {
            100
        }
        elseif ($Database -match '(?i)(dent|stoma|clinic)') {
            20
        }
        else {
            0
        }
        return [pscustomobject]@{
            Name = $Database
            TableCount = $tableCount
            DomainMatches = $domainMatches
            StrongNameMatch = ($Database -match '(?i)ident')
            Score = $nameScore + ($domainMatches * 5) + [Math]::Min(20, [Math]::Floor($tableCount / 25))
        }
    }
    finally {
        $command.Dispose()
        $connection.Dispose()
    }
}

function Select-IdentDatabase {
    param(
        [object[]]$Fingerprints,
        [string]$ConfiguredDatabase,
        [string]$ConfiguredDataSource = ''
    )

    $items = @($Fingerprints)
    if ($items.Count -eq 0) {
        return $null
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredDatabase)) {
        $saved = @($items | Where-Object { $_.Name -ieq $ConfiguredDatabase })
        if ($saved.Count -eq 1) {
            return $saved[0]
        }
        if ($saved.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($ConfiguredDataSource)) {
            $savedEndpoint = $saved |
                Where-Object { [string]$_.DataSource -ieq $ConfiguredDataSource } |
                Select-Object -First 1
            if ($null -ne $savedEndpoint) {
                return $savedEndpoint
            }
        }
    }
    if ($items.Count -eq 1) {
        return $items[0]
    }
    $sorted = @($items | Sort-Object Score, TableCount -Descending)
    $strongNameMatch = (
        $sorted[0].PSObject.Properties.Name -contains 'StrongNameMatch' -and
        [bool]$sorted[0].StrongNameMatch
    )
    if ($strongNameMatch -and [int]$sorted[0].Score -ge 100 -and [int]$sorted[0].Score -gt [int]$sorted[1].Score) {
        return $sorted[0]
    }
    if (
        [int]$sorted[0].DomainMatches -ge 2 -and
        [int]$sorted[0].Score -ge ([int]$sorted[1].Score + 10)
    ) {
        return $sorted[0]
    }
    return $null
}

function Save-SqlDiscovery {
    param(
        [pscustomobject]$Context,
        [pscustomobject]$ConnectionResult,
        [pscustomobject]$Database
    )

    $config = $Context.Config
    $config.sql.server = [string]$ConnectionResult.Endpoint.Server
    $config.sql.instanceName = [string]$ConnectionResult.Endpoint.InstanceName
    $config.sql.port = [int]$ConnectionResult.Endpoint.Port
    if ($config.sql.PSObject.Properties.Name -contains 'dataSource') {
        $config.sql.dataSource = [string]$ConnectionResult.Endpoint.DataSource
    }
    else {
        $config.sql | Add-Member -NotePropertyName dataSource -NotePropertyValue ([string]$ConnectionResult.Endpoint.DataSource)
    }
    $config.sql.database = [string]$Database.Name
    $temporaryPath = "$($Context.ConfigPath).tmp-$PID"
    $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Context.ConfigPath -Force
}

function Save-SqlDiscoveryReport {
    param(
        [pscustomobject]$Context,
        [object[]]$Attempts,
        [object[]]$DatabaseCandidates,
        [string]$Result
    )

    $path = Join-Path $Context.BaseDirectory 'sql-discovery.json'
    [ordered]@{
        timestamp = (Get-Date).ToString('o')
        computer = $env:COMPUTERNAME
        result = $Result
        configuredServer = [string]$Context.Config.sql.server
        databaseCandidates = @($DatabaseCandidates | ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                source = [string]$_.Source
            }
        })
        attempts = @($Attempts)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-AutoConfigureSql {
    param([pscustomobject]$Context)

    Write-Step 'Searching for the SQL Server used by IDENT'
    $candidates = @(Get-SqlEndpointCandidates -Context $Context)
    $databaseCandidates = @(Get-IdentDatabaseCandidates -Context $Context)
    Write-Host "Candidates: $($candidates.Count)"
    if ($databaseCandidates.Count -gt 0) {
        Write-Host "Database names from saved/local IDENT configuration: $($databaseCandidates.Count)"
    }
    $connections = @()
    $attempts = @()
    foreach ($candidate in $candidates) {
        Write-Host "  Trying $($candidate.DataSource) [$($candidate.Source)]..."
        try {
            $connection = Test-SqlEndpoint `
                -Context $Context `
                -Endpoint $candidate `
                -DatabaseCandidates $databaseCandidates
            $connections += $connection
            $attempts += [ordered]@{
                dataSource = [string]$candidate.DataSource
                source = [string]$candidate.Source
                connected = $true
                databases = @($connection.Databases)
                error = ''
            }
            Write-Host '  Connected.' -ForegroundColor Green
        }
        catch {
            $message = [string]$_.Exception.Message
            $attempts += [ordered]@{
                dataSource = [string]$candidate.DataSource
                source = [string]$candidate.Source
                connected = $false
                databases = @()
                error = $message
            }
            Write-Host "  Not available: $message" -ForegroundColor DarkYellow
        }
    }
    if ($connections.Count -eq 0) {
        $reportPath = Save-SqlDiscoveryReport -Context $Context -Attempts $attempts -DatabaseCandidates $databaseCandidates -Result 'no_connection'
        throw "SQL Server was not found. Keep IDENT open and verify that readonly_user can connect from this computer. Diagnostic file: $reportPath"
    }

    $accessibleDatabaseCount = @(
        $connections |
            ForEach-Object { $_.Databases } |
            Where-Object { $_ -notin @('master', 'model', 'msdb', 'tempdb') }
    ).Count
    if ($accessibleDatabaseCount -eq 0) {
        $reportPath = Save-SqlDiscoveryReport -Context $Context -Attempts $attempts -DatabaseCandidates $databaseCandidates -Result 'no_accessible_database'
        throw "The SQL login connected, but it cannot access any non-system databases. Diagnostic file: $reportPath"
    }

    Write-Step 'Identifying the IDENT database from schema metadata'
    $fingerprints = @()
    foreach ($connectionResult in $connections) {
        $databaseNames = @($connectionResult.Databases | Where-Object { $_ -notin @('master', 'model', 'msdb', 'tempdb') })
        foreach ($databaseName in $databaseNames) {
            try {
                $fingerprint = Get-DatabaseFingerprint `
                    -Context $Context `
                    -Endpoint $connectionResult.Endpoint `
                    -Database $databaseName
                $fingerprint | Add-Member -NotePropertyName DataSource -NotePropertyValue ([string]$connectionResult.Endpoint.DataSource)
                $fingerprint | Add-Member -NotePropertyName ConnectionResult -NotePropertyValue $connectionResult
                $fingerprints += $fingerprint
            }
            catch {
                Write-Host "  Skipped $($connectionResult.Endpoint.DataSource) / ${databaseName}: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }
    if ($fingerprints.Count -eq 0) {
        $reportPath = Save-SqlDiscoveryReport -Context $Context -Attempts $attempts -DatabaseCandidates $databaseCandidates -Result 'schema_unavailable'
        throw "No accessible database schema could be inspected. Diagnostic file: $reportPath"
    }

    $fingerprints |
        Sort-Object Score -Descending |
        Format-Table DataSource, Name, TableCount, DomainMatches, Score -AutoSize
    $selected = Select-IdentDatabase `
        -Fingerprints $fingerprints `
        -ConfiguredDatabase ([string]$Context.Config.sql.database) `
        -ConfiguredDataSource (Get-SqlDataSource -SqlConfig $Context.Config.sql)
    if ($null -eq $selected) {
        $ordered = @($fingerprints | Sort-Object Score, TableCount -Descending)
        if ($NonInteractive) {
            $reportPath = Save-SqlDiscoveryReport -Context $Context -Attempts $attempts -DatabaseCandidates $databaseCandidates -Result 'database_selection_required'
            $options = @($ordered | ForEach-Object { "$($_.DataSource) / $($_.Name)" }) -join ', '
            throw "Several databases are possible: $options. Select Data Source and database in Code9 IDENT Admin. Diagnostic file: $reportPath"
        }
        Write-Host 'Several databases are possible. Choose one number:' -ForegroundColor Yellow
        for ($index = 0; $index -lt $ordered.Count; $index++) {
            Write-Host "  $($index + 1). $($ordered[$index].DataSource) / $($ordered[$index].Name)"
        }
        $choiceText = Read-Host 'Database number'
        $choice = 0
        if (-not [int]::TryParse($choiceText, [ref]$choice) -or $choice -lt 1 -or $choice -gt $ordered.Count) {
            throw 'A valid database number was not selected.'
        }
        $selected = $ordered[$choice - 1]
    }

    $connectionResult = $selected.ConnectionResult
    Save-SqlDiscovery -Context $Context -ConnectionResult $connectionResult -Database $selected
    Write-Host ''
    Write-Host "SQL Server: $($connectionResult.Endpoint.DataSource)" -ForegroundColor Green
    Write-Host "Database:   $($selected.Name)" -ForegroundColor Green
    Write-Host 'Configuration saved.' -ForegroundColor Green

    $schema = Export-SqlSchema -Context $Context
    $reportPath = Save-SqlDiscoveryReport -Context $Context -Attempts $attempts -DatabaseCandidates $databaseCandidates -Result 'configured'
    Write-Host "Schema exported: $($schema.summary.tables) tables/views, $($schema.summary.columns) columns." -ForegroundColor Green
    Write-Host "File: $($Context.SchemaPath)" -ForegroundColor Green
    Write-Host "Discovery report: $reportPath" -ForegroundColor Green
    Write-AgentLog -Context $Context -Level 'info' -Event 'sql_auto_configured' -Data @{
        dataSource = [string]$connectionResult.Endpoint.DataSource
        database = [string]$selected.Name
        tables = [int]$schema.summary.tables
        columns = [int]$schema.summary.columns
    }
}

function Test-SqlConnection {
    param([pscustomobject]$Context)

    $query = @'
SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS InstanceName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    DB_NAME() AS CurrentDatabase;

SELECT name AS DatabaseName
FROM sys.databases
WHERE HAS_DBACCESS(name) = 1
ORDER BY name;
'@

    $connection = New-Object System.Data.SqlClient.SqlConnection
    $connection.ConnectionString = Get-SqlConnectionString -Context $Context -UseMaster
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $command.CommandTimeout = [int]$Context.Config.sql.commandTimeoutSeconds

    try {
        $connection.Open()
        $reader = $command.ExecuteReader()
        $serverInfo = $null
        if ($reader.Read()) {
            $serverInfo = [pscustomobject]@{
                ServerName = [string]$reader['ServerName']
                InstanceName = if ($reader['InstanceName'] -is [DBNull]) { '' } else { [string]$reader['InstanceName'] }
                ProductVersion = [string]$reader['ProductVersion']
                CurrentDatabase = [string]$reader['CurrentDatabase']
            }
        }

        $databases = @()
        if ($reader.NextResult()) {
            while ($reader.Read()) {
                $databases += [string]$reader['DatabaseName']
            }
        }
        $reader.Close()

        return [pscustomobject]@{
            Server = $serverInfo
            Databases = $databases
        }
    }
    finally {
        $command.Dispose()
        $connection.Dispose()
    }
}

function Export-SqlSchema {
    param([pscustomobject]$Context)

    if ([string]::IsNullOrWhiteSpace([string]$Context.Config.sql.database)) {
        throw 'Database is empty in config.local.json. Run 1-Setup.cmd and choose a database.'
    }

    $query = @'
SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.TABLE_TYPE,
    c.ORDINAL_POSITION,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    c.CHARACTER_MAXIMUM_LENGTH,
    c.NUMERIC_PRECISION,
    c.NUMERIC_SCALE,
    c.IS_NULLABLE
FROM INFORMATION_SCHEMA.TABLES t
LEFT JOIN INFORMATION_SCHEMA.COLUMNS c
    ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
   AND c.TABLE_NAME = t.TABLE_NAME
WHERE t.TABLE_TYPE IN ('BASE TABLE', 'VIEW')
ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME, c.ORDINAL_POSITION
'@

    $rows = Invoke-SqlQuery -Context $Context -Query $query
    $groups = $rows.Rows | Group-Object -Property TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE
    $tables = @()

    foreach ($group in $groups) {
        $first = $group.Group[0]
        $columns = @()
        foreach ($row in $group.Group) {
            if ($row.COLUMN_NAME -is [DBNull]) {
                continue
            }
            $columns += [pscustomobject]@{
                position = [int]$row.ORDINAL_POSITION
                name = [string]$row.COLUMN_NAME
                type = [string]$row.DATA_TYPE
                maxLength = if ($row.CHARACTER_MAXIMUM_LENGTH -is [DBNull]) { $null } else { [int]$row.CHARACTER_MAXIMUM_LENGTH }
                precision = if ($row.NUMERIC_PRECISION -is [DBNull]) { $null } else { [int]$row.NUMERIC_PRECISION }
                scale = if ($row.NUMERIC_SCALE -is [DBNull]) { $null } else { [int]$row.NUMERIC_SCALE }
                nullable = ([string]$row.IS_NULLABLE -eq 'YES')
            }
        }

        $tables += [pscustomobject]@{
            schema = [string]$first.TABLE_SCHEMA
            name = [string]$first.TABLE_NAME
            type = [string]$first.TABLE_TYPE
            columns = $columns
        }
    }

    $inventory = [ordered]@{
        generatedAt = (Get-Date).ToString('o')
        server = [string]$Context.Config.sql.server
        database = [string]$Context.Config.sql.database
        summary = [ordered]@{
            tables = $tables.Count
            columns = @($tables | ForEach-Object { $_.columns }).Count
        }
        tables = $tables
    }

    $inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Context.SchemaPath -Encoding UTF8
    return [pscustomobject]$inventory
}

function Remove-SqlComments {
    param([string]$Sql)
    $withoutBlocks = [regex]::Replace($Sql, '/\*[\s\S]*?\*/', ' ')
    return [regex]::Replace($withoutBlocks, '--.*$', ' ', [Text.RegularExpressions.RegexOptions]::Multiline)
}

function Assert-ReadOnlySql {
    param(
        [string]$Sql,
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Sql)) {
        throw "$Label is empty in mapping.local.json."
    }

    $normalized = (Remove-SqlComments -Sql $Sql).Trim()
    $normalized = $normalized.TrimEnd(';').Trim()
    if ($normalized -notmatch '^(?i)(select|with)\b') {
        throw "$Label must start with SELECT or WITH."
    }
    if ($normalized.Contains(';')) {
        throw "$Label must contain one read-only statement."
    }
    if ($normalized -match '(?i)\b(insert|update|delete|merge|drop|alter|truncate|create|exec|execute|grant|revoke|backup|restore|dbcc)\b') {
        throw "$Label contains a forbidden SQL keyword."
    }
    return $normalized
}

function Get-RowValue {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Row.PSObject.Properties | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if ($null -ne $property -and $null -ne $property.Value -and $property.Value -isnot [DBNull]) {
            return $property.Value
        }
    }
    return $null
}

function Convert-ToInt {
    param(
        [object]$Value,
        [string]$Label
    )

    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Label must be an integer."
    }
    return $parsed
}

function Convert-ToBoolean {
    param([object]$Value)

    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) {
        return ([int64]$Value -ne 0)
    }
    return @('1', 'true', 'yes', 'busy', 'occupied') -contains ([string]$Value).Trim().ToLowerInvariant()
}

function Convert-ToIdentDate {
    param(
        [object]$Value,
        [string]$Label
    )

    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    if ($Value -is [DateTime]) {
        return ([DateTime]$Value).ToString('yyyy-MM-ddTHH:mm:ss')
    }

    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Value, [ref]$parsed)) {
        throw "$Label must be a date and time."
    }
    return $parsed.ToString('yyyy-MM-ddTHH:mm:sszzz')
}

function Convert-RowsToTimetable {
    param(
        [object[]]$DoctorRows,
        [object[]]$BranchRows,
        [object[]]$IntervalRows
    )

    $doctorIds = @{}
    $doctors = @()
    for ($index = 0; $index -lt $DoctorRows.Count; $index++) {
        $row = $DoctorRows[$index]
        $id = Convert-ToInt -Value (Get-RowValue -Row $row -Names @('Id', 'DoctorId')) -Label "Doctors[$index].Id"
        $name = [string](Get-RowValue -Row $row -Names @('Name', 'DoctorName', 'FullName', 'Fio', 'FIO'))
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Doctors[$index].Name is required."
        }
        if (-not $doctorIds.ContainsKey($id)) {
            $doctorIds[$id] = $true
            $doctors += [pscustomobject]@{ Id = $id; Name = $name.Trim() }
        }
    }

    $branchIds = @{}
    $branches = @()
    for ($index = 0; $index -lt $BranchRows.Count; $index++) {
        $row = $BranchRows[$index]
        $id = Convert-ToInt -Value (Get-RowValue -Row $row -Names @('Id', 'BranchId', 'ClinicId')) -Label "Branches[$index].Id"
        $name = [string](Get-RowValue -Row $row -Names @('Name', 'BranchName', 'ClinicName'))
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Branches[$index].Name is required."
        }
        if (-not $branchIds.ContainsKey($id)) {
            $branchIds[$id] = $true
            $branches += [pscustomobject]@{ Id = $id; Name = $name.Trim() }
        }
    }

    $intervals = @()
    for ($index = 0; $index -lt $IntervalRows.Count; $index++) {
        $row = $IntervalRows[$index]
        $doctorId = Convert-ToInt -Value (Get-RowValue -Row $row -Names @('DoctorId')) -Label "Intervals[$index].DoctorId"
        $branchId = Convert-ToInt -Value (Get-RowValue -Row $row -Names @('BranchId', 'ClinicId')) -Label "Intervals[$index].BranchId"
        $start = Convert-ToIdentDate -Value (Get-RowValue -Row $row -Names @('StartDateTime', 'StartAt', 'Start')) -Label "Intervals[$index].StartDateTime"
        $length = Convert-ToInt -Value (Get-RowValue -Row $row -Names @('LengthInMinutes', 'DurationMinutes', 'Length')) -Label "Intervals[$index].LengthInMinutes"
        $busy = Convert-ToBoolean -Value (Get-RowValue -Row $row -Names @('IsBusy', 'Busy', 'IsOccupied'))

        if ($length -le 0) {
            throw "Intervals[$index].LengthInMinutes must be positive."
        }
        if (-not $doctorIds.ContainsKey($doctorId)) {
            throw "Intervals[$index] references unknown DoctorId $doctorId."
        }
        if (-not $branchIds.ContainsKey($branchId)) {
            throw "Intervals[$index] references unknown BranchId $branchId."
        }

        $intervals += [pscustomobject]@{
            DoctorId = $doctorId
            BranchId = $branchId
            StartDateTime = $start
            LengthInMinutes = $length
            IsBusy = $busy
        }
    }

    return [pscustomobject]@{
        Doctors = $doctors
        Branches = $branches
        Intervals = $intervals
    }
}

function Get-Timetable {
    param([pscustomobject]$Context)

    if (-not (Test-Path -LiteralPath $Context.MappingPath)) {
        throw "Mapping file not found: $($Context.MappingPath)"
    }
    $mapping = Read-JsonFile -Path $Context.MappingPath
    $doctorsSql = Assert-ReadOnlySql -Sql ([string]$mapping.doctorsSql) -Label 'doctorsSql'
    $branchesSql = Assert-ReadOnlySql -Sql ([string]$mapping.branchesSql) -Label 'branchesSql'
    $intervalsSql = Assert-ReadOnlySql -Sql ([string]$mapping.intervalsSql) -Label 'intervalsSql'

    $doctorTable = Invoke-SqlQuery -Context $Context -Query $doctorsSql
    $branchTable = Invoke-SqlQuery -Context $Context -Query $branchesSql
    $intervalTable = Invoke-SqlQuery -Context $Context -Query $intervalsSql

    return Convert-RowsToTimetable `
        -DoctorRows @($doctorTable.Rows) `
        -BranchRows @($branchTable.Rows) `
        -IntervalRows @($intervalTable.Rows)
}

function Show-TimetableSummary {
    param([pscustomobject]$Timetable)

    $free = @($Timetable.Intervals | Where-Object { -not $_.IsBusy }).Count
    $busy = @($Timetable.Intervals | Where-Object { $_.IsBusy }).Count
    Write-Host "Doctors:  $(@($Timetable.Doctors).Count)"
    Write-Host "Branches: $(@($Timetable.Branches).Count)"
    Write-Host "Intervals: $(@($Timetable.Intervals).Count) (free: $free, busy: $busy)"
}

function Send-Timetable {
    param(
        [pscustomobject]$Context,
        [pscustomobject]$Timetable
    )

    $encryptedKey = if ($Context.Secrets.PSObject.Properties.Name -contains 'agentApiKeyDpapi') {
        [string]$Context.Secrets.agentApiKeyDpapi
    } else {
        [string]$Context.Secrets.identIntegrationKeyDpapi
    }
    $key = Get-PlainTextSecret -EncryptedValue $encryptedKey
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'Code9 agent key is not configured. Run 1-Setup.cmd again.'
    }

    $baseUrl = ([string]$Context.Config.backend.baseUrl).TrimEnd('/')
    $url = "$baseUrl/api/agent/timetable"
    $body = $Timetable | ConvertTo-Json -Depth 8 -Compress
    $headers = @{ 'X-Agent-Key' = $key }
    $response = Invoke-WebRequest `
        -Uri $url `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec ([int]$Context.Config.backend.timeoutSeconds) `
        -UseBasicParsing

    if ($response.StatusCode -ne 200) {
        throw "Backend returned HTTP $($response.StatusCode)."
    }
    return $response
}

function Invoke-AgentSelfTest {
    $doctors = @(
        [pscustomobject]@{ Id = 10; Name = 'Test Doctor' }
    )
    $branches = @(
        [pscustomobject]@{ Id = 20; Name = 'Test Branch' }
    )
    $intervals = @(
        [pscustomobject]@{
            DoctorId = 10
            BranchId = 20
            StartDateTime = [DateTime]'2026-07-28T10:00:00'
            LengthInMinutes = 30
            IsBusy = 0
        }
    )

    $payload = Convert-RowsToTimetable -DoctorRows $doctors -BranchRows $branches -IntervalRows $intervals
    if ($payload.Doctors.Count -ne 1 -or $payload.Branches.Count -ne 1 -or $payload.Intervals.Count -ne 1) {
        throw 'Self-test payload count mismatch.'
    }
    if ($payload.Intervals[0].StartDateTime -ne '2026-07-28T10:00:00') {
        throw 'Self-test date normalization failed.'
    }
    if ($payload.Intervals[0].IsBusy) {
        throw 'Self-test busy flag normalization failed.'
    }
    [void](Assert-ReadOnlySql -Sql 'SELECT 1 AS Id' -Label 'selfTestSql')
    try {
        [void](Assert-ReadOnlySql -Sql 'DELETE FROM dbo.Test' -Label 'unsafeSql')
        throw 'Self-test failed to block unsafe SQL.'
    }
    catch {
        if ($_.Exception.Message -eq 'Self-test failed to block unsafe SQL.') {
            throw
        }
    }
    $singleDatabase = Select-IdentDatabase -Fingerprints @(
        [pscustomobject]@{ Name = 'ClinicDb'; TableCount = 100; DomainMatches = 0; StrongNameMatch = $false; Score = 4 }
    ) -ConfiguredDatabase ''
    if ($singleDatabase.Name -ne 'ClinicDb') {
        throw 'Self-test failed to select the only accessible database.'
    }
    $namedDatabase = Select-IdentDatabase -Fingerprints @(
        [pscustomobject]@{ Name = 'Archive'; TableCount = 500; DomainMatches = 0; StrongNameMatch = $false; Score = 20 },
        [pscustomobject]@{ Name = 'IDENT_Main'; TableCount = 100; DomainMatches = 3; StrongNameMatch = $true; Score = 119 }
    ) -ConfiguredDatabase ''
    if ($namedDatabase.Name -ne 'IDENT_Main') {
        throw 'Self-test failed to prefer an IDENT-named database.'
    }
    $ambiguousDatabase = Select-IdentDatabase -Fingerprints @(
        [pscustomobject]@{ Name = 'Database1'; TableCount = 100; DomainMatches = 1; StrongNameMatch = $false; Score = 9 },
        [pscustomobject]@{ Name = 'Database2'; TableCount = 95; DomainMatches = 1; StrongNameMatch = $false; Score = 8 }
    ) -ConfiguredDatabase ''
    if ($null -ne $ambiguousDatabase) {
        throw 'Self-test selected an ambiguous database.'
    }
    $genericNamedDatabase = Select-IdentDatabase -Fingerprints @(
        [pscustomobject]@{ Name = 'ClinicDb'; TableCount = 200; DomainMatches = 0; StrongNameMatch = $false; Score = 120 },
        [pscustomobject]@{ Name = 'Archive'; TableCount = 100; DomainMatches = 0; StrongNameMatch = $false; Score = 20 }
    ) -ConfiguredDatabase ''
    if ($null -ne $genericNamedDatabase) {
        throw 'Self-test trusted a generic clinic database name without schema evidence.'
    }
    $tcpEndpoint = ConvertTo-SqlEndpoint -DataSource 'tcp:192.168.0.3,51433' -Source 'self-test'
    if ($tcpEndpoint.Server -ne '192.168.0.3' -or $tcpEndpoint.Port -ne 51433) {
        throw 'Self-test failed to parse a TCP SQL endpoint.'
    }
    $pipeEndpoint = ConvertTo-SqlEndpoint -DataSource 'np:\\SERVER\pipe\MSSQL$IDENT\sql\query' -Source 'self-test'
    if ($pipeEndpoint.Server -ne 'SERVER' -or $pipeEndpoint.DataSource -notmatch '^np:') {
        throw 'Self-test failed to parse a named-pipe SQL endpoint.'
    }
    $explicitSource = Get-SqlDataSource -SqlConfig ([pscustomobject]@{
        dataSource = 'np:\\SERVER\pipe\sql\query'
        server = 'ignored'
        instanceName = ''
        port = 0
    })
    if ($explicitSource -ne 'np:\\SERVER\pipe\sql\query') {
        throw 'Self-test failed to preserve an explicit SQL data source.'
    }
    $nestedNumber = Get-NestedSqlErrorNumber -Exception ([pscustomobject]@{
        InnerException = [pscustomobject]@{ Number = 18456 }
    })
    if ($nestedNumber -ne 18456) {
        throw 'Self-test failed to read a nested SQL error number.'
    }
    $configurationDatabases = @(Get-DatabaseNamesFromConfigurationText -Content @'
Server=tcp:192.168.0.3,15000;Initial Catalog=IDENT_MAIN;User ID=readonly_user;
{"databaseName":"IDENT_ARCHIVE"}
<database>IDENT_REPORTS</database>
'@ -Source 'self-test')
    if (
        @($configurationDatabases | Where-Object { $_.Name -eq 'IDENT_MAIN' }).Count -ne 1 -or
        @($configurationDatabases | Where-Object { $_.Name -eq 'IDENT_ARCHIVE' }).Count -ne 1 -or
        @($configurationDatabases | Where-Object { $_.Name -eq 'IDENT_REPORTS' }).Count -ne 1
    ) {
        throw 'Self-test failed to extract database names from IDENT configuration text.'
    }
    Write-Host 'SELF-TEST OK' -ForegroundColor Green
}

if ($SelfTest) {
    Invoke-AgentSelfTest
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}

$context = Get-AgentContext -Path $ConfigPath

try {
    if ($AutoConfigureSql) {
        Invoke-AutoConfigureSql -Context $context
        exit 0
    }

    if ($DiscoverInstances) {
        Write-Step "Discovering SQL Server instances on $($context.Config.sql.server)"
        $instances = @(Find-SqlBrowserInstances -Server ([string]$context.Config.sql.server))
        if ($instances.Count -eq 0) {
            Write-Host 'SQL Browser did not return an instance. This usually means UDP 1434 is blocked or SQL Browser is disabled.' -ForegroundColor Yellow
            Write-Host 'This is not a password error.'
        }
        else {
            $instances | Format-List
        }
        exit 0
    }

    if ($TestConnection) {
        Write-Step 'Testing read-only SQL connection'
        $result = Test-SqlConnection -Context $context
        $result.Server | Format-List
        Write-Host 'Accessible databases:' -ForegroundColor Cyan
        $result.Databases | ForEach-Object { Write-Host "  $_" }
        Write-AgentLog -Context $context -Level 'info' -Event 'sql_connection_ok' -Data @{
            server = $result.Server.ServerName
            instance = $result.Server.InstanceName
            databaseCount = $result.Databases.Count
        }
        exit 0
    }

    if ($ExportSchema) {
        Write-Step 'Exporting database structure (no patient rows)'
        $schema = Export-SqlSchema -Context $context
        Write-Host "Tables/views: $($schema.summary.tables)"
        Write-Host "Columns:      $($schema.summary.columns)"
        Write-Host "Saved to:    $($context.SchemaPath)" -ForegroundColor Green
        Write-AgentLog -Context $context -Level 'info' -Event 'schema_exported' -Data @{
            database = $schema.database
            tables = $schema.summary.tables
            columns = $schema.summary.columns
        }
        exit 0
    }

    if ($Preview) {
        Write-Step 'Building timetable preview from IDENT database'
        $previewPayload = Get-Timetable -Context $context
        Show-TimetableSummary -Timetable $previewPayload
        Write-AgentLog -Context $context -Level 'info' -Event 'preview_ok' -Data @{
            doctors = @($previewPayload.Doctors).Count
            branches = @($previewPayload.Branches).Count
            intervals = @($previewPayload.Intervals).Count
        }
        exit 0
    }

    if ($Push) {
        Write-Step 'Reading IDENT schedule'
        $pushPayload = Get-Timetable -Context $context
        Show-TimetableSummary -Timetable $pushPayload
        Write-Step 'Sending schedule to Code9 backend'
        $sendResult = Send-Timetable -Context $context -Timetable $pushPayload
        $pushResult = [ordered]@{
            timestamp = (Get-Date).ToString('o')
            ok = $true
            statusCode = $sendResult.StatusCode
            doctors = @($pushPayload.Doctors).Count
            branches = @($pushPayload.Branches).Count
            intervals = @($pushPayload.Intervals).Count
            freeIntervals = @($pushPayload.Intervals | Where-Object { -not $_.IsBusy }).Count
            busyIntervals = @($pushPayload.Intervals | Where-Object { $_.IsBusy }).Count
        }
        $pushResult | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $context.ResultPath -Encoding UTF8
        Write-Host "Schedule sent successfully. HTTP $($sendResult.StatusCode)." -ForegroundColor Green
        Write-AgentLog -Context $context -Level 'info' -Event 'timetable_sent' -Data @{
            doctors = @($pushPayload.Doctors).Count
            branches = @($pushPayload.Branches).Count
            intervals = @($pushPayload.Intervals).Count
            status = $sendResult.StatusCode
        }
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-AgentLog -Context $context -Level 'error' -Event 'agent_failed' -Data @{
        mode = $PSCmdlet.ParameterSetName
        message = $_.Exception.Message
    }
    exit 1
}
