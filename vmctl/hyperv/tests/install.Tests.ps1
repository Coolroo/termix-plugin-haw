# Pester 5 tests for install.ps1. They run on Linux pwsh: the pure parts
# directly, a whole install (and uninstall) in a temporary folder with every
# Windows-only part mocked. What only a real Windows run proves (the account,
# icacls, the SYSTEM task, sshd -t and the restart) is for the host itself.

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    $script:Dir = Split-Path -Parent $script:Here
    $script:VmctlSrc = Join-Path $script:Dir 'vmctl.ps1'
    $script:Src = Join-Path $script:Dir 'install.ps1'
    # vmctl.ps1 too: the tests check that it reads the config install.ps1 writes.
    . $script:VmctlSrc
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
        param([string]$Sha = $script:Hash, [string]$Key = $script:Key, [bool]$Uninstall = $false, [bool]$Replace = $false, [string[]]$Protected = @('build-*'))
        Assert-InstallParameters -PublicKey $Key -Account 'vmctl' -Sha256 $Sha -NamePattern '^[a-z][a-z0-9-]{0,62}$' -Protected $Protected `
            -CeilingCpus 16 -CeilingMemoryMB 32768 -CeilingDiskGB 0 -ConsoleHost 'hv1.example.lan' -ConsolePort 2179 -Uninstall $Uninstall -ReplaceConfig $Replace
    }
    function script:New-Rule {
        param([string]$Sid, [long]$Rights, [bool]$Inherited = $false, [bool]$Allow = $true)
        [pscustomobject]@{ Sid = $Sid; Rights = $Rights; Allow = $Allow; Inherited = $Inherited }
    }
    # The ACLs as install.ps1 leaves them.
    function script:Get-GoodFacts {
        param([string]$Path)
        if ($Path -like '*vmctl.ps1' -or $Path -like '*vmctl.json') {
            return [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $false; Rules = @(New-Rule 'S-1-5-18' 0x1F01FF $true) }
        }
        $rules = @((New-Rule 'S-1-5-18' 0x1F01FF), (New-Rule 'S-1-5-32-544' 0x1F01FF))
        if ($Path -eq $script:HawDir) { $rules += New-Rule $script:AccountSid 0x1200A9 }
        return [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = $rules }
    }
    # The task's part: put the checked file in place.
    function script:Invoke-FakeTask {
        Copy-Item -LiteralPath $script:Candidate -Destination $script:SshdConfig -Force
    }
    function script:Get-Lines {
        param([string]$From)
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
    BeforeAll { $script:Hash = 'A' * 64 }
    It 'needs a key and a SHA-256 to install' {
        { New-Opts -Key '' } | Should -Throw '*-PublicKey*'
        { New-Opts -Sha '' } | Should -Throw '*-Sha256*'
        { New-Opts -Sha 'abc' } | Should -Throw '*-Sha256*'
    }
    It 'needs neither to uninstall' {
        (Assert-InstallParameters -PublicKey '' -Account 'vmctl' -Sha256 '' -NamePattern 'x' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $true -ReplaceConfig $false).Uninstall | Should -BeTrue
    }
    It 'refuses a bad account name, pattern, ceiling or console' {
        { Assert-InstallParameters -PublicKey $script:Key -Account 'vm ctl' -Sha256 $script:Hash -NamePattern 'x' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false } | Should -Throw '*-Account*'
        { Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -NamePattern '([a-z' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false } | Should -Throw '*-NamePattern*'
        { Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -NamePattern 'x' -Protected @() -CeilingCpus -1 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false } | Should -Throw '*-CeilingCpus*'
        { Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -NamePattern 'x' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost 'hv 1' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false } | Should -Throw '*-ConsoleHost*'
        { Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -NamePattern 'x' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 0 -Uninstall $false -ReplaceConfig $false } | Should -Throw '*-ConsolePort*'
    }
    It 'splits -Protected given as one string "a,b" (powershell -File)' {
        $o = New-Opts -Protected @('build-*, web-1')
        @($o.Protected).Count | Should -Be 2
        $o.Protected[1] | Should -Be 'web-1'
    }
}

Describe 'the hash of vmctl.ps1' {
    It 'refuses a file whose SHA-256 differs' {
        $f = Join-Path $TestDrive 'vmctl.ps1'
        [IO.File]::WriteAllText($f, "'a changed file'`n")
        { Assert-ScriptHash -Path $f -Expected ('0' * 64) } | Should -Throw '*not the reviewed file*'
    }
    It 'takes the file whose SHA-256 is the one given, in either case' {
        $h = Get-Sha256 $script:VmctlSrc
        Assert-ScriptHash -Path $script:VmctlSrc -Expected $h.ToLowerInvariant() | Should -Be $h
    }
}

Describe 'the account''s groups' {
    It 'refuses an account in Administrators' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-544', 'S-1-5-32-578') | Should -Match 'in Administrators'
    }
    It 'refuses an account in another group' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-555') | Should -Match 'other groups'
    }
    It 'takes Users and Hyper-V Administrators, or fewer' {
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @('S-1-5-32-545', 'S-1-5-32-578') | Should -BeNullOrEmpty
        Get-AccountGroupProblem -AccountName 'vmctl' -GroupSids @() | Should -BeNullOrEmpty
    }
}

Describe 'vmctl.json from the parameters' {
    BeforeAll { $script:Hash = 'A' * 64 }
    It 'is a config that vmctl.ps1 reads without a problem' {
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
        $o = Assert-InstallParameters -PublicKey $script:Key -Account 'vmctl' -Sha256 $script:Hash -NamePattern '^a$' -Protected @() -CeilingCpus 0 -CeilingMemoryMB 0 -CeilingDiskGB 0 -ConsoleHost '' -ConsolePort 2179 -Uninstall $false -ReplaceConfig $false
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
        $out[$out.Count - 1] | Should -Be '# HAW vmctl: end'
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
        $lines = @('Port 22', '', '')
        (@(Remove-HawSshdBlock $lines) -join '|') | Should -BeExactly 'Port 22||'
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
        $lf.Newline | Should -Be "`n"
        (Join-ConfigText -Lines $lf.Lines -Newline $lf.Newline) | Should -BeExactly "a`nb`n"
    }
    It 'warns when the global part limits who logs in' {
        Get-SshdAccessWarning -Lines @('AllowGroups administrators', 'Match User x', 'AllowUsers y') -AccountName 'vmctl' | Should -Match 'AllowGroups'
        Get-SshdAccessWarning -Lines @('Port 22', 'Match User x', '  AllowUsers y') -AccountName 'vmctl' | Should -BeNullOrEmpty
    }
}

Describe 'the ACL checks' {
    BeforeAll {
        $script:Full = @('S-1-5-18', 'S-1-5-32-544')
        $script:GoodRules = @((New-Rule 'S-1-5-18' 0x1F01FF), (New-Rule 'S-1-5-32-544' 0x1F01FF), (New-Rule $script:AccountSid 0x1200A9))
    }
    It 'takes exactly SYSTEM, Administrators and the account read-only, owner Administrators' {
        $f = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = $script:GoodRules }
        Test-AclPlan -Facts $f -Full $script:Full -Read @($script:AccountSid) -Owner 'S-1-5-32-544' | Should -BeTrue
    }
    It 'refuses <Why>' -TestCases @(
        @{ Why = 'inherited entries'; Change = { param($f) $f.Protected = $false } },
        @{ Why = 'another owner'; Change = { param($f) $f.Owner = 'S-1-5-21-9' } },
        @{ Why = 'an account that can write'; Change = { param($f) $f.Rules[2].Rights = 0x1301BF } },
        @{ Why = 'another SID'; Change = { param($f) $f.Rules += New-Rule 'S-1-5-11' 0x1200A9 } },
        @{ Why = 'a deny entry'; Change = { param($f) $f.Rules[2].Allow = $false } },
        @{ Why = 'Administrators without full control'; Change = { param($f) $f.Rules[1].Rights = 0x1200A9 } }
    ) {
        $rules = @($script:GoodRules | ForEach-Object { New-Rule $_.Sid $_.Rights })
        $f = [pscustomobject]@{ Owner = 'S-1-5-32-544'; Protected = $true; Rules = $rules }
        & $Change $f
        Test-AclPlan -Facts $f -Full $script:Full -Read @($script:AccountSid) -Owner 'S-1-5-32-544' | Should -BeFalse
    }
    It 'takes a file that only inherits, and refuses one with its own entries' {
        Test-InheritOnly ([pscustomobject]@{ Protected = $false; Rules = @(New-Rule 'S-1-5-18' 0x1F01FF $true) }) | Should -BeTrue
        Test-InheritOnly ([pscustomobject]@{ Protected = $false; Rules = @(New-Rule 'S-1-5-11' 0x1301BF $false) }) | Should -BeFalse
        Test-InheritOnly ([pscustomobject]@{ Protected = $true; Rules = @() }) | Should -BeFalse
    }
}

Describe 'the self-check of the info reply' {
    It 'takes lists that are lists, empty and one-element ones too' {
        Test-InfoLists (ConvertFrom-Json $script:InfoReply).result | Should -BeTrue
    }
    It 'finds a list written as {"value":[...],"Count":n} (Windows PowerShell 5.1)' {
        $bad = $script:InfoReply.Replace('"verbs":["info","list","show","start","stop","restart","console-info"]', '"verbs":{"value":["info"],"Count":1}')
        Test-InfoLists (ConvertFrom-Json $bad).result | Should -BeFalse
        $bad2 = $script:InfoReply.Replace('"versions":[1]', '"versions":1')
        Test-InfoLists (ConvertFrom-Json $bad2).result | Should -BeFalse
    }
}

Describe 'the restart script and the password' {
    It 'is a script that parses, copies the new file in and rolls back' {
        $text = @(New-RestartScriptLines -SetupDir 'C:\ProgramData\haw\setup' -SshdConfig 'C:\ProgramData\ssh\sshd_config') -join "`n"
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
        $text | Should -Match "sshd_config.new"
        $text | Should -Match "sshd_config.before"
        $text | Should -Match 'Restart-Service -Name sshd'
        $text | Should -Match 'ROLLED BACK'
        $text | Should -Match ([regex]::Escape("`$cfg = 'C:\ProgramData\ssh\sshd_config'"))
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
        Copy-Item -LiteralPath $script:VmctlSrc -Destination (Join-Path $script:SrcDir 'vmctl.ps1') -Force
        $script:Hash = Get-Sha256 $script:VmctlSrc
        Set-InstallRoot -Root $script:Root -AccountName 'vmctl'
        [IO.File]::WriteAllText($script:SshdConfig, $script:DefaultSshdText)
        $script:PlanOnly = $false
        $script:Changes = 0
        $script:Failed = 0
        $script:Output.Clear()
        $script:User = $null
        $script:Groups = @('S-1-5-32-545')
        $script:AclGood = $false

        Mock Write-Host { }
        Mock Test-HyperVPresent { $true }
        Mock Get-SshdExe { 'sshd.exe' }
        Mock Get-LocalAccount { $script:User }
        Mock New-HawAccount {
            $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = $script:AccountMarker; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        }
        Mock Set-HawAccountFlags { }
        Mock Get-AccountGroupSids { $script:Groups }
        Mock Add-HyperVAdminMember { $script:Groups += 'S-1-5-32-578' }
        Mock Get-AclFacts {
            if ($script:AclGood) { return (Get-GoodFacts $Path) }
            [pscustomobject]@{ Owner = 'S-1-5-21-9'; Protected = $false; Rules = @(New-Rule 'S-1-5-32-545' 0x1200A9 $false) }
        }
        Mock Set-ExactAcl { }
        Mock Reset-FileAcl { }
        Mock Test-SshdCandidate { [pscustomobject]@{ Ok = $true; Output = '' } }
        Mock Start-SshdRestart { }
        Mock Invoke-VmctlSelfCheck { ConvertFrom-Json $script:InfoReply }
        Mock Test-RestartTask { $true }
        Mock Remove-RestartTask { }
        Mock Remove-HawAccount { $script:User = $null }
    }

    It 'plans only with -WhatIf: WOULD lines, no file, no account, no restart' {
        $script:PlanOnly = $true
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Changes | Should -Be 0
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Test-Path -LiteralPath $script:KeysFile | Should -BeFalse
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
        Should -Invoke New-HawAccount -Times 0
        Should -Invoke Set-ExactAcl -Times 0
        Should -Invoke Start-SshdRestart -Times 0
        Should -Invoke Invoke-VmctlSelfCheck -Times 0
        $text = $script:Output -join "`n"
        $text | Should -Match 'WOULD account vmctl'
        $text | Should -Match 'WOULD folder'
        $text | Should -Match 'WOULD sshd_config'
        $text | Should -Not -Match '(?m)^SET'
    }

    It 'installs everything the first time, and changes nothing the second time' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Should -Invoke New-HawAccount -Times 1 -Exactly
        Should -Invoke Add-HyperVAdminMember -Times 1 -Exactly
        Should -Invoke Set-ExactAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:HawDir -and $Read -contains $script:AccountSid -and $Folder }
        Should -Invoke Set-ExactAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:SetupDir -and @($Read).Count -eq 0 }
        Should -Invoke Set-ExactAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:KeysFile -and @($Read).Count -eq 0 }
        Get-Sha256 $script:VmctlDest | Should -Be $script:Hash
        (Get-VmctlConfig -Path $script:ConfigDest).Problem | Should -BeNullOrEmpty
        [IO.File]::ReadAllText($script:KeysFile) | Should -BeExactly ($script:Key + "`r`n")
        # sshd_config itself is the task's to change; the checked candidate waits for it.
        [IO.File]::ReadAllText($script:SshdConfig) | Should -BeExactly $script:DefaultSshdText
        [IO.File]::ReadAllText($script:Before) | Should -BeExactly $script:DefaultSshdText
        $cand = Split-ConfigText ([IO.File]::ReadAllText($script:Candidate))
        $cand.Newline | Should -Be "`r`n"
        @($cand.Lines | Select-Object -Last 9)[1] | Should -Be 'Match User vmctl'
        @($cand.Lines | Select-Object -Last 9)[3] | Should -Be ('    ForceCommand powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $script:VmctlForcePath)
        Test-Path -LiteralPath $script:RestartScript | Should -BeTrue
        Should -Invoke Test-SshdCandidate -Times 1 -Exactly
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
        ($script:Output -join "`n") | Should -Match 'restarts sshd in about 3 seconds'
        ($script:Output -join "`n") | Should -Match ([regex]::Escape($script:RestartDone))
        ($script:Output -join "`n") | Should -Match 'OK    vmctl check'

        # The task ran; the ACLs are now right.
        Invoke-FakeTask
        $script:AclGood = $true
        $from = $script:Output.Count
        $script:Changes = 0
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Changes | Should -Be 0
        @(Get-Lines $from | Where-Object { $_ -match '^(SET|WOULD)' }) | Should -BeNullOrEmpty
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
        Should -Invoke New-HawAccount -Times 1 -Exactly
    }

    It 'never prints the key file text or a password' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        ($script:Output -join "`n") | Should -Not -Match ([regex]::Escape($script:KeyB64))
    }

    It 'stops before any change when vmctl.ps1 is not the reviewed file' {
        { Invoke-Install -Options (New-Opts -Sha ('0' * 64)) -SourceDir $script:SrcDir } | Should -Throw '*not the reviewed file*'
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Should -Invoke New-HawAccount -Times 0
    }

    It 'stops before the folder when the account is in Administrators' {
        $script:User = [pscustomobject]@{ Name = 'vmctl'; SID = [pscustomobject]@{ Value = $script:AccountSid }; Description = 'someone else''s'; PasswordExpires = $null; UserMayChangePassword = $false; Enabled = $true }
        $script:Groups = @('S-1-5-32-545', 'S-1-5-32-544')
        { Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir } | Should -Throw '*in Administrators*'
        Test-Path -LiteralPath $script:HawDir | Should -BeFalse
        Should -Invoke Add-HyperVAdminMember -Times 0
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

    It 'prints FAIL when the installed vmctl.ps1 finds a config problem' {
        Mock Invoke-VmctlSelfCheck { ConvertFrom-Json ($script:InfoReply.Replace('"configProblem":null', '"configProblem":"protected must be a list of strings"')) }
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        $script:Failed | Should -Be 1
        ($script:Output -join "`n") | Should -Match 'FAIL  vmctl check: vmctl.json: protected must be'
    }

    It 'resets a file in the folder that has its own entries' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Should -Invoke Reset-FileAcl -Times 2 -Exactly
    }

    It 'uninstalls in two runs: sshd first, then the folder and the task' {
        Invoke-Install -Options (New-Opts) -SourceDir $script:SrcDir
        Invoke-FakeTask
        $script:AclGood = $true

        Invoke-Uninstall (New-Opts -Uninstall $true)
        [IO.File]::ReadAllText($script:Candidate) | Should -BeExactly $script:DefaultSshdText
        Should -Invoke Start-SshdRestart -Times 2 -Exactly
        Test-Path -LiteralPath $script:KeysFile | Should -BeFalse
        Test-Path -LiteralPath $script:VmctlDest | Should -BeFalse
        Test-Path -LiteralPath $script:ConfigDest | Should -BeFalse
        Should -Invoke Remove-HawAccount -Times 1 -Exactly
        Test-Path -LiteralPath $script:RestartScript | Should -BeTrue
        ($script:Output -join "`n") | Should -Match 'TODO  last parts'
        Should -Invoke Remove-RestartTask -Times 0

        Invoke-FakeTask
        Invoke-Uninstall (New-Opts -Uninstall $true)
        Should -Invoke Start-SshdRestart -Times 2 -Exactly
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
        Should -Invoke Remove-HawAccount -Times 0
        Should -Invoke Start-SshdRestart -Times 1 -Exactly
    }
}
