<#
    .SYNOPSIS
        This is a Pester test script meant to perform a series of checks on proprietary scripts and modules to ensure
        it does not contains any company-specific information. It is to be used as a final gate between private scripts/modules
        before sharing with the community.

    .EXAMPLE
        PS> $params = @{
                Script = @{
                Path = 'C:\Community.Tests.ps1'
                Parameters = @{
                    FolderPath = 'C:\Path'
                    CompanyReference = 'Acme Corporation'
                }
            }
        PS> Invoke-Pester @params
        
        This example invokes Pester using this community test script to run tests against a company-specific script.

    .PARAMETER FolderPath
         A mandatory string parameter representing a folder full of PowerShell scripts. This folder will be recursively read
         for all PowerShell scripts and modules to process.

    .PARAMETER CompanyReference
         An optional parameter representing one or more strings separated by a comma that represent any company-specific strings
         that need to be removed prior to community sharing.

#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path -Path $_ -PathType Container })]
    [string]$FolderPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$CompanyReference
)

## Command names to ignore when searching for missing
$defaultCommandNames = (Get-Command -Module 'CimCmdlets','DnsClient','Microsoft.PowerShell.*','Pester' -All).Name

## Modules to ignore with commnds when searching for missing
$defaultModules = (Get-Module -Name 'Microsoft.PowerShell.*','Pester').Name

## Find all PowerShell files (PS1, PSM1) inside of the folder path
if ($scripts = Get-ChildItem -Path $FolderPath -Recurse -Filter '*.ps*' | Sort-Object Name) {
    $scripts | foreach({
        $script = $_.FullName
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script,[ref]$null,[ref]$null)
        
        ## Find all command references inside of the script
        $commandRefs = $ast.FindAll({$args[0] -is [System.Management.Automation.Language.CommandAst]},$true)
        
        ## If a Pester test script, find all mocks
        $script:commandRefNames = @()
        if ($testRefs = Select-String -path $script -Pattern "mock [`"|'](.*)[`"|']") {
            $testRefs = $testRefs.Matches
            $commandRefNames += $testRefs | foreach {
                $_.Groups[1].Value
            }
        }

        $script:commandRefNames += (@($commandRefs).foreach({ [string]$_.CommandElements[0] }) | Select-Object -Unique)
        $script:commandDeclarationNames = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Select-Object -ExpandProperty Name
        
        describe "[$($script)] Test" {

            if ($CompanyReference) {
                $companyRefRegex = ('({0})' -f ($CompanyReference -join '|'))
                if ($companyReferences = [regex]::Matches((Get-Content $script -Raw),$companyRefRegex)) {
                    if ($companyReferences -ne $null) {
                        $companyReferences = $companyReferences.Groups[1].Value
                    }
                }
            }

            $properties = @(
                @{
                    Name = 'Command'
                    Expression = { $alias = Get-Alias -Name $_ -ErrorAction Ignore
                        if ($alias) {
                            $alias.ResolvedCommandName
                        } else {
                            $_
                        }
                    }
                }
            )

            $privateCommandNames = $script:commandRefNames | Select-Object -Property $properties | Where {
                $_.Command -notin $defaultCommandNames -and 
                $_.Command -notin $commandDeclarationNames -and
                $_.Command -match '^\w' -and
                $_.Command -notmatch 'powershell_ise\.exe'
            } | Select-Object -ExpandProperty Command

            $privateModuleNames = (Select-String -Path $script -Pattern 'Import-Module (.*)').where({ $_.Matches.Groups[1].Value -notin $defaultModules })
            
            it 'has no references to our company-specific strings' {
                $companyReferences | should benullOrempty
            }

            it 'has no references to private functions' {
                $privateCommandNames | should be $null
            }

            it 'has no references to private modules' {
                $privateModuleNames | should benullOrempty
            }
        }
    })
}