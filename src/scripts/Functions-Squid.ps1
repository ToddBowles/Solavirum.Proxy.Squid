#Requires -RunAsAdministrator

function Start-SquidService
{
    [CmdletBinding()]
    param
    (

    )

    $serviceName = "squidsrv"
    Write-Verbose "Start Squid Service [$serviceName]"
    try
    {
        Start-Service $serviceName
    }
    catch
    {
        Write-Warning "Service [$serviceName] could not be started due to an error."
        Write-Warning $_
    }
}

function Stop-SquidService
{
    [CmdletBinding()]
    param
    (

    )

    $serviceName = "squidsrv"
    Write-Verbose "Stopping Squid Service [$serviceName]"
    try
    {
        Stop-Service $serviceName
    }
    catch
    {
        Write-Warning "Service [$serviceName] could not be stopped due to an error."
        Write-Warning $_
    }
}

function Check-SquidInstalled
{
    [CmdletBinding()]
    param
    (
        [scriptblock]$DI_getInstalledApplications={ Get-InstalledApplications }
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-InstalledApplications.ps1"
    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

    $installedApplications = & $DI_getInstalledApplications
    $anySquid = $installedApplications | Any -Predicate { $_.ProgramName -like "*Squid*" }
    return $anySquid
}

function Install-Squid
{
    [CmdletBinding()]
    param
    (
        [switch]$throwOnFailure=$true
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $rootDirectoryPath = $rootDirectory.FullName

    $commonScriptsPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsPath\Functions-Enumerables.ps1"

    $SquidInstallerFile = Get-ChildItem -Path "$rootDirectoryPath\installer" | Single

    $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
    $logFilePath = "$rootDirectoryPath\logs\SquidInstall_$timestamp.log"
    New-Item -Path $logFilePath -ItemType File -Force

    $arguments = @()
    $arguments += "/i"
    $arguments += "`"$($SquidInstallerFile.FullName)`""
    $arguments += "/qn"
    $arguments += "/l*v"
    $arguments += "`"$logFilePath`""

    Write-Verbose "Installing Squid: [msiexec [$arguments]]"
    $result = Start-Process -FilePath msiexec -ArgumentList ([String]::Join(" ", $arguments)) -Wait -Passthru
    $exitCode = $result.ExitCode

    $hash = @{
        "Arguments"=$arguments;
        "ExitCode"=$exitCode;
        "LogFilePath"=$logFilePath;
        "Successful"=($exitCode -eq 0);
    }

    $result = new-object PSObject $hash

    if ($throwOnFailure -and -not ($result.Successful))
    {
        throw "Failed to install from [$($SquidInstallerFile.FullName). Exit code [$exitCode]."
    }

    return $result
}

function Uninstall-Squid
{
    [CmdletBinding()]
    param
    (
        [switch]$throwOnFailure=$false
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

    $program = gci "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" | 
        foreach { gp $_.PSPath } | 
        ? { $_ -match "Squid" } | 
        Single

    $uninstall = $program.UninstallString
    if ($uninstall)
    {
        $uninstall = $uninstall -Replace "msiexec.exe","" -Replace "/I","" -Replace "/X",""
        $uninstall = $uninstall.Trim()

        $timestamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmss")
        $logFilePath = "$rootDirectoryPath\logs\SquidUninstall_$timestamp.log"
        New-Item -Path $logFilePath -ItemType File -Force

        $arguments = @()
        $arguments += "/X"
        $arguments += "`"$uninstall`""
        $arguments += "/qn"
        $arguments += "/l*v"
        $arguments += "`"$logFilePath`""

        Write "Uninstalling Squid: [msiexec $arguments]"
        $result = Start-Process -FilePath msiexec -ArgumentList ([String]::Join(" ", $arguments)) -Wait -Passthru
        $exitCode = $result.ExitCode

        $hash = @{
            "Arguments"=$arguments;
            "ExitCode"=$exitCode;
            "LogFilePath"=$logFilePath;
            "Successful"=($exitCode -eq 0);
        }

        $result = new-object PSObject $hash

        if ($throwOnFailure -and -not ($result.Successful))
        {
            throw "Failed to uninstall Squid from [$uninstall]. Exit code [$exitCode]."
        }

        return $result
    }
}

function Configure-Squid
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$configId,
        [System.IO.DirectoryInfo]$DI_squidConfigurationDirectory
    )

    if ($rootDirectory -eq $null) { throw "rootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $rootDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-FileSystem.ps1"

    if ($DI_squidConfigurationDirectory -eq $null)
    {
        $DI_squidConfigurationDirectory = Ensure-DirectoryExists "C:\Squid\etc\squid"
    }

    $baseConfig = "$rootDirectoryPath\configuration\$configId.conf"
    if (-not (Test-Path $baseConfig))
    {
        throw "The configId specified [$configId] was not valid. No configuration file could be found."
    }

    $tempConfigFile = "$rootDirectoryPath\configuration\script-working\squid-$([Guid]::NewGuid().ToString("N")).conf"
    $tempConfigFile = New-Item -Path $tempConfigFile -Force -Type "File"

    $configurationFileDestination = "$($DI_nxlogConfigurationDirectory.FullName)\squid.conf"
    $configurationFileDestination = New-Item -Path $configurationFileDestination -Force -Type "File"

    Write-Verbose "Copying configuration file from [$($tempConfigFile.FullName)] to [$($configurationFileDestination.FullName)]."
    Copy-Item $tempConfigFile $configurationFileDestination -Force
}