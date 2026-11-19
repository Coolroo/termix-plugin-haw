<#
.SYNOPSIS
Set a Hyper-V host up for HAW (design B): the vmctl account, its key, the front
and the worker, the queue, the worker task, the host's limits, and sshd's forced
command. Run it once, as administrator.

.DESCRIPTION
Every run checks each part and changes only what differs, so a second run
changes nothing (the last line says "CHANGED 0"). -WhatIf prints what it would
change and changes nothing. -Uninstall removes what it made. DESIGN.md says why
the back end is a front and a worker.

  Scripts  vmctl.ps1 (the front) and vmctl-worker.ps1 (the worker) from -Source,
           only when their SHA-256 are -Sha256 and -WorkerSha256, copied to
           C:\ProgramData\haw. That folder: SYSTEM and Administrators full,
           nothing inherited; the account may only reach its parts: read and
           execute on vmctl.ps1, and the queue.
  Queue    C:\ProgramData\haw\queue: the account may create a file and write
           and read its own, and read the replies; it may not list the folder,
           make folders, delete or change permissions. DESIGN.md has the ACL.
  Config   C:\ProgramData\haw\vmctl.json from -NamePattern, -Protected, the
           ceilings and -ConsoleHost; only the worker reads it. An existing
           file is kept unless -ReplaceConfig is given.
  Account  A local account (-Account, default vmctl) with a random password
           that nobody sees (it logs in with the key only), in Users only. The
           script stops if the account is in Administrators or another group;
           it takes the account out of Hyper-V Administrators when an older
           install.ps1 put it there.
  Task     haw-vmctl-worker: runs vmctl-worker.ps1 -Job $(Arg0) as SYSTEM, in
           parallel, at most 3 minutes, no triggers. The account may read and
           run it (GRGX), nothing more.
  Key      -PublicKey (the key of the Termix host that HAW uses) in
           C:\ProgramData\ssh\haw-<account>_authorized_keys, SYSTEM and
           Administrators only.
  sshd     A marked block at the end of sshd_config: Match User <account>, its
           key file, ForceCommand vmctl.ps1, no forwarding, no TTY. The new
           sshd_config is checked with `sshd -t` first; a SYSTEM task then puts
           it in place and restarts sshd a few seconds later (outside this
           session), and puts the old file back if sshd does not run.
  Check    Last, it runs the installed front with an "info" request as this
           administrator (so the real task runs) and checks the reply.

Lines it prints: OK (already right), SET (changed), WOULD (-WhatIf), TODO (a
step for later), INFO, WARN, FAIL. It never prints a secret.

.EXAMPLE
.\install.ps1 -PublicKey 'ssh-ed25519 AAAA... termix' -Sha256 <vmctl.ps1> -WorkerSha256 <vmctl-worker.ps1> -Protected 'build-*' -CeilingCpus 16 -CeilingMemoryMB 32768 -ConsoleHost hv1.example.lan -WhatIf
.EXAMPLE
.\install.ps1 -Uninstall
#>
# The functions below read these parameters from the script scope.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'read by the functions in this file')]
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # One public key line, 'ssh-ed25519 AAAA... comment': the key of the Termix
    # host that HAW connects with.
    [string]$PublicKey = '',
    # The local account that HAW logs in as.
    [string]$Account = 'vmctl',
    # The SHA-256 of the reviewed vmctl.ps1 and vmctl-worker.ps1 (64 hex digits each). Required.
    [string]$Sha256 = '',
    [string]$WorkerSha256 = '',
    # The folder that holds vmctl.ps1 and vmctl-worker.ps1. Default: this script's folder.
    [string]$Source = '',
    # vmctl.json: the VMs HAW may act on, the protect list, the ceilings, the console name.
    [string]$NamePattern = '^[a-z][a-z0-9-]{0,62}$',
    [string[]]$Protected = @(),
    # 0: no ceiling.
    [int]$CeilingCpus = 0,
    [long]$CeilingMemoryMB = 0,
    [long]$CeilingDiskGB = 0,
    # The name that the console's certificate carries. Empty: vmctl uses the machine's name.
    [string]$ConsoleHost = '',
    [int]$ConsolePort = 2179,
    # Write vmctl.json from the parameters even when it is there.
    [switch]$ReplaceConfig,
    # Remove what this script made.
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------ fixed values
$script:SidSystem = 'S-1-5-18'
$script:SidAdministrators = 'S-1-5-32-544'
$script:SidUsers = 'S-1-5-32-545'
$script:SidHyperVAdmins = 'S-1-5-32-578'
$script:SidCreatorOwner = 'S-1-3-0'
$script:SidOwnerRights = 'S-1-3-4'
$script:AccountMarker = 'HAW vmctl account (made by install.ps1)'
$script:TaskName = 'haw-vmctl-sshd-restart'
$script:WorkerTaskName = 'haw-vmctl-worker'
$script:BeginMarker = '# HAW vmctl: begin (made by install.ps1; change the host with install.ps1)'
$script:EndMarker = '# HAW vmctl: end'
# File rights as numbers (FileSystemRights). Synchronize (0x100000) is left out of
# every comparison: Windows adds it or not.
$script:RightsSync = 0x100000
$script:RightsFull = 0x1F01FF
$script:RightsReadExecute = 0x200A9   # RD REA X RA RC
$script:RightsTraverse = 0xA0          # X RA
$script:RightsDropFile = 0xA2          # WD X RA (on a folder: add a file)
$script:RightsReadFile = 0x20089       # RD REA RA RC
$script:RightsOwnFile = 0x19F          # RD WD AD REA WEA RA WA
$script:RightsOwnerRights = 0x80       # RA

$script:Changes = 0
$script:Failed = 0
$script:PlanOnly = [bool]$WhatIfPreference
# Every printed line, also for the tests.
$script:Output = New-Object System.Collections.ArrayList

# All paths come from ProgramData; the tests point them at a temporary folder.
function Set-InstallRoot {
    param([string]$Root, [string]$AccountName)
    $script:Root = $Root
    $script:HawDir = Join-Path $Root 'haw'
    $script:SetupDir = Join-Path $script:HawDir 'setup'
    $script:QueueDir = Join-Path $script:HawDir 'queue'
    $script:VmctlDest = Join-Path $script:HawDir 'vmctl.ps1'
    $script:WorkerDest = Join-Path $script:HawDir 'vmctl-worker.ps1'
    $script:ConfigDest = Join-Path $script:HawDir 'vmctl.json'
    $script:SshDir = Join-Path $Root 'ssh'
    $script:SshdConfig = Join-Path $script:SshDir 'sshd_config'
    $script:KeysFile = Join-Path $script:SshDir ('haw-' + $AccountName + '_authorized_keys')
    $script:Candidate = Join-Path $script:SetupDir 'sshd_config.new'
    $script:Before = Join-Path $script:SetupDir 'sshd_config.before'
    $script:RestartScript = Join-Path $script:SetupDir 'sshd-restart.ps1'
    $script:RestartDone = Join-Path $script:SetupDir 'restart-done.txt'
    # The path in sshd_config's ForceCommand, with forward slashes.
    $script:VmctlForcePath = ($Root -replace '\\', '/') + '/haw/vmctl.ps1'
    # The path in the worker task's action, with backslashes.
    $script:WorkerTaskPath = ($Root -replace '/', '\') + '\haw\vmctl-worker.ps1'
}

# ------------------------------------------------------------------ output
function Write-Line {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'the report is for the console, not the pipeline')]
    param([string]$Kind, [string]$Item, [string]$Detail = '')
    if ($Detail) { $line = '{0,-5} {1}: {2}' -f $Kind, $Item, $Detail }
    else { $line = '{0,-5} {1}' -f $Kind, $Item }
    [void]$script:Output.Add($line)
    Write-Host $line
}

# Every change goes through here: in a plan (-WhatIf) it prints WOULD and runs
# nothing, else it runs $Action, counts it and prints SET.
function Invoke-Change {
    param([string]$Item, [string]$Detail, [scriptblock]$Action)
    if ($script:PlanOnly) {
        Write-Line 'WOULD' $Item $Detail
    } else {
        $null = & $Action
        $script:Changes++
        Write-Line 'SET' $Item $Detail
    }
}

# A file's SHA-256, upper-case hex. .NET, not Get-FileHash, which obeys -WhatIf in 5.1.
function Get-Sha256 {
    param([string]$Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# ------------------------------------------------------------------ pure logic
# These take plain values and return plain values; tests/install.Tests.ps1 covers them.

# One ssh-ed25519 key line: type, base64 of a 51-byte key blob, an optional comment.
# Returns the line trimmed, or throws.
function Test-PublicKeyLine {
    param([string]$Line)
    if (-not $Line) { throw '-PublicKey is required: one line, ''ssh-ed25519 AAAA... comment''' }
    $t = $Line.Trim()
    if ($t -match '[\r\n]') { throw '-PublicKey must be one line' }
    $m = [regex]::Match($t, '^ssh-ed25519 ([A-Za-z0-9+/]+={0,2})(?: +([\x21-\x7E][\x20-\x7E]*))?\z')
    if (-not $m.Success) { throw '-PublicKey must be a bare ssh-ed25519 key line, ''ssh-ed25519 AAAA... comment'', without options' }
    try { $blob = [Convert]::FromBase64String($m.Groups[1].Value) } catch { throw '-PublicKey: the key is not valid base64' }
    $want = [byte[]](0, 0, 0, 11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + [byte[]](0, 0, 0, 32)
    if ($blob.Length -ne 51) { throw '-PublicKey: the key is not an ed25519 key' }
    for ($i = 0; $i -lt $want.Length; $i++) {
        if ($blob[$i] -ne $want[$i]) { throw '-PublicKey: the key is not an ed25519 key' }
    }
    return $t
}

function Test-Sha256Text {
    param([string]$Value)
    return [bool]($Value -match '^[0-9A-Fa-f]{64}\z')
}

# Stops unless the file's SHA-256 is $Expected.
function Assert-ScriptHash {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ($Path + ' is not there') }
    $have = Get-Sha256 $Path
    if ($have -ne $Expected.ToUpperInvariant()) {
        throw ($Path + ' has SHA-256 ' + $have + ', not the expected ' + $Expected.ToUpperInvariant() + '; it is not the reviewed file, so nothing is installed')
    }
    return $have
}

# The account's groups, as SIDs: a message when they are wrong, else $null.
# Users only. Hyper-V Administrators is taken back when install.ps1 made the
# account (an older install put it there); else the script stops.
function Get-AccountGroupProblem {
    param([string]$AccountName, [string[]]$GroupSids, [bool]$MadeByInstall = $false)
    $sids = @($GroupSids | Where-Object { $_ })
    if ($sids -contains $script:SidAdministrators) {
        return ($AccountName + ' is in Administrators. HAW''s account must not be an administrator: remove it from Administrators, or give -Account another name')
    }
    if ($sids -contains $script:SidHyperVAdmins -and -not $MadeByInstall) {
        return ($AccountName + ' is in Hyper-V Administrators and install.ps1 did not make it. HAW''s account is a plain user: remove it from Hyper-V Administrators, or give -Account another name')
    }
    $other = @($sids | Where-Object { $_ -ne $script:SidUsers -and $_ -ne $script:SidHyperVAdmins })
    if ($other.Count -gt 0) {
        return ($AccountName + ' is in other groups (' + ($other -join ', ') + '). It may be in Users only: remove it from the others, or give -Account another name')
    }
    return $null
}

# -Protected through `powershell -File` arrives as one string "a,b".
function Split-ListParameter {
    param([string[]]$Values)
    return @($Values | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Checks the parameters. Returns them as one object, or throws.
function Assert-InstallParameters {
    param(
        [string]$PublicKey, [string]$Account, [string]$Sha256, [string]$WorkerSha256, [string]$NamePattern, [string[]]$Protected,
        [long]$CeilingCpus, [long]$CeilingMemoryMB, [long]$CeilingDiskGB, [string]$ConsoleHost, [int]$ConsolePort,
        [bool]$Uninstall, [bool]$ReplaceConfig
    )
    if ($Account -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}\z') { throw '-Account must be 1 to 20 letters, digits, _ or -, starting with a letter' }
    $opts = [pscustomobject]@{
        Account = $Account; PublicKey = ''; Sha256 = ''; WorkerSha256 = ''; NamePattern = $NamePattern; Protected = @()
        CeilingCpus = $CeilingCpus; CeilingMemoryMB = $CeilingMemoryMB; CeilingDiskGB = $CeilingDiskGB
        ConsoleHost = $ConsoleHost; ConsolePort = $ConsolePort; Uninstall = $Uninstall; ReplaceConfig = $ReplaceConfig
    }
    if ($Uninstall) { return $opts }
    $opts.PublicKey = Test-PublicKeyLine $PublicKey
    if (-not (Test-Sha256Text $Sha256)) { throw '-Sha256 is required: the SHA-256 of the reviewed vmctl.ps1, 64 hex digits' }
    if (-not (Test-Sha256Text $WorkerSha256)) { throw '-WorkerSha256 is required: the SHA-256 of the reviewed vmctl-worker.ps1, 64 hex digits' }
    $opts.Sha256 = $Sha256.ToUpperInvariant()
    $opts.WorkerSha256 = $WorkerSha256.ToUpperInvariant()
    if (-not $NamePattern) { throw '-NamePattern must not be empty' }
    try { $null = New-Object System.Text.RegularExpressions.Regex($NamePattern) } catch { $why = $_.Exception; if ($why.InnerException) { $why = $why.InnerException }; throw ('-NamePattern is not a valid regular expression: ' + $why.Message) }
    $opts.Protected = @(Split-ListParameter $Protected)
    foreach ($n in 'CeilingCpus', 'CeilingMemoryMB', 'CeilingDiskGB') {
        if ($opts.$n -lt 0) { throw ('-' + $n + ' must be 0 (no ceiling) or more') }
    }
    if ($ConsoleHost -and $ConsoleHost -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})\z') { throw '-ConsoleHost must be a host name' }
    if ($ConsolePort -lt 1 -or $ConsolePort -gt 65535) { throw '-ConsolePort must be from 1 to 65535' }
    return $opts
}

# vmctl.json from the parameters (docs/protocol.md, "The host's own limits").
function New-VmctlConfigText {
    param($Options)
    $cfg = [ordered]@{
        namePattern = $Options.NamePattern
        protected   = [object[]]@($Options.Protected)
    }
    $ceilings = [ordered]@{}
    if ($Options.CeilingCpus -gt 0) { $ceilings['cpus'] = [long]$Options.CeilingCpus }
    if ($Options.CeilingMemoryMB -gt 0) { $ceilings['memoryMB'] = [long]$Options.CeilingMemoryMB }
    if ($Options.CeilingDiskGB -gt 0) { $ceilings['diskGB'] = [long]$Options.CeilingDiskGB }
    if ($ceilings.Count -gt 0) { $cfg['ceilings'] = $ceilings }
    if ($Options.ConsoleHost -or $Options.ConsolePort -ne 2179) {
        $console = [ordered]@{}
        if ($Options.ConsoleHost) { $console['host'] = $Options.ConsoleHost }
        $console['port'] = [int]$Options.ConsolePort
        $cfg['console'] = $console
    }
    $json = ConvertTo-Json -InputObject $cfg -Depth 5
    return (($json -replace "`r`n", "`n") -replace "`n", "`r`n") + "`r`n"
}

# The block at the end of sshd_config.
function New-HawSshdBlock {
    param([string]$AccountName, [string]$VmctlPath)
    return @(
        $script:BeginMarker,
        ('Match User ' + $AccountName),
        ('    AuthorizedKeysFile __PROGRAMDATA__/ssh/haw-' + $AccountName + '_authorized_keys'),
        ('    ForceCommand powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $VmctlPath),
        '    AllowTcpForwarding no',
        '    AllowAgentForwarding no',
        '    X11Forwarding no',
        '    PermitTTY no',
        $script:EndMarker
    )
}

# Text to lines and back; the file's own newline (CRLF or LF) is kept.
function Split-ConfigText {
    param([string]$Text)
    $nl = "`n"
    if ($Text.Contains("`r`n")) { $nl = "`r`n" }
    $lines = @($Text -split "\r?\n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { $lines = @() } else { $lines = @($lines[0..($lines.Count - 2)]) }
    }
    return [pscustomobject]@{ Lines = [string[]]$lines; Newline = $nl }
}

function Join-ConfigText {
    param([string[]]$Lines, [string]$Newline)
    return ((@($Lines) -join $Newline) + $Newline)
}

# The [begin, end] line numbers of each marked block. Throws on broken markers.
function Get-HawBlockRanges {
    param([string[]]$Lines)
    $ranges = @()
    $start = -1
    for ($i = 0; $i -lt @($Lines).Count; $i++) {
        $t = $Lines[$i].Trim()
        if ($t.StartsWith('# HAW vmctl: begin')) {
            if ($start -ge 0) { throw 'sshd_config has two "# HAW vmctl: begin" lines without an end line between them; fix it by hand' }
            $start = $i
        } elseif ($t -eq $script:EndMarker) {
            if ($start -lt 0) { throw 'sshd_config has a "# HAW vmctl: end" line without a begin line; fix it by hand' }
            $ranges += [pscustomobject]@{ Start = $start; End = $i }
            $start = -1
        }
    }
    if ($start -ge 0) { throw 'sshd_config has a "# HAW vmctl: begin" line without an end line; fix it by hand' }
    return $ranges
}

# The lines without the marked blocks (and without the blank lines that end up
# at the end). Lines without a block come back as they are.
function Remove-HawSshdBlock {
    param([string[]]$Lines)
    $ranges = @(Get-HawBlockRanges $Lines)
    if ($ranges.Count -eq 0) { return $Lines }
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt @($Lines).Count; $i++) {
        $inside = $false
        foreach ($r in $ranges) { if ($i -ge $r.Start -and $i -le $r.End) { $inside = $true } }
        if (-not $inside) { [void]$out.Add($Lines[$i]) }
    }
    while ($out.Count -gt 0 -and $out[$out.Count - 1].Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    return $out.ToArray()
}

# The lines with exactly one marked block, at the end: a block that is there
# (anywhere) is replaced, never doubled. sshd's Match blocks run to the next
# Match or the end, so the block must be last.
function Set-HawSshdBlock {
    param([string[]]$Lines, [string[]]$Block)
    $base = @(Remove-HawSshdBlock $Lines)
    $n = $base.Count
    while ($n -gt 0 -and $base[$n - 1].Trim() -eq '') { $n-- }
    if ($n -eq 0) { return $Block }
    $base = @($base[0..($n - 1)])
    return (@($base) + @('') + @($Block))
}

# A warning when sshd_config's global part limits who may log in.
function Get-SshdAccessWarning {
    param([string[]]$Lines, [string]$AccountName)
    foreach ($l in @($Lines)) {
        if ($l -match '^\s*Match\s') { break }
        if ($l -match '^\s*(AllowUsers|AllowGroups|DenyUsers|DenyGroups)\s') {
            return ('sshd_config has "' + $l.Trim() + '": check that it lets ' + $AccountName + ' log in')
        }
    }
    return $null
}

# ------------------------------------------------------------------ access lists
# An entry: Sid, Flags ('all' = this folder, subfolders and files; 'this' = this
# object only; 'files' = files in the folder only, not the folder), Mask (the
# rights without Synchronize) and Grant (the same for icacls).
function New-AclEntry {
    param([string]$Sid, [string]$Flags, [long]$Mask, [string]$Grant)
    return [pscustomobject]@{ Sid = $Sid; Flags = $Flags; Mask = $Mask; Grant = $Grant }
}

# What each path gets. Full control for SYSTEM and Administrators everywhere;
# the account only what it needs (DESIGN.md, "The queue's access list").
function Get-AclSpec {
    param([string]$Kind, [string]$AccountSid = '')
    $sy = $script:SidSystem
    $ba = $script:SidAdministrators
    switch ($Kind) {
        'haw' {
            # The account may pass through to vmctl.ps1 and the queue; it can't list the folder.
            return @(
                (New-AclEntry $sy 'all' $script:RightsFull '(OI)(CI)F'),
                (New-AclEntry $ba 'all' $script:RightsFull '(OI)(CI)F'),
                (New-AclEntry $AccountSid 'this' $script:RightsTraverse '(X,RA,S)'))
        }
        'queue' {
            return @(
                (New-AclEntry $sy 'all' $script:RightsFull '(OI)(CI)F'),
                (New-AclEntry $ba 'all' $script:RightsFull '(OI)(CI)F'),
                # The folder: add a file; not list, not add a folder, not delete a file in it.
                (New-AclEntry $AccountSid 'this' $script:RightsDropFile '(WD,X,RA,S)'),
                # Every file in it: read (the replies).
                (New-AclEntry $AccountSid 'files' $script:RightsReadFile '(OI)(IO)(RD,REA,RA,RC,S)'),
                # A file the account makes: it may also write it (its request).
                (New-AclEntry $script:SidCreatorOwner 'files' $script:RightsOwnFile '(OI)(IO)(RD,WD,AD,REA,WEA,RA,WA,S)'),
                # The owner of a file gets nothing more: no change of permissions.
                (New-AclEntry $script:SidOwnerRights 'files' $script:RightsOwnerRights '(OI)(IO)(RA,S)'))
        }
        'setup' { return @((New-AclEntry $sy 'all' $script:RightsFull '(OI)(CI)F'), (New-AclEntry $ba 'all' $script:RightsFull '(OI)(CI)F')) }
        'file' { return @((New-AclEntry $sy 'this' $script:RightsFull 'F'), (New-AclEntry $ba 'this' $script:RightsFull 'F')) }
    }
    throw ('no access list for ' + $Kind)
}

# ACL facts (Owner, Protected, Rules with Sid, Rights, Flags, Allow, Inherited)
# against a spec: exactly its entries, nothing inherited, owner Administrators.
function Test-AclSpec {
    param($Facts, [object[]]$Spec)
    if (-not $Facts.Protected) { return $false }
    if ($Facts.Owner -ne $script:SidAdministrators) { return $false }
    $rules = @($Facts.Rules)
    $notSync = -bnot [long]$script:RightsSync
    foreach ($r in $rules) {
        if (-not $r.Allow -or $r.Inherited) { return $false }
        $match = @($Spec | Where-Object { $_.Sid -eq $r.Sid -and $_.Flags -eq $r.Flags -and (([long]$r.Rights -band $notSync) -eq ([long]$_.Mask -band $notSync)) })
        if ($match.Count -eq 0) { return $false }
    }
    foreach ($e in $Spec) {
        $have = @($rules | Where-Object { $_.Sid -eq $e.Sid -and $_.Flags -eq $e.Flags -and (([long]$_.Rights -band $notSync) -eq ([long]$e.Mask -band $notSync)) })
        if ($have.Count -eq 0) { return $false }
    }
    return $true
}

# A file in the haw folder: only what it inherits from the folder.
function Test-InheritOnly {
    param($Facts)
    if ($Facts.Protected) { return $false }
    foreach ($r in @($Facts.Rules)) { if (-not $r.Inherited) { return $false } }
    return $true
}

# vmctl.ps1: what it inherits, plus read and execute for the account, nothing more.
function Test-FrontFileAcl {
    param($Facts, [string]$AccountSid)
    if ($Facts.Protected) { return $false }
    $own = @($Facts.Rules | Where-Object { -not $_.Inherited })
    if ($own.Count -ne 1) { return $false }
    $notSync = -bnot [long]$script:RightsSync
    $r = $own[0]
    return [bool]($r.Allow -and $r.Sid -eq $AccountSid -and $r.Flags -eq 'this' -and (([long]$r.Rights -band $notSync) -eq $script:RightsReadExecute))
}

# ------------------------------------------------------------------ the worker task
# Task Scheduler's own access list: SYSTEM and Administrators full, the account
# read and run (GRGX) only.
function New-WorkerTaskSddl {
    param([string]$AccountSid)
    return ('D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;' + $AccountSid + ')')
}

# The action's arguments. $(Arg0) is what Run() gets: the job's GUID.
function New-WorkerTaskArguments {
    param([string]$WorkerPath)
    return ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $WorkerPath + '" -Job $(Arg0)')
}

# The registered task (Get-WorkerTaskState) against what it should be.
function Test-WorkerTaskState {
    param($State, [string]$Arguments, [string]$AccountSid)
    if ($null -eq $State -or -not $State.Exists) { return $false }
    if ($State.ActionCount -ne 1 -or $State.Path -ne 'powershell.exe' -or $State.Arguments -cne $Arguments) { return $false }
    if (@('SYSTEM', 'S-1-5-18', 'NT AUTHORITY\SYSTEM') -notcontains [string]$State.UserId) { return $false }
    if ($State.LogonType -ne 5 -or $State.MultipleInstances -ne 0 -or $State.TimeLimit -ne 'PT3M') { return $false }
    if (-not $State.Enabled -or $State.TriggerCount -ne 0) { return $false }
    # The account's entries in the task's DACL: exactly one, allow, read and run.
    $aces = @([regex]::Matches([string]$State.Sddl, '\(([^)]*)\)') | ForEach-Object { $_.Groups[1].Value })
    $mine = @($aces | Where-Object { ($_ -split ';')[-1] -eq $AccountSid })
    if ($mine.Count -ne 1) { return $false }
    $f = $mine[0] -split ';'
    if ($f[0] -ne 'A') { return $false }
    # Task Scheduler stores GRGX as the file rights it stands for (0x1200a9), so
    # compare numbers, without Synchronize (BUG-009, seen on a real host).
    $mask = ConvertTo-FileAccessMask $f[2]
    return [bool]($mask -ge 0 -and ($mask -band (-bnot [long]$script:RightsSync)) -eq $script:RightsReadExecute)
}

# An SDDL access right (0x1200a9, FRFX, GRGX ...) as file rights, generic rights
# mapped the way NTFS maps them; -1 for a right this does not know.
function ConvertTo-FileAccessMask {
    param([string]$Rights)
    if ($Rights -match '^0[xX][0-9a-fA-F]{1,8}$') { $mask = [Convert]::ToInt64($Rights.Substring(2), 16) }
    elseif ($Rights -match '^([A-Z]{2})+$') {
        $codes = @{
            GA = 0x10000000; GR = 2147483648; GW = 0x40000000; GX = 0x20000000
            FA = 0x1F01FF; FR = 0x120089; FW = 0x120116; FX = 0x1200A0
            RC = 0x20000; SD = 0x10000; WD = 0x40000; WO = 0x80000
        }
        $mask = [long]0
        for ($i = 0; $i -lt $Rights.Length; $i += 2) {
            $code = $Rights.Substring($i, 2)
            if (-not $codes.ContainsKey($code)) { return [long]-1 }
            $mask = $mask -bor [long]$codes[$code]
        }
    }
    else { return [long]-1 }
    $generic = @(@(0x10000000, 0x1F01FF), @(2147483648, 0x120089), @(0x40000000, 0x120116), @(0x20000000, 0x1200A0))
    foreach ($g in $generic) {
        if (($mask -band [long]$g[0]) -ne 0) { $mask = ($mask -band (-bnot [long]$g[0])) -bor [long]$g[1] }
    }
    return [long]$mask
}

# ------------------------------------------------------------------ the sshd restart script
# The script the SYSTEM task runs: put the checked sshd_config in place,
# restart sshd, and put the old one back if sshd does not run then.
function New-RestartScriptLines {
    param([string]$SetupDir, [string]$SshdConfig)
    $q = { param($s) "'" + $s.Replace("'", "''") + "'" }
    return @(
        ('# Made by install.ps1 (HAW vmctl). The SYSTEM task ' + $script:TaskName + ' runs it, outside any SSH session.'),
        '# It puts the checked sshd_config in place and restarts sshd; if sshd does not run then, it puts the old file back.',
        '$ErrorActionPreference = ''Stop''',
        ('$setup = ' + (& $q $SetupDir)),
        ('$cfg = ' + (& $q $SshdConfig)),
        'Start-Sleep -Seconds 3',
        '$result = ''sshd running''',
        'try {',
        '    Copy-Item -LiteralPath (Join-Path $setup ''sshd_config.new'') -Destination $cfg -Force',
        '    Restart-Service -Name sshd -Force',
        '    Start-Sleep -Seconds 5',
        '    if ((Get-Service -Name sshd).Status -ne ''Running'') { throw ''sshd does not run with the new sshd_config'' }',
        '} catch {',
        '    $why = $_.Exception.Message',
        '    try { Copy-Item -LiteralPath (Join-Path $setup ''sshd_config.before'') -Destination $cfg -Force; Start-Service -Name sshd } catch { $why = $why + ''; and then: '' + $_.Exception.Message }',
        '    $result = ''ROLLED BACK to the sshd_config from before ('' + $why + '')''',
        '}',
        'Set-Content -LiteralPath (Join-Path $setup ''restart-done.txt'') -Value ($result + '', '' + (Get-Date -Format o))'
    )
}

# A random password straight into a SecureString: it is never a string, never
# printed, never stored. 32 random characters plus one of each kind.
function New-RandomPassword {
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $all = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!#%+-=_'
        $kinds = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-=_')
        $bytes = New-Object byte[] 36
        $rng.GetBytes($bytes)
        $ss = New-Object Security.SecureString
        for ($i = 0; $i -lt 32; $i++) { $ss.AppendChar($all[$bytes[$i] % $all.Length]) }
        for ($k = 0; $k -lt 4; $k++) { $ss.AppendChar($kinds[$k][$bytes[32 + $k] % $kinds[$k].Length]) }
        [Array]::Clear($bytes, 0, $bytes.Length)
        $ss.MakeReadOnly()
        return $ss
    } finally { $rng.Dispose() }
}

# The lists of an "info" result (from ConvertFrom-Json) are lists: Windows
# PowerShell 5.1 can write a list as {"value":[...],"Count":n}, and this finds that.
function Test-InfoLists {
    param($Result)
    if ($null -eq $Result) { return $false }
    if ($Result.verbs -isnot [array] -or @($Result.verbs).Count -lt 1) { return $false }
    if ($null -eq $Result.protocol -or $Result.protocol.versions -isnot [array]) { return $false }
    if ($Result.networks -isnot [array]) { return $false }
    if ($null -eq $Result.capacity -or $Result.capacity.disks -isnot [array]) { return $false }
    return $true
}

# ------------------------------------------------------------------ Windows parts
# Each one is small, so the tests can mock it.
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-HyperVPresent {
    return [bool]((Get-Module -ListAvailable -Name Hyper-V) -and (Get-Service -Name vmms -ErrorAction SilentlyContinue))
}

# sshd.exe's path, or $null when OpenSSH Server is not there.
function Get-SshdExe {
    if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) { return $null }
    $c = Get-Command sshd.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:WINDIR 'System32\OpenSSH\sshd.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

function Get-LocalAccount {
    param([string]$Name)
    return (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
}

function New-HawAccount {
    param([string]$Name)
    $null = New-LocalUser -Name $Name -Password (New-RandomPassword) -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires -Description $script:AccountMarker
}

function Set-HawAccountFlags {
    param([string]$Name)
    Set-LocalUser -Name $Name -PasswordNeverExpires $true -UserMayChangePassword $false
    Enable-LocalUser -Name $Name
}

# The SIDs of the local groups the account is in. Through ADSI: Get-LocalGroupMember
# fails on a group that holds an orphaned or Entra ID member.
function Get-AccountGroupSids {
    param([string]$Name)
    $u = [ADSI]('WinNT://' + $env:COMPUTERNAME + '/' + $Name + ',user')
    $out = @()
    foreach ($g in @($u.psbase.Invoke('Groups'))) {
        $bytes = $g.GetType().InvokeMember('objectSid', 'GetProperty', $null, $g, $null)
        $out += (New-Object Security.Principal.SecurityIdentifier($bytes, 0)).Value
    }
    return $out
}

function Remove-HyperVAdminMember {
    param([string]$Name)
    Remove-LocalGroupMember -SID $script:SidHyperVAdmins -Member $Name
}

# Flags of an access rule: 'all', 'this', 'files', or what they are.
function ConvertTo-AclFlags {
    param([int]$Inheritance, [int]$Propagation)
    $ci = ($Inheritance -band 1) -ne 0
    $oi = ($Inheritance -band 2) -ne 0
    $io = ($Propagation -band 2) -ne 0
    $np = ($Propagation -band 1) -ne 0
    if (-not $ci -and -not $oi) { return 'this' }
    if ($ci -and $oi -and -not $io -and -not $np) { return 'all' }
    if ($oi -and -not $ci -and $io -and -not $np) { return 'files' }
    return ('other ' + $Inheritance + '/' + $Propagation)
}

function Get-AclFacts {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $sidType = [Security.Principal.SecurityIdentifier]
    $rules = @()
    foreach ($r in @($acl.GetAccessRules($true, $true, $sidType))) {
        $rules += [pscustomobject]@{
            Sid       = $r.IdentityReference.Value
            Rights    = [long]$r.FileSystemRights
            Flags     = (ConvertTo-AclFlags ([int]$r.InheritanceFlags) ([int]$r.PropagationFlags))
            Allow     = ([string]$r.AccessControlType -eq 'Allow')
            Inherited = [bool]$r.IsInherited
        }
    }
    return [pscustomobject]@{ Owner = $acl.GetOwner($sidType).Value; Protected = $acl.AreAccessRulesProtected; Rules = $rules }
}

function Invoke-Icacls {
    param([string[]]$Arguments)
    $out = & icacls.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw ('icacls ' + ($Arguments -join ' ') + ' failed: ' + $out) }
}

# Exactly the spec's entries, nothing inherited, owner Administrators. The
# owner first: setting it makes Windows turn OWNER RIGHTS entries inherit-only
# and drop their (OI), so an entry granted before it does nothing (BUG-009,
# seen on a real host). Then full control (replacing), then every other SID
# removed, then the account's entries added one by one (one /grant:r per SID
# would keep only the last). The spec's own SIDs are removed too: Get-Acl does
# not show an OWNER RIGHTS entry that lost its (OI), but icacls still finds it.
function Set-AclSpec {
    param([string]$Path, [object[]]$Spec)
    $full = @($Spec | Where-Object { $_.Sid -eq $script:SidSystem -or $_.Sid -eq $script:SidAdministrators })
    $rest = @($Spec | Where-Object { $_.Sid -ne $script:SidSystem -and $_.Sid -ne $script:SidAdministrators })
    Invoke-Icacls @($Path, '/setowner', ('*' + $script:SidAdministrators))
    Invoke-Icacls @($Path, '/inheritance:r')
    Invoke-Icacls (@($Path, '/grant:r') + @($full | ForEach-Object { '*' + $_.Sid + ':' + $_.Grant }))
    $seen = @(@((Get-AclFacts $Path).Rules) | ForEach-Object { $_.Sid })
    foreach ($sid in @(@($seen) + @($rest | ForEach-Object { $_.Sid }) | Sort-Object -Unique)) {
        if ($sid -ne $script:SidSystem -and $sid -ne $script:SidAdministrators) { Invoke-Icacls @($Path, '/remove', ('*' + $sid)) }
    }
    foreach ($e in $rest) { Invoke-Icacls @($Path, '/grant', ('*' + $e.Sid + ':' + $e.Grant)) }
}

function Reset-FileAcl {
    param([string]$Path)
    Invoke-Icacls @($Path, '/reset')
}

function Set-FrontFileAcl {
    param([string]$Path, [string]$AccountSid)
    Invoke-Icacls @($Path, '/reset')
    Invoke-Icacls @($Path, '/grant', ('*' + $AccountSid + ':(RX)'))
}

# The worker task as Task Scheduler has it (COM), or Exists = $false.
function Get-WorkerTaskState {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try { $t = $svc.GetFolder('\').GetTask($script:WorkerTaskName) } catch { return [pscustomobject]@{ Exists = $false } }
    $d = $t.Definition
    $a = $null
    foreach ($x in $d.Actions) { $a = $x; break }
    return [pscustomobject]@{
        Exists = $true; ActionCount = [int]$d.Actions.Count; Path = [string]$a.Path; Arguments = [string]$a.Arguments
        UserId = [string]$d.Principal.UserId; LogonType = [int]$d.Principal.LogonType
        MultipleInstances = [int]$d.Settings.MultipleInstances; TimeLimit = [string]$d.Settings.ExecutionTimeLimit
        Enabled = [bool]$t.Enabled; TriggerCount = [int]$d.Triggers.Count; Sddl = [string]$t.GetSecurityDescriptor(4)
    }
}

# Registers (or replaces) the worker task through the Schedule.Service COM API:
# SYSTEM as a service account (logon type 5), parallel instances, 3 minutes at
# most, no trigger, and the access list from New-WorkerTaskSddl.
function Register-WorkerTask {
    param([string]$Arguments, [string]$Sddl)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $def = $svc.NewTask(0)
    $def.RegistrationInfo.Description = 'HAW vmctl worker (made by install.ps1): answers the vmctl account''s requests as SYSTEM.'
    $def.Principal.LogonType = 5
    $def.Principal.RunLevel = 1
    $def.Settings.MultipleInstances = 0
    $def.Settings.ExecutionTimeLimit = 'PT3M'
    $def.Settings.DisallowStartIfOnBatteries = $false
    $def.Settings.StopIfGoingOnBatteries = $false
    $def.Settings.AllowDemandStart = $true
    $def.Settings.Enabled = $true
    $action = $def.Actions.Create(0)
    $action.Path = 'powershell.exe'
    $action.Arguments = $Arguments
    $null = $svc.GetFolder('\').RegisterTaskDefinition($script:WorkerTaskName, $def, 6, 'SYSTEM', $null, 5, $Sddl)
}

function Remove-WorkerTask {
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $svc.GetFolder('\').DeleteTask($script:WorkerTaskName, 0)
}

# sshd -t -f on the candidate file. Returns Ok and the output.
function Test-SshdCandidate {
    param([string]$Exe, [string]$Path)
    $out = & $Exe -t -f $Path 2>&1
    return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = (($out | ForEach-Object { "$_" }) -join ' ') }
}

function Start-SshdRestart {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:RestartScript + '"')
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $script:TaskName -Action $action -Principal $principal -Force
    Start-ScheduledTask -TaskName $script:TaskName
}

function Test-RestartTask {
    return [bool](Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)
}

function Remove-RestartTask {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
}

function Remove-HawAccount {
    param($User)
    $sid = $User.SID.Value
    foreach ($p in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.SID -eq $sid })) {
        Remove-CimInstance -InputObject $p
    }
    Remove-LocalUser -SID $User.SID -Confirm:$false
}

# Runs the installed front with an "info" request, as this administrator: the
# real worker task answers. Returns the reply, or $null when there is none.
function Invoke-VmctlSelfCheck {
    $req = '{"haw":"vmctl","v":1,"id":"install-check","verb":"info","args":{}}'
    $out = @($req | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:VmctlDest 2>$null)
    $line = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { return $null }
    return (ConvertFrom-Json -InputObject $line)
}

# ------------------------------------------------------------------ sync steps
# Writes text (UTF-8, no byte order mark) when it differs. Returns $true when it
# wrote (or would write).
function Sync-FileText {
    param([string]$Path, [string]$Text, [string]$Item)
    $old = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $old = [IO.File]::ReadAllText($Path) }
    if ($null -ne $old -and $old -ceq $Text) { Write-Line 'OK' $Item $Path; return $false }
    Invoke-Change $Item ('write ' + $Path) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false))) }
    return $true
}

function Sync-Folder {
    param([string]$Path, [string]$Item)
    if (Test-Path -LiteralPath $Path -PathType Container) { Write-Line 'OK' $Item $Path; return }
    Invoke-Change $Item ('make ' + $Path) { $null = New-Item -ItemType Directory -Path $Path -Force }
}

function Sync-AclSpec {
    param([string]$Path, [string]$Item, [string]$Detail, [object[]]$Spec)
    if ((Test-Path -LiteralPath $Path) -and (Test-AclSpec -Facts (Get-AclFacts $Path) -Spec $Spec)) {
        Write-Line 'OK' $Item $Detail
        return
    }
    Invoke-Change $Item $Detail { Set-AclSpec -Path $Path -Spec $Spec }
}

# Copies a script when the installed copy differs; checks the copy's hash.
function Sync-Script {
    param([string]$From, [string]$To, [string]$Hash, [string]$Item)
    if ((Test-Path -LiteralPath $To -PathType Leaf) -and (Get-Sha256 $To) -eq $Hash) { Write-Line 'OK' $Item $To; return }
    Invoke-Change $Item ('copy to ' + $To) { Copy-Item -LiteralPath $From -Destination $To -Force }
    if (-not $script:PlanOnly) { $null = Assert-ScriptHash -Path $To -Expected $Hash }
}

# ------------------------------------------------------------------ install
# Returns the account's SID, or $null in a plan where the account is not there yet.
function Sync-Account {
    param($Options)
    $name = $Options.Account
    $user = Get-LocalAccount $name
    if (-not $user) {
        Invoke-Change ('account ' + $name) 'make it: a random password nobody sees, never expires, in Users only' { New-HawAccount $name }
        if (-not $script:PlanOnly) { $user = Get-LocalAccount $name }
    } else {
        if ($user.Description -ne $script:AccountMarker) { Write-Line 'INFO' ('account ' + $name) 'it was there before install.ps1; -Uninstall leaves it' }
        if ($null -eq $user.PasswordExpires -and -not $user.UserMayChangePassword -and $user.Enabled) {
            Write-Line 'OK' ('account ' + $name) 'enabled, password never expires, the account cannot change it'
        } else {
            Invoke-Change ('account ' + $name) 'enable it; password never expires; the account cannot change it' { Set-HawAccountFlags $name }
        }
    }
    if (-not $user) { return $null }
    $sids = @(Get-AccountGroupSids $name)
    $problem = Get-AccountGroupProblem -AccountName $name -GroupSids $sids -MadeByInstall ($user.Description -eq $script:AccountMarker)
    if ($problem) { throw $problem }
    if ($sids -contains $script:SidHyperVAdmins) {
        Invoke-Change ('account ' + $name) 'take it out of Hyper-V Administrators (an older install.ps1 put it there; the worker does the Hyper-V work now)' { Remove-HyperVAdminMember $name }
    } else {
        Write-Line 'OK' ('account ' + $name) 'in Users only'
    }
    return $user.SID.Value
}

function Sync-WorkerTask {
    param([string]$AccountSid)
    $args0 = New-WorkerTaskArguments $script:WorkerTaskPath
    $detail = 'runs vmctl-worker.ps1 as SYSTEM; ' + 'the account may read and run it'
    if (-not $AccountSid) { Write-Line 'WOULD' ('task ' + $script:WorkerTaskName) $detail; return }
    if (Test-WorkerTaskState -State (Get-WorkerTaskState) -Arguments $args0 -AccountSid $AccountSid) {
        Write-Line 'OK' ('task ' + $script:WorkerTaskName) $detail
        return
    }
    $sddl = New-WorkerTaskSddl $AccountSid
    Invoke-Change ('task ' + $script:WorkerTaskName) $detail { Register-WorkerTask -Arguments $args0 -Sddl $sddl }
}

function Sync-Sshd {
    param($Options, [string]$SshdExe)
    $text = [IO.File]::ReadAllText($script:SshdConfig)
    $parts = Split-ConfigText $text
    $warn = Get-SshdAccessWarning -Lines $parts.Lines -AccountName $Options.Account
    if ($warn) { Write-Line 'WARN' 'sshd_config' $warn }
    if ($Options.Uninstall) { $lines = @(Remove-HawSshdBlock $parts.Lines) }
    else { $lines = @(Set-HawSshdBlock -Lines $parts.Lines -Block @(New-HawSshdBlock -AccountName $Options.Account -VmctlPath $script:VmctlForcePath)) }
    $newText = Join-ConfigText -Lines $lines -Newline $parts.Newline
    if ($newText -ceq $text) {
        if ($Options.Uninstall) { Write-Line 'OK' 'sshd_config' 'no HAW block' } else { Write-Line 'OK' 'sshd_config' ('the HAW block for ' + $Options.Account + ' is there, at the end') }
        return $false
    }
    $what = 'add the HAW block for ' + $Options.Account + ' at the end, check it with sshd -t, restart sshd'
    if ($Options.Uninstall) { $what = 'remove the HAW block, check it with sshd -t, restart sshd' }
    if ($script:PlanOnly) { Write-Line 'WOULD' 'sshd_config' $what; return $true }

    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($script:Candidate, $newText, $enc)
    $check = Test-SshdCandidate -Exe $SshdExe -Path $script:Candidate
    if (-not $check.Ok) { throw ('sshd -t refused the new sshd_config, so sshd_config is not changed: ' + $check.Output) }
    Write-Line 'OK' 'sshd -t' 'the new sshd_config is valid'
    [IO.File]::WriteAllText($script:Before, $text, $enc)
    [IO.File]::WriteAllText($script:RestartScript, (Join-ConfigText -Lines @(New-RestartScriptLines -SetupDir $script:SetupDir -SshdConfig $script:SshdConfig) -Newline "`r`n"), $enc)
    if (Test-Path -LiteralPath $script:RestartDone) { Remove-Item -LiteralPath $script:RestartDone -Force }
    Invoke-Change 'sshd_config' $what { Start-SshdRestart }
    Write-Line 'INFO' 'sshd' ('the SYSTEM task ' + $script:TaskName + ' puts the new sshd_config in place and restarts sshd in about 3 seconds; SSH sessions may drop')
    Write-Line 'INFO' 'sshd' ('to confirm, after 10 seconds: Get-Content ' + $script:RestartDone + ' (it says "sshd running", or "ROLLED BACK" and why)')
    return $true
}

function Invoke-Install {
    param($Options, [string]$SourceDir)
    $frontSrc = Join-Path $SourceDir 'vmctl.ps1'
    $workerSrc = Join-Path $SourceDir 'vmctl-worker.ps1'
    if (-not (Test-HyperVPresent)) { throw 'Hyper-V is not on this machine (no Hyper-V module or no vmms service)' }
    Write-Line 'OK' 'Hyper-V' 'the module and the vmms service are there'
    $sshdExe = Get-SshdExe
    if (-not $sshdExe) { throw 'OpenSSH Server is not installed (no sshd service or sshd.exe)' }
    if (-not (Test-Path -LiteralPath $script:SshdConfig -PathType Leaf)) { throw ($script:SshdConfig + ' is not there: start sshd once so that it makes the file') }
    Write-Line 'OK' 'OpenSSH Server' $sshdExe
    $frontHash = Assert-ScriptHash -Path $frontSrc -Expected $Options.Sha256
    Write-Line 'OK' 'vmctl.ps1' ('SHA-256 ' + $frontHash + ' as expected')
    $workerHash = Assert-ScriptHash -Path $workerSrc -Expected $Options.WorkerSha256
    Write-Line 'OK' 'vmctl-worker.ps1' ('SHA-256 ' + $workerHash + ' as expected')

    $sid = Sync-Account $Options
    $who = $Options.Account

    Sync-Folder $script:HawDir 'folder'
    if ($sid) { Sync-AclSpec -Path $script:HawDir -Item 'folder access' -Detail ('SYSTEM and Administrators full; ' + $who + ' may pass through, not list') -Spec (Get-AclSpec 'haw' $sid) }
    else { Write-Line 'WOULD' 'folder access' ('SYSTEM and Administrators full; ' + $who + ' may pass through, not list') }
    Sync-Folder $script:SetupDir 'setup folder'
    Sync-AclSpec -Path $script:SetupDir -Item 'setup folder access' -Detail 'SYSTEM and Administrators only' -Spec (Get-AclSpec 'setup')
    Sync-Folder $script:QueueDir 'queue'
    if ($sid) { Sync-AclSpec -Path $script:QueueDir -Item 'queue access' -Detail ($who + ' may add a file, write its own, read all; not list, delete or change access') -Spec (Get-AclSpec 'queue' $sid) }
    else { Write-Line 'WOULD' 'queue access' ($who + ' may add a file, write its own, read all; not list, delete or change access') }

    Sync-Script -From $frontSrc -To $script:VmctlDest -Hash $frontHash -Item 'installed vmctl.ps1'
    Sync-Script -From $workerSrc -To $script:WorkerDest -Hash $workerHash -Item 'installed vmctl-worker.ps1'

    $cfgText = New-VmctlConfigText $Options
    if ((Test-Path -LiteralPath $script:ConfigDest -PathType Leaf) -and -not $Options.ReplaceConfig) {
        if ([IO.File]::ReadAllText($script:ConfigDest) -ceq $cfgText) { Write-Line 'OK' 'vmctl.json' $script:ConfigDest }
        else { Write-Line 'OK' 'vmctl.json' ('kept as it is; the limit parameters are not used (give -ReplaceConfig to write the file from them)') }
    } else {
        $null = Sync-FileText -Path $script:ConfigDest -Text $cfgText -Item 'vmctl.json'
    }

    # The account: read and execute on the front; nothing on the worker or the config.
    if (Test-Path -LiteralPath $script:VmctlDest -PathType Leaf) {
        if ($sid -and (Test-FrontFileAcl (Get-AclFacts $script:VmctlDest) $sid)) { Write-Line 'OK' 'access of vmctl.ps1' ('as the folder, and ' + $who + ' read and execute') }
        elseif ($sid) { $s = $sid; Invoke-Change 'access of vmctl.ps1' ('as the folder, and ' + $who + ' read and execute') { Set-FrontFileAcl -Path $script:VmctlDest -AccountSid $s } }
    }
    foreach ($f in @($script:WorkerDest, $script:ConfigDest)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if (Test-InheritOnly (Get-AclFacts $f)) { Write-Line 'OK' ('access of ' + (Split-Path -Leaf $f)) 'as the folder (SYSTEM and Administrators only)' }
        else { $ff = $f; Invoke-Change ('access of ' + (Split-Path -Leaf $f)) 'reset to the folder''s (SYSTEM and Administrators only)' { Reset-FileAcl $ff } }
    }
    if (-not (Test-Path -LiteralPath $script:VmctlDest -PathType Leaf) -or -not $sid) {
        Write-Line 'WOULD' 'access of the scripts' ('vmctl.ps1: ' + $who + ' read and execute; vmctl-worker.ps1 and vmctl.json: as the folder')
    }

    Sync-WorkerTask $sid

    $null = Sync-FileText -Path $script:KeysFile -Text ($Options.PublicKey + "`r`n") -Item 'key file'
    if (Test-Path -LiteralPath $script:KeysFile) {
        Sync-AclSpec -Path $script:KeysFile -Item 'key file access' -Detail 'SYSTEM and Administrators only, owner Administrators' -Spec (Get-AclSpec 'file')
    } else {
        Write-Line 'WOULD' 'key file access' 'SYSTEM and Administrators only, owner Administrators'
    }

    $null = Sync-Sshd -Options $Options -SshdExe $sshdExe

    if (-not $script:PlanOnly) {
        $reply = Invoke-VmctlSelfCheck
        if ($null -eq $reply) { $script:Failed++; Write-Line 'FAIL' 'vmctl check' 'the installed vmctl.ps1 gave no reply to "info"' }
        elseif ($reply.result -and $reply.result.configProblem) { $script:Failed++; Write-Line 'FAIL' 'vmctl check' ('vmctl.json: ' + $reply.result.configProblem) }
        elseif (-not $reply.ok) { $script:Failed++; Write-Line 'FAIL' 'vmctl check' ($reply.error.code + ': ' + $reply.error.message) }
        elseif (-not (Test-InfoLists $reply.result)) { $script:Failed++; Write-Line 'FAIL' 'vmctl check' 'the lists in the "info" reply are not JSON lists; HAW cannot read this reply' }
        else { Write-Line 'OK' 'vmctl check' ('"info" answers through the worker task, Hyper-V back end ' + $reply.result.backend.version + ', config OK') }
    }
}

# ------------------------------------------------------------------ uninstall
function Invoke-Uninstall {
    param($Options)
    $sshdExe = Get-SshdExe
    $restarting = $false
    if ($sshdExe -and (Test-Path -LiteralPath $script:SshdConfig -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $script:SetupDir -PathType Container)) {
            Invoke-Change 'setup folder' ('make ' + $script:SetupDir + ' for the sshd restart') {
                $null = New-Item -ItemType Directory -Path $script:SetupDir -Force
                Set-AclSpec -Path $script:SetupDir -Spec (Get-AclSpec 'setup')
            }
        }
        $restarting = Sync-Sshd -Options $Options -SshdExe $sshdExe
    } else {
        Write-Line 'OK' 'sshd_config' 'OpenSSH Server or sshd_config is not there'
    }

    if (Test-Path -LiteralPath $script:KeysFile) { Invoke-Change 'key file' ('remove ' + $script:KeysFile) { Remove-Item -LiteralPath $script:KeysFile -Force } }
    else { Write-Line 'OK' 'key file' 'not there' }

    $user = Get-LocalAccount $Options.Account
    if (-not $user) { Write-Line 'OK' ('account ' + $Options.Account) 'not there' }
    elseif ($user.Description -ne $script:AccountMarker) { Write-Line 'WARN' ('account ' + $Options.Account) 'not made by install.ps1, so it is left; remove it by hand if HAW was its only use' }
    else { $u = $user; Invoke-Change ('account ' + $Options.Account) 'remove it and its profile' { Remove-HawAccount $u } }

    if ((Get-WorkerTaskState).Exists) { Invoke-Change ('task ' + $script:WorkerTaskName) 'remove it' { Remove-WorkerTask } }
    else { Write-Line 'OK' ('task ' + $script:WorkerTaskName) 'not there' }

    foreach ($f in @($script:VmctlDest, $script:WorkerDest, $script:ConfigDest)) {
        if (Test-Path -LiteralPath $f) { $ff = $f; Invoke-Change (Split-Path -Leaf $f) ('remove ' + $f) { Remove-Item -LiteralPath $ff -Force } }
    }
    if (Test-Path -LiteralPath $script:QueueDir) { Invoke-Change 'queue' ('remove ' + $script:QueueDir) { Remove-Item -LiteralPath $script:QueueDir -Recurse -Force } }

    if ($restarting) {
        Write-Line 'TODO' 'last parts' ('after sshd restarted, run install.ps1 -Uninstall again: it removes ' + $script:HawDir + ' and the task ' + $script:TaskName + ', which the restart needs now')
        return
    }
    if (Test-RestartTask) { Invoke-Change ('task ' + $script:TaskName) 'remove it' { Remove-RestartTask } }
    else { Write-Line 'OK' ('task ' + $script:TaskName) 'not there' }
    if (Test-Path -LiteralPath $script:HawDir) { Invoke-Change 'folder' ('remove ' + $script:HawDir) { Remove-Item -LiteralPath $script:HawDir -Recurse -Force } }
    else { Write-Line 'OK' 'folder' 'not there' }
}

function Invoke-HawSetup {
    if (-not (Test-IsAdmin)) { throw 'run this in an elevated PowerShell (Run as administrator)' }
    $opts = Assert-InstallParameters -PublicKey $PublicKey -Account $Account -Sha256 $Sha256 -WorkerSha256 $WorkerSha256 -NamePattern $NamePattern -Protected $Protected `
        -CeilingCpus $CeilingCpus -CeilingMemoryMB $CeilingMemoryMB -CeilingDiskGB $CeilingDiskGB -ConsoleHost $ConsoleHost -ConsolePort $ConsolePort -Uninstall ([bool]$Uninstall) -ReplaceConfig ([bool]$ReplaceConfig)
    $root = $env:ProgramData
    if (-not $root) { $root = 'C:\ProgramData' }
    Set-InstallRoot -Root $root -AccountName $opts.Account
    $src = $Source
    if (-not $src) { $src = $PSScriptRoot }
    if ($opts.Uninstall) { Invoke-Uninstall $opts }
    else { Invoke-Install -Options $opts -SourceDir $src }
    Write-Line 'CHANGED' ([string]$script:Changes)
}

# Dot-sourced by the tests: define the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-HawSetup }
    catch { Write-Line 'FAIL' 'install.ps1' $_.Exception.Message; exit 1 }
    if ($script:Failed) { exit 1 }
}
