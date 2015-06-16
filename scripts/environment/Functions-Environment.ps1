function Get-KnownEnvironments
{
    return @("CI", "Staging", "Production")
}

function Get-StackName
{
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$environment
    )
    
    return "$(Get-UniqueEnvironmentComponentIdentifier)-$environment"
}

function Get-DependenciesS3BucketPrefix
{
    param
    (
        [string]$environment
    )

    return "$(Get-UniqueEnvironmentComponentIdentifier)/$environment"
}

function Get-UniqueEnvironmentComponentIdentifier
{
    return "SquidProxy"
}

function Get-DependenciesS3BucketName
{
    return "oth.console.cloudformation.scratch"
}


function Get-LogsS3BucketName
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [string]$environmentName
    )

    return "oth.console.$(Get-UniqueEnvironmentComponentIdentifier).$environmentName.logs".ToLowerInvariant()
}

function New-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [string]$awsRegion="ap-southeast-2",
        [string]$octopusServerUrl="http://octopus.aws.console.othsolutions.com.au:8088/",
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [switch]$wait,
        [switch]$disableCleanupOnFailure
    )

    try
    {
        write-verbose "Creating New Environment $environmentName"

        if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

        $scriptFileLocation = Split-Path $script:MyInvocation.MyCommand.Path
        write-verbose "Script is located at [$scriptFileLocation]."

        $rootDirectoryDirectoryPath = $rootDirectory.FullName
        $commonScriptsDirectoryPath = "$rootDirectoryDirectoryPath\scripts\common"

        . "$commonScriptsDirectoryPath\Functions-OctopusDeploy.ps1"
        $knownEnvironments = Get-KnownEnvironments
        if (!$knownEnvironments.Contains($environmentName))
        {
            write-warning "You have specified an environment [$environmentName] that is not in the list of known environments [$($knownEnvironments -join ", ")]. The script will temporarily create an environment in Octopus, and then delete it at the end."
            $shouldRemoveOctopusEnvironmentWhenDone = $true

            try
            {
                $octopusEnvironment = New-OctopusEnvironment -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentName $environmentName -EnvironmentDescription "[SCRIPT] Environment automatically created because it did not already exist and the New-Environment Powershell function was being executed."
            }
            catch 
            {
                Write-Warning "Octopus Environment [$environmentName] could not be created."
                Write-Warning $_
            }
        }
        else
        {
            $shouldRemoveOctopusEnvironmentWhenDone = $false

            $octopusEnvironment = Get-OctopusEnvironmentByName -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentName $environmentName
        }

        . "$commonScriptsDirectoryPath\Functions-Aws.ps1"

        Ensure-AwsPowershellFunctionsAvailable

        Write-Verbose "Gathering environment setup dependencies into single zip archive for distribution to S3 for usage by CloudFormation."
        $directories = Get-ChildItem -Directory -Path $($rootDirectory.FullName) |
            Where-Object { $_.Name -like "scripts" -or $_.Name -like "tools" }

        $user = (& whoami).Replace("\", "_")
        $date = [DateTime]::Now.ToString("yyyyMMddHHmmss")

        $archive = "$scriptFileLocation\script-working\$environmentName\$user\$date\dependencies.zip"

        . "$commonScriptsDirectoryPath\Functions-Compression.ps1"

        $archive = 7Zip-ZipDirectories $directories $archive -SubdirectoriesToExclude @("script-working","test-working")
        $archive = 7Zip-ZipFiles "$($rootDirectory.FullName)\script-root-indicator" $archive -Additive

        Write-Verbose "Uploading dependencies archive to S3 for usage by CloudFormation."
        $dependenciesS3Bucket = Get-DependenciesS3BucketName

        $dependenciesArchiveS3Key = "$(Get-DependenciesS3BucketPrefix $environmentName)/$user/$date/dependencies.zip"

        . "$commonScriptsDirectoryPath\Functions-Aws-S3.ps1"
        . "$commonScriptsDirectoryPath\Functions-Enumerables.ps1"

        $dependenciesArchiveS3Key = UploadFileToS3 -AwsKey $awsKey -AwsSecret $awsSecret -AwsBucket $dependenciesS3Bucket -AwsRegion $awsRegion -File $archive -S3FileKey $dependenciesArchiveS3Key

        $filter_name = New-Object Amazon.EC2.Model.Filter -Property @{Name = "name"; Value = "Windows_Server-2012-R2_RTM-English-64Bit-Core*"}
        $ec2ImageDetails = Get-EC2Image -Owner amazon -Filter $filter_name  -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion | 
            Sort-Object Name -Descending | 
            First

        $amiId = $ec2ImageDetails.ImageId

        $parametersHash = @{
            "AdminPassword"="SLKopirHc2fkrHVs0Wud";
            "DependenciesS3Bucket"=$dependenciesS3Bucket;
            "DependenciesS3BucketAccessKey"=$awsKey;
            "DependenciesS3BucketSecretKey"=$awsSecret;
            "DependenciesArchiveS3Url"="https://s3-ap-southeast-2.amazonaws.com/$dependenciesS3Bucket/$dependenciesArchiveS3Key";
            "OctopusEnvironment"="$environmentName";
            "OctopusServerURL"=$octopusServerUrl;
            "OctopusAPIKey"=$octopusApiKey;
            "AmiId"=$amiId;
            "LogsS3BucketName" = (Get-LogsS3BucketName $environmentName);
        }

        . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"

        $stacksHash = @{}

        $resultHash = @{}
        $resultHash.Add("Stacks", $stacksHash)
        $resultHash.Add("Url", $null)
        $resultHash.Add("OctopusEnvironmentId", $octopusEnvironment.Id)

        $result = new-object PSObject $resultHash

        $tags = @()
        $octopusEnvironmentTag = new-object Amazon.CloudFormation.Model.Tag
        $octopusEnvironmentTag.Key = "OctopusEnvironment"
        $octopusEnvironmentTag.Value = $environmentName
        $tags += $octopusEnvironmentTag

        $templateFilePath = "$($rootDirectory.FullName)\scripts\environment\Proxy.Squid.cloudformation.template"
        $templateContent = Get-Content $templateFilePath -Raw
        $stackName = "$(Get-StackName $environmentName)"
        write-verbose "Creating [$stackName] stack using template at [$templateFilePath]."
        $apiStackId = New-CFNStack -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -StackName $stackName -TemplateBody $templateContent -Parameters (Convert-HashTableToAWSCloudFormationParametersArray $parametersHash) -DisableRollback:$true -Tags $tags -Capabilities CAPABILITY_IAM
        $stacksHash.Add($apiStackId, $null)

        if ($wait)
        {
            $result = Wait-Environment -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -NewEnvironmentResult $result

            $stackIds = ($result.Stacks.GetEnumerator() | Select -ExpandProperty Name )
            foreach ($stackId in $stackIds)
            {
                $stack = $result.Stacks[$stackId]
                if ($stack.StackStatus -ne [Amazon.CloudFormation.StackStatus]::CREATE_COMPLETE)
                {
                    throw "Stack creation for [$stackId] failed. If DisableCleanupOnFailure is set, you will be able to check the Stack in the AWS Dashboard and investigate. If not, rerun with that switch set to get more information."
                } 
            }

            $apiStack = $result.Stacks[$apiStackId]
            $result.Url = ($apiStack.Outputs | Where-Object { $_.OutputKey -eq "URL" } | Single).OutputValue
        }

        return $result
    }
    catch
    {
        if (!$disableCleanupOnFailure)
        {
            Write-Warning "A failure occurred and DisableCleanupOnFailure flag was set to false. Cleaning up."
            Delete-Environment -environmentName $environmentName -awsKey $awsKey -awsSecret $awsSecret -awsRegion $awsRegion -octopusServerUrl $octopusServerUrl -octopusApiKey $octopusApiKey -Wait
        }

        throw $_
    }
}

function Wait-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [string]$awsRegion="ap-southeast-2",
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $newEnvironmentResult
    )

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $scriptFileLocation = Split-Path $script:MyInvocation.MyCommand.Path
    write-verbose "Script is located at [$scriptFileLocation]."

    $rootDirectoryDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"

    $stackIds = ($newEnvironmentResult.Stacks.GetEnumerator() | Select -ExpandProperty Name )
    foreach ($stackId in $stackIds)
    {
        $stack = Wait-CloudFormationStack -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -StackName "$stackId"
        $newEnvironmentResult.Stacks.Set_Item($stackId, $stack)
    }
    
    return $newEnvironmentResult
}

function Delete-Environment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$environmentName,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsKey,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$awsSecret,
        [string]$awsRegion="ap-southeast-2",
        [string]$octopusServerUrl="http://octopus.aws.console.othsolutions.com.au:8088/",
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$octopusApiKey,
        [switch]$wait
    )

    Write-Verbose "Deleting Environment $environmentName"

    if ($rootDirectory -eq $null) { throw "RootDirectory script scoped variable not set. Thats bad, its used to find dependencies." }

    $scriptFileLocation = Split-Path $script:MyInvocation.MyCommand.Path
    write-verbose "Script is located at [$scriptFileLocation]."

    $rootDirectoryDirectoryPath = $rootDirectory.FullName
    $commonScriptsDirectoryPath = "$rootDirectoryDirectoryPath\scripts\common"

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"
    . "$commonScriptsDirectoryPath\Functions-OctopusDeploy.ps1"

    $stackName = Get-StackName $environmentName

    Write-Verbose "Cleaning up Octopus environment $environmentName"
    $machines = Get-OctopusMachinesByRole -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -Role $stackName
    $machines | ForEach-Object { $deletedMachine = Delete-OctopusMachine -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -MachineId $_.Id }

    if (-not ((Get-KnownEnvironments) -contains $environmentName))
    {
        try
        {
            $environment = Get-OctopusEnvironmentByName -EnvironmentName $environmentName -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey
            if ($environment -ne $null)
            {
                $deletedEnvironment = Delete-OctopusEnvironment -OctopusServerUrl $octopusServerUrl -OctopusApiKey $octopusApiKey -EnvironmentId $environment.Id
            }
        }
        catch 
        {
            Write-Warning "Octopus Environment [$environmentName] could not be deleted."
            Write-Warning $_
        }
    }

    . "$commonScriptsDirectoryPath\Functions-Aws.ps1"

    Ensure-AwsPowershellFunctionsAvailable
    
    . "$commonScriptsDirectoryPath\Functions-Aws-S3.ps1"

    $logsBucketName = Get-LogsS3BucketName -environmentName $environmentName
    Write-Verbose "Removing bucket [$logsBucketName] outside stack teardown to prevent issues with bucket deletion (involving writing to the bucket after its cleared but before its deleted)."
    try
    {
        Remove-S3Bucket -BucketName $logsBucketName -AccessKey $awskey -SecretKey $awsSecret -Region $awsRegion -DeleteObjects -Force
    }
    catch 
    {
        Write-Warning "Bucket [$logsBucketName] could not be removed."
        Write-Warning $_
    }

    . "$commonScriptsDirectoryPath\Functions-Aws-CloudFormation.ps1"

    Remove-CFNStack -AccessKey $awsKey -SecretKey $awsSecret -Region $awsRegion -Force -StackName "$stackName"

    if ($wait)
    {
        try
        {
            $stack = Wait-CloudFormationStack -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -StackName "$stackName" -TestStatus ([Amazon.CloudFormation.StackStatus]::DELETE_IN_PROGRESS)
        }
        catch
        {
            if (-not($_.Exception.Message -like "Stack*does not exist"))
            {
                throw
            }
        }
    }

    $dependenciesS3Bucket = Get-DependenciesS3BucketName
    RemoveFilesFromS3ByPrefix -AwsKey $awsKey -AwsSecret $awsSecret -AwsRegion $awsRegion -AwsBucket $dependenciesS3Bucket -Prefix (Get-DependenciesS3BucketPrefix $environmentName) -Force
}
