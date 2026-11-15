<#
.SYNOPSIS
Set a Hyper-V host up for HAW: the vmctl account, its key, vmctl.ps1, the
host's limits, and sshd's forced command. Run it once, as administrator.

.DESCRIPTION
Every run checks each part and changes only what differs, so a second run
changes nothing (the last line says "CHANGED 0"). -WhatIf prints what it would
change and changes nothing. -Uninstall removes what it made.

  Script   vmctl.ps1 from -Source, only when its SHA-256 is -Sha256, copied to
           C:\ProgramData\haw. That folder: SYSTEM and Administrators full
           control, the account read and execute only, nothing inherited.
  Config   C:\ProgramData\haw\vmctl.json from -NamePattern, -Protected, the
           ceilings and -ConsoleHost. An existing file is kept unless
           -ReplaceConfig is given.
  Account  A local account (-Account, default vmctl) with a random password
           that nobody sees (it logs in with the key only), in Hyper-V
           Administrators and Users only. The script stops if the account is
           in Administrators or in any other group.
  Key      -PublicKey (the key of the Termix host that HAW uses) in
           C:\ProgramData\ssh\haw-<account>_authorized_keys, SYSTEM and
           Administrators only.
  sshd     A marked block at the end of sshd_config: Match User <account>, its
           key file, ForceCommand vmctl.ps1, no forwarding, no TTY. The new
           sshd_config is checked with `sshd -t` first; a SYSTEM task then puts
           it in place and restarts sshd a few seconds later (outside this
           session), and puts the old file back if sshd does not run.

Lines it prints: OK (already right), SET (changed), WOULD (-WhatIf), TODO (a
step for later), INFO, WARN, FAIL. It never prints a secret.

.EXAMPLE
.\install.ps1 -PublicKey 'ssh-ed25519 AAAA... termix' -Sha256 <hash of vmctl.ps1> -Protected 'build-*' -CeilingCpus 16 -CeilingMemoryMB 32768 -ConsoleHost hv1.example.lan -WhatIf
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
    # The SHA-256 of the reviewed vmctl.ps1 (64 hex digits). Required.
    [string]$Sha256 = '',
    # The folder that holds vmctl.ps1. Default: this script's folder.
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
$script:AccountMarker = 'HAW vmctl account (made by install.ps1)'
$script:TaskName = 'haw-vmctl-sshd-restart'
$script:BeginMarker = '# HAW vmctl: begin (made by install.ps1; change the host with install.ps1)'
$script:EndMarker = '# HAW vmctl: end'
$script:DefaultPattern = '^[a-z][a-z0-9-]{0,62}$'
# File rights as numbers: full control, read and execute, and the bits that write.
$script:RightsFull = 0x1F01FF
$script:RightsReadExecute = 0x200A9
$script:RightsWrite = 0xD0156

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
    $script:VmctlDest = Join-Path $script:HawDir 'vmctl.ps1'
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
function Get-AccountGroupProblem {
    param([string]$AccountName, [string[]]$GroupSids)
    $sids = @($GroupSids | Where-Object { $_ })
    if ($sids -contains $script:SidAdministrators) {
        return ($AccountName + ' is in Administrators. HAW''s account must not be an administrator: remove it from Administrators, or give -Account another name')
    }
    $other = @($sids | Where-Object { $_ -ne $script:SidUsers -and $_ -ne $script:SidHyperVAdmins })
    if ($other.Count -gt 0) {
        return ($AccountName + ' is in other groups (' + ($other -join ', ') + '). It may be in Hyper-V Administrators and Users only: remove it from the others, or give -Account another name')
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
        [string]$PublicKey, [string]$Account, [string]$Sha256, [string]$NamePattern, [string[]]$Protected,
        [long]$CeilingCpus, [long]$CeilingMemoryMB, [long]$CeilingDiskGB, [string]$ConsoleHost, [int]$ConsolePort,
        [bool]$Uninstall, [bool]$ReplaceConfig
    )
    if ($Account -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,19}\z') { throw '-Account must be 1 to 20 letters, digits, _ or -, starting with a letter' }
    $opts = [pscustomobject]@{
        Account = $Account; PublicKey = ''; Sha256 = ''; NamePattern = $NamePattern; Protected = @()
        CeilingCpus = $CeilingCpus; CeilingMemoryMB = $CeilingMemoryMB; CeilingDiskGB = $CeilingDiskGB
        ConsoleHost = $ConsoleHost; ConsolePort = $ConsolePort; Uninstall = $Uninstall; ReplaceConfig = $ReplaceConfig
    }
    if ($Uninstall) { return $opts }
    $opts.PublicKey = Test-PublicKeyLine $PublicKey
    if (-not (Test-Sha256Text $Sha256)) { throw '-Sha256 is required: the SHA-256 of the reviewed vmctl.ps1, 64 hex digits' }
    $opts.Sha256 = $Sha256.ToUpperInvariant()
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

# ACL facts (Owner, Protected, Rules with Sid, Rights, Allow, Inherited) against
# what a path should have: $Full and $Read are SIDs; nothing else, nothing inherited.
function Test-AclPlan {
    param($Facts, [string[]]$Full, [string[]]$Read = @(), [string]$Owner = '')
    if (-not $Facts.Protected) { return $false }
    if ($Owner -and $Facts.Owner -ne $Owner) { return $false }
    $rules = @($Facts.Rules)
    foreach ($r in $rules) {
        if (-not $r.Allow -or $r.Inherited) { return $false }
        if ($Full -notcontains $r.Sid -and $Read -notcontains $r.Sid) { return $false }
        if ($Read -contains $r.Sid -and ([long]$r.Rights -band $script:RightsWrite) -ne 0) { return $false }
    }
    foreach ($s in $Full) {
        if (@($rules | Where-Object { $_.Sid -eq $s -and ([long]$_.Rights -band $script:RightsFull) -eq $script:RightsFull }).Count -eq 0) { return $false }
    }
    foreach ($s in $Read) {
        if (@($rules | Where-Object { $_.Sid -eq $s -and ([long]$_.Rights -band $script:RightsReadExecute) -eq $script:RightsReadExecute }).Count -eq 0) { return $false }
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

function Add-HyperVAdminMember {
    param([string]$Name)
    Add-LocalGroupMember -SID $script:SidHyperVAdmins -Member $Name
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

# Exactly these grants, nothing inherited, owner Administrators.
function Set-ExactAcl {
    param([string]$Path, [string[]]$Full, [string[]]$Read = @(), [switch]$Folder)
    $inherit = ''
    if ($Folder) { $inherit = '(OI)(CI)' }
    $grants = @()
    foreach ($s in $Full) { $grants += ('*' + $s + ':' + $inherit + 'F') }
    foreach ($s in $Read) { $grants += ('*' + $s + ':' + $inherit + 'RX') }
    Invoke-Icacls (@($Path, '/inheritance:r', '/grant:r') + $grants)
    Invoke-Icacls @($Path, '/setowner', ('*' + $script:SidAdministrators))
    foreach ($r in @((Get-AclFacts $Path).Rules)) {
        if ($Full -notcontains $r.Sid -and $Read -notcontains $r.Sid) { Invoke-Icacls @($Path, '/remove', ('*' + $r.Sid)) }
    }
}

function Reset-FileAcl {
    param([string]$Path)
    Invoke-Icacls @($Path, '/reset')
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

# Runs the installed vmctl.ps1 with an "info" request, as this administrator.
# Returns the reply, or $null when there is none.
function Invoke-VmctlSelfCheck {
    $req = '{"haw":"vmctl","v":1,"id":"install-check","verb":"info","args":{}}'
    $out = @($req | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:VmctlDest 2>$null)
    $line = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_.StartsWith('{') }) | Select-Object -Last 1
    if (-not $line) { return $null }
    return (ConvertFrom-Json -InputObject $line)
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

function Sync-Acl {
    param([string]$Path, [string]$Item, [string]$Detail, [string[]]$Full, [string[]]$Read = @(), [switch]$Folder)
    if ((Test-Path -LiteralPath $Path) -and (Test-AclPlan -Facts (Get-AclFacts $Path) -Full $Full -Read $Read -Owner $script:SidAdministrators)) {
        Write-Line 'OK' $Item $Detail
        return
    }
    Invoke-Change $Item $Detail { Set-ExactAcl -Path $Path -Full $Full -Read $Read -Folder:$Folder }
}

# ------------------------------------------------------------------ install
function Sync-Account {
    param($Options)
    $name = $Options.Account
    $user = Get-LocalAccount $name
    if (-not $user) {
        Invoke-Change ('account ' + $name) 'make it: a random password nobody sees, never expires, in Users' { New-HawAccount $name }
        if (-not $script:PlanOnly) { $user = Get-LocalAccount $name }
    } else {
        if ($user.Description -ne $script:AccountMarker) { Write-Line 'INFO' ('account ' + $name) 'it was there before install.ps1; -Uninstall leaves it' }
        if ($null -eq $user.PasswordExpires -and -not $user.UserMayChangePassword -and $user.Enabled) {
            Write-Line 'OK' ('account ' + $name) 'enabled, password never expires, the account cannot change it'
        } else {
            Invoke-Change ('account ' + $name) 'enable it; password never expires; the account cannot change it' { Set-HawAccountFlags $name }
        }
    }
    if (-not $user) {
        Write-Line 'WOULD' ('account ' + $name) 'add to Hyper-V Administrators'
        return $null
    }
    $sids = @(Get-AccountGroupSids $name)
    $problem = Get-AccountGroupProblem -AccountName $name -GroupSids $sids
    if ($problem) { throw $problem }
    if ($sids -contains $script:SidHyperVAdmins) { Write-Line 'OK' ('account ' + $name) 'in Hyper-V Administrators, not in Administrators' }
    else { Invoke-Change ('account ' + $name) 'add to Hyper-V Administrators' { Add-HyperVAdminMember $name } }
    return $user.SID.Value
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
    $src = Join-Path $SourceDir 'vmctl.ps1'
    if (-not (Test-HyperVPresent)) { throw 'Hyper-V is not on this machine (no Hyper-V module or no vmms service)' }
    Write-Line 'OK' 'Hyper-V' 'the module and the vmms service are there'
    $sshdExe = Get-SshdExe
    if (-not $sshdExe) { throw 'OpenSSH Server is not installed (no sshd service or sshd.exe)' }
    if (-not (Test-Path -LiteralPath $script:SshdConfig -PathType Leaf)) { throw ($script:SshdConfig + ' is not there: start sshd once so that it makes the file') }
    Write-Line 'OK' 'OpenSSH Server' $sshdExe
    $hash = Assert-ScriptHash -Path $src -Expected $Options.Sha256
    Write-Line 'OK' 'vmctl.ps1' ('SHA-256 ' + $hash + ' as expected')

    $accountSid = Sync-Account $Options
    $full = @($script:SidSystem, $script:SidAdministrators)

    Sync-Folder $script:HawDir 'folder'
    if ($accountSid) {
        Sync-Acl -Path $script:HawDir -Item 'folder access' -Detail ('SYSTEM and Administrators full, ' + $Options.Account + ' read and execute only') -Full $full -Read @($accountSid) -Folder
    } else {
        Write-Line 'WOULD' 'folder access' ('SYSTEM and Administrators full, ' + $Options.Account + ' read and execute only')
    }
    Sync-Folder $script:SetupDir 'setup folder'
    Sync-Acl -Path $script:SetupDir -Item 'setup folder access' -Detail 'SYSTEM and Administrators only' -Full $full -Folder

    if ((Test-Path -LiteralPath $script:VmctlDest -PathType Leaf) -and (Get-Sha256 $script:VmctlDest) -eq $hash) {
        Write-Line 'OK' 'installed vmctl.ps1' $script:VmctlDest
    } else {
        Invoke-Change 'installed vmctl.ps1' ('copy to ' + $script:VmctlDest) { Copy-Item -LiteralPath $src -Destination $script:VmctlDest -Force }
        if (-not $script:PlanOnly) { $null = Assert-ScriptHash -Path $script:VmctlDest -Expected $hash }
    }

    $cfgText = New-VmctlConfigText $Options
    if ((Test-Path -LiteralPath $script:ConfigDest -PathType Leaf) -and -not $Options.ReplaceConfig) {
        if ([IO.File]::ReadAllText($script:ConfigDest) -ceq $cfgText) { Write-Line 'OK' 'vmctl.json' $script:ConfigDest }
        else { Write-Line 'OK' 'vmctl.json' ('kept as it is; the limit parameters are not used (give -ReplaceConfig to write the file from them)') }
    } else {
        $null = Sync-FileText -Path $script:ConfigDest -Text $cfgText -Item 'vmctl.json'
    }
    foreach ($f in @($script:VmctlDest, $script:ConfigDest)) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
        if (Test-InheritOnly (Get-AclFacts $f)) { Write-Line 'OK' ('access of ' + (Split-Path -Leaf $f)) 'as the folder' }
        else { $ff = $f; Invoke-Change ('access of ' + (Split-Path -Leaf $f)) 'reset to the folder''s' { Reset-FileAcl $ff } }
    }

    $null = Sync-FileText -Path $script:KeysFile -Text ($Options.PublicKey + "`r`n") -Item 'key file'
    if (Test-Path -LiteralPath $script:KeysFile) {
        Sync-Acl -Path $script:KeysFile -Item 'key file access' -Detail 'SYSTEM and Administrators only, owner Administrators' -Full $full
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
        else { Write-Line 'OK' 'vmctl check' ('"info" answers, Hyper-V back end ' + $reply.result.backend.version + ', config OK') }
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
                Set-ExactAcl -Path $script:SetupDir -Full @($script:SidSystem, $script:SidAdministrators) -Folder
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

    foreach ($f in @($script:VmctlDest, $script:ConfigDest)) {
        if (Test-Path -LiteralPath $f) { $ff = $f; Invoke-Change (Split-Path -Leaf $f) ('remove ' + $f) { Remove-Item -LiteralPath $ff -Force } }
    }

    if ($restarting) {
        Write-Line 'TODO' 'last parts' ('after sshd restarted, run install.ps1 -Uninstall again: it removes ' + $script:HawDir + ' and the task ' + $script:TaskName + ', which the restart needs now')
        return
    }
    if (Test-RestartTask) { Invoke-Change 'task' ('remove ' + $script:TaskName) { Remove-RestartTask } }
    else { Write-Line 'OK' 'task' 'not there' }
    if (Test-Path -LiteralPath $script:HawDir) { Invoke-Change 'folder' ('remove ' + $script:HawDir) { Remove-Item -LiteralPath $script:HawDir -Recurse -Force } }
    else { Write-Line 'OK' 'folder' 'not there' }
}

function Invoke-HawSetup {
    if (-not (Test-IsAdmin)) { throw 'run this in an elevated PowerShell (Run as administrator)' }
    $opts = Assert-InstallParameters -PublicKey $PublicKey -Account $Account -Sha256 $Sha256 -NamePattern $NamePattern -Protected $Protected `
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
