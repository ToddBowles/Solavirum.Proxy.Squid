$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path) -ireplace "tests.", ""
. "$here\$sut"

. "$currentDirectoryPath\_Find-RootDirectory.ps1"
$rootDirectory = Find-RootDirectory $here

. "$($rootDirectory.FullName)\scripts\common\Functions-Credentials.ps1"

function Create-UniqueEnvironmentName
{
    $currentUtcDateTime = [DateTime]::UtcNow
    $a = $currentUtcDateTime.ToString("yy") + $currentUtcDateTime.DayOfYear.ToString("000")
    $b = ([int](([int]$currentUtcDateTime.Subtract($currentUtcDateTime.Date).TotalSeconds) / 2)).ToString("00000")
    return "T$a$b"
}

function Get-AwsCredentials
{
    $keyLookup = "SQUID_PROXY_AWS_ENVIRONMENT_KEY"
    $secretLookup = "SQUID_PROXY_AWS_ENVIRONMENT_SECRET"

    $awsCreds = @{
        AwsKey = (Get-CredentialByKey $keyLookup);
        AwsSecret = (Get-CredentialByKey $secretLookup);
    }
    return New-Object PSObject -Property $awsCreds
}

function Get-OctopusCredentials
{
    $keyLookup = "SQUID_PROXY_OCTOPUS_API_KEY"

    $octopusCreds = @{
        Key = (Get-CredentialByKey $keyLookup);
    }
    return New-Object PSObject -Property $octopusCreds
}

Describe "New-Environment" {
    Context "When executed with appropriate parameters" {
        It "Returns appropriate outputs, including stack identifiers and URLs for exposed services" {
            $creds = Get-AWSCredentials
            $octopusCreds = Get-OctopusCredentials
            $environmentName = Create-UniqueEnvironmentName

            try
            {
                $environmentCreationResult = New-Environment -AwsKey $creds.AwsKey -AwsSecret $creds.AwsSecret -OctopusApiKey $octopusCreds.Key -EnvironmentName $environmentName -Wait -disableCleanupOnFailure

                Write-Verbose (ConvertTo-Json $environmentCreationResult)

                $environmentCreationResult.Url | Should Not BeNullOrEmpty

                $result = Invoke-WebRequest -Uri "www.google.com" -Proxy "$($environmentCreationResult.Url)" -Method GET
                $result.StatusCode | Should Be 200
            }
            finally
            {
                Delete-Environment -AwsKey $creds.AwsKey -AwsSecret $creds.AwsSecret -OctopusApiKey $octopusCreds.Key -EnvironmentName $environmentName -Wait
            }
        }
    }
}