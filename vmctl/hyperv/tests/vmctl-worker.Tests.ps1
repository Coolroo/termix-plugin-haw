# Pester 5 tests for vmctl-worker.ps1 (the worker: every check, every verb).
# Requests go through the queue as on a host (a .req file in, a .rep file out). They run on Linux pwsh: the Hyper-V and Windows
# commands are stand-in functions that each test mocks. What only a real
# Hyper-V host proves (the cmdlets' own behaviour, Windows PowerShell 5.1's
# console, sshd) is for the host's own check after install.ps1.

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    $script:Src = Join-Path (Split-Path -Parent $script:Here) 'vmctl-worker.ps1'

    # Stand-ins for the commands that only Windows with Hyper-V has, so that Pester can mock them.
    function global:Get-VM { [CmdletBinding()] param([string[]]$Name) }
    function global:Start-VM { [CmdletBinding(SupportsShouldProcess = $true)] param([object[]]$VM, [string[]]$Name, [switch]$AsJob, [switch]$Passthru) }
    function global:Stop-VM { [CmdletBinding(SupportsShouldProcess = $true)] param([object[]]$VM, [string[]]$Name, [switch]$Force, [switch]$TurnOff, [switch]$Save, [switch]$AsJob, [switch]$Passthru) }
    function global:Restart-VM { [CmdletBinding(SupportsShouldProcess = $true)] param([object[]]$VM, [string[]]$Name, [switch]$Force, [switch]$AsJob, [switch]$Passthru) }
    function global:Resume-VM { [CmdletBinding(SupportsShouldProcess = $true)] param([object[]]$VM, [string[]]$Name, [switch]$AsJob, [switch]$Passthru) }
    function global:Get-VMNetworkAdapter { [CmdletBinding()] param([object[]]$VM) }
    function global:Get-VMHardDiskDrive { [CmdletBinding()] param([object[]]$VM) }
    function global:Get-VHD { [CmdletBinding()] param([string[]]$Path) }
    function global:Get-VMSnapshot { [CmdletBinding()] param([object[]]$VM) }
    function global:Get-VMHost { [CmdletBinding()] param() }
    function global:Get-VMSwitch { [CmdletBinding()] param() }
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { [CmdletBinding()] param([string]$ClassName) }
    }

    . $script:Src

    function script:New-FakeVm {
        param([string]$Name, [string]$State = 'Off', [int]$Cpus = 2, [long]$StartupMB = 4096, [long]$AssignedMB = 0, [int]$UptimeSeconds = 0)
        [pscustomobject]@{
            Name = $Name; Id = [guid]::NewGuid(); State = $State; ProcessorCount = $Cpus
            MemoryStartup = $StartupMB * 1MB; MemoryAssigned = $AssignedMB * 1MB
            Uptime = [timespan]::FromSeconds($UptimeSeconds); Generation = 2; Notes = 'a test VM'; Status = 'Operating normally'
        }
    }
    function script:Set-Config {
        param([string]$Text)
        [IO.File]::WriteAllText($script:Cfg, $Text)
    }
    # One request through the whole path (JSON in, JSON out). The raw line is in $script:Json.
    function script:Send {
        param([string]$Verb, [hashtable]$Arguments = @{}, [string]$Config = $script:Cfg)
        $line = ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{ haw = 'vmctl'; v = 1; id = 't-1'; verb = $Verb; args = $Arguments })
        return (Send-Line $line $Config)
    }
    # As the front does it: the line in queue\<guid>.req, the worker, then queue\<guid>.rep.
    function script:Send-Line {
        param([string]$Line, [string]$Config = $script:Cfg)
        $job = [guid]::NewGuid().ToString()
        [IO.File]::WriteAllText((Join-Path $script:Queue ($job + '.req')), $Line + "`n")
        Invoke-WorkerJob -Job $job -QueueDir $script:Queue -ConfigPath $Config | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Queue ($job + '.req')) | Should -BeFalse
        $text = [IO.File]::ReadAllText((Join-Path $script:Queue ($job + '.rep')))
        $text | Should -Match "^[^`n]*`n\z"
        $script:Json = $text.TrimEnd("`n")
        return (ConvertFrom-Json -InputObject $script:Json)
    }
    $script:GoodConfig = '{"namePattern":"^[a-z][a-z0-9-]{0,62}$","protected":["build-*","Lab-?","lit[1]"],"ceilings":{"cpus":16,"memoryMB":16384,"diskGB":500},"console":{"host":"hv1.example.lan","port":2179}}'
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
    It 'names no host, address or domain of a real network' {
        $text = Get-Content -Raw $script:Src
        $text | Should -Not -Match '\b(?:10|172|192)\.\d+\.\d+\.\d+\b'
    }
}

Describe 'vmctl-worker.ps1' {
    BeforeEach {
        $script:Cfg = Join-Path $TestDrive 'vmctl.json'
        $script:Queue = Join-Path $TestDrive 'queue'
        $null = New-Item -ItemType Directory -Path $script:Queue -Force
        Set-Config $script:GoodConfig
        $script:FakeVms = @(
            (New-FakeVm 'web-2' 'Running' 2 2048 3072 3600),
            (New-FakeVm 'web-1' 'Off' 2 4096),
            (New-FakeVm 'build-1' 'Running' 4 8192 8192 60),
            (New-FakeVm 'Big-VM' 'Off' 8 16384),
            (New-FakeVm 'lab-3' 'Running' 1 1024 1024 10)
        )
        $script:Adapters = @{
            'web-1' = @([pscustomobject]@{ IPAddresses = @('192.0.2.10', 'fe80::215:5dff:fe01:203'); SwitchName = 'LAN'; MacAddress = '00155D010203' })
            'web-2' = @([pscustomobject]@{ IPAddresses = @('192.0.2.11', '2001:db8::11'); SwitchName = 'LAN'; MacAddress = '00155D010204' },
                [pscustomobject]@{ IPAddresses = @(); SwitchName = $null; MacAddress = '00155D010205' })
        }
        Mock Get-VM { $script:FakeVms }
        Mock Get-VMNetworkAdapter { $a = $script:Adapters[[string]$VM[0].Name]; if ($a) { $a } }
        Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = 'C:\vms\disk.vhdx' } }
        Mock Get-VHD { [pscustomobject]@{ Size = 40GB; FileSize = 12.5GB } }
        Mock Get-VMSnapshot { [pscustomobject]@{ Name = 'a' }; [pscustomobject]@{ Name = 'b' } }
        Mock Get-VMHost { [pscustomobject]@{ LogicalProcessorCount = 16; MemoryCapacity = 64GB } }
        Mock Get-CimInstance { [pscustomobject]@{ FreePhysicalMemory = 20971520 } }
        Mock Get-PSDrive { [pscustomobject]@{ Name = 'C'; Used = 520GB; Free = 410GB }; [pscustomobject]@{ Name = 'E'; Used = $null; Free = $null } }
        Mock Get-VMSwitch { [pscustomobject]@{ Name = 'LAN'; SwitchType = 'External' } }
        Mock Start-VM { $VM[0].State = 'Running'; $VM[0].MemoryAssigned = $VM[0].MemoryStartup }
        Mock Stop-VM { $VM[0].State = 'Off'; [pscustomobject]@{ Kind = 'job' } }
        Mock Restart-VM { }
        Mock Resume-VM { $VM[0].State = 'Running' }
        Mock Wait-VmJob { [pscustomobject]@{ Done = $true; Error = $null } }
        Mock Write-VmctlLog { }
    }

    Context 'the request' {
        It 'refuses text that is not JSON, with id null' {
            $r = Send-Line 'this is not json'
            $r.ok | Should -BeFalse
            $r.error.code | Should -Be 'bad-request'
            $r.id | Should -BeNullOrEmpty
            $script:Json | Should -Match '"id":null'
        }
        It 'refuses JSON that is not an object' {
            (Send-Line '[1,2]').error.code | Should -Be 'bad-request'
            (Send-Line '"list"').error.code | Should -Be 'bad-request'
            (Send-Line 'null').error.code | Should -Be 'bad-request'
        }
        It 'refuses a missing or wrong haw, and echoes a good id' {
            $r = Send-Line '{"v":1,"id":"abc-1","verb":"list","args":{}}'
            $r.error.code | Should -Be 'bad-request'
            $r.id | Should -Be 'abc-1'
            (Send-Line '{"haw":"other","v":1,"id":"abc-1","verb":"list","args":{}}').error.code | Should -Be 'bad-request'
            (Send-Line '{"haw":"VMCTL","v":1,"id":"abc-1","verb":"list","args":{}}').error.code | Should -Be 'bad-request'
        }
        It 'refuses a missing or bad id, and answers with id null' -TestCases @(
            @{ Id = $null }, @{ Id = '' }, @{ Id = 'has space' }, @{ Id = 'a_b' }, @{ Id = ('x' * 65) }, @{ Id = 5 }
        ) {
            $req = [ordered]@{ haw = 'vmctl'; v = 1; verb = 'list'; args = @{} }
            if ($null -ne $Id) { $req['id'] = $Id }
            $r = Send-Line (ConvertTo-Json -Compress -InputObject $req)
            $r.error.code | Should -Be 'bad-request'
            $script:Json | Should -Match '"id":null'
        }
        It 'takes an id of 64 characters' {
            (Send-Line ('{"haw":"vmctl","v":1,"id":"' + ('a' * 64) + '","verb":"list","args":{}}')).ok | Should -BeTrue
        }
        It 'refuses a v that is not an integer' -TestCases @(@{ V = '"1"' }, @{ V = '1.5' }, @{ V = 'true' }, @{ V = 'null' }) {
            (Send-Line ('{"haw":"vmctl","v":' + $V + ',"id":"a","verb":"list","args":{}}')).error.code | Should -Be 'bad-request'
        }
        It 'answers another v with code version and the versions it speaks' {
            $r = Send-Line '{"haw":"vmctl","v":2,"id":"a","verb":"list","args":{},"future":true}'
            $r.error.code | Should -Be 'version'
            $r.v | Should -Be 1
            $r.id | Should -Be 'a'
            $script:Json | Should -Match '"versions":\[1\]'
        }
        It 'refuses an unknown field' {
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","verb":"list","args":{},"extra":1}').error.code | Should -Be 'bad-request'
        }
        It 'refuses a missing or wrong verb or args' {
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","args":{}}').error.code | Should -Be 'bad-request'
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","verb":7,"args":{}}').error.code | Should -Be 'bad-request'
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","verb":"list"}').error.code | Should -Be 'bad-request'
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","verb":"list","args":[]}').error.code | Should -Be 'bad-request'
            (Send-Line '{"haw":"vmctl","v":1,"id":"a","verb":"list","args":"x"}').error.code | Should -Be 'bad-request'
        }
        It 'answers unknown-verb for a verb that is not in the protocol' {
            (Send 'format-disk').error.code | Should -Be 'unknown-verb'
            (Send 'LIST').error.code | Should -Be 'unknown-verb'
        }
        It 'answers not-in-this-version for <Verb>, whatever its args' -TestCases @(
            @{ Verb = 'create' }, @{ Verb = 'delete' }, @{ Verb = 'snapshot' }, @{ Verb = 'restore' }, @{ Verb = 'users' }
        ) {
            $r = Send $Verb @{ name = 'web-1'; anything = 1 }
            $r.error.code | Should -Be 'not-in-this-version'
            Should -Invoke Get-VM -Times 0
        }
        It 'refuses an unknown argument' {
            (Send 'list' @{ all = $true }).error.code | Should -Be 'bad-request'
            (Send 'show' @{ name = 'web-1'; deep = $true }).error.code | Should -Be 'bad-request'
            (Send 'show' @{ Name = 'web-1' }).error.code | Should -Be 'bad-request'
        }
        It 'refuses an argument of the wrong type' {
            (Send 'show' @{ name = 5 }).error.code | Should -Be 'bad-request'
            (Send 'stop' @{ name = 'web-2'; force = 'yes' }).error.code | Should -Be 'bad-request'
            (Send 'stop' @{ name = 'web-2'; force = 1 }).error.code | Should -Be 'bad-request'
            Should -Invoke Stop-VM -Times 0
        }
        It 'refuses a missing name' {
            (Send 'show').error.code | Should -Be 'bad-request'
            (Send 'start' @{ name = '' }).error.code | Should -Be 'bad-request'
        }
        It 'refuses the name <Name> before it asks Hyper-V anything' -TestCases @(
            @{ Name = 'web-*' }, @{ Name = 'web-?' }, @{ Name = 'web-[1]' }, @{ Name = '*' }, @{ Name = 'a`b' }, @{ Name = "web-1`n" }
        ) {
            foreach ($verb in 'show', 'start', 'stop', 'restart', 'resume', 'console-info') {
                (Send $verb @{ name = $Name }).error.code | Should -Be 'bad-request'
            }
            Should -Invoke Get-VM -Times 0
        }
        It 'never gives Get-VM a -Name' {
            $null = Send 'show' @{ name = 'web-1' }
            $null = Send 'start' @{ name = 'web-1' }
            Should -Invoke Get-VM -ParameterFilter { $PSBoundParameters.ContainsKey('Name') } -Times 0
        }
    }

    Context 'reading the request line' {
        It 'reads up to the first newline, without CR and BOM' {
            $bytes = [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("{`"a`":1}`r`nmore after the line")
            $r = Read-RequestLine -Stream (New-Object IO.MemoryStream(, $bytes))
            $r.Problem | Should -BeNullOrEmpty
            $r.Text | Should -BeExactly '{"a":1}'
        }
        It 'takes a line without a newline at the end of input' {
            (Read-RequestLine -Stream (New-Object IO.MemoryStream(, [Text.Encoding]::UTF8.GetBytes('{}')))).Text | Should -Be '{}'
        }
        It 'refuses an empty request' {
            (Read-RequestLine -Stream (New-Object IO.MemoryStream(, [byte[]]@(10)))).Problem | Should -Match 'empty'
        }
        It 'refuses a request longer than 64 KB, and takes one of 64 KB' {
            $big = [Text.Encoding]::ASCII.GetBytes(('x' * 65537) + "`n")
            (Read-RequestLine -Stream (New-Object IO.MemoryStream(, $big))).Problem | Should -Match '64 KB'
            $ok = [Text.Encoding]::ASCII.GetBytes(('x' * 65536) + "`n")
            (Read-RequestLine -Stream (New-Object IO.MemoryStream(, $ok))).Problem | Should -BeNullOrEmpty
        }
        It 'refuses bytes that are not UTF-8' {
            (Read-RequestLine -Stream (New-Object IO.MemoryStream(, [byte[]](0x7B, 0xFF, 0x7D, 10)))).Problem | Should -Match 'UTF-8'
        }
        It 'turns a read problem into bad-request' {
            $r = ConvertFrom-Json (Get-VmctlReplyJson -Line $null -ReadProblem 'the request is longer than 64 KB' -ConfigPath $script:Cfg)
            $r.error.code | Should -Be 'bad-request'
        }
    }

    Context 'the config file' {
        It 'answers info with configProblem and every other verb with config when the file is missing' {
            $missing = Join-Path $TestDrive 'none.json'
            $r = Send 'info' -Config $missing
            $r.ok | Should -BeTrue
            $r.result.configProblem | Should -Match 'missing'
            $r.result.limits | Should -BeNullOrEmpty
            foreach ($verb in 'list', 'show', 'start', 'stop', 'restart', 'resume', 'console-info') {
                $a = @{}
                if ($verb -ne 'list') { $a = @{ name = 'web-1' } }
                (Send $verb $a -Config $missing).error.code | Should -Be 'config'
            }
            Should -Invoke Start-VM -Times 0
            Should -Invoke Stop-VM -Times 0
            Should -Invoke Resume-VM -Times 0
        }
        It 'finds the problem in <Why>' -TestCases @(
            @{ Why = 'text that is not JSON'; Text = 'namePattern = x' },
            @{ Why = 'a list at the top'; Text = '[]' },
            @{ Why = 'an unknown field'; Text = '{"protect":["build-*"]}' },
            @{ Why = 'a pattern that does not compile'; Text = '{"namePattern":"([a-z"}' },
            @{ Why = 'an empty pattern'; Text = '{"namePattern":""}' },
            @{ Why = 'protected as one string'; Text = '{"protected":"build-*"}' },
            @{ Why = 'protected with a number'; Text = '{"protected":["a",1]}' },
            @{ Why = 'a ceiling of 0'; Text = '{"ceilings":{"cpus":0}}' },
            @{ Why = 'a ceiling as text'; Text = '{"ceilings":{"memoryMB":"8G"}}' },
            @{ Why = 'an unknown ceiling'; Text = '{"ceilings":{"gpus":1}}' },
            @{ Why = 'console port 0'; Text = '{"console":{"port":0}}' },
            @{ Why = 'console host with a space'; Text = '{"console":{"host":"hv 1"}}' }
        ) {
            Set-Config $Text
            (Send 'info').result.configProblem | Should -Not -BeNullOrEmpty
            (Send 'list').error.code | Should -Be 'config'
        }
        It 'takes the defaults for what an empty object leaves out' {
            Set-Config '{}'
            $r = Send 'info'
            $r.result.configProblem | Should -BeNullOrEmpty
            $r.result.limits.namePattern | Should -BeExactly '^[a-z][a-z0-9-]{0,62}$'
            $script:Json | Should -Match '"protected":\[\]'
            $script:Json | Should -Match '"ceilings":\{\}'
            $c = (Send 'console-info' @{ name = 'web-1' }).result.console
            $c.host | Should -Be ([Environment]::MachineName)
            $c.port | Should -Be 2179
        }
        It 'reads the example config without a problem' {
            $example = Join-Path (Split-Path -Parent $script:Here) 'vmctl.example.json'
            (Send 'info' -Config $example).result.configProblem | Should -BeNullOrEmpty
        }
    }

    Context 'info' {
        It 'gives host, backend, protocol, capacity, networks, verbs and limits' {
            $r = (Send 'info').result
            $r.host.name | Should -Be ([Environment]::MachineName)
            $r.backend.kind | Should -Be 'hyper-v'
            $r.backend.version | Should -Be '1.1.0'
            $r.capacity.cpus | Should -Be 16
            $r.capacity.memoryMB | Should -Be 65536
            $r.capacity.freeMemoryMB | Should -Be 20480
            $r.capacity.disks[0].name | Should -Be 'C:'
            $r.capacity.disks[0].sizeGB | Should -Be 930
            $r.capacity.disks[0].freeGB | Should -Be 410
            $r.networks[0].kind | Should -BeExactly 'external'
            $r.limits.ceilings.memoryMB | Should -Be 16384
            $r.configProblem | Should -BeNullOrEmpty
            $script:Json | Should -Match '"configProblem":null'
            ($r.verbs -join ',') | Should -Be 'info,list,show,start,stop,restart,resume,console-info'
        }
        It 'keeps one-element lists as lists' {
            $null = Send 'info'
            $script:Json | Should -Match '"versions":\[1\]'
            $script:Json | Should -Match '"disks":\[\{"name":"C:"'
            $script:Json | Should -Match '"networks":\[\{"name":"LAN"'
        }
        It 'gives empty lists as lists' {
            Mock Get-VMSwitch { }
            Mock Get-PSDrive { }
            $null = Send 'info'
            $script:Json | Should -Match '"networks":\[\]'
            $script:Json | Should -Match '"disks":\[\]'
        }
    }

    Context 'list' {
        It 'gives every VM, sorted by name, with the protocol fields' {
            $vms = @((Send 'list').result.vms)
            ($vms | ForEach-Object { $_.name }) -join ',' | Should -Be 'Big-VM,build-1,lab-3,web-1,web-2'
            $w2 = $vms | Where-Object { $_.name -eq 'web-2' }
            $w2.state | Should -Be 'running'
            $w2.cpus | Should -Be 2
            $w2.memoryMB | Should -Be 3072
            $w2.uptimeSeconds | Should -Be 3600
            $w2.id | Should -Match '^[0-9a-f-]{36}$'
            $w1 = $vms | Where-Object { $_.name -eq 'web-1' }
            $w1.memoryMB | Should -Be 4096
            $w1.state | Should -Be 'off'
        }
        It 'gives Hyper-V''s status and marks a critical state (Paused-Critical)' {
            $w2 = $script:FakeVms | Where-Object { $_.Name -eq 'web-2' }
            $w2.State = 'PausedCritical'
            $w2.Status = 'Paused-Critical'
            $vms = @((Send 'list').result.vms)
            $v = $vms | Where-Object { $_.name -eq 'web-2' }
            $v.state | Should -BeExactly 'paused'
            $v.critical | Should -BeTrue
            $v.status | Should -BeExactly 'Paused-Critical'
            $w1 = $vms | Where-Object { $_.name -eq 'web-1' }
            $w1.critical | Should -BeFalse
            $w1.status | Should -BeExactly 'Operating normally'
            $script:Json | Should -Match '"name":"web-1"[^}]*"status":"Operating normally","critical":false'
        }
        It 'marks a VM critical by its status alone, and gives an empty status as ""' {
            $w2 = $script:FakeVms | Where-Object { $_.Name -eq 'web-2' }
            $w2.State = 'Paused'
            $w2.Status = 'Paused-Critical'
            ($script:FakeVms | Where-Object { $_.Name -eq 'web-1' }).Status = $null
            $vms = @((Send 'list').result.vms)
            ($vms | Where-Object { $_.name -eq 'web-2' }).critical | Should -BeTrue
            $script:Json | Should -Match '"name":"web-1"[^}]*"status":"","critical":false'
        }
        It 'marks names outside the pattern and protected names (wildcards, no case)' {
            $vms = @((Send 'list').result.vms)
            ($vms | Where-Object { $_.name -eq 'Big-VM' }).allowed | Should -BeFalse
            ($vms | Where-Object { $_.name -eq 'web-1' }).allowed | Should -BeTrue
            ($vms | Where-Object { $_.name -eq 'build-1' }).protected | Should -BeTrue
            ($vms | Where-Object { $_.name -eq 'lab-3' }).protected | Should -BeTrue
            ($vms | Where-Object { $_.name -eq 'web-2' }).protected | Should -BeFalse
        }
        It 'leaves out link-local addresses and keeps one address a list' {
            $null = Send 'list'
            $script:Json | Should -Match '"name":"web-1"[^}]*"addresses":\["192\.0\.2\.10"\]'
            $script:Json | Should -Match '"name":"web-2"[^}]*"addresses":\["192\.0\.2\.11","2001:db8::11"\]'
            $script:Json | Should -Match '"name":"build-1"[^}]*"addresses":\[\]'
        }
        It 'gives an empty list and a one-VM list as lists' {
            $script:FakeVms = @()
            $null = Send 'list'
            $script:Json | Should -Match '"vms":\[\]'
            $script:FakeVms = @(New-FakeVm 'web-1')
            $null = Send 'list'
            $script:Json | Should -Match '"vms":\[\{"name":"web-1"'
        }
        It 'maps each Hyper-V state' -TestCases @(
            @{ S = 'Running'; W = 'running' }, @{ S = 'Off'; W = 'off' }, @{ S = 'Paused'; W = 'paused' }, @{ S = 'Saved'; W = 'saved' },
            @{ S = 'Starting'; W = 'starting' }, @{ S = 'Stopping'; W = 'stopping' }, @{ S = 'Saving'; W = 'other' }, @{ S = 'RunningCritical'; W = 'running' },
            @{ S = 'PausedCritical'; W = 'paused' }, @{ S = 'OffCritical'; W = 'off' }, @{ S = 'Critical'; W = 'other' }
        ) {
            ConvertTo-VmState $S | Should -BeExactly $W
        }
    }

    Context 'show' {
        It 'gives the VM with generation, disks, networks, checkpoints and notes' {
            $vm = (Send 'show' @{ name = 'web-2' }).result.vm
            $vm.name | Should -Be 'web-2'
            $vm.generation | Should -Be 2
            $vm.disks[0].sizeGB | Should -Be 40
            $vm.disks[0].usedGB | Should -Be 12.5
            $vm.checkpoints | Should -Be 2
            $vm.notes | Should -Be 'a test VM'
            $vm.networks[0].switch | Should -Be 'LAN'
            $vm.networks[0].mac | Should -BeExactly '00:15:5d:01:02:04'
            $vm.networks[1].switch | Should -Be ''
            $script:Json | Should -Match '"disks":\[\{"sizeGB":40'
            $script:Json | Should -Match '"mac":"00:15:5d:01:02:05","addresses":\[\]'
        }
        It 'gives the drive of the first disk file with its free space' {
            Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = $null }; [pscustomobject]@{ Path = 'D:\Hyper-V\web-2.vhdx' }; [pscustomobject]@{ Path = 'C:\vms\b.vhdx' } }
            Mock Get-PSDrive { [pscustomobject]@{ Name = 'C'; Used = 520GB; Free = 410GB }; [pscustomobject]@{ Name = 'D'; Used = 927.5GB; Free = 3.2GB } }
            $vm = (Send 'show' @{ name = 'web-2' }).result.vm
            $vm.drive.name | Should -BeExactly 'D:'
            $vm.drive.freeGB | Should -Be 3.2
            $vm.drive.sizeGB | Should -Be 930.7
            Should -Invoke Get-PSDrive -Times 1 -ParameterFilter { $Name -eq 'D' }
        }
        It 'gives drive null for a disk on a share, no disk, or a drive Windows does not measure' {
            Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = '\\files\vms\web-2.vhdx' } }
            $null = Send 'show' @{ name = 'web-2' }
            $script:Json | Should -Match '"drive":null'
            Mock Get-VMHardDiskDrive { }
            $null = Send 'show' @{ name = 'web-2' }
            $script:Json | Should -Match '"drive":null'
            Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = 'E:\web-2.vhdx' } }
            (Send 'show' @{ name = 'web-2' }).ok | Should -BeTrue
            $script:Json | Should -Match '"drive":null'
            Mock Get-PSDrive { throw 'no such drive' }
            (Send 'show' @{ name = 'web-2' }).ok | Should -BeTrue
            $script:Json | Should -Match '"drive":null'
        }
        It 'gives sizeGB null when Get-VHD fails, and still answers' {
            Mock Get-VHD { throw 'access denied' }
            $r = Send 'show' @{ name = 'web-1' }
            $r.ok | Should -BeTrue
            $script:Json | Should -Match '"disks":\[\{"sizeGB":null,"usedGB":null\}\]'
        }
        It 'gives an empty disk list as a list' {
            Mock Get-VMHardDiskDrive { }
            $null = Send 'show' @{ name = 'web-1' }
            $script:Json | Should -Match '"disks":\[\]'
        }
        It 'answers not-found for a name no VM has, and looks names up with their case' {
            (Send 'show' @{ name = 'web-9' }).error.code | Should -Be 'not-found'
            (Send 'show' @{ name = 'big-vm' }).error.code | Should -Be 'not-found'
        }
        It 'refuses two VMs of one name' {
            $script:FakeVms += New-FakeVm 'web-1'
            $r = Send 'show' @{ name = 'web-1' }
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Match 'more than one'
        }
    }

    Context 'start' {
        It 'starts an off VM with the VM object from Get-VM' {
            $r = Send 'start' @{ name = 'web-1' }
            $r.ok | Should -BeTrue
            $r.result.vm.state | Should -Be 'running'
            Should -Invoke Start-VM -Times 1 -ParameterFilter { $VM[0].Name -ceq 'web-1' -and -not $PSBoundParameters.ContainsKey('Name') }
        }
        It 'starts a saved VM' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'web-1' }).State = 'Saved'
            (Send 'start' @{ name = 'web-1' }).ok | Should -BeTrue
        }
        It 'refuses a VM that runs (wrong-state)' {
            (Send 'start' @{ name = 'web-2' }).error.code | Should -Be 'wrong-state'
            Should -Invoke Start-VM -Times 0
        }
        It 'refuses a paused VM and says to resume it' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'web-2' }).State = 'PausedCritical'
            $r = Send 'start' @{ name = 'web-2' }
            $r.error.code | Should -Be 'wrong-state'
            $r.error.message | Should -Match 'resume it instead'
            Should -Invoke Start-VM -Times 0
        }
        It 'refuses a name outside the pattern' {
            (Send 'start' @{ name = 'Big-VM' }).error.code | Should -Be 'name-not-allowed'
            Should -Invoke Start-VM -Times 0
        }
        It 'starts a protected VM' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'build-1' }).State = 'Off'
            (Send 'start' @{ name = 'build-1' }).ok | Should -BeTrue
        }
        It 'answers not-found for a name no VM has' {
            (Send 'start' @{ name = 'web-9' }).error.code | Should -Be 'not-found'
        }
        It 'starts when the running VMs reach the ceiling exactly' {
            # Running: 7 CPUs, 12288 MB; web-1 takes 2 CPUs, 4096 MB; ceilings 16 and 16384.
            (Send 'start' @{ name = 'web-1' }).ok | Should -BeTrue
        }
        It 'refuses to go past the CPU ceiling' {
            Set-Config '{"ceilings":{"cpus":8}}'
            $r = Send 'start' @{ name = 'web-1' }
            $r.error.code | Should -Be 'ceiling'
            $r.error.message | Should -Match '9 CPUs'
            Should -Invoke Start-VM -Times 0
        }
        It 'refuses to go past the memory ceiling' {
            Set-Config '{"ceilings":{"memoryMB":16000}}'
            (Send 'start' @{ name = 'web-1' }).error.code | Should -Be 'ceiling'
            Should -Invoke Start-VM -Times 0
        }
        It 'counts paused VMs and leaves saved and off VMs out' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'web-2' }).State = 'Paused'
            ($script:FakeVms | Where-Object { $_.Name -eq 'build-1' }).State = 'Saved'
            Set-Config '{"ceilings":{"cpus":5}}'
            # Paused web-2 (2) + lab-3 (1) + web-1 (2) = 5.
            (Send 'start' @{ name = 'web-1' }).ok | Should -BeTrue
        }
        It 'turns a Hyper-V failure into backend, one line, no stack trace' {
            Mock Start-VM { throw "The virtual machine could not be started.`r`nNot enough memory." }
            $r = Send 'start' @{ name = 'web-1' }
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Be 'The virtual machine could not be started. Not enough memory.'
            $script:Json | Should -Not -Match 'at line|ScriptStackTrace|\.ps1'
        }
    }

    Context 'stop' {
        It 'asks the guest to shut down by default' {
            $r = Send 'stop' @{ name = 'web-2' }
            $r.ok | Should -BeTrue
            $r.result.vm.state | Should -Be 'off'
            Should -Invoke Stop-VM -Times 1 -ParameterFilter { $Force -and $AsJob -and -not $TurnOff -and $VM[0].Name -ceq 'web-2' }
        }
        It 'turns the VM off with force' {
            (Send 'stop' @{ name = 'web-2'; force = $true }).ok | Should -BeTrue
            Should -Invoke Stop-VM -Times 1 -ParameterFilter { $TurnOff -and -not $AsJob }
        }
        It 'answers ok with the state of the moment when the guest takes longer' {
            Mock Stop-VM { [pscustomobject]@{ Kind = 'job' } }
            Mock Wait-VmJob { [pscustomobject]@{ Done = $false; Error = $null } }
            $r = Send 'stop' @{ name = 'web-2' }
            $r.ok | Should -BeTrue
            $r.result.vm.state | Should -Be 'running'
        }
        It 'turns a failed guest shutdown into backend' {
            Mock Wait-VmJob { [pscustomobject]@{ Done = $true; Error = 'the shutdown service is not running' } }
            $r = Send 'stop' @{ name = 'web-2' }
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Match 'shutdown service'
        }
        It 'refuses an off VM (wrong-state), also with force' {
            (Send 'stop' @{ name = 'web-1' }).error.code | Should -Be 'wrong-state'
            (Send 'stop' @{ name = 'web-1'; force = $true }).error.code | Should -Be 'wrong-state'
            Should -Invoke Stop-VM -Times 0
        }
        It 'refuses a protected VM: <Name>' -TestCases @(@{ Name = 'build-1' }, @{ Name = 'lab-3' }) {
            $r = Send 'stop' @{ name = $Name; force = $true }
            $r.error.code | Should -Be 'protected'
            Should -Invoke Stop-VM -Times 0
        }
        It 'refuses a name outside the pattern' {
            (Send 'stop' @{ name = 'Big-VM' }).error.code | Should -Be 'name-not-allowed'
        }
    }

    Context 'restart' {
        It 'shuts the guest down, then starts it, by default' {
            $r = Send 'restart' @{ name = 'web-2' }
            $r.ok | Should -BeTrue
            $r.result.vm.state | Should -Be 'running'
            Should -Invoke Stop-VM -Times 1 -ParameterFilter { $Force -and $AsJob -and -not $TurnOff }
            Should -Invoke Start-VM -Times 1
            Should -Invoke Restart-VM -Times 0
        }
        It 'resets with force' {
            (Send 'restart' @{ name = 'web-2'; force = $true }).ok | Should -BeTrue
            Should -Invoke Restart-VM -Times 1 -ParameterFilter { $Force -and $VM[0].Name -ceq 'web-2' }
            Should -Invoke Stop-VM -Times 0
        }
        It 'answers backend and does not start when the guest takes too long' {
            Mock Stop-VM { [pscustomobject]@{ Kind = 'job' } }
            Mock Wait-VmJob { [pscustomobject]@{ Done = $false; Error = $null } }
            (Send 'restart' @{ name = 'web-2' }).error.code | Should -Be 'backend'
            Should -Invoke Start-VM -Times 0
        }
        It 'refuses an off VM and a protected VM' {
            (Send 'restart' @{ name = 'web-1' }).error.code | Should -Be 'wrong-state'
            (Send 'restart' @{ name = 'build-1' }).error.code | Should -Be 'protected'
            Should -Invoke Restart-VM -Times 0
        }
    }

    Context 'resume' {
        BeforeEach {
            $script:Paused = $script:FakeVms | Where-Object { $_.Name -eq 'web-2' }
            $script:Paused.State = 'PausedCritical'
            $script:Paused.Status = 'Paused-Critical'
            Mock Resume-VM { $VM[0].State = 'Running'; $VM[0].Status = 'Operating normally' }
        }
        It 'resumes a paused VM with the VM object from Get-VM' {
            $r = Send 'resume' @{ name = 'web-2' }
            $r.ok | Should -BeTrue
            $r.result.vm.state | Should -Be 'running'
            $r.result.vm.critical | Should -BeFalse
            Should -Invoke Resume-VM -Times 1 -ParameterFilter { $VM[0].Name -ceq 'web-2' -and -not $PSBoundParameters.ContainsKey('Name') }
        }
        It 'resumes a protected VM, as start does' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'build-1' }).State = 'Paused'
            (Send 'resume' @{ name = 'build-1' }).ok | Should -BeTrue
            Should -Invoke Resume-VM -Times 1
        }
        It 'checks no ceiling: a paused VM holds its CPUs and memory already' {
            Set-Config '{"ceilings":{"cpus":2}}'
            (Send 'resume' @{ name = 'web-2' }).ok | Should -BeTrue
        }
        It 'refuses a VM that is not paused (wrong-state): <Why>' -TestCases @(
            @{ Why = 'running'; Name = 'lab-3'; Hint = 'resume needs it paused$' },
            @{ Why = 'off'; Name = 'web-1'; Hint = 'start it instead' }
        ) {
            $r = Send 'resume' @{ name = $Name }
            $r.error.code | Should -Be 'wrong-state'
            $r.error.message | Should -Match $Hint
            Should -Invoke Resume-VM -Times 0
        }
        It 'refuses a name outside the pattern, and a name no VM has' {
            ($script:FakeVms | Where-Object { $_.Name -eq 'Big-VM' }).State = 'Paused'
            (Send 'resume' @{ name = 'Big-VM' }).error.code | Should -Be 'name-not-allowed'
            (Send 'resume' @{ name = 'web-9' }).error.code | Should -Be 'not-found'
            Should -Invoke Resume-VM -Times 0
        }
        It 'refuses an unknown argument' {
            (Send 'resume' @{ name = 'web-2'; force = $true }).error.code | Should -Be 'bad-request'
            Should -Invoke Resume-VM -Times 0
        }
        It 'answers backend with the free space when Hyper-V pauses the VM again' {
            Mock Resume-VM { }
            Mock Get-VMHardDiskDrive { [pscustomobject]@{ Path = 'D:\Hyper-V\web-2.vhdx' } }
            Mock Get-PSDrive { [pscustomobject]@{ Name = 'D'; Used = 927.5GB; Free = 0.4GB } }
            $r = Send 'resume' @{ name = 'web-2' }
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Match 'paused again \(critical\)'
            $r.error.message | Should -Match 'D: has 0\.4 GB free'
            $r.error.message | Should -Match 'Free space first'
        }
        It 'turns a Hyper-V failure into backend' {
            Mock Resume-VM { throw 'The operation cannot be performed while the object is in its current state.' }
            $r = Send 'resume' @{ name = 'web-2' }
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Match 'current state'
        }
    }

    Context 'console-info' {
        It 'gives the console name and port from the config and the VM id' {
            $vm = $script:FakeVms | Where-Object { $_.Name -eq 'web-1' }
            $c = (Send 'console-info' @{ name = 'web-1' }).result.console
            $c.kind | Should -Be 'vmconnect'
            $c.host | Should -Be 'hv1.example.lan'
            $c.port | Should -Be 2179
            $c.vmId | Should -BeExactly ([string]$vm.Id).ToLowerInvariant()
        }
        It 'refuses a name outside the pattern' {
            (Send 'console-info' @{ name = 'Big-VM' }).error.code | Should -Be 'name-not-allowed'
        }
    }

    Context 'protect patterns' {
        It 'matches * and ? without case, and takes [ ] as they are' {
            Test-NameProtected 'build-7' @('BUILD-*') | Should -BeTrue
            Test-NameProtected 'lab-3' @('Lab-?') | Should -BeTrue
            Test-NameProtected 'lab-33' @('lab-?') | Should -BeFalse
            Test-NameProtected 'lit[1]' @('lit[1]') | Should -BeTrue
            Test-NameProtected 'lit1' @('lit[1]') | Should -BeFalse
            Test-NameProtected 'web-1' @() | Should -BeFalse
        }
    }

    Context 'the reply' {
        It 'is one line, with haw, v, id and ok' {
            foreach ($verb in 'info', 'list') {
                $null = Send $verb
                $script:Json | Should -Not -Match "[`r`n]"
                $script:Json | Should -Match '^\{"haw":"vmctl","v":1,"id":"t-1","ok":true,"result":'
            }
        }
        It 'turns any failure into backend' {
            Mock Get-VM { throw 'Hyper-V is not running' }
            $r = Send 'list'
            $r.error.code | Should -Be 'backend'
            $r.error.message | Should -Be 'Hyper-V is not running'
        }
    }
}


Describe 'vmctl-worker.ps1 and the queue' {
    BeforeEach {
        $script:Cfg = Join-Path $TestDrive 'vmctl.json'
        Set-Config '{}'
        $script:Queue = Join-Path $TestDrive ('q-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $script:Queue -Force
        $script:Job = [guid]::NewGuid().ToString()
        $script:Req = Join-Path $script:Queue ($script:Job + '.req')
        $script:Rep = Join-Path $script:Queue ($script:Job + '.rep')
        Mock Write-VmctlLog { }
    }
    It 'refuses a job that is not a GUID in lower case, and touches no file: <Bad>' -TestCases @(
        @{ Bad = '' }, @{ Bad = 'x' }, @{ Bad = '..\vmctl' }, @{ Bad = '../vmctl' }, @{ Bad = 'C:\Windows\x' },
        @{ Bad = '8D1C3A8E-9A51-4C47-8A0D-5D0F5B3E7D10' }, @{ Bad = '{8d1c3a8e-9a51-4c47-8a0d-5d0f5b3e7d10}' },
        @{ Bad = '8d1c3a8e9a514c478a0d5d0f5b3e7d10' }, @{ Bad = "8d1c3a8e-9a51-4c47-8a0d-5d0f5b3e7d10`n" }, @{ Bad = '8d1c3a8e-9a51-4c47-8a0d-5d0f5b3e7d10 -ConfigPath x' }
    ) {
        [IO.File]::WriteAllText($script:Req, '{"haw":"vmctl"}' + "`n")
        Invoke-WorkerJob -Job $Bad -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Queue).Count | Should -Be 1
    }
    It 'answers the request file, deletes it, and leaves no temporary file' {
        [IO.File]::WriteAllText($script:Req, '{"haw":"vmctl","v":1,"id":"q-1","verb":"create","args":{}}' + "`n")
        Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeTrue
        Test-Path -LiteralPath $script:Req | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:Queue | ForEach-Object { $_.Name }) | Should -Be @($script:Job + '.rep')
        (ConvertFrom-Json ([IO.File]::ReadAllText($script:Rep))).error.code | Should -Be 'not-in-this-version'
    }
    It 'replaces a reply file that is there' {
        [IO.File]::WriteAllText($script:Rep, 'planted')
        [IO.File]::WriteAllText($script:Req, 'not json' + "`n")
        Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeTrue
        (ConvertFrom-Json ([IO.File]::ReadAllText($script:Rep))).error.code | Should -Be 'bad-request'
    }
    It 'writes no reply when there is no request file' {
        Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeFalse
        Test-Path -LiteralPath $script:Rep | Should -BeFalse
    }
    It 'answers bad-request for a request file over 64 KB' {
        [IO.File]::WriteAllText($script:Req, ('x' * 70000))
        Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeTrue
        $r = ConvertFrom-Json ([IO.File]::ReadAllText($script:Rep))
        $r.error.code | Should -Be 'bad-request'
        $r.error.message | Should -Match '64 KB'
    }
    It 'refuses a request file that is a link, and deletes the link only' {
        $target = Join-Path $TestDrive 'secret.txt'
        [IO.File]::WriteAllText($target, '{"haw":"vmctl","v":1,"id":"s-1","verb":"list","args":{}}')
        $null = New-Item -ItemType SymbolicLink -Path $script:Req -Target $target
        Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg | Should -BeTrue
        $r = ConvertFrom-Json ([IO.File]::ReadAllText($script:Rep))
        $r.error.code | Should -Be 'bad-request'
        $r.error.message | Should -Match 'link'
        Test-Path -LiteralPath $script:Req | Should -BeFalse
        Test-Path -LiteralPath $target | Should -BeTrue
    }
    It 'deletes .req, .rep and .tmp files older than 10 minutes, and keeps the rest' {
        $old = [datetime]::UtcNow.AddMinutes(-11)
        foreach ($n in 'a.req', 'b.rep', 'c.tmp', 'd.req', 'e.txt') { [IO.File]::WriteAllText((Join-Path $script:Queue $n), 'x') }
        foreach ($n in 'a.req', 'b.rep', 'c.tmp', 'e.txt') { [IO.File]::SetLastWriteTimeUtc((Join-Path $script:Queue $n), $old) }
        [IO.File]::WriteAllText($script:Req, 'not json' + "`n")
        $null = Invoke-WorkerJob -Job $script:Job -QueueDir $script:Queue -ConfigPath $script:Cfg
        @(Get-ChildItem -LiteralPath $script:Queue | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @(($script:Job + '.rep'), 'd.req', 'e.txt')
    }
    It 'writes the reply through a temporary file and a rename' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-ReplyFile' }, $true)
        $text = $fn.Extent.Text
        $text | Should -Match 'CreateNew'
        $text | Should -Match '\.tmp'
        $text | Should -Match '\[IO\.File\]::Move'
    }
}

Describe 'vmctl-worker.ps1 as the task runs it' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'refuses anything besides -Job <guid> (exit 2), and prints nothing: <Why>' -TestCases @(
        @{ Why = 'a config path'; Extra = @('-ConfigPath', '/tmp/evil.json') },
        @{ Why = 'a second word'; Extra = @('more') },
        @{ Why = 'a common parameter'; Extra = @('-ErrorAction', 'Ignore') }
    ) {
        $out = @(& $script:Pwsh -NoProfile -NonInteractive -File $script:Src -Job ([guid]::NewGuid().ToString()) @Extra 2>$null)
        $LASTEXITCODE | Should -Be 2
        $out.Count | Should -Be 0
    }
    It 'refuses a job that is not a GUID (exit 1)' {
        $out = @(& $script:Pwsh -NoProfile -NonInteractive -File $script:Src -Job 'nope' 2>$null)
        $LASTEXITCODE | Should -Be 1
        $out.Count | Should -Be 0
    }
    It 'has no parameter but -Job' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) | Should -Be @('Job')
        @($ast.ParamBlock.Attributes).Count | Should -Be 0
    }
}
