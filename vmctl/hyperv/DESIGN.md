# The Hyper-V back end: a front and a worker (design B)

## Why a worker

A first design ran everything as the vmctl account, which was a member of
Hyper-V Administrators. A test on Windows 11 showed that this does not work over
Win32-OpenSSH with a key. A key login gives a network logon token, and Hyper-V
refuses such a token ("You do not have the required permission ...
authorization policy"). Plain WMI (`Win32_OperatingSystem`) refuses it too
("Access denied"). Giving WMI Remote Enable on `root\cimv2` and
`root\virtualization\v2`, and adding the account to Distributed COM Users, did
not help. sshd does obey `ForceCommand` in a `Match User` block.

So the account does no Hyper-V work. It is a plain user (Users only), and a
scheduled task that runs as SYSTEM does the work.

## The parts

| Part                        | Runs as                                     | Does                                                                                                                                                                                                                                                    |
| --------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vmctl.ps1` (front)         | the vmctl account, as sshd's forced command | Reads one line from stdin (64 KB at most). Writes it, as it came, to `queue\<guid>.req`, where `<guid>` is a new random GUID. Starts the task `haw-vmctl-worker` with `Run(<guid>)`. Waits up to 110 s for `queue\<guid>.rep` and prints that one line. |
| `vmctl-worker.ps1` (worker) | SYSTEM, from the task                       | Takes `-Job <guid>`. Reads and deletes `queue\<guid>.req`. Checks the request, does the verb and writes the reply to `queue\<guid>.rep`. Deletes queue files older than 10 minutes.                                                                     |
| `install.ps1`               | an administrator                            | Makes the account, the folders and their access lists, both scripts (each pinned by SHA-256), `vmctl.json`, the task, the key file and the sshd block. Then it checks the whole path with an `info` request through the front.                          |

The front answers by itself in only three cases, always with `ok: false`:

- It can't read the line: `bad-request`.
- The task does not start: `backend`, "the vmctl worker did not start: ...".
- No reply comes in 110 s: `backend`, "the vmctl worker did not answer in time".

It never sends a request's own text back. Its `id` is the request's id when that
is valid, else `null`.

## The trust boundary is the worker

The front checks nothing. It does not trust the line, and it does not parse the
line beyond looking for an id it can echo. The worker checks everything: the
envelope, the version, the verb, the arguments, the allow pattern, the protect
list, the ceilings and the VM states. These are the same checks as before; only
the transport changed.

The account can reach the worker in only two ways:

1. **The request line.** The worker reads it as data and checks it fully. It
   never runs request text as code.
2. **The task's argument.** `Run()` puts whatever string it gets into
   `$(Arg0)`, so this string is the account's to choose. The task runs
   `powershell.exe ... -File vmctl-worker.ps1 -Job $(Arg0)`. To keep that safe:
   - The worker refuses any `-Job` that is not a lower-case GUID. Such a GUID
     can only name a file in the queue.
   - The worker has no other parameter. It is not an advanced script, so it has
     no `-ErrorAction`, `-OutVariable` or other common parameters either.
   - Any extra word on the command line lands in `$args`, and the worker exits
     with code 2 without touching a file.
   - The tests give the config and queue paths to `Invoke-WorkerJob` as
     function arguments. For this reason the earlier script parameter
     `-ConfigPath` is gone: an injected `-ConfigPath` would have let the account
     choose its own limits.

The front names each file with a new GUID and never with the request id. So the
account can't aim the worker at a file it names, and two requests with the same
id don't collide.

## The queue's access list

The folder `C:\ProgramData\haw\queue` has its own access list, with nothing
inherited and Administrators as the owner:

| Who                    | Applies to                | Rights                                 | Why                                                                                                                                                                                                                                                                        |
| ---------------------- | ------------------------- | -------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| SYSTEM, Administrators | folder, subfolders, files | Full                                   | the worker and the administrators                                                                                                                                                                                                                                          |
| the account            | this folder only          | `WD,X,RA,S` (add a file, pass through) | It can drop a `.req`. It can't list the folder (no `RD`), so it can't learn other jobs' GUIDs. It can't make a subfolder (no `AD`), so it can't make a junction. It can't delete a file in the folder (no `DC`), and it can't change the folder's access (no `WDAC`/`WO`). |
| the account            | files only                | `RD,REA,RA,RC,S` (read)                | It reads its `.rep`, which SYSTEM made and owns.                                                                                                                                                                                                                           |
| CREATOR OWNER          | files only                | `RD,WD,AD,REA,WEA,RA,WA,S`             | The account may write the `.req` it made, and no other file.                                                                                                                                                                                                               |
| OWNER RIGHTS           | files only                | `RA,S`                                 | The owner of a file gets no implicit `WRITE_DAC` or `READ_CONTROL`, so the account can't change the access list of its own `.req`.                                                                                                                                         |

What the account can't do:

- **Change, replace or delete a reply.** A `.rep` is created by SYSTEM, so the
  CREATOR OWNER entry becomes SYSTEM's, and the account has only read on it.
  To delete or rename over a file it would need `D` on the file or `DC` on the
  folder, and it has neither.
- **Read another job's reply.** In theory it could, if it knew the GUID. But it
  can't list the folder, and the GUIDs are random. The account is also the only
  client of the queue: every reply in the queue answers one of its own
  requests, and a reply holds nothing that the account could not ask for
  itself. So this is acceptable.
- **Plant a file outside the queue.** It has no write right anywhere else under
  `C:\ProgramData\haw`. It has no subfolders and no junctions in the queue. The
  file names that the worker uses are always `<guid>.req`, `<guid>.rep` or
  `<new guid>.tmp`, always inside the queue.
- **Make SYSTEM write through a link.** The worker writes the reply to a new
  file with a random name (`CreateNew`, which fails on any name that is
  already there), then renames it over `<guid>.rep`. A rename replaces the
  name; it does not write through a link at that name. The 10-minute sweep
  deletes names with `File.Delete`, which deletes a link and not its target.
- **Make SYSTEM read through a symbolic link.** The worker refuses a `.req`
  that is a reparse point, and it reads at most 64 KB. A hard link as `.req`
  would be read as text. Two reasons make this an acceptable risk:
  - To make a hard link, the account must run code, and its forced command
    does not let it. Also, newer Windows builds ask for write access to the
    link's target.
  - Even then, the reply would show only JSON parse results, and two fields
    cut to 500 characters (the verb in `unknown-verb`, and the name in
    `not-found`).

What the account can do:

- **Fill the queue, or start many workers.** The front writes one file of at
  most 64 KB per SSH session. Each worker runs for at most 3 minutes, and the
  sweep deletes old files. This is load from the one client, the same as
  sending many requests.

The rest of `C:\ProgramData\haw`:

- **The folder itself:** SYSTEM and Administrators have full control, and the
  folder inherits nothing. The account has `X,RA,S` on the folder only: it may
  pass through, but not list.
- **`vmctl.ps1`:** what it inherits, plus `RX` for the account.
- **`vmctl-worker.ps1` and `vmctl.json`:** only what they inherit (SYSTEM and
  Administrators). The account can't read or write them.
- **`setup\`:** SYSTEM and Administrators only. It holds the sshd candidate,
  the backup and the restart script.

## The worker task

- **Name:** `haw-vmctl-worker`.
- **Action:** `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\haw\vmctl-worker.ps1" -Job $(Arg0)`.
- **Principal:** SYSTEM, logon type 5 (service account), highest run level.
- **Settings:** instances run in parallel, `ExecutionTimeLimit` is PT3M, there
  are no triggers, and battery rules are off.
- **Registration:** through `Schedule.Service` with
  `RegisterTaskDefinition(name, def, 6, 'SYSTEM', $null, 5, $sddl)`.
- **Access list:** `$sddl` is `D:(A;;FA;;;BA)(A;;FA;;;SY)(A;;GRGX;;;<account SID>)`,
  so the account may read and run the task, and nothing more.
- **Repeat runs:** `install.ps1` reads the task back over COM and registers it
  again only when it differs.

The times fit inside HAW's 120 s:

- The front waits 110 s.
- The worker waits at most 80 s for a guest to shut down on `stop` (it then
  answers with the state at that moment), and 60 s on `restart` (it then
  answers `backend`).
- This leaves time for the task to start and for the Hyper-V module to load.

## Not proven on real Windows yet

The tests run on Linux pwsh 7.4 with every Windows part mocked. These things are
still open:

1. **The account starting the task.** A plain user with a network logon (key
   over Win32-OpenSSH) must be able to `Run()` a task it has `GRGX` on. A live
   test of exactly this is pending.
2. **The argument.** `Run(<guid>)` must reach the action as `$(Arg0)`.
3. **The queue's access list.**
   - The account must be able to create a file with only `WD` on the folder,
     plus write through the inherited CREATOR OWNER entry.
   - The OWNER RIGHTS entry must not stop that write.
   - The account must be able to open and read a `.rep` that SYSTEM owns.
   - Every grant includes `S` (synchronize), which a synchronous open needs.
4. **The account and the haw folder.** `powershell.exe -File` must start
   `vmctl.ps1` when the account has only `X,RA` on the haw folder and `RX` on
   the file. If it does not, give the account `RX` on the folder itself.
5. **Reading stdin.** Windows PowerShell 5.1 must read stdin through
   `[Console]::OpenStandardInput()` under sshd. On the test machine, Termix's
   client did deliver stdin to PowerShell.
6. **Windows PowerShell 5.1 details:**
   - `ConvertTo-Json` keeps one-element and empty lists as lists. The
     install self-check refuses a reply where it does not.
   - `[IO.File]::Move` and `FileMode.CreateNew` behave the same on NTFS as
     they do in the tests.
   - `Get-Item` shows `ReparsePoint` for a symbolic link.
7. **icacls.** It must write the entries with exactly the flags that
   `Test-AclSpec` expects. If Windows splits or merges an entry, every run would
   report SET for the queue. That is harmless, but it is not idempotent.
8. **The task's access list as read back.** `GetSecurityDescriptor(4)` may give
   `GRGX` or `0xa0000000`. Both are accepted.
9. **The SYSTEM worker and Hyper-V.** The worker must use Hyper-V as SYSTEM, and
   `Stop-VM -AsJob` must go on after the worker exits.
