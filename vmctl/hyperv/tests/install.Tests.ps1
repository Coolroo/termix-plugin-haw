# Pester 5 tests for install.ps1 (design B). They run on Linux pwsh: the pure
# parts directly, a whole install (and uninstall) in a temporary folder with
# every Windows-only part mocked. What only a real Windows run proves (the
# account, icacls, the COM task registration, sshd -t and the restart) is for
# the host itself; DESIGN.md lists it.

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    $script:Dir = Split-Path -Parent $script:Here
    $script:FrontSrc = Join-Path $script:Dir 'vmctl.ps1'
    $script:WorkerSrc = Join-Path $script:Dir 'vmctl-worker.ps1'
    $script:Src = Join-Path $script:Dir 'install.ps1'
    # The worker too: the tests check that it reads the config install.ps1 writes.
    . $script:WorkerSrc
    . $script:Src

    $blob = [byte[]](0, 0, 0, 11) + [Text.Encoding]::ASCII.GetBytes('ssh-ed25519') + [byte[]](0, 0, 0, 32) + [byte[]](1..32)
    $script:KeyB64 = [Convert]::ToBase64String([byte[]]$blob)
    $script:Key = 'ssh-ed25519 ' + $script:KeyB64 + ' termix@example'
    # The default sshd_config of Windows' OpenSSH (the lines that matter), with CRLF.
    $script:DefaultSshd = @(
        '# This is the sshd server system-wide configuration file.',
        'AuthorizedKeysFile	.ssh/authorized_keys',
        '#PasswordAuthentication yes',
        'Subsystem	sftp	sftp-server.exe',
        '',
        'Match Group administrators',
        '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys'
    )
    $script:DefaultSshdText = ($script:DefaultSshd -join "`r`n") + "`r`n"
    $script:WantBlock = @(
        '# HAW vmctl: begin (made by install.ps1; change the host with install.ps1)',
        'Match User vmctl',
        '    AuthorizedKeysFile __PROGRAMDATA__/ssh/haw-vmctl_authorized_keys',
        '    ForceCommand powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:/ProgramData/haw/vmctl.ps1',
        '    AllowTcpForwarding no',
        '    AllowAgentForwarding no',
        '    X11Forwarding no',
        '    PermitTTY no',
        '# HAW vmctl: end'
    )
    $script:AccountSid = 'S-1-5-21-1000-2000-3000-1001'
    $script:InfoReply = '{"haw":"vmctl","v":1,"id":"install-check","ok":true,"result":{"host":{"name":"HV1"},"backend":{"kind":"hyper-v","version":"1.0.0"},"protocol":{"versions":[1]},"capacity":{"cpus":16,"memoryMB":65536,"freeMemoryMB":20480,"disks":[{"name":"C:","sizeGB":930,"freeGB":410}]},"networks":[],"verbs":["info","list","show","start","stop","restart","console-info"],"limits":{"namePattern":"x","protected":[],"ceilings":{}},"configProblem":null}}'

    function script:New-Opts {
        param([string]$Sha = $script:Hash, [string]$WorkerSha = $script:WorkerHash, [string]$Key = $script:Key, [bool]$Uninstall = $false, [bool]$Replace = $false, [string[]]$Protected = @('build-*'))
        Assert-InstallParameters -PublicKey $Key -Account 'vmctl' -Sha256 $Sha -WorkerSha256 $WorkerSha -NamePattern '^[a-z][a-z0-9-]{0,62}$' -Protected $Protected `
            -CeilingCpus 16 -CeilingMemoryMB 32768 -CeilingDiskGB 0 -ConsoleHost 'hv1.example.lan' -ConsolePort 2179 -Uninstall $Uninstall -ReplaceConfig $Replace
    }
    function script:New-Rule {
        param([string]$Sid, [long]$Rights, [string]$Flags = 'this', [bool]$Inherited = $false, [bool]$Allow = $true)
        [pscustomobject]@{ Sid = $Sid; Rights = $Rights; Flags = $Flags; Allow = $Allow; Inherited = $Inherited }
    }
    # Facts as Windows would give them for a spec (with Synchronize, as icacls sets it).
    function script:ConvertTo-Facts {
        param([object[]]$Spec)
        [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = @($Spec | ForEach-Object { New-Rule $_.Sid ([long]$_.Mask -bor 0x100000) $_.Flags }) }
    }
    # The ACLs as install.ps1 leaves them.
    function script:Get-GoodFacts {
        param([string]$Path)
        $inherited = @((New-Rule 'S-1-5-18' 0x1F01FF 'this' $true), (New-Rule 'S-1-5-32-544' 0x1F01FF 'this' $true))
        if ($Path -eq $script:VmctlDest) { return [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = @($inherited + @(New-Rule $script:AccountSid 0x1200A9)) } }
        if ($Path -eq $script:WorkerDest -or $Path -eq $script:ConfigDest) { return [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = $inherited } }
        if ($Path -eq $script:HawDir) { return (ConvertTo-Facts (Get-AclSpec 'haw' $script:AccountSid)) }
        if ($Path -eq $script:QueueDir) { return (ConvertTo-Facts (Get-AclSpec 'queue' $script:AccountSid)) }
        if ($Path -eq $script:SetupDir) { return (ConvertTo-Facts (Get-AclSpec 'setup')) }
        return (ConvertTo-Facts (Get-AclSpec 'file'))
    }
    function script:New-GoodTaskState {
        param([string]$Arguments, [string]$Sddl)
        [pscustomobject]@{
            Exists = $true; ActionCount = 1; Path = 'powershell.exe'; Arguments = $Arguments; UserId = 'SYSTEM'; LogonType = 5
            MultipleInstances = 0; TimeLimit = 'PT3M'; Enabled = $true; TriggerCount = 0; Sddl = $Sddl
        }
    }
    # The task's part: put the checked file in place.
    function script:Invoke-FakeTask {
        Copy-Item -LiteralPath $script:Candidate -Destination $script:SshdConfig -Force
    }
    function script:Get-Lines {
        param([int]$From)
        @($script:Output | Select-Object -Skip $From)
    }
}

Describe 'the file itself' {
    It 'is ASCII only, so Windows PowerShell 5.1 reads it the same without a BOM' {
        @([IO.File]::ReadAllBytes($script:Src) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'parses with no errors' {
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'uses no syntax that Windows PowerShell 5.1 lacks (?:, ??, ?., &&, ||, -AsHashtable)' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$tokens, [ref]$errors)
        @($ast.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst') }, $true)).Count | Should -Be 0
        @($tokens | Where-Object { $_.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket') }).Count | Should -Be 0
        (Get-Content -Raw $script:Src) | Should -Not -Match '-AsHashtable'
    }
}

Describe 'the public key' {
    It 'takes one ed25519 line, with or without a comment' {
        Test-PublicKeyLine ('  ' + $script:Key + '  ') | Should -BeExactly $script:Key
        Test-PublicKeyLine ('ssh-ed25519 ' + $script:KeyB64) | Should -BeExactly ('ssh-ed25519 ' + $script:KeyB64)
    }
    It 'refuses <Why>' -TestCases @(
        @{ Why = 'an empty key'; Line = '' },
        @{ Why = 'an RSA key'; Line = 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ termix' },
        @{ Why = 'a key with options'; Line = 'restrict,command="x" ssh-ed25519 KEYB64 termix' },
        @{ Why = 'two lines'; Line = "ssh-ed25519 KEYB64 a`nssh-ed25519 KEYB64 b" },
        @{ Why = 'bad base64'; Line = 'ssh-ed25519 AAAA$$$$ termix' },
        @{ Why = 'a short blob'; Line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 termix' },
        @{ Why = 'a blob of another type'; Line = 'ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAAAAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA termix' }
    ) {
        { Test-PublicKeyLine ($Line -replace 'KEYB64', $script:KeyB64) } | Should -Throw
    }
}

Describe 'the parameters' {
    BeforeAll { $script:Hash = 'A' * 64; $script:WorkerHash = 'B' * 64 }
    It 'needs a key and both SHA-256 to install' {
        { New-Opts -Key '' } | Should -Throw '*-PublicKey*'
        { New-Opts -Sha '' } | Should -Throw '*-Sha256*'
        { New-Opts -Sha 'abc' } | Should -Throw '*-Sha256*'
        { New-Opts -WorkerSha '' } | Should -Throw '*-WorkerSha256*'
        { New-Opts -WorkerSha ('A' * 63) } | Should -Throw '*-WorkerSha256*'
    }
    It 'needs none of them to uninstall' {
        (Assert-InstallParameters -PublicKey '' -Account 'vmctl' -Sha256 '' -WorkerSha256 '' -NamePattern 'x' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $true -ReplaceConfig $false).Uninstall | Should -BeTrue
    }
    It 'refuses a bad account name, pattern, ceiling or console' {
        $base = @{ PublicKey = $script:Key; Account = 'vmctl'; Sha256 = $script:Hash; WorkerSha256 = $script:WorkerHash; NamePattern = 'x'; Protected = @(); CeilingCpus = 0; CeilingMemoryMB = 0; CeilingDiskGB = 0; ConsoleHost = ''; ConsolePort = 2179; Uninstall = $false; ReplaceConfig = $false }
        $a = $base.Clone(); $a.Account = 'vm ctl'; { Assert-InstallParameters @a } | Should -Throw '*-Account*'
        $a = $base.Clone(); $a.NamePattern = '([a-z'; { Assert-InstallParameters @a } | Should -Throw '*-NamePattern*'
        $a = $base.Clone(); $a.CeilingCpus = -1; { Assert-InstallParameters @a } | Should -Throw '*-CeilingCpus*'
        $a = $base.Clone(); $a.ConsoleHost = 'hv 1'; { Assert-InstallParameters @a } | Should -Throw '*-ConsoleHost*'
        $a = $base.Clone(); $a.ConsolePort = 0; { Assert-InstallParameters @a } | Should -Throw '*-ConsolePort*'
    }
    It 'splits -Protected given as one string "a,b" (powershell -File)' {
        $o = New-Opts -Protected @('build-*, web-1')
        @($o.Protected).Count | Should -Be 2
        $o.Protected[1] | Should -Be 'web-1'
    }
}

Describe 'the hash of a script' {
    It 'refuses a file whose SHA-256 differs' {
        $f = Join-Path $TestDrive 'vmctl.ps1'
        [IO.File]::WriteAllText($f, "'a changed file'`n")
        { Assert-ScriptHash -Path $f -Expected ('0' * 64) } | Should -Throw '*not the reviewed file*'
    }
    It 'takes the file whose SHA-256 is the one given, in either case' {
        $h = Get-Sha256 $script:WorkerSrc
        Assert-ScriptHash -Path $script:WorkerSrc -Expected $h.ToLowerInvariant() | Should -Be $h
    }
}

Describe 'the account''s groups (Users only)' {
    It 'refuses an account in Administrators, also one install.ps1 made' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-544') -MadeByInstall $true | Should -Match 'in Administrators'
    }
    It 'refuses an account in Hyper-V Administrators that install.ps1 did not make' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-578') -MadeByInstall $false | Should -Match 'Hyper-V Administrators'
    }
    It 'lets install.ps1 take its own account out of Hyper-V Administrators' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-578') -MadeByInstall $true | Should -BeNullOrEmpty
    }
    It 'refuses an account in another group' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-555') -MadeByInstall $true | Should -Match 'other groups'
    }
    It 'takes Users only, or no group' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545') | Should -BeNullOrEmpty
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @() | Should -BeNullOrEmpty
    }
}

Describe 'vmctl.json from the parameters' {
    BeforeAll { $script:Hash = 'A' * 64; $script:WorkerHash = 'B' * 64 }
    It 'is a config that the worker reads without a problem' {
        $f = Join-Path $TestDrive 'vmctl.json'
        [IO.File]::WriteAllText($f, (New-VmctlConfigText (New-Opts)))
        $c = Get-VmctlConfig -Path $f
        $c.Problem | Should -BeNullOrEmpty
        $c.Cpus | Should -Be 16
        $c.MemoryMB | Should -Be 32768
        $c.DiskGB | Should -BeNullOrEmpty
        $c.ConsoleHost | Should -Be 'hv1.example.lan'
        @($c.Protected) | Should -Be @('build-*')
    }
    It 'keeps one protect entry a list, and none an empty list' {
        (New-VmctlConfigText (New-Opts -Protected @('web-1'))) -replace '\s', '' | Should -Match '"protected":\["web-1"\]'
        (New-VmctlConfigText (New-Opts -Protected @())) -replace '\s', '' | Should -Match '"protected":\[\]'
    }
    It 'leaves out the ceilings of 0 and the console when no name is given' {
        $o = Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -WorkerSha256 $script:WorkerHash -NamePattern '^a$' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false
        $t = New-VmctlConfigText $o
        $t | Should -Not -Match 'ceilings'
        $t | Should -Not -Match 'console'
        $t | Should -Match "`r`n$"
    }
}

Describe 'the sshd_config block' {
    It 'is the block of the protocol, for the account' {
        @(New-HawSshdBlock -AccountName 'vmctl' -VmctlPath 'C:/ProgramData/haw/vmctl.ps1') | Should -Be $script:WantBlock
    }
    It 'goes at the end, after the Match block of the default config, with one blank line' {
        $out = @(Set-HawSshdBlock -Lines $script:DefaultSshd -Block $script:WantBlock)
        $out.Count | Should -Be ($script:DefaultSshd.Count + 1 + $script:WantBlock.Count)
        $out[$script:DefaultSshd.Count] | Should -Be ''
        @($out | Select-Object -Last $script:WantBlock.Count) | Should -Be $script:WantBlock
    }
    It 'changes nothing the second time' {
        $once = @(Set-HawSshdBlock -Lines $script:DefaultSshd -Block $script:WantBlock)
        $twice = @(Set-HawSshdBlock -Lines $once -Block $script:WantBlock)
        ($twice -join "`n") | Should -BeExactly ($once -join "`n")
    }
    It 'replaces a block that is there, never doubles it, and moves it to the end' {
        $old = @('# HAW vmctl: begin (old text)', 'Match User old', '    PermitTTY no', '# HAW vmctl: end')
        $lines = @('Port 22', '') + $old + @('', 'Match Group administrators', '  AuthorizedKeysFile x')
        $out = @(Set-HawSshdBlock -Lines $lines -Block $script:WantBlock)
        @($out | Where-Object { $_ -like '# HAW vmctl: begin*' }).Count | Should -Be 1
        $out | Should -Not -Contain 'Match User old'
        @($out | Select-Object -Last $script:WantBlock.Count) | Should -Be $script:WantBlock
        $out | Should -Contain 'Match Group administrators'
    }
    It 'removes the block and gives the file back as it was' {
        $with = @(Set-HawSshdBlock -Lines $script:DefaultSshd -Block $script:WantBlock)
        @(Remove-HawSshdBlock $with) | Should -Be $script:DefaultSshd
    }
    It 'leaves a file without a block exactly as it is, trailing blank lines too' {
        (@(Remove-HawSshdBlock @('Port 22', '', '')) -join '|') | Should -BeExactly 'Port 22||'
    }
    It 'stops at broken markers' {
        { Set-HawSshdBlock -Lines @('# HAW vmctl: begin', 'Match User x') -Block $script:WantBlock } | Should -Throw '*without an end*'
        { Set-HawSshdBlock -Lines @('Port 22', '# HAW vmctl: end') -Block $script:WantBlock } | Should -Throw '*without a begin*'
        { Remove-HawSshdBlock @('# HAW vmctl: begin', '# HAW vmctl: begin', '# HAW vmctl: end') } | Should -Throw '*two*'
    }
    It 'handles an empty file and a file of blank lines' {
        @(Set-HawSshdBlock -Lines @() -Block $script:WantBlock) | Should -Be $script:WantBlock
        @(Set-HawSshdBlock -Lines @('') -Block $script:WantBlock) | Should -Be $script:WantBlock
        @(Set-HawSshdBlock -Lines @('', '  ', '') -Block $script:WantBlock) | Should -Be $script:WantBlock
    }
    It 'keeps CRLF or LF as the file has it' {
        $p = Split-ConfigText $script:DefaultSshdText
        $p.Newline | Should -Be "`r`n"
        (Join-ConfigText -Lines $p.Lines -Newline $p.Newline) | Should -BeExactly $script:DefaultSshdText
        $lf = Split-ConfigText "a`nb`n"
        (Join-ConfigText -Lines $lf.Lines -Newline $lf.Newline) | Should -BeExactly "a`nb`n"
    }
    It 'warns when the global part limits who logs in' {
        Get-SshdAccessWarning -Lines @('AllowGroups administrators', 'Match User x') -AccountName 'vmctl' | Should -Match 'AllowGroups'
        Get-SshdAccessWarning -Lines @('Port 22', 'Match User x', '  AllowUsers y') -AccountName 'vmctl' | Should -BeNullOrEmpty
    }
}

Describe 'the access lists' {
    It 'gives the queue: the account adds files, reads all, writes its own; nobody but SYSTEM and Administrators deletes or changes access' {
        $spec = @(Get-AclSpec 'queue' $script:AccountSid)
        $acct = @($spec | Where-Object { $_.Sid -eq $script:AccountSid })
        ($acct | Where-Object { $_.Flags -eq 'this' }).Mask | Should -Be 0xA2
        ($acct | Where-Object { $_.Flags -eq 'files' }).Mask | Should -Be 0x20089
        ($spec | Where-Object { $_.Sid -eq 'S-1-3-0' }).Mask | Should -Be 0x19F
        ($spec | Where-Object { $_.Sid -eq 'S-1-3-4' }).Mask | Should -Be 0x80
        # No list (RD on the folder), no subfolder (AD), no delete (D, DC), no WDAC, no WO for anyone but SYSTEM and Administrators.
        foreach ($e in @($spec | Where-Object { $_.Sid -ne 'S-1-5-18' -and $_.Sid -ne 'S-1-5-32-544' })) {
            ($e.Mask -band (0x10000 -bor 0x40 -bor 0x40000 -bor 0x80000)) | Should -Be 0
        }
        (($acct | Where-Object { $_.Flags -eq 'this' }).Mask -band (0x1 -bor 0x4)) | Should -Be 0
        ($acct | Where-Object { $_.Flags -eq 'files' }).Mask -band 0x2 | Should -Be 0
    }
    It 'gives the account only passage through the haw folder, no listing' {
        $e = @(Get-AclSpec 'haw' $script:AccountSid | Where-Object { $_.Sid -eq $script:AccountSid })
        $e.Count | Should -Be 1
        $e[0].Flags | Should -Be 'this'
        ($e[0].Mask -band 0x1) | Should -Be 0
    }
    It 'takes facts that are exactly the spec, Synchronize or not' {
        $spec = @(Get-AclSpec 'queue' $script:AccountSid)
        Test-AclSpec -Facts (ConvertTo-Facts $spec) -Spec $spec | Should -BeTrue
        $plain = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = @($spec | ForEach-Object { New-Rule $_.Sid $_.Mask $_.Flags }) }
        Test-AclSpec -Facts $plain -Spec $spec | Should -BeTrue
    }
    It 'refuses <Why>' -TestCases @(
        @{ Why = 'inherited entries'; Change = { param($f) $f.Protected = $false } },
        @{ Why = 'another owner'; Change = { param($f) $f.Owner = 'S-1-5-21-9' } },
        @{ Why = 'an account that may list the queue'; Change = { param($f) ($f.Rules | Where-Object { $_.Sid -eq $script:AccountSid -and $_.Flags -eq 'this' }).Rights = 0x1200A3 } },
        @{ Why = 'an account that may write the replies'; Change = { param($f) ($f.Rules | Where-Object { $_.Sid -eq $script:AccountSid -and $_.Flags -eq 'files' }).Rights = 0x12019F } },
        @{ Why = 'an entry with other flags'; Change = { param($f) ($f.Rules | Where-Object { $_.Sid -eq 'S-1-3-0' }).Flags = 'all' } },
        @{ Why = 'another SID'; Change = { param($f) $f.Rules += New-Rule 'S-1-5-11' 0x1200A9 'all' } },
        @{ Why = 'a deny entry'; Change = { param($f) $f.Rules[2].Allow = $false } },
        @{ Why = 'a missing entry'; Change = { param($f) $f.Rules = @($f.Rules | Where-Object { $_.Sid -ne 'S-1-3-4' }) } }
    ) {
        $spec = @(Get-AclSpec 'queue' $script:AccountSid)
        $f = ConvertTo-Facts $spec
        & $Change $f
        Test-AclSpec -Facts $f -Spec $spec | Should -BeFalse
    }
    It 'reads rule flags as all, this or files' {
        ConvertTo-AclFlags 3 0 | Should -Be 'all'
        ConvertTo-AclFlags 0 0 | Should -Be 'this'
        ConvertTo-AclFlags 1 0 | Should -Match '^other'
        ConvertTo-AclFlags 2 2 | Should -Be 'files'
        ConvertTo-AclFlags 3 2 | Should -Match '^other'
    }
    It 'takes vmctl.ps1 with what it inherits plus read and execute for the account, nothing more' {
        $inh = @((New-Rule 'S-1-5-18' 0x1F01FF 'this' $true))
        Test-FrontFileAcl ([pscustomobject]@{ Protected = $false; Rules = @($inh + @(New-Rule $script:AccountSid 0x1200A9)) }) $script:AccountSid | Should -BeTrue
        Test-FrontFileAcl ([pscustomobject]@{ Protected = $false; Rules = $inh }) $script:AccountSid | Should -BeFalse
        Test-FrontFileAcl ([pscustomobject]@{ Protected = $false; Rules = @($inh + @(New-Rule $script:AccountSid 0x1301BF)) }) $script:AccountSid | Should -BeFalse
        Test-FrontFileAcl ([pscustomobject]@{ Protected = $true; Rules = @(New-Rule $script:AccountSid 0x1200A9) }) $script:AccountSid | Should -BeFalse
    }
    It 'takes a file that only inherits, and refuses one with its own entries' {
        Test-InheritOnly ([pscustomobject]@{ Protected = $false; Rules = @(New-Rule 'S-1-5-18' 0x1F01FF 'this' $true) }) | Should -BeTrue
        Test-InheritOnly ([pscustomobject]@{ Protected = $false; Rules = @(New-Rule $script:AccountSid 0x1200A9) }) | Should -BeFalse
    }
}

Describe 'setting an access list (icacls order)' {
    BeforeEach {
        $script:IcaclsCalls = New-Object System.Collections.ArrayList
        Mock Invoke-Icacls { $null = $script:IcaclsCalls.Add(($Arguments -join ' ')) }
        # Get-Acl does not show an OWNER RIGHTS entry that lost its (OI): only the account here.
        Mock Get-AclFacts { [pscustomobject]@{ Owner = $script:SidAdministrators; Protected = $true; Rules = @([pscustomobject]@{ Sid = $script:AccountSid; Rights = 0xA2; Flags = 'this'; Allow = $true; Inherited = $false }) } }
    }
    It 'sets the owner before any grant, because a later owner change strips OWNER RIGHTS'' (OI) (BUG-009)' {
        Set-AclSpec -Path 'C:\q' -Spec (Get-AclSpec 'queue' $script:AccountSid)
        $script:IcaclsCalls[0] | Should -BeExactly 'C:\q /setowner *S-1-5-32-544'
        @($script:IcaclsCalls | Where-Object { $_ -like '*/setowner*' }).Count | Should -Be 1
    }
    It 'removes the spec''s own SIDs before it grants them, also when Get-Acl does not show them' {
        Set-AclSpec -Path 'C:\q' -Spec (Get-AclSpec 'queue' $script:AccountSid)
        $calls = @($script:IcaclsCalls)
        foreach ($sid in @($script:AccountSid, $script:SidCreatorOwner, $script:SidOwnerRights)) {
            $remove = [array]::IndexOf($calls, 'C:\q /remove *' + $sid)
            $remove | Should -BeGreaterThan 0
            $grant = @(0..($calls.Count - 1) | Where-Object { $calls[$_].StartsWith('C:\q /grant *' + $sid + ':') })[0]
            $grant | Should -BeGreaterThan $remove
        }
        @($calls | Where-Object { $_ -eq 'C:\q /remove *S-1-5-18' -or $_ -eq 'C:\q /remove *S-1-5-32-544' }).Count | Should -Be 0
        $calls | Should -Contain 'C:\q /grant *S-1-3-4:(OI)(IO)(RA,S)'
    }
}

Describe 'the worker task' {
    It 'has an access list built from the account''s SID: SYSTEM and Administrators full, the account read and run' {
        New-WorkerTaskSddl 'S-1-5-21-1-2-3-1001' | Should -BeExactly 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;S-1-5-21-1-2-3-1001)'
    }
    It 'runs the worker with the GUID from Run() as -Job' {
        New-WorkerTaskArguments 'C:\ProgramData\haw\vmctl-worker.ps1' | Should -BeExactly '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\haw\vmctl-worker.ps1" -Job $(Arg0)'
    }
    It 'takes a task as install.ps1 registers it' {
        $a = New-WorkerTaskArguments 'C:\x\vmctl-worker.ps1'
        Test-WorkerTaskState -State (New-GoodTaskState $a (New-WorkerTaskSddl $script:AccountSid)) -Arguments $a -AccountSid $script:AccountSid | Should -BeTrue
        $normal = 'O:BAG:SYD:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0xa0000000;;;' + $script:AccountSid + ')'
        Test-WorkerTaskState -State (New-GoodTaskState $a $normal) -Arguments $a -AccountSid $script:AccountSid | Should -BeTrue
    }
    It 'takes the task as Task Scheduler stores it on a real host (BUG-009)' {
        # GetSecurityDescriptor(4) on a real host: GRGX comes back as 0x1200a9, with inherited entries.
        $a = New-WorkerTaskArguments 'C:\x\vmctl-worker.ps1'
        $real = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;0x1200a9;;;' + $script:AccountSid + ')(A;ID;0x1f019f;;;BA)(A;ID;0x1f019f;;;SY)(A;ID;FA;;;BA)(A;;FR;;;SY)'
        Test-WorkerTaskState -State (New-GoodTaskState $a $real) -Arguments $a -AccountSid $script:AccountSid | Should -BeTrue
        $named = 'D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;FRFX;;;' + $script:AccountSid + ')'
        Test-WorkerTaskState -State (New-GoodTaskState $a $named) -Arguments $a -AccountSid $script:AccountSid | Should -BeTrue
    }
    It 'reads an SDDL right as file rights: <Rights> is <Mask>' -TestCases @(
        @{ Rights = 'GRGX'; Mask = 0x1200A9 },
        @{ Rights = 'GXGR'; Mask = 0x1200A9 },
        @{ Rights = 'FRFX'; Mask = 0x1200A9 },
        @{ Rights = '0x1200a9'; Mask = 0x1200A9 },
        @{ Rights = '0xA0000000'; Mask = 0x1200A9 },
        @{ Rights = 'GA'; Mask = 0x1F01FF },
        @{ Rights = 'FA'; Mask = 0x1F01FF },
        @{ Rights = 'ZZ'; Mask = -1 },
        @{ Rights = 'GRG'; Mask = -1 }
    ) {
        ConvertTo-FileAccessMask $Rights | Should -Be ([long]$Mask)
    }
    It 'refuses <Why>' -TestCases @(
        @{ Why = 'no task'; Change = { param($s) $s.Exists = $false } },
        @{ Why = 'other arguments'; Change = { param($s) $s.Arguments = $s.Arguments + ' -ConfigPath x' } },
        @{ Why = 'another user'; Change = { param($s) $s.UserId = 'vmctl' } },
        @{ Why = 'an interactive logon'; Change = { param($s) $s.LogonType = 3 } },
        @{ Why = 'one instance at a time'; Change = { param($s) $s.MultipleInstances = 1 } },
        @{ Why = 'another time limit'; Change = { param($s) $s.TimeLimit = 'PT72H' } },
        @{ Why = 'a trigger'; Change = { param($s) $s.TriggerCount = 1 } },
        @{ Why = 'full control for the account'; Change = { param($s) $s.Sddl = $s.Sddl.Replace('GRGX', 'FA') } },
        @{ Why = 'read, run and write for the account'; Change = { param($s) $s.Sddl = $s.Sddl.Replace('GRGX', '0x1201bf') } },
        @{ Why = 'read only for the account'; Change = { param($s) $s.Sddl = $s.Sddl.Replace('GRGX', 'FR') } },
        @{ Why = 'a right it does not know'; Change = { param($s) $s.Sddl = $s.Sddl.Replace('GRGX', 'GRXX') } },
        @{ Why = 'a deny entry for the account'; Change = { param($s) $s.Sddl = $s.Sddl.Replace('(A;;GRGX;', '(D;;GRGX;') } },
        @{ Why = 'a second entry for the account'; Change = { param($s) $s.Sddl = $s.Sddl + '(A;;GW;;;' + $script:AccountSid + ')' } },
        @{ Why = 'no entry for the account'; Change = { param($s) $s.Sddl = 'D:(A;;FA;;;BA)(A;;FA;;;SY)' } }
    ) {
        $a = New-WorkerTaskArguments 'C:\x\vmctl-worker.ps1'
        $s = New-GoodTaskState $a (New-WorkerTaskSddl $script:AccountSid)
        & $Change $s
        Test-WorkerTaskState -State $s -Arguments $a -AccountSid $script:AccountSid | Should -BeFalse
    }
}

Describe 'the self-check of the info reply' {
    It 'takes lists that are lists, empty and one-element ones too' {
        Test-InfoLists (ConvertFrom-Json $script:InfoReply).result | Should -BeTrue
    }
    It 'finds a list written as {"value":[...],"Count":n} (Windows PowerShell 5.1)' {
        $bad = $script:InfoReply.Replace('"verbs":["info","list","show","start","stop","restart","console-info"]', '"verbs":{"value":["info"],"Count":1}')
        Test-InfoLists (ConvertFrom-Json $bad).result | Should -BeFalse
        Test-InfoLists (ConvertFrom-Json ($script:InfoReply.Replace('"versions":[1]', '"versions":1'))).result | Should -BeFalse
    }
}

Describe 'the restart script and the password' {
    It 'is a script that parses, copies the new file in and rolls back' {
        $text = @(New-RestartScriptLines -SetupDir 'C:\ProgramData\haw\setup' -SshdConfig 'C:\ProgramData\ssh\sshd_config') -join "`n"
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $text | Should -Match 'sshd_config.new'
        $text | Should -Match 'sshd_config.before'
        $text | Should -Match 'ROLLED BACK'
    }
    It 'makes a random password of 36 characters with each kind, never twice the same' {
        $a = New-RandomPassword
        $b = New-RandomPassword
        $a.IsReadOnly() | Should -BeTrue
        $pa = (New-Object System.Net.NetworkCredential('', $a)).Password
        $pb = (New-Object System.Net.NetworkCredential('', $b)).Password
        $pa.Length | Should -Be 36
        $pa | Should -Not -Be $pb
        $pa | Should -MatchExactly '[A-Z]'
        $pa | Should -MatchExactly '[a-z]'
        $pa | Should -Match '[0-9]'
        $pa | Should -Match '[!#%+=_-]'
    }
}

Describe 'a whole install, Windows parts mocked' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ('pd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Root 'ssh') -Force
        $script:SrcDir = Join-Path $TestDrive 'src'
        $null = New-Item -ItemType Directory -Path $script:SrcDir -Force
        Copy-Item -LiteralPath $script:FrontSrc -Destination (Join-Path $script:SrcDir 'vmctl.ps1') -Force
        Copy-Item -LiteralPath $script:WorkerSrc -Destination (Join-Path $script:SrcDir 'vmctl-worker.ps1') -Force
        $script:Hash = Get-Sha256 $script:FrontSrc
        $script:WorkerHash = Get-Sha256 $script:WorkerSrc
        Set-InstallRoot -Root $script:Root -AccountName 'vmctl'
        [IO.File]::WriteAllText($script:SshdConfig, $script:DefaultSshdText)
        $script:PlanOnly = $false
        $script:Changes = 0
        $script:Failed = 0
        $script:Output.Clear()
        $script:User = $null
        $script:Groups = @('S-1-5-32-545')
        $script:AclGood = $false
        $script:TaskState = [pscustomobject]@{ Exists = $false }

        Mock Write-Host { }
        Mock Test-HyperVPresent { $true }
        Mock Get-SshdExe { 'sshd.exe' }
        Mock Get-LocalAccount { $script:User }
        Mock New-HawAccount {
            $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = $script:AccountMarker; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        }
        Mock Set-HawAccountFlags { }
        Mock Get-AccountGroupSids { $script:Groups }
        Mock Remove-HyperVAdminMember { $script:Groups = @($script:Groups | Where-Object { $_ -ne 'S-1-5-32-578' }) }
        Mock Get-AclFacts {
            if ($script:AclGood) { return (Get-GoodFacts $Path) }
            [pscustomobject]@{ Owner = 'S-1-5-21-9'; Protected = $false; Rules = @(New-Rule 'S-1-5-32-545' 0x1200A9 'all' $false) }
        }
        Mock Set-AclSpec { }
        Mock Reset-FileAcl { }
        Mock Set-FrontFileAcl { }
        Mock Get-WorkerTaskState { $script:TaskState }
        Mock Register-WorkerTask { $script:TaskState = New-GoodTaskState $Arguments $Sddl }
        Mock Remove-WorkerTask { $script:TaskState = [pscustomobject]@{ Exists = $false } }
        Mock Test-SshdCandidate { [pscustomobject]@{ Ok = $true; Output = '' } }
        Mock Start-SshdRestart { }
        Mock Invoke-VmctlSelfCheck { ConvertFrom-Json $script:InfoReply }
        Mock Test-RestartTask { $true }
        Mock Remove-RestartTask { }
        Mock Remove-HawAccount { $script:User = $null }
    }

    It 'plans only with -WhatIf: WOULD lines, no file, no account, no task, no restart' {
        $script:PlanOnly = $true
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Changes | Should -Be 0
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Test-Path -LiteralPath $script:KeysFile | Should -BeFalse
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
        Should -Invoke New-HawAccount -Times 0
        Should -Invoke Set-AclSpec -Times 0
        Should -Invoke Register-WorkerTask -Times 0
        Should -Invoke Start-SshdRestart -Times 0
        Should -Invoke Invoke-VmctlSelfCheck -Times 0
        $text = $script:Output -join "`n"
        foreach ($w in 'WOULD account vmctl', 'WOULD folder', 'WOULD queue', 'WOULD task haw-vmctl-worker', 'WOULD sshd_config', 'WOULD installed vmctl-worker.ps1') { $text | Should -Match ([regex]::Escape($w)) }
        $text | Should -Not -Match '(?m)^SET'
    }

    It 'installs everything the first time, and changes nothing the second time' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Should -Invoke New-HawAccount -Times 1 -Exactly
        Should -Invoke Remove-HyperVAdminMember -Times 0
        Should -Invoke Set-AclSpec -Times 1 -Exactly -ParameterFilter { $Path -eq $script:HawDir -and @($Spec | Where-Object { $_.Sid -eq $script:AccountSid }).Count -eq 1 }
        Should -Invoke Set-AclSpec -Times 1 -Exactly -ParameterFilter { $Path -eq $script:QueueDir -and @($Spec | Where-Object { $_.Sid -eq $script:AccountSid }).Count -eq 2 }
        Should -Invoke Set-AclSpec -Times 1 -Exactly -ParameterFilter { $Path -eq $script:SetupDir }
        Should -Invoke Set-AclSpec -Times 1 -Exactly -ParameterFilter { $Path -eq $script:KeysFile }
        Should -Invoke Set-FrontFileAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:VmctlDest -and $AccountSid -eq $script:AccountSid }
        Should -Invoke Reset-FileAcl -Times 2 -Exactly
        Should -Invoke Register-WorkerTask -Times 1 -Exactly -ParameterFilter { $Sddl -eq ('D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;' + $script:AccountSid + ')') -and $Arguments -like '*vmctl-worker.ps1" -Job $(Arg0)' }
        Get-Sha256 $script:VmctlDest | Should -Be $script:Hash
        Get-Sha256 $script:WorkerDest | Should -Be $script:WorkerHash
        Test-Path -LiteralPath $script:QueueDir -PathType Container | Should -BeTrue
        (Get-VmctlConfig -Path $script:ConfigDest).Problem | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($script:KeysFile) | Should -BeExactly ($script:Key + "`r`n")
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
        $cand = Split-ConfigText ([IO.File]::ReadAllText($script:Candidate))
        @($cand.Lines | Select-Object -Last 9)[1] | Should -Be 'Match User vmctl'
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
        Should -Invoke Invoke-VmctlSelfCheck -Times 1 -Exactly
        ($script:Output -join "`n") | Should -Match 'OK    vmctl check: "info" answers through the worker task'

        Invoke-FakeTask
        $script:AclGood = $true
        $from = $script:Output.Count
        $script:Changes = 0
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Changes | Should -Be 0
        @(Get-Lines $from | Where-Object { $_ -match '^(SET|WOULD)' }) | Should -BeNullOrEmpty
        Should -Invoke Register-WorkerTask -Times 1 -Exactly
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
    }

    It 'takes its own account out of Hyper-V Administrators (an older install)' {
        $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = $script:AccountMarker; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        $script:Groups = @('S-1-5-32-545', 'S-1-5-32-578')
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Should -Invoke Remove-HyperVAdminMember -Times 1 -Exactly
        ($script:Output -join "`n") | Should -Match 'take it out of Hyper-V Administrators'
    }

    It 'stops before the folder when someone else''s account is in Hyper-V Administrators' {
        $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = 'someone else''s'; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        $script:Groups = @('S-1-5-32-545', 'S-1-5-32-578')
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*Hyper-V Administrators*'
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Should -Invoke Remove-HyperVAdminMember -Times 0
    }

    It 'stops before the folder when the account is in Administrators' {
        $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = $script:AccountMarker; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        $script:Groups = @('S-1-5-32-545', 'S-1-5-32-544')
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*in Administrators*'
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
    }

    It 'stops before any change when a script is not the reviewed file: <Which>' -TestCases @(@{ Which = 'front' }, @{ Which = 'worker' }) {
        if ($Which -eq 'front') { $o = New-Opts -Sha ('0' * 64) } else { $o = New-Opts -WorkerSha ('0' * 64) }
        { Invoke-Install -Options $o -SourceDir $script:SrcDir } | Should -Throw '*not the reviewed file*'
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Should -Invoke New-HawAccount -Times 0
    }

    It 'stops when OpenSSH Server or Hyper-V is not there' {
        Mock Get-SshdExe { $null }
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*OpenSSH Server*'
        Mock Test-HyperVPresent { $false }
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*Hyper-V*'
    }

    It 'does not put in place a config that sshd -t refuses' {
        Mock Test-SshdCandidate { [pscustomobject]@{ Ok = $false; Output = 'line 9: Bad configuration option' } }
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*sshd -t refused*'
        Should -Invoke Start-SshdRestart -Times 0
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
    }

    It 'keeps an existing vmctl.json unless -ReplaceConfig is given' {
        $null = New-Item -ItemType Directory -Path $script:HawDir -Force
        [IO.File]::WriteAllText($script:ConfigDest, '{"protected":["mine"]}')
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        [IO.File]::ReadAllText($script:ConfigDest) | Should -BeExactly '{"protected":["mine"]}'
        Invoke-Install -Options (New-Opts -Replace $true) -SourceDir $script:SrcDir
        @((Get-VmctlConfig -Path $script:ConfigDest).Protected) | Should -Be @('build-*')
    }

    It 're-registers a task that is not as it should be' {
        $script:TaskState = New-GoodTaskState '-File other.ps1' 'D:(A;;FA;;;BA)'
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Should -Invoke Register-WorkerTask -Times 1 -Exactly
    }

    It 'prints FAIL when the self-check through the worker finds a problem' {
        Mock Invoke-VmctlSelfCheck { ConvertFrom-Json '{"haw":"vmctl","v":1,"id":"install-check","ok":false,"error":{"code":"backend","message":"the vmctl worker did not answer in time"}}' }
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Failed | Should -Be 1
        ($script:Output -join "`n") | Should -Match 'FAIL  vmctl check: backend: the vmctl worker did not answer in time'
    }

    It 'uninstalls in two runs: sshd, account, task, scripts and queue first, then the folder and the restart task' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Invoke-FakeTask
        $script:AclGood = $true

        Invoke-Uninstall (New-Opts -Uninstall $true)
        [IO.File]::ReadAllText($script:Candidate) | Should -BeExactly $script:DefaultSshdText
        Should -Invoke Start-SshdRestart -Times 2 -Exactly
        Should -Invoke Remove-HawAccount -Times 1 -Exactly
        Should -Invoke Remove-WorkerTask -Times 1 -Exactly
        foreach ($p in $script:KeysFile, $script:VmctlDest, $script:WorkerDest, $script:ConfigDest, $script:QueueDir) { Test-Path -LiteralPath $p | Should -BeFalse }
        Test-Path -LiteralPath $script:RestartScript | Should -BeTrue
        ($script:Output -join "`n") | Should -Match 'TODO  last parts'
        Should -Invoke Remove-RestartTask -Times 0

        Invoke-FakeTask
        Invoke-Uninstall (New-Opts -Uninstall $true)
        Should -Invoke Start-SshdRestart -Times 2 -Exactly
        Should -Invoke Remove-WorkerTask -Times 1 -Exactly
        Should -Invoke Remove-RestartTask -Times 1 -Exactly
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
    }

    It 'leaves an account that install.ps1 did not make' {
        $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = 'someone else''s'; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        Invoke-Uninstall (New-Opts -Uninstall $true)
        Should -Invoke Remove-HawAccount -Times 0
        ($script:Output -join "`n") | Should -Match 'WARN  account vmctl'
    }

    It 'plans an uninstall with -WhatIf and changes nothing' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Invoke-FakeTask
        $script:PlanOnly = $true
        $script:Changes = 0
        Invoke-Uninstall (New-Opts -Uninstall $true)
        $script:Changes | Should -Be 0
        Test-Path -LiteralPath $script:KeysFile | Should -BeTrue
        Test-Path -LiteralPath $script:QueueDir | Should -BeTrue
        Should -Invoke Remove-HawAccount -Times 0
        Should -Invoke Remove-WorkerTask -Times 0
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
    }

    It 'never prints the key or a password' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        ($script:Output -join "`n") | Should -Not -Match ([regex]::Escape($script:KeyB64))
    }
}
