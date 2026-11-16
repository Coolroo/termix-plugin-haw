<#
.SYNOPSIS
HAW's Hyper-V back end, the front: the vmctl account's forced command. It hands
one request to the worker and prints the worker's reply.

.DESCRIPTION
sshd runs this file for the vmctl account (ForceCommand; install.ps1 sets that
up). The account is a plain user: Hyper-V does not let it in over SSH, so the
front does no Hyper-V work and checks nothing. It:

  1. reads ONE line from standard input (at most 64 KB);
  2. writes it, as it came, to C:\ProgramData\haw\queue\<guid>.req, where
     <guid> is a new random GUID (never the request's id, so the account
     cannot aim at another file);
  3. starts the scheduled task haw-vmctl-worker with that GUID as its argument;
  4. waits up to 110 seconds for queue\<guid>.rep and prints its one line.

When the line can't be read, the task can't be started or no reply comes, it
prints a protocol reply itself (ok: false, code bad-request or backend). Nothing
else goes to standard output; logs go to standard error. The exit code is 0
when it printed a reply. The worker (vmctl-worker.ps1, run as SYSTEM) checks
everything; DESIGN.md says why.

It runs on Windows PowerShell 5.1 (the forced command is powershell.exe) and on
PowerShell 7 (the tests).
#>
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

$script:WorkerTaskName = 'haw-vmctl-worker'
$script:MaxRequestBytes = 65536
$script:ReplyWaitSeconds = 110
$script:PollMilliseconds = 200

function Write-FrontLog {
    param([string]$Text)
    try { [Console]::Error.WriteLine('vmctl: ' + $Text) } catch { $null = $_ }
}

function Format-FrontMessage {
    param([string]$Text)
    if (-not $Text) { return 'no message' }
    $t = ($Text -replace '[\r\n\t]+', ' ').Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
    return $t
}

# Reads up to the first newline, at most $Max bytes. Returns Text, or Problem
# when the request can't be read. It stops at the newline, so a client that
# keeps its end open is answered.
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

# The request's id, only to put in a reply the front writes itself: the id when
# it is a valid one, else $null. Nothing else of the request is used here.
function Get-LooseRequestId {
    param([string]$Text)
    try {
        $o = ConvertFrom-Json -InputObject $Text
        if ($null -eq $o -or $o -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        foreach ($p in $o.PSObject.Properties) {
            if ($p.Name -ceq 'id' -and $p.Value -is [string] -and $p.Value -cmatch '^[A-Za-z0-9-]{1,64}\z') { return [string]$p.Value }
        }
    } catch { $null = $_ }
    return $null
}

# A reply of the front's own: ok false, with the code and message.
function New-FrontReply {
    param($Id, [string]$Code, [string]$Message)
    $reply = [ordered]@{ haw = 'vmctl'; v = 1; id = $Id; ok = $false; error = [ordered]@{ code = $Code; message = $Message } }
    return (ConvertTo-Json -InputObject $reply -Compress -Depth 5)
}

# The request line as it came, in a new file (CreateNew: never into a file that is there).
function Write-RequestFile {
    param([string]$Path, [string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text + "`n")
    $stream = New-Object System.IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }
    finally { $stream.Dispose() }
}

# Starts the worker task with the job's GUID as its one argument ($(Arg0)).
function Start-WorkerTask {
    param([string]$Job)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    $task = $svc.GetFolder('\').GetTask($script:WorkerTaskName)
    $null = $task.Run($Job)
}

# The reply's line once the file is there (the worker renames a whole file into
# place), or $null after $Seconds.
function Wait-ReplyFile {
    param([string]$Path, [int]$Seconds)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    while ($true) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try {
                $text = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
                foreach ($l in ($text -split "\r?\n")) { if ($l.Trim()) { return $l.Trim() } }
                return ''
            } catch { Write-FrontLog ('reading the reply failed, trying again: ' + (Format-FrontMessage $_.Exception.Message)) }
        }
        if ([datetime]::UtcNow -ge $deadline) { return $null }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
}

# One request: returns the reply line to print.
function Invoke-FrontRequest {
    param([System.IO.Stream]$Stream, [string]$QueueDir, [int]$TimeoutSeconds = $script:ReplyWaitSeconds)
    $in = Read-RequestLine -Stream $Stream
    if ($in.Problem) { return (New-FrontReply -Id $null -Code 'bad-request' -Message $in.Problem) }
    $id = Get-LooseRequestId $in.Text
    $job = [guid]::NewGuid().ToString()
    try {
        Write-RequestFile -Path (Join-Path $QueueDir ($job + '.req')) -Text $in.Text
        Start-WorkerTask -Job $job
    } catch {
        Write-FrontLog ('the worker did not start: ' + (Format-FrontMessage $_.Exception.Message))
        return (New-FrontReply -Id $id -Code 'backend' -Message ('the vmctl worker did not start: ' + (Format-FrontMessage $_.Exception.Message)))
    }
    $line = Wait-ReplyFile -Path (Join-Path $QueueDir ($job + '.rep')) -Seconds $TimeoutSeconds
    if ($null -eq $line) { return (New-FrontReply -Id $id -Code 'backend' -Message 'the vmctl worker did not answer in time') }
    if (-not $line.StartsWith('{')) { return (New-FrontReply -Id $id -Code 'backend' -Message 'the vmctl worker gave an empty reply') }
    return $line
}

# The reply as UTF-8 bytes without a byte order mark, then a newline.
function Write-ReplyLine {
    param([string]$Json, [System.IO.Stream]$Stream = $null)
    if ($null -eq $Stream) { $Stream = [Console]::OpenStandardOutput() }
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Json + "`n")
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

# The forced command's entry. -QueueDir and -TimeoutSeconds are for the tests:
# the forced command gives none, and the account can't add any.
function Invoke-FrontMain {
    param([string]$QueueDir = '', [int]$TimeoutSeconds = $script:ReplyWaitSeconds)
    $json = '{"haw":"vmctl","v":1,"id":null,"ok":false,"error":{"code":"backend","message":"vmctl failed before it could answer"}}'
    try {
        if (-not $QueueDir) { $QueueDir = Join-Path (Join-Path $env:ProgramData 'haw') 'queue' }
        $json = Invoke-FrontRequest -Stream ([Console]::OpenStandardInput()) -QueueDir $QueueDir -TimeoutSeconds $TimeoutSeconds
    } catch {
        Write-FrontLog ('failed: ' + (Format-FrontMessage $_.Exception.Message))
    }
    try { Write-ReplyLine $json } catch { exit 1 }
    exit 0
}

# Dot-sourced by the tests: define the functions only.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-FrontMain
}
