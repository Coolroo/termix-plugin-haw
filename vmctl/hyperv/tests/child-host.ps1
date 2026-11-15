# Runs vmctl.ps1 as sshd would (a process of its own, the request on standard
# input), with stand-ins for the Hyper-V commands, so that the tests can check
# standard output, standard error and the exit code. Tests only.
param([string]$Script, [string]$ConfigPath)

function global:Get-VM {
    [CmdletBinding()] param([string[]]$Name)
    [Console]::Error.WriteLine('stand-in Get-VM: this line goes to standard error')
    [pscustomobject]@{
        Name = 'web-1'; Id = [guid]'8d1c3a8e-9a51-4c47-8a0d-5d0f5b3e7d10'; State = 'Running'; ProcessorCount = 2
        MemoryStartup = 4096MB; MemoryAssigned = 4096MB; Uptime = [timespan]::FromSeconds(3600); Generation = 2; Notes = ''
    }
}
function global:Get-VMNetworkAdapter {
    [CmdletBinding()] param([object[]]$VM)
    Write-Warning 'a warning from a stand-in'
    Write-Verbose 'verbose from a stand-in'
    [pscustomobject]@{ IPAddresses = @('192.0.2.10', 'fe80::1'); SwitchName = 'LAN'; MacAddress = '00155D010203' }
}

& $Script -ConfigPath $ConfigPath
exit $LASTEXITCODE
