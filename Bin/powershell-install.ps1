<#
.SYNOPSIS
    Installs PowerShell
.DESCRIPTION
    Installs PowerShell. If PowerShell installation already exists it will
    update it only if the requested version differs from the one already
    installed.
.PARAMETER Version
    Default: Latest
    Represents a build version on specific channel. Possible values:
    - Latest - Latest version of PowerShell
    - 2-part version in a format A.B - represents a specific release
          examples: 2.0, 1.0
    - Branch name
          examples: release/v7.1.0,-preview.5
    Note: The version parameter overrides the channel parameter.
.PARAMETER InstallDir - TODO
    Default: %LocalAppData%\Microsoft\dotnet
    Path to where to install dotnet. Note that binaries will be placed directly
    in a given directory.
.PARAMETER Architecture
    Default: <auto> - this value represents currently running OS architecture
    Architecture of PowerShell binaries to be installed.
    Possible values are: <auto>, amd64, x64, x86, arm64, arm
.PARAMETER DryRun - FIXME
    If set it will not perform installation but instead display what command
    line to use to consistently installcurrently requested version of PowerShell.
    In example if you specify version 'latest' it will display a link
    with specific version so that this command can be used deterministicly in a build script.
    It also displays binaries location if you prefer to install or download it yourself.
.PARAMETER NoPath - TODO
    By default this script will set environment variable PATH for the current process to the binaries folder inside installation folder.
    If set it will display binaries location but not set any environment variable.
.PARAMETER Verbose - TODO
    Displays diagnostics information.
.PARAMETER AzureFeed
    Default: https://dotnetcli.azureedge.net/dotnet
    This parameter typically is not changed by the user.
    It allows changing the URL for the Azure feed used by this installer.
.PARAMETER UncachedFeed - TODO
    This parameter typically is not changed by the user.
    It allows changing the URL for the Uncached feed used by this installer.
.PARAMETER FeedCredential - TODO
    Used as a query string to append to the Azure feed.
    It allows changing the URL to use non-public blob storage accounts.
.PARAMETER ProxyAddress - TODO
    If set, the installer will use the proxy when making web requests
.PARAMETER ProxyUseDefaultCredentials - TODO
    Default: false
    Use default credentials, when using proxy address.
.PARAMETER SkipNonVersionedFiles - TODO
    Default: false
    Skips installing non-versioned files if they already exist, such as dotnet.exe.
.PARAMETER NoCdn - TODO
    Disable downloading from the Azure CDN, and use the uncached feed directly.
.PARAMETER JSonFile - TODO
    Determines the SDK version from a user specified global.json file
    Note: global.json must have a value for 'SDK:Version'
#>
[CmdletBinding()]
param (
    [string]$Version = "Latest",
    [ValidateSet("x86", "amd64", "arm32", "arm", "arm64", IgnoreCase = $false)]
    [string]$Architecture = "<auto>",
    [ValidateSet(
        "windows",
        "win",
        "windows_nt",
        #"linux",
        "macos",
        IgnoreCase = $false
    )]
    [string]$Os = "<auto>",
    [switch]$DryRun,
    [string]$ProxyAddress,
    [switch]$ProxyUseDefaultCredentials
)

# Configuration and Variables =================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$GithubFeed = "https://github.com/PowerShell/PowerShell"

# End Config and Variables ====================================================

# Helpers =====================================================================

function Say([string]$header = "PowerShell-install:", $str) {
    Write-Host "$header $str"
}

function Say-Verbose([string]$header = "PowerShell-install:", $str) {
    Write-Verbose "$header $str"
}

function Say-Invocation($Invocation) {
    $command = $Invocation.MyCommand;
    $args = (($Invocation.BoundParameters.Keys |
            foreach { "-$_ `"$($Invocation.BoundParameters[$_])`"" }) -join " ")
    Say-Verbose "$command $args"
}

function Invoke-With-Retry(
    [ScriptBlock]$ScriptBlock,
    [int]$MaxAttempts = 3,
    [int]$SecondsBetweenAttempts = 1
    ) {
    $Attempts = 0

    while ($true) {
        try {
            return $ScriptBlock.Invoke()
        } catch {
            $Attempts++
            if ($Attempts -lt $MaxAttempts) {
                Start-Sleep $SecondsBetweenAttempts
            } else {
                throw
            }
        }
    }
}

function Load-Assembly([string] $Assembly) {
    try {
        Add-Type -Assembly $Assembly | Out-Null
    } catch {
        # On Nano Server, Powershell Core Edition is used.  Add-Type is unable
        # to resolve base class assemblies because they are not GAC'd.
        # Loading the base class assemblies is not unnecessary as the types
        # will automatically get resolved.
    }
}

function Get-Machine-Architecture() {
    Say-Invocation $MyInvocation

    # On PS x86, PROCESSOR_ARCHITECTURE reports x86 even on x64 systems.
    # To get the correct architecture, we need to use PROCESSOR_ARCHITEW6432.
    # PS x64 doesn't define this, so we fall back to PROCESSOR_ARCHITECTURE.
    # Possible values: amd64, x64, x86, arm64, arm

    if ( $ENV:PROCESSOR_ARCHITEW6432 -ne $null ) {
        return $ENV:PROCESSOR_ARCHITEW6432
    }

    return $ENV:PROCESSOR_ARCHITECTURE
}

function Get-CLIArchitecture-From-Architecture([string]$Architecture) {
    Say-Invocation $MyInvocation

    switch ($Architecture.ToLower()) {
        { $_ -eq "<auto>" } { return Get-CLIArchitecture-From-Architecture $(Get-Machine-Architecture) }
        { ($_ -eq "amd64") -or ($_ -eq "x64") } { return "x64" }
        { $_ -eq "x86" } { return "x86" }
        { ($_ -eq "arm") -or ($_ -eq "arm32") } { return "arm" }
        { $_ -eq "arm64" } { return "arm64" }
        default {
            throw "Architecture not supported. If you think this is a bug, report it at https://github.com/dotnet/sdk/issues"
        }
    }
}

function Get-LinuxOs {
    # TODO
    return "Debian".ToLower()
}

function Get-CLIOs-From-Os([string]$Os) {
    Say-Invocation $MyInvocation

    switch ($Os.ToLower()) {
        { $_ -eq "<auto>" } { return Get-CLIOs-From-Os $ENV:OS }
        #{ $_ -eq "linux" } { return Get-LinuxOs }
        { ($_ -eq "windows") -or ($_ -eq "windows_nt") } { return "win" }
        { ($_ -eq "osx") -or ($_ -eq "macos") } { return "osx" }
        Default { throw "Architecture not supported." }
    }
}

function GetHTTPResponse([Uri] $Uri) {
    Invoke-With-Retry(
        {

            $HttpClient = $null

            try {
                # HttpClient is used vs Invoke-WebRequest in order to support Nano Server which doesn't support the Invoke-WebRequest cmdlet.
                Load-Assembly -Assembly System.Net.Http

                if (-not $ProxyAddress) {
                    try {
                        # Despite no proxy being explicitly specified, we may still be behind a default proxy
                        $DefaultProxy = [System.Net.WebRequest]::DefaultWebProxy;
                        if ($DefaultProxy -and (-not $DefaultProxy.IsBypassed($Uri))) {
                            $ProxyAddress = $DefaultProxy.GetProxy($Uri).OriginalString
                            $ProxyUseDefaultCredentials = $true
                        }
                    } catch {
                        # Eat the exception and move forward as the above code is an attempt
                        #    at resolving the DefaultProxy that may not have been a problem.
                        $ProxyAddress = $null
                        Say-Verbose("Exception ignored: $_.Exception.Message - moving forward...")
                    }
                }

                if ($ProxyAddress) {
                    $HttpClientHandler = New-Object System.Net.Http.HttpClientHandler
                    $HttpClientHandler.Proxy = New-Object System.Net.WebProxy -Property @{Address = $ProxyAddress; UseDefaultCredentials = $ProxyUseDefaultCredentials }
                    $HttpClient = New-Object System.Net.Http.HttpClient -ArgumentList $HttpClientHandler
                } else {

                    $HttpClient = New-Object System.Net.Http.HttpClient
                }
                # Default timeout for HttpClient is 100s.  For a 50 MB download this assumes 500 KB/s average, any less will time out
                # 20 minutes allows it to work over much slower connections.
                $HttpClient.Timeout = New-TimeSpan -Minutes 20
                $Response = $HttpClient.GetAsync("${Uri}").Result
                if (($Response -eq $null) -or (-not ($Response.IsSuccessStatusCode))) {
                    # The feed credential is potentially sensitive info. Do not log FeedCredential to console output.
                    $ErrorMsg = "Failed to download $Uri."
                    if ($Response -ne $null) {
                        $ErrorMsg += "  $Response"
                    }

                    throw $ErrorMsg
                }

                return $Response
            } finally {
                if ($HttpClient -ne $null) {
                    $HttpClient.Dispose()
                }
            }
        }
    )
}

function Get-Download-Link(
    [string]$Version,
    [string]$CLIOs,
    [string]$CLIArchitecture
) {
    Say-Invocation $MyInvocation

    if ($Version.ToLower() -eq "latest") {
        $base_uri = (GetHTTPResponse "${GithubFeed}/releases/latest").RequestMessage.RequestUri.OriginalString
        $Version = ($base_uri -split "/" | Select-Object -Last 1).Replace("v", "")
    } else {
        $base_uri = (GetHTTPResponse "${GithubFeed}/releases/tag/v${Version}").RequestMessage.RequestUri.OriginalString
    }
    $base_uri = $base_uri.Replace("tag", "download") + "/PowerShell-${Version}-${CLIOs}-${CLIArchitecture}"
    switch ($CLIOs.ToLower()) {
        { $_ -eq "win" } { return "${base_uri}.msi" }
        { $_ -eq "osx" } { return "${base_uri}.pkg" }
        # TODO Linux
        Default {
            # TODO
        }
    }
}

function DownloadFile($Source, [string]$OutPath) {
    if ($Source -notlike "http*") {
        #  Using System.IO.Path.GetFullPath to get the current directory
        #    does not work in this context - $pwd gives the current directory
        if (![System.IO.Path]::IsPathRooted($Source)) {
            $Source = $(Join-Path -Path $pwd -ChildPath $Source)
        }
        $Source = Get-Absolute-Path $Source
        Say "Copying file from $Source to $OutPath"
        Copy-Item $Source $OutPath
        return
    }

    $Stream = $null

    try {
        $Response = GetHTTPResponse -Uri $Source
        $Stream = $Response.Content.ReadAsStreamAsync().Result
        $File = [System.IO.File]::Create($OutPath)
        $Stream.CopyTo($File)
        $File.Close()
    } finally {
        if ($Stream -ne $null) {
            $Stream.Dispose()
        }
    }
}

function Is-PowerShell-Installed([string]$Version) {
    Say-Invocation $MyInvocation
    if ($PSVersionTable.PSVersion -ge $Version) {
        Say "Powershell is already updated !"
        exit 0
    }
    return $true
}

function Install-PowerShell ([string]$File, [string]$CLIOs) {
    Say-Invocation $MyInvocation

    if ( $CLIOs -eq "win") {
        msiexec.exe /package $File /quiet ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0 ENABLE_PSREMOTING=0 REGISTER_MANIFEST=1
    }
}
# End Helpers =================================================================

# Main Section ================================================================

$CLIArchitecture = Get-CLIArchitecture-From-Architecture $Architecture
$CLIOs = Get-CLIOs-From-Os $Os
$DownloadLink = Get-Download-Link $Version $CLIOs $CLIArchitecture
$ScriptName = $MyInvocation.MyCommand.Name

if ($DryRun) {
    Say "Payload URLs:"
    Say "Primary named payload URL: $DownloadLink"
    $RepeatableCommand = ".\$ScriptName -Version $Version -Os $CLIOs -Architecture $CLIArchitecture"
    foreach ($key in $MyInvocation.BoundParameters.Keys) {
        if (-not (@("Architecture", "Version", "DryRun", "Os", "Architecture") -contains $key)) {
            $RepeatableCommand += " -$key `"$($MyInvocation.BoundParameters[$key])`""
        }
    }
    Say "Repeatable invocation: $RepeatableCommand"
    exit 0
}

$installDrive = $((Get-Item $env:ProgramFiles).PSDrive.Name);
$diskInfo = Get-PSDrive -Name $installDrive
if ($diskInfo.Free / 1MB -le 400) {
    Say "There is not enough disk space on drive ${installDrive}:"
    exit 0
}

# Is-PowerShell-Installed $Version

$FileInstaller = ($DownloadLink -split "/" | Select-Object -Last 1)
Say-Verbose "FileInstaller: $FileInstaller"
$FileInstallerPath = "$env:TEMP\$FileInstaller"
Say-Verbose "FileInstallerPath: $FileInstallerPath"

$DownloadFailed = $false
Say "Downloading link: $DownloadLink"
try {
    DownloadFile -Source $DownloadLink -OutPath $FileInstallerPath
}
catch {
    Say "Cannot download: $DownloadLink"
    $DownloadFailed = $true
}

if ($DownloadFailed) {
    throw "Could not find/download: `"$DownloadLink`" with version = $Version`nRefer to: https://github.com/PowerShell/PowerShell/releases for information on PowerShell support"
}

Say "Installation: $FileInstaller"
Install-PowerShell $FileInstallerPath $CLIOs

Remove-Item $FileInstallerPath

Say "Installation finished"
exit 0