#Requires -RunAsAdministrator

$here = Split-Path $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -ireplace "tests.", ""
. "$here\$sut"

. "$here\_Find-RootDirectory.ps1"
$rootDirectory = Find-RootDirectory $here

function Get-UniqueTestWorkingDirectory
{
    $tempDirectoryName = [System.Guid]::NewGuid().ToString()
    return "$here\test-working\$tempDirectoryName"
}

Describe "Install-Squid" {
    Context "When Squid is not already installed" {
        It "Installs Squid silently" {
            try
            {
                $result = Install-Squid -ThrowOnFailure:$false

                Get-Content $result.LogFilePath |
                    Write-Verbose
            }
            finally
            {
                if ($result.Successful)
                {
                    Uninstall-Squid
                }
            }
        }
    }
}

Describe "Check-SquidInstalled" {
    Context "When supplied with a set of installed applications containing one with a ProgramName of Squid" {
        It "Returns true" {
            $installedApplications = @(
                new-object PSObject -Property @{ProgramName="bananas"};
                new-object PSObject -Property @{ProgramName="Squid"};
            )

            $result = Check-SquidInstalled -DI_getInstalledApplications { $installedApplications }

            $result | Should Be $true
        }
    }

    Context "When supplied with a set of installed applications not containing one with a ProgramName of Squid" {
        It "Returns true" {
            $installedApplications = @(
                new-object PSObject -Property @{ProgramName="bananas"};
                new-object PSObject -Property @{ProgramName="other things"};
            )

            $result = Check-SquidInstalled -DI_getInstalledApplications { $installedApplications }

            $result | Should Be $false
        }
    }
}