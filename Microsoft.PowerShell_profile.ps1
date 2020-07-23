<#
 #  PowerShell Profile
 #
 #  Author  :   Didier Bröska - didier.broska@gmail.com
 #  Date    :   22/07/2020
 #
 #>

# Theming - Oh My Posh
Set-Theme Avit

# Keybindings - PS ReadLine
Set-PSReadLineKeyHandler -Key Ctrl+d -Function DeleteCharOrExit
Set-PSReadLineKeyHandler -Key Ctrl+l -Function ClearScreen
Set-PSReadLineKeyHandler -Key Ctrl+w -Function BackwardDeleteWord

# Path env
$env:Path += ";${PSScriptRoot}\Bin;$env:LOCALAPPDATA\Microsoft\dotnet"

# Aliases
Set-Alias touch New-Item
## SSH for GIT
Set-Alias ssh "$env:ProgramFiles\git\usr\bin\ssh.exe"
Set-Alias ssh-agent "$env:ProgramFiles\git\usr\bin\ssh-agent.exe"
Set-Alias ssh-add "$env:ProgramFiles\git\usr\bin\ssh-add.exe"

# DotNet completion
## PowerShell parameter completion shim for the dotnet CLI
Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
        dotnet complete --position $cursorPosition "$wordToComplete" | ForEach-Object {
           [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        }
}