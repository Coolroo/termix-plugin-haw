# Pester 5 tests for vmctl.ps1, the front: the vmctl account's forced command.
# It hands the line to the worker through the queue and prints the reply. The
# scheduled task is mocked (Start-WorkerTask); some tests run the real worker in
# its place. What only Windows proves (that the plain account may Run() the task,
# the COM call itself) is in DESIGN.md.

BeforeAll {
    $script:Here = Split-Path -Parent $PSCommandPath
    $script:Dir = Split-Path -Parent $script:Here
    $script:Src = Join-Path $script:Dir 'vmctl.ps1'
    $script:WorkerSrc = Join-Path $script:Dir 'vmctl-worker.ps1'

    function global:Get-VM { [CmdletBinding()] param([string[]]$Name) }
    function global:Get-VMNetworkAdapter { [CmdletBinding()] param([object[]]$VM) }

    # The worker first, then the front: the front's functions are the ones under test.
    . $script:WorkerSrc
    . $script:Src

    function script:Invoke-Line {
        param([string]$Line, [int]$Timeout = 5)
        $bytes = [Text.Encoding]::UTF8.GetBytes($Line + "`n")
        return (Invoke-FrontRequest -Stream (New-Object IO.MemoryStream(, $bytes)) -QueueDir $script:Queue -TimeoutSeconds $Timeout)
    }
    $script:GuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

Describe 'the file itself' {
    It 'is ASCII only, so Windows PowerShell 5.1 reads it the same without a BOM' {
        @([IO.File]::ReadAllBytes($script:Src) | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'parses with no errors, and uses no syntax that Windows PowerShell 5.1 lacks' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
        @($ast.FindAll({ param($n) $n.GetType().Name -in @('TernaryExpressionAst', 'PipelineChainAst') }, $true)).Count | Should -Be 0
        @($tokens | Where-Object { $_.Kind -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket') }).Count | Should -Be 0
    }
    It 'calls no Hyper-V or WMI command: the account could not' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$null)
        $names = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        @($names | Where-Object { $_ -match '-VM|VHD|VMHost|VMSwitch|VMSnapshot|CimInstance|WmiObject' }).Count | Should -Be 0
    }
    It 'takes no parameter: the forced command gives none' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters).Count | Should -Be 0
    }
}

Describe 'vmctl.ps1' {
    BeforeEach {
        $script:Queue = Join-Path $TestDrive ('q-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $script:Queue -Force
        $script:Cfg = Join-Path $TestDrive 'vmctl.json'
        [IO.File]::WriteAllText($script:Cfg, '{}')
        $script:Jobs = @()
        $script:Seen = @()
        $script:Canned = '{"haw":"vmctl","v":1,"id":"a-1","ok":true,"result":{"vms":[]}}'
        # The task: note the job, read its request, answer with the canned line.
        Mock Start-WorkerTask {
            $script:Jobs += $Job
            $script:Seen += [IO.File]::ReadAllText((Join-Path $script:Queue ($Job + '.req')))
            [IO.File]::WriteAllText((Join-Path $script:Queue ($Job + '.rep')), $script:Canned + "`n")
        }
        Mock Write-FrontLog { }
        Mock Write-VmctlLog { }
    }

    It 'writes the line as it came to queue\<guid>.req, starts the task with that GUID, and gives the reply' {
        $line = '{"haw":"vmctl","v":1,"id":"a-1","verb":"list","args":{}}'
        Invoke-Line $line | Should -BeExactly $script:Canned
        $script:Jobs.Count | Should -Be 1
        $script:Jobs[0] | Should -MatchExactly $script:GuidPattern
        $script:Seen[0] | Should -BeExactly ($line + "`n")
    }
    It 'names the file with a new GUID, never with the request id' {
        $id = [guid]::NewGuid().ToString()
        $null = Invoke-Line ('{"haw":"vmctl","v":1,"id":"' + $id + '","verb":"list","args":{}}')
        $null = Invoke-Line ('{"haw":"vmctl","v":1,"id":"' + $id + '","verb":"list","args":{}}')
        $script:Jobs[0] | Should -Not -Be $id
        $script:Jobs[1] | Should -Not -Be $script:Jobs[0]
    }
    It 'relays a line that is not JSON; the worker answers bad-request with id null' {
        Mock Start-WorkerTask { $null = Invoke-WorkerJob -Job $Job -QueueDir $script:Queue -ConfigPath $script:Cfg }
        $r = ConvertFrom-Json (Invoke-Line 'this is not json')
        $r.error.code | Should -Be 'bad-request'
        $r.id | Should -BeNullOrEmpty
        Should -Invoke Start-WorkerTask -Times 1 -Exactly
    }
    It 'relays a request the worker refuses, with the worker''s answer' {
        Mock Start-WorkerTask { $null = Invoke-WorkerJob -Job $Job -QueueDir $script:Queue -ConfigPath $script:Cfg }
        $r = ConvertFrom-Json (Invoke-Line '{"haw":"vmctl","v":1,"id":"a-2","verb":"show","args":{"name":"web-*"}}')
        $r.error.code | Should -Be 'bad-request'
        $r.id | Should -Be 'a-2'
    }
    It 'gives the worker''s answer for a real verb (the worker and its checks run)' {
        Mock Get-VM { [pscustomobject]@{ Name = 'web-1'; Id = [guid]::NewGuid(); State = 'Off'; ProcessorCount = 1; MemoryStartup = 1GB; MemoryAssigned = 0; Uptime = [timespan]::Zero; Generation = 2; Notes = '' } }
        Mock Start-WorkerTask { $null = Invoke-WorkerJob -Job $Job -QueueDir $script:Queue -ConfigPath $script:Cfg }
        $out = Invoke-Line '{"haw":"vmctl","v":1,"id":"a-3","verb":"list","args":{}}'
        $out | Should -Match '^\{"haw":"vmctl","v":1,"id":"a-3","ok":true,"result":\{"vms":\[\{"name":"web-1"'
    }
    It 'answers backend when no reply comes in time, with the id when it is valid' {
        Mock Start-WorkerTask { }
        $r = ConvertFrom-Json (Invoke-Line '{"haw":"vmctl","v":1,"id":"a-4","verb":"list","args":{}}' -Timeout 1)
        $r.ok | Should -BeFalse
        $r.error.code | Should -Be 'backend'
        $r.error.message | Should -Be 'the vmctl worker did not answer in time'
        $r.id | Should -Be 'a-4'
    }
    It 'answers with id null when the id is not valid: <Why>' -TestCases @(
        @{ Why = 'no JSON'; Line = 'hello' },
        @{ Why = 'a bad id'; Line = '{"id":"has space"}' },
        @{ Why = 'an id of another case'; Line = '{"ID":"a-5"}' },
        @{ Why = 'a number'; Line = '{"id":5}' }
    ) {
        Mock Start-WorkerTask { }
        $out = Invoke-Line $Line -Timeout 1
        $out | Should -Match '"id":null'
    }
    It 'answers backend "did not start" when the task can''t be started' {
        Mock Start-WorkerTask { throw 'Access is denied. (Exception from HRESULT: 0x80070005)' }
        $r = ConvertFrom-Json (Invoke-Line '{"haw":"vmctl","v":1,"id":"a-6","verb":"list","args":{}}')
        $r.error.code | Should -Be 'backend'
        $r.error.message | Should -Match '^the vmctl worker did not start: Access is denied'
        $r.id | Should -Be 'a-6'
    }
    It 'answers backend when the reply file is empty' {
        $script:Canned = ''
        (ConvertFrom-Json (Invoke-Line '{"haw":"vmctl","v":1,"id":"a-7","verb":"list","args":{}}')).error.message | Should -Match 'empty reply'
    }
    It 'answers bad-request itself for a line it can''t read, and starts nothing' {
        $big = [Text.Encoding]::ASCII.GetBytes(('x' * 65537) + "`n")
        $r = ConvertFrom-Json (Invoke-FrontRequest -Stream (New-Object IO.MemoryStream(, $big)) -QueueDir $script:Queue -TimeoutSeconds 1)
        $r.error.code | Should -Be 'bad-request'
        $r.error.message | Should -Match '64 KB'
        $r = ConvertFrom-Json (Invoke-FrontRequest -Stream (New-Object IO.MemoryStream(, [byte[]]@(10))) -QueueDir $script:Queue -TimeoutSeconds 1)
        $r.error.message | Should -Match 'empty'
        Should -Invoke Start-WorkerTask -Times 0
        @(Get-ChildItem -LiteralPath $script:Queue).Count | Should -Be 0
    }
    It 'never writes into a file that is there' {
        $p =Join-Path $script:Queue 'taken.req'
        [IO.File]::WriteAllText($p, 'old')
        { Write-RequestFile -Path $p -Text 'new' } | Should -Throw
        [IO.File]::ReadAllText($p) | Should -Be 'old'
    }
    It 'starts the task named haw-vmctl-worker with Run(<guid>)' {
        $ast = [Management.Automation.Language.Parser]::ParseFile($script:Src, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-WorkerTask' }, $true)
        $fn.Extent.Text | Should -Match 'Schedule\.Service'
        $fn.Extent.Text | Should -Match '\.Run\(\$Job\)'
        $script:WorkerTaskName | Should -Be 'haw-vmctl-worker'
    }
}

Describe 'vmctl.ps1 as a process' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
        $script:Child = Join-Path $script:Here 'child-host.ps1'
    }
    BeforeEach {
        $script:Queue = Join-Path $TestDrive ('p-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $script:Queue -Force
        $script:Cfg = Join-Path $TestDrive 'vmctl.json'
        [IO.File]::WriteAllText($script:Cfg, '{"protected":["build-*"]}')
        $script:ErrFile = Join-Path $TestDrive 'stderr.txt'
    }
    It 'writes only the reply on standard output, as one line, and exits 0 (<Why>)' -TestCases @(
        @{ Why = 'list'; Mode = 'answer'; Line = '{"haw":"vmctl","v":1,"id":"p-1","verb":"list","args":{}}'; Code = $null },
        @{ Why = 'not JSON'; Mode = 'answer'; Line = 'hello'; Code = 'bad-request' },
        @{ Why = 'an empty line'; Mode = 'answer'; Line = ''; Code = 'bad-request' },
        @{ Why = 'not in this version'; Mode = 'answer'; Line = '{"haw":"vmctl","v":1,"id":"p-1","verb":"create","args":{}}'; Code = 'not-in-this-version' },
        @{ Why = 'the task can''t start'; Mode = 'fail'; Line = '{"haw":"vmctl","v":1,"id":"p-1","verb":"list","args":{}}'; Code = 'backend' },
        @{ Why = 'no answer'; Mode = 'silent'; Line = '{"haw":"vmctl","v":1,"id":"p-1","verb":"list","args":{}}'; Code = 'backend' }
    ) {
        $out = @($Line | & $script:Pwsh -NoProfile -NonInteractive -File $script:Child -Front $script:Src -Worker $script:WorkerSrc -QueueDir $script:Queue -ConfigPath $script:Cfg -Mode $Mode -Timeout 2 2> $script:ErrFile)
        $LASTEXITCODE | Should -Be 0
        $out.Count | Should -Be 1
        $out[0] | Should -Match '^\{"haw":"vmctl".*\}$'
        $r = ConvertFrom-Json $out[0]
        if ($Code) { $r.error.code | Should -Be $Code } else { $r.ok | Should -BeTrue }
    }
    It 'gives the list from the stand-ins, and logs on standard error only' {
        $out = @('{"haw":"vmctl","v":1,"id":"p-2","verb":"list","args":{}}' | & $script:Pwsh -NoProfile -NonInteractive -File $script:Child -Front $script:Src -Worker $script:WorkerSrc -QueueDir $script:Queue -ConfigPath $script:Cfg 2> $script:ErrFile)
        $out.Count | Should -Be 1
        $out[0] | Should -Match '"vms":\[\{"name":"web-1".*"addresses":\["192\.0\.2\.10"\]'
        (Get-Content -Raw $script:ErrFile) | Should -Match 'stand-in Get-VM'
    }
}
