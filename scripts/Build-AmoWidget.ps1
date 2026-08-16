[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WidgetDirectory,
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-WidgetArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $stream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $stream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        $files = Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File | Sort-Object FullName
        foreach ($file in $files) {
            $relativePath = $file.FullName.Substring($SourceDirectory.Length).TrimStart([char[]]@('\', '/'))
            $entryName = $relativePath.Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            $inputStream = $null
            try {
                $inputStream = [IO.File]::OpenRead($file.FullName)
                $inputStream.CopyTo($entryStream)
            }
            finally {
                if ($inputStream) { $inputStream.Dispose() }
                $entryStream.Dispose()
            }
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        $stream.Dispose()
    }
}

$widgetRoot = [IO.Path]::GetFullPath($WidgetDirectory)
$source = [IO.Path]::GetFullPath((Join-Path $widgetRoot 'front'))
$dist = [IO.Path]::GetFullPath((Join-Path $widgetRoot 'dist'))
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
    throw "Widget front directory was not found: $source"
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must use the x.y.z format.'
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null
$versioned = [IO.Path]::GetFullPath((Join-Path $dist "ident-amocrm-widget-$Version.zip"))
$latest = [IO.Path]::GetFullPath((Join-Path $dist 'widget.zip'))
$distPrefix = $dist.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

foreach ($path in @($versioned, $latest)) {
    if (-not $path.StartsWith($distPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Archive path escaped the widget dist directory.'
    }
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

New-WidgetArchive -SourceDirectory $source -DestinationPath $versioned
Copy-Item -LiteralPath $versioned -Destination $latest

Get-Item -LiteralPath $versioned, $latest | Select-Object FullName, Length
