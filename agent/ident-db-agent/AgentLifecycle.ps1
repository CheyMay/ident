function Get-IdentPowerSample {
    if (-not ('Code9IdentPowerClock' -as [type])) {
        # Active time excludes suspend/hibernate and is unaffected by wall-clock corrections.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Code9IdentPowerClock {
    [DllImport("kernel32.dll")] static extern bool QueryUnbiasedInterruptTime(out ulong value);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
    public static double[] Read() {
        ulong active;
        if (!QueryUnbiasedInterruptTime(out active)) throw new InvalidOperationException("Active clock unavailable.");
        return new double[] { active / 10000.0, (double)GetTickCount64() };
    }
}
'@
    }
    $sample=[Code9IdentPowerClock]::Read()
    return [pscustomobject]@{ ActiveMs=$sample[0]; UptimeMs=$sample[1] }
}

function Test-IdentPowerResume {
    param([object]$Previous,[object]$Current)
    if ($null -eq $Previous) { return $false }
    $active=[double]$Current.ActiveMs-[double]$Previous.ActiveMs
    $uptime=[double]$Current.UptimeMs-[double]$Previous.UptimeMs
    return $active -ge 0 -and $uptime -ge 0 -and ($uptime-$active) -ge 2000
}

function Get-IdentCloseAction {
    param([string]$Reason,[bool]$AllowClose)
    if (-not $AllowClose -and $Reason -eq 'UserClosing') { return 'hide' }
    return 'close'
}

function Repair-IdentHiddenShortcuts {
    param([string]$Directory)
    $directory=[IO.Path]::GetFullPath($Directory)
    $shell=New-Object -ComObject WScript.Shell
    $items=@(
        @([Environment]::GetFolderPath('Desktop'),'Code9 IDENT.lnk','IdentDesktop.ps1'),
        @([Environment]::GetFolderPath('Startup'),'Code9 IDENT Agent.lnk','IdentSupervisor.ps1'),
        @([Environment]::GetFolderPath('Startup'),'Code9 IDENT Agent Status.lnk','IdentDesktop.ps1')
    )
    foreach($item in $items) {
        if (-not $item[0]) { continue }
        $path=Join-Path $item[0] $item[1]
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $shortcut=$shell.CreateShortcut($path)
        $scriptPath=Join-Path $directory $item[2]
        # Do not repurpose a user shortcut that happens to share the product's name.
        if ([IO.Path]::GetFileName($shortcut.TargetPath) -ine 'powershell.exe' -or
            $shortcut.Arguments.IndexOf(('"'+$scriptPath+'"'),[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $arguments=[regex]::Replace($shortcut.Arguments,'(?i)(?:^|\s)-WindowStyle\s+(?:Hidden|Normal|Minimized|Maximized)\b','')
        $shortcut.Arguments='-WindowStyle Hidden '+$arguments.Trim()
        $shortcut.WindowStyle=7
        $shortcut.Save()
    }
}
