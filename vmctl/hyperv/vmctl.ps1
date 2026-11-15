<#
.SYNOPSIS
HAW's Hyper-V back end: it answers one request of the vmctl protocol, version 1.

.DESCRIPTION
sshd runs this file as the forced command of the vmctl account (install.ps1 sets
that up). It reads ONE line of JSON from standard input (at most 64 KB), checks
it completely, does the verb, and writes ONE line of JSON to standard output.
Its logs go to standard error only. The exit code is 0 when it wrote a reply,
also for "ok": false. docs/protocol.md in this repo is the protocol.

The host's own limits are in C:\ProgramData\haw\vmctl.json (namePattern,
protected, ceilings, console). Only administrators can change that file; no
request can name another file. When it is missing or wrong, "info" still
answers (with configProblem) and every other verb answers "config".

Verbs: info, list, show, start, stop, restart, console-info. The protocol's
create, delete, snapshot, restore and users answer "not-in-this-version".

A VM name from a request is never run as code. It is compared with the names
that Get-VM gives, and only the VM objects that Get-VM gave go to Start-VM,
Stop-VM and Restart-VM. Names with wildcard characters are refused first.

It runs on Windows PowerShell 5.1 (the forced command is powershell.exe) and on
PowerShell 7 (the tests).
#>
[CmdletBinding()]
param(
    # For the tests only. sshd's forced command runs this file without
    # parameters, so on a host the config is always the one under ProgramData.
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ fixed values
$script:VmctlVersion = '1.0.0'
$script:ProtocolVersions = @(1)
$script:Verbs = @('info', 'list', 'show', 'start', 'stop', 'restart', 'console-info')
$script:LaterVerbs = @('create', 'delete', 'snapshot', 'restore', 'users')
$script:RequestFields = @('haw', 'v', 'id', 'verb', 'args')
# The arguments of each verb: name -> type ('name' or 'bool') and whether it must be there.
$script:VerbArgs = @{
    'info'         = @{}
    'list'         = @{}
    'show'         = @{ 'name' = @{ Type = 'name'; Required = $true } }
    'start'        = @{ 'name' = @{ Type = 'name'; Required = $true } }
    'stop'         = @{ 'name' = @{ Type = 'name'; Required = $true }; 'force' = @{ Type = 'bool'; Required = $false } }
    'restart'      = @{ 'name' = @{ Type = 'name'; Required = $true }; 'force' = @{ Type = 'bool'; Required = $false } }
    'console-info' = @{ 'name' = @{ Type = 'name'; Required = $true } }
}
$script:ConfigFields = @('namePattern', 'protected', 'ceilings', 'console')
$script:CeilingFields = @('cpus', 'memoryMB', 'diskGB')
$script:ConsoleFields = @('host', 'port')
$script:DefaultNamePattern = '^[a-z][a-z0-9-]{0,62}$'
$script:DefaultConsolePort = 2179
$script:MaxRequestBytes = 65536
$script:MaxReplyBytes = 1048576
$script:MaxNameLength = 100
# HAW gives up after 120 seconds: a guest that takes longer to shut down is left
# shutting down, and the reply says what state the VM is in.
$script:StopWaitSeconds = 90
$script:RestartStopWaitSeconds = 75
# States in which a VM holds CPUs and memory (for the ceilings).
$script:LoadStates = @('running', 'paused', 'starting', 'stopping')

# ------------------------------------------------------------------ errors and logs
# A refusal with a protocol error code. Thrown, then turned into the reply.
function Stop-Vmctl {
    param([string]$Code, [string]$Message, [object[]]$Versions = $null)
    $e = New-Object System.Exception $Message
    $e.Data['vmctlCode'] = $Code
    if ($null -ne $Versions) { $e.Data['vmctlVersions'] = [int[]]$Versions }
    throw $e
}

# Logs go to standard error only: standard output carries the reply and nothing else.
function Write-VmctlLog {
    param([string]$Text)
    try { [Console]::Error.WriteLine('vmctl: ' + $Text) } catch { $null = $_ }
}

# One line, at most 500 characters, no stack trace.
function Format-VmctlMessage {
    param([string]$Text)
    if (-not $Text) { return 'no message' }
    $t = ($Text -replace '[\r\n\t]+', ' ').Trim()
    if ($t.Length -gt 500) { $t = $t.Substring(0, 500) }
    return $t
}

# The code, message and versions of an error record (a Stop-Vmctl refusal, or any
# other failure, which becomes "backend").
function Get-VmctlErrorInfo {
    param($ErrorRecord)
    $ex = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ex = $ErrorRecord.Exception }
    $walk = $ex
    while ($null -ne $walk) {
        if ($walk.Data -and $walk.Data.Contains('vmctlCode')) {
            $versions = $null
            if ($walk.Data.Contains('vmctlVersions')) { $versions = $walk.Data['vmctlVersions'] }
            return [pscustomobject]@{ Code = [string]$walk.Data['vmctlCode']; Message = (Format-VmctlMessage $walk.Message); Versions = $versions }
        }
        $walk = $walk.InnerException
    }
    $msg = 'the hypervisor failed'
    if ($null -ne $ex -and $ex.Message) { $msg = $ex.Message }
    return [pscustomobject]@{ Code = 'backend'; Message = (Format-VmctlMessage $msg); Versions = $null }
}

# ------------------------------------------------------------------ JSON
# Members of an object from ConvertFrom-Json, by exact name (PowerShell's own
# lookup ignores case). Returns an ordered list of @{ Name; Value }.
function Get-JsonMembers {
    param($Object)
    $out = @()
    foreach ($p in $Object.PSObject.Properties) {
        foreach ($o in $out) {
            if ($o.Name -eq $p.Name) { Stop-Vmctl 'bad-request' ('the field "' + $p.Name + '" is there twice') }
        }
        $out += , ([pscustomobject]@{ Name = [string]$p.Name; Value = $p.Value })
    }
    return $out
}

function Find-JsonMember {
    param([object[]]$Members, [string]$Name)
    foreach ($m in $Members) { if ($m.Name -ceq $Name) { return $m } }
    return $null
}

function Test-JsonObject {
    param($Value)
    return ($null -ne $Value -and $Value -is [System.Management.Automation.PSCustomObject])
}

function Test-JsonInteger {
    param($Value)
    return ($Value -is [int] -or $Value -is [long])
}

function Test-JsonNumber {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
}

function ConvertFrom-VmctlJsonText {
    param([string]$Text)
    try { return , (ConvertFrom-Json -InputObject $Text) }
    catch { Stop-Vmctl 'bad-request' 'the request is not JSON' }
}

# One compressed line. -InputObject keeps a list a list (the pipeline would unroll it).
function ConvertTo-VmctlJson {
    param($Reply)
    return (ConvertTo-Json -InputObject $Reply -Compress -Depth 10)
}

# ------------------------------------------------------------------ input and output
# Reads up to the first newline, at most $Max bytes. Returns Text, or Problem when
# the request can't be read. It stops at the newline, so a client that keeps its
# end open is answered.
function Read-RequestLine {
    param([System.IO.Stream]$Stream, [int]$Max = $script:MaxRequestBytes)
    $buf = New-Object byte[] 4096
    $mem = New-Object System.IO.MemoryStream
    $tooLong = $false
    while ($true) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $nl = [Array]::IndexOf($buf, [byte]10, 0, $n)
        if ($nl -ge 0) { $mem.Write($buf, 0, $nl); break }
        $mem.Write($buf, 0, $n)
        if ($mem.Length -gt $Max) { $tooLong = $true; break }
    }
    if ($tooLong -or $mem.Length -gt $Max) { return [pscustomobject]@{ Text = $null; Problem = 'the request is longer than 64 KB' } }
    $bytes = $mem.ToArray()
    try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
    catch { return [pscustomobject]@{ Text = $null; Problem = 'the request is not UTF-8' } }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text.TrimEnd([char]13)
    if ($text.Trim().Length -eq 0) { return [pscustomobject]@{ Text = $null; Problem = 'the request is empty' } }
    return [pscustomobject]@{ Text = $text; Problem = $null }
}

# The reply as UTF-8 bytes without a byte order mark, then a newline.
function Write-ReplyLine {
    param([string]$Json, [System.IO.Stream]$Stream = $null)
    if ($null -eq $Stream) { $Stream = [Console]::OpenStandardOutput() }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Json + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

# ------------------------------------------------------------------ the request
# Returns the id when it is a valid one (so the reply can echo it), else $null.
function Get-RequestId {
    param([object[]]$Members)
    $m = Find-JsonMember $Members 'id'
    if ($null -ne $m -and $m.Value -is [string] -and $m.Value -cmatch '^[A-Za-z0-9-]{1,64}\z') { return [string]$m.Value }
    return $null
}

# A VM name from a request: a string, 1 to 100 characters, no control
# characters, and none of the wildcard characters of Get-VM -Name and -like.
function Test-VmNameArgument {
    param($Value)
    if ($Value -isnot [string]) { Stop-Vmctl 'bad-request' 'name must be a string' }
    if ($Value.Length -lt 1 -or $Value.Length -gt $script:MaxNameLength) { Stop-Vmctl 'bad-request' ('name must be 1 to ' + $script:MaxNameLength + ' characters') }
    if ($Value -match '[\[\]\*\?`]') { Stop-Vmctl 'bad-request' 'name must not hold the characters [ ] * ? or `' }
    if ($Value -match '\p{C}') { Stop-Vmctl 'bad-request' 'name must not hold control characters' }
    return [string]$Value
}

# Checks the whole request. Returns @{ Verb; Arguments (hashtable) } or throws a refusal.
function Test-VmctlRequest {
    param($Request)
    if (-not (Test-JsonObject $Request)) { Stop-Vmctl 'bad-request' 'the request must be a JSON object' }
    $members = @(Get-JsonMembers $Request)

    $haw = Find-JsonMember $members 'haw'
    if ($null -eq $haw -or $haw.Value -isnot [string] -or $haw.Value -cne 'vmctl') { Stop-Vmctl 'bad-request' 'haw must be "vmctl"' }
    if ($null -eq (Get-RequestId $members)) { Stop-Vmctl 'bad-request' 'id must be a string of 1 to 64 letters, digits or -' }

    $v = Find-JsonMember $members 'v'
    if ($null -eq $v -or -not (Test-JsonInteger $v.Value)) { Stop-Vmctl 'bad-request' 'v must be an integer' }
    if ($script:ProtocolVersions -notcontains [long]$v.Value) {
        Stop-Vmctl 'version' ('this back end does not speak version ' + $v.Value) $script:ProtocolVersions
    }

    foreach ($m in $members) {
        if ($script:RequestFields -cnotcontains $m.Name) { Stop-Vmctl 'bad-request' ('unknown field "' + $m.Name + '"') }
    }

    $verb = Find-JsonMember $members 'verb'
    if ($null -eq $verb -or $verb.Value -isnot [string]) { Stop-Vmctl 'bad-request' 'verb must be a string' }
    $a = Find-JsonMember $members 'args'
    if ($null -eq $a -or -not (Test-JsonObject $a.Value)) { Stop-Vmctl 'bad-request' 'args must be an object' }
    $verbName = [string]$verb.Value

    if ($script:LaterVerbs -ccontains $verbName) {
        Stop-Vmctl 'not-in-this-version' ($verbName + ' is not in version ' + $script:VmctlVersion + ' of the Hyper-V back end')
    }
    if ($script:Verbs -cnotcontains $verbName) { Stop-Vmctl 'unknown-verb' ('"' + $verbName + '" is not a verb of the vmctl protocol') }

    $spec = $script:VerbArgs[$verbName]
    $arguments = @{}
    foreach ($m in @(Get-JsonMembers $a.Value)) {
        if (-not ($spec.Keys -ccontains $m.Name)) { Stop-Vmctl 'bad-request' ('unknown argument "' + $m.Name + '" for ' + $verbName) }
        $type = $spec[$m.Name].Type
        if ($type -eq 'name') { $arguments[$m.Name] = Test-VmNameArgument $m.Value }
        elseif ($type -eq 'bool') {
            if ($m.Value -isnot [bool]) { Stop-Vmctl 'bad-request' ($m.Name + ' must be true or false') }
            $arguments[$m.Name] = [bool]$m.Value
        }
    }
    foreach ($k in $spec.Keys) {
        if ($spec[$k].Required -and -not $arguments.ContainsKey($k)) { Stop-Vmctl 'bad-request' ($verbName + ' needs the argument "' + $k + '"') }
    }
    return [pscustomobject]@{ Verb = $verbName; Arguments = $arguments }
}

# ------------------------------------------------------------------ the host config
function Get-DefaultConfigPath {
    if (-not $env:ProgramData) { return $null }
    return (Join-Path $env:ProgramData 'haw\vmctl.json')
}

function New-ConfigRegex {
    param([string]$Pattern)
    return New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::None, [TimeSpan]::FromSeconds(1))
}

# Reads and checks the config. Never throws: a missing or wrong file gives
# Problem (a message) and the defaults for the rest.
function Get-VmctlConfig {
    param([string]$Path)
    $cfg = [pscustomobject]@{
        Problem     = $null
        NamePattern = $script:DefaultNamePattern
        Regex       = (New-ConfigRegex $script:DefaultNamePattern)
        Protected   = @()
        Cpus        = $null
        MemoryMB    = $null
        DiskGB      = $null
        ConsoleHost = [Environment]::MachineName
        ConsolePort = $script:DefaultConsolePort
    }
    try {
        if (-not $Path) { $Path = Get-DefaultConfigPath }
        if (-not $Path) { throw 'ProgramData is not set, so there is no config path' }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('the config file ' + $Path + ' is missing') }
        $text = [IO.File]::ReadAllText($Path)
        try { $obj = ConvertFrom-Json -InputObject $text } catch { throw ('the config file ' + $Path + ' is not JSON') }
        if (-not (Test-JsonObject $obj)) { throw 'the config file must hold a JSON object' }
        $members = @(Get-JsonMembers $obj)
        foreach ($m in $members) {
            if ($script:ConfigFields -cnotcontains $m.Name) { throw ('unknown field "' + $m.Name + '" in the config file') }
        }

        $np = Find-JsonMember $members 'namePattern'
        if ($null -ne $np) {
            if ($np.Value -isnot [string] -or $np.Value.Length -eq 0) { throw 'namePattern must be a non-empty string' }
            try { $cfg.Regex = New-ConfigRegex $np.Value } catch { $why = $_.Exception; if ($why.InnerException) { $why = $why.InnerException }; throw ('namePattern is not a valid regular expression: ' + $why.Message) }
            $cfg.NamePattern = [string]$np.Value
        }

        $pr = Find-JsonMember $members 'protected'
        if ($null -ne $pr) {
            if ($pr.Value -isnot [array]) { throw 'protected must be a list of strings' }
            $list = @()
            foreach ($p in $pr.Value) {
                if ($p -isnot [string] -or $p.Length -eq 0) { throw 'protected must be a list of non-empty strings' }
                $list += [string]$p
            }
            $cfg.Protected = $list
        }

        $ce = Find-JsonMember $members 'ceilings'
        if ($null -ne $ce) {
            if (-not (Test-JsonObject $ce.Value)) { throw 'ceilings must be an object' }
            foreach ($m in @(Get-JsonMembers $ce.Value)) {
                if ($script:CeilingFields -cnotcontains $m.Name) { throw ('unknown field "' + $m.Name + '" in ceilings') }
                if (-not (Test-JsonNumber $m.Value) -or [double]$m.Value -le 0) { throw ('ceilings.' + $m.Name + ' must be a number above 0') }
                if ($m.Name -ceq 'cpus') { $cfg.Cpus = $m.Value }
                elseif ($m.Name -ceq 'memoryMB') { $cfg.MemoryMB = $m.Value }
                else { $cfg.DiskGB = $m.Value }
            }
        }

        $co = Find-JsonMember $members 'console'
        if ($null -ne $co) {
            if (-not (Test-JsonObject $co.Value)) { throw 'console must be an object' }
            foreach ($m in @(Get-JsonMembers $co.Value)) {
                if ($script:ConsoleFields -cnotcontains $m.Name) { throw ('unknown field "' + $m.Name + '" in console') }
                if ($m.Name -ceq 'host') {
                    if ($m.Value -isnot [string] -or $m.Value -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})\z') { throw 'console.host must be a host name' }
                    $cfg.ConsoleHost = [string]$m.Value
                } else {
                    if (-not (Test-JsonInteger $m.Value) -or $m.Value -lt 1 -or $m.Value -gt 65535) { throw 'console.port must be an integer from 1 to 65535' }
                    $cfg.ConsolePort = [int]$m.Value
                }
            }
        }
    } catch {
        $cfg.Problem = Format-VmctlMessage $_.Exception.Message
    }
    return $cfg
}

# ------------------------------------------------------------------ guard rails
function Test-NameAllowed {
    param([string]$Name, $Config)
    try { return $Config.Regex.IsMatch($Name) } catch { return $false }
}

# Protect entries: * and ? only, without case. [ ] and ` are taken as they are.
function Test-NameProtected {
    param([string]$Name, [string[]]$Patterns)
    foreach ($p in @($Patterns)) {
        if (-not $p) { continue }
        $esc = $p.Replace('`', '``').Replace('[', '`[').Replace(']', '`]')
        if ($Name -like $esc) { return $true }
    }
    return $false
}

function Assert-NameAllowed {
    param([string]$Name, $Config)
    if (-not (Test-NameAllowed $Name $Config)) {
        Stop-Vmctl 'name-not-allowed' ($Name + ' does not match this host''s allow pattern')
    }
}

function Assert-NotProtected {
    param([string]$Name, $Config)
    if (Test-NameProtected $Name $Config.Protected) {
        Stop-Vmctl 'protected' ($Name + ' is on this host''s protect list')
    }
}

# ------------------------------------------------------------------ Hyper-V
function ConvertTo-VmState {
    param($State)
    switch ([string]$State) {
        'Running' { return 'running' }
        'Off' { return 'off' }
        'Paused' { return 'paused' }
        'Saved' { return 'saved' }
        'Starting' { return 'starting' }
        'Stopping' { return 'stopping' }
        default { return 'other' }
    }
}

function Get-AllVms {
    Get-VM -ErrorAction Stop
}

# The one VM with exactly this name (case and all). Get-VM is called without
# -Name, so the request's text is never a pattern.
function Find-Vm {
    param([string]$Name)
    $found = @()
    foreach ($vm in @(Get-AllVms)) { if ([string]$vm.Name -ceq $Name) { $found += $vm } }
    if ($found.Count -eq 0) { Stop-Vmctl 'not-found' ('no VM is named ' + $Name) }
    if ($found.Count -gt 1) { Stop-Vmctl 'backend' ('more than one VM is named ' + $Name + '; give them different names') }
    return $found[0]
}

function ConvertTo-MB {
    param($Bytes)
    if ($null -eq $Bytes) { return [int64]0 }
    return [int64][math]::Floor([double]$Bytes / 1MB)
}

function ConvertTo-GB {
    param($Bytes)
    if ($null -eq $Bytes) { return $null }
    return [double][math]::Round([double]$Bytes / 1GB, 1)
}

function Get-VmMemoryMB {
    param($Vm)
    if ((ConvertTo-VmState $Vm.State) -eq 'running' -and [double]$Vm.MemoryAssigned -gt 0) { return (ConvertTo-MB $Vm.MemoryAssigned) }
    return (ConvertTo-MB $Vm.MemoryStartup)
}

function Get-VmAdapters {
    param($Vm)
    try { return @(Get-VMNetworkAdapter -VM $Vm -ErrorAction Stop) }
    catch { Write-VmctlLog ('no network adapters for ' + $Vm.Name + ': ' + (Format-VmctlMessage $_.Exception.Message)); return @() }
}

# Addresses without IPv6 link-local ones (fe80::/10), each once.
function Get-AdapterAddresses {
    param([object[]]$Adapters)
    $out = @()
    foreach ($a in @($Adapters)) {
        foreach ($ip in @($a.IPAddresses)) {
            if ($null -eq $ip) { continue }
            $s = ([string]$ip).Trim()
            if (-not $s -or $s -match '^fe[89ab][0-9a-f]:') { continue }
            if ($out -notcontains $s) { $out += $s }
        }
    }
    return $out
}

function Format-Mac {
    param($Mac)
    $m = ([string]$Mac) -replace '[^0-9A-Fa-f]', ''
    if ($m.Length -ne 12) { return ([string]$Mac).ToLowerInvariant() }
    $parts = @()
    for ($i = 0; $i -lt 12; $i += 2) { $parts += $m.Substring($i, 2) }
    return ($parts -join ':').ToLowerInvariant()
}

# A VM as the protocol gives it.
function ConvertTo-VmInfo {
    param($Vm, $Config, [object[]]$Adapters = $null)
    if ($null -eq $Adapters) { $Adapters = @(Get-VmAdapters $Vm) }
    $uptime = [int64]0
    if ($null -ne $Vm.Uptime) { $uptime = [int64][math]::Floor([double]$Vm.Uptime.TotalSeconds) }
    $name = [string]$Vm.Name
    return [ordered]@{
        name          = $name
        id            = ([string]$Vm.Id).ToLowerInvariant()
        state         = (ConvertTo-VmState $Vm.State)
        cpus          = [int]$Vm.ProcessorCount
        memoryMB      = (Get-VmMemoryMB $Vm)
        uptimeSeconds = $uptime
        addresses     = @(Get-AdapterAddresses $Adapters)
        allowed       = [bool](Test-NameAllowed $name $Config)
        protected     = [bool](Test-NameProtected $name $Config.Protected)
    }
}

function Get-VmDisks {
    param($Vm)
    $out = @()
    foreach ($d in @(Get-VMHardDiskDrive -VM $Vm -ErrorAction Stop)) {
        $size = $null
        $used = $null
        if ($d.Path) {
            try {
                $vhd = Get-VHD -Path ([string]$d.Path) -ErrorAction Stop
                $size = ConvertTo-GB $vhd.Size
                $used = ConvertTo-GB $vhd.FileSize
            } catch { Write-VmctlLog ('Get-VHD failed for a disk of ' + $Vm.Name + ': ' + (Format-VmctlMessage $_.Exception.Message)) }
        }
        $out += , ([ordered]@{ sizeGB = $size; usedGB = $used })
    }
    return $out
}

function Get-VmNetworks {
    param([object[]]$Adapters)
    $out = @()
    foreach ($a in @($Adapters)) {
        $sw = ''
        if ($a.SwitchName) { $sw = [string]$a.SwitchName }
        $out += , ([ordered]@{ switch = $sw; mac = (Format-Mac $a.MacAddress); addresses = @(Get-AdapterAddresses @($a)) })
    }
    return $out
}

# The CPUs and memory that VMs other than $Vm hold now, plus what $Vm takes at start.
function Assert-Ceiling {
    param($Vm, $Config)
    if ($null -eq $Config.Cpus -and $null -eq $Config.MemoryMB) { return }
    $cpus = [double]$Vm.ProcessorCount
    $mem = [double](ConvertTo-MB $Vm.MemoryStartup)
    foreach ($o in @(Get-AllVms)) {
        if ([string]$o.Id -eq [string]$Vm.Id) { continue }
        if ($script:LoadStates -notcontains (ConvertTo-VmState $o.State)) { continue }
        $cpus += [double]$o.ProcessorCount
        $m = ConvertTo-MB $o.MemoryAssigned
        if ($m -le 0) { $m = ConvertTo-MB $o.MemoryStartup }
        $mem += [double]$m
    }
    if ($null -ne $Config.Cpus -and $cpus -gt [double]$Config.Cpus) {
        Stop-Vmctl 'ceiling' ('starting ' + $Vm.Name + ' would give running VMs ' + $cpus + ' CPUs; this host''s ceiling is ' + $Config.Cpus)
    }
    if ($null -ne $Config.MemoryMB -and $mem -gt [double]$Config.MemoryMB) {
        Stop-Vmctl 'ceiling' ('starting ' + $Vm.Name + ' would give running VMs ' + $mem + ' MB of memory; this host''s ceiling is ' + $Config.MemoryMB + ' MB')
    }
}

# Waits for a job from Stop-VM -AsJob. Done: it ended; Error: why it failed.
function Wait-VmJob {
    param($Job, [int]$Seconds)
    $null = Wait-Job -Job $Job -Timeout $Seconds
    $state = [string]$Job.State
    if ($state -ne 'Completed' -and $state -ne 'Failed' -and $state -ne 'Stopped') {
        return [pscustomobject]@{ Done = $false; Error = $null }
    }
    $err = $null
    try { $null = Receive-Job -Job $Job -ErrorAction Stop } catch { $err = $_.Exception.Message }
    if ($state -ne 'Completed' -and -not $err) {
        $err = 'the shutdown ended as ' + $state
        try { if ($Job.ChildJobs[0].JobStateInfo.Reason) { $err = $Job.ChildJobs[0].JobStateInfo.Reason.Message } } catch { $null = $_ }
    }
    try { Remove-Job -Job $Job -Force } catch { $null = $_ }
    return [pscustomobject]@{ Done = $true; Error = $err }
}

# A guest shutdown (Stop-VM -Force asks the guest and does not prompt), waited
# for at most $Seconds.
function Invoke-GuestShutdown {
    param($Vm, [int]$Seconds)
    $job = Stop-VM -VM $Vm -Force -Confirm:$false -AsJob -ErrorAction Stop
    $w = Wait-VmJob -Job $job -Seconds $Seconds
    if ($w.Error) { Stop-Vmctl 'backend' ('the guest shutdown of ' + $Vm.Name + ' failed: ' + $w.Error) }
    return $w.Done
}

# ------------------------------------------------------------------ verbs
# Only the ceilings that are set: a missing one means no limit.
function Get-CeilingsView {
    param($Config)
    $c = [ordered]@{}
    if ($null -ne $Config.Cpus) { $c['cpus'] = $Config.Cpus }
    if ($null -ne $Config.MemoryMB) { $c['memoryMB'] = $Config.MemoryMB }
    if ($null -ne $Config.DiskGB) { $c['diskGB'] = $Config.DiskGB }
    return $c
}

function Invoke-InfoVerb {
    param($Config)
    $vmHost = Get-VMHost -ErrorAction Stop
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $disks = @()
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop)) {
        if ($null -eq $d.Free -or $null -eq $d.Used) { continue }
        $disks += , ([ordered]@{
                name   = ([string]$d.Name + ':')
                sizeGB = (ConvertTo-GB ([double]$d.Used + [double]$d.Free))
                freeGB = (ConvertTo-GB $d.Free)
            })
    }
    $networks = @()
    foreach ($s in @(Get-VMSwitch -ErrorAction Stop)) {
        $networks += , ([ordered]@{ name = [string]$s.Name; kind = ([string]$s.SwitchType).ToLowerInvariant() })
    }
    $limits = $null
    if (-not $Config.Problem) {
        $limits = [ordered]@{
            namePattern = $Config.NamePattern
            protected   = [object[]]@($Config.Protected)
            ceilings    = (Get-CeilingsView $Config)
        }
    }
    return [ordered]@{
        host          = [ordered]@{ name = [Environment]::MachineName }
        backend       = [ordered]@{ kind = 'hyper-v'; version = $script:VmctlVersion }
        protocol      = [ordered]@{ versions = [object[]]$script:ProtocolVersions }
        capacity      = [ordered]@{
            cpus         = [int]$vmHost.LogicalProcessorCount
            memoryMB     = (ConvertTo-MB $vmHost.MemoryCapacity)
            freeMemoryMB = [int64][math]::Floor([double]$os.FreePhysicalMemory / 1024)
            disks        = [object[]]$disks
        }
        networks      = [object[]]$networks
        verbs         = [object[]]$script:Verbs
        limits        = $limits
        configProblem = $Config.Problem
    }
}

function Invoke-ListVerb {
    param($Config)
    $vms = @()
    foreach ($vm in @((Get-AllVms) | Sort-Object -Property @{ Expression = { [string]$_.Name } })) {
        $vms += , (ConvertTo-VmInfo $vm $Config)
    }
    return [ordered]@{ vms = [object[]]$vms }
}

function Invoke-ShowVerb {
    param([hashtable]$Arguments, $Config)
    $name = $Arguments['name']
    # A read, like list (which shows the VM with allowed: false): no allow check.
    $vm = Find-Vm $name
    $adapters = @(Get-VmAdapters $vm)
    $info = ConvertTo-VmInfo $vm $Config $adapters
    $info['generation'] = [int]$vm.Generation
    $info['disks'] = @(Get-VmDisks $vm)
    $info['networks'] = @(Get-VmNetworks $adapters)
    $info['checkpoints'] = [int]@(Get-VMSnapshot -VM $vm -ErrorAction Stop).Count
    $notes = ''
    if ($vm.Notes) { $notes = [string]$vm.Notes }
    $info['notes'] = $notes
    return [ordered]@{ vm = $info }
}

function Invoke-StartVerb {
    param([hashtable]$Arguments, $Config)
    $name = $Arguments['name']
    Assert-NameAllowed $name $Config
    $vm = Find-Vm $name
    $state = ConvertTo-VmState $vm.State
    if ($state -ne 'off' -and $state -ne 'saved') { Stop-Vmctl 'wrong-state' ($name + ' is ' + $state + '; start needs it off or saved') }
    Assert-Ceiling $vm $Config
    $null = Start-VM -VM $vm -Confirm:$false -ErrorAction Stop
    return [ordered]@{ vm = (ConvertTo-VmInfo (Find-Vm $name) $Config) }
}

function Invoke-StopVerb {
    param([hashtable]$Arguments, $Config)
    $name = $Arguments['name']
    $force = [bool]$Arguments['force']
    Assert-NameAllowed $name $Config
    Assert-NotProtected $name $Config
    $vm = Find-Vm $name
    $state = ConvertTo-VmState $vm.State
    if ($force) {
        if (@('running', 'paused', 'starting', 'stopping') -notcontains $state) { Stop-Vmctl 'wrong-state' ($name + ' is ' + $state + '; there is nothing to turn off') }
        $null = Stop-VM -VM $vm -TurnOff -Confirm:$false -ErrorAction Stop
    } else {
        if ($state -ne 'running') { Stop-Vmctl 'wrong-state' ($name + ' is ' + $state + '; a shutdown needs it running') }
        $done = Invoke-GuestShutdown $vm $script:StopWaitSeconds
        if (-not $done) { Write-VmctlLog ($name + ' is still shutting down after ' + $script:StopWaitSeconds + ' seconds') }
    }
    return [ordered]@{ vm = (ConvertTo-VmInfo (Find-Vm $name) $Config) }
}

function Invoke-RestartVerb {
    param([hashtable]$Arguments, $Config)
    $name = $Arguments['name']
    $force = [bool]$Arguments['force']
    Assert-NameAllowed $name $Config
    Assert-NotProtected $name $Config
    $vm = Find-Vm $name
    $state = ConvertTo-VmState $vm.State
    if ($force) {
        if (@('running', 'paused') -notcontains $state) { Stop-Vmctl 'wrong-state' ($name + ' is ' + $state + '; a reset needs it running') }
        $null = Restart-VM -VM $vm -Force -Confirm:$false -ErrorAction Stop
    } else {
        if ($state -ne 'running') { Stop-Vmctl 'wrong-state' ($name + ' is ' + $state + '; a restart needs it running') }
        $done = Invoke-GuestShutdown $vm $script:RestartStopWaitSeconds
        if (-not $done) {
            Stop-Vmctl 'backend' ($name + ' did not shut down within ' + $script:RestartStopWaitSeconds + ' seconds; it goes on shutting down, start it when it is off')
        }
        $off = Find-Vm $name
        $null = Start-VM -VM $off -Confirm:$false -ErrorAction Stop
    }
    return [ordered]@{ vm = (ConvertTo-VmInfo (Find-Vm $name) $Config) }
}

function Invoke-ConsoleInfoVerb {
    param([hashtable]$Arguments, $Config)
    $name = $Arguments['name']
    Assert-NameAllowed $name $Config
    $vm = Find-Vm $name
    return [ordered]@{
        console = [ordered]@{
            kind = 'vmconnect'
            host = $Config.ConsoleHost
            port = [int]$Config.ConsolePort
            vmId = ([string]$vm.Id).ToLowerInvariant()
        }
    }
}

# ------------------------------------------------------------------ one request
function New-VmctlReply {
    param($Id, [bool]$Ok, $Result = $null, $ErrorInfo = $null)
    $reply = [ordered]@{ haw = 'vmctl'; v = 1; id = $Id; ok = $Ok }
    if ($Ok) { $reply['result'] = $Result }
    else {
        $e = [ordered]@{ code = $ErrorInfo.Code; message = $ErrorInfo.Message }
        if ($null -ne $ErrorInfo.Versions) { $e['versions'] = [object[]]@($ErrorInfo.Versions) }
        $reply['error'] = $e
    }
    return $reply
}

# The reply (an ordered dictionary) to one request line. Never throws.
function Invoke-VmctlRequest {
    param([string]$Line, [string]$ReadProblem = $null, [string]$ConfigPath = '')
    $id = $null
    $verbName = '?'
    try {
        if ($ReadProblem) { Stop-Vmctl 'bad-request' $ReadProblem }
        $req = ConvertFrom-VmctlJsonText $Line
        if (Test-JsonObject $req) { $id = Get-RequestId @(Get-JsonMembers $req) }
        $r = Test-VmctlRequest $req
        $verbName = $r.Verb
        $config = Get-VmctlConfig -Path $ConfigPath
        if ($config.Problem -and $r.Verb -ne 'info') { Stop-Vmctl 'config' $config.Problem }
        switch ($r.Verb) {
            'info' { $result = Invoke-InfoVerb $config }
            'list' { $result = Invoke-ListVerb $config }
            'show' { $result = Invoke-ShowVerb $r.Arguments $config }
            'start' { $result = Invoke-StartVerb $r.Arguments $config }
            'stop' { $result = Invoke-StopVerb $r.Arguments $config }
            'restart' { $result = Invoke-RestartVerb $r.Arguments $config }
            'console-info' { $result = Invoke-ConsoleInfoVerb $r.Arguments $config }
        }
        Write-VmctlLog ($verbName + ': ok')
        return (New-VmctlReply -Id $id -Ok $true -Result $result)
    } catch {
        $info = Get-VmctlErrorInfo $_
        Write-VmctlLog ($verbName + ': ' + $info.Code + ': ' + $info.Message)
        return (New-VmctlReply -Id $id -Ok $false -ErrorInfo $info)
    }
}

# The reply line for a request line, at most 1 MB.
function Get-VmctlReplyJson {
    param([string]$Line, [string]$ReadProblem = $null, [string]$ConfigPath = '')
    $reply = Invoke-VmctlRequest -Line $Line -ReadProblem $ReadProblem -ConfigPath $ConfigPath
    try {
        $json = ConvertTo-VmctlJson $reply
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaxReplyBytes) { Stop-Vmctl 'backend' 'the reply would be longer than 1 MB' }
        return $json
    } catch {
        $info = Get-VmctlErrorInfo $_
        return (ConvertTo-VmctlJson (New-VmctlReply -Id $reply['id'] -Ok $false -ErrorInfo $info))
    }
}

function Invoke-VmctlMain {
    $json = '{"haw":"vmctl","v":1,"id":null,"ok":false,"error":{"code":"backend","message":"vmctl failed before it could answer"}}'
    try {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $null = $_ }
        $in = Read-RequestLine -Stream ([Console]::OpenStandardInput())
        $json = Get-VmctlReplyJson -Line $in.Text -ReadProblem $in.Problem -ConfigPath $ConfigPath
    } catch {
        Write-VmctlLog ('failed: ' + (Format-VmctlMessage $_.Exception.Message))
    }
    try { Write-ReplyLine $json } catch { exit 1 }
    exit 0
}

# Dot-sourced by the tests: define the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-VmctlMain
}
