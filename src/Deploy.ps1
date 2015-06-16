$VerbosePreference = "Continue"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

$rootDirectory = new-object System.IO.DirectoryInfo $here
$rootDirectoryPath = $rootDirectory.FullName

. "$rootDirectoryPath\scripts\Functions-Squid.ps1"

Stop-SquidService

Install-Squid
New-NetFirewallRule -DisplayName "Squid Proxy" -Direction Inbound -Program "C:\Squid\bin\Squid.exe" -Action Allow -Profile Any

$configId = "default"
Configure-Squid -ConfigId $configId
Start-SquidService