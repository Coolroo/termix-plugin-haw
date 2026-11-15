# Hyper-V hosts

A Windows machine with Hyper-V becomes a VM host in four parts: a key in
Termix, a Termix host that logs in as the vmctl account, the host key, and
`install.ps1` on the machine. HAW shows the same steps, with this version's
download lines and hashes, when **Check** finds no vmctl.

## What install.ps1 does

Run as administrator, it checks each part and changes only what differs; a
second run changes nothing. `-WhatIf` only says what it would change.

- Checks the SHA-256 of `vmctl.ps1` against `-Sha256` and refuses a file that
  differs. Copies it to `C:\ProgramData\haw`, a folder that SYSTEM and
  Administrators can change and the vmctl account can only read.
- Writes `C:\ProgramData\haw\vmctl.json` from its parameters, only when there
  is none (or with `-ReplaceConfig`).
- Makes the local account `vmctl` (`-Account`) with a random password that is
  never shown or kept, in _Hyper-V Administrators_ only. It stops if the
  account is in any other group.
- Writes the account's key file, `C:\ProgramData\ssh\haw-vmctl_authorized_keys`
  (SYSTEM and Administrators only), from `-PublicKey`.
- Adds a marked block at the end of `sshd_config`:
  ```
  # HAW vmctl: begin (made by install.ps1; change the host with install.ps1)
  Match User vmctl
      AuthorizedKeysFile __PROGRAMDATA__/ssh/haw-vmctl_authorized_keys
      ForceCommand powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:/ProgramData/haw/vmctl.ps1
      AllowTcpForwarding no
      AllowAgentForwarding no
      X11Forwarding no
      PermitTTY no
  # HAW vmctl: end
  ```
  It checks the new file with `sshd -t` first. A SYSTEM scheduled task then
  puts it in place and restarts sshd a few seconds later, outside your session;
  if sshd does not start, the task puts the old file back.
- Ends with one `info` request to the installed vmctl and checks the reply.

`-Uninstall` removes what it made (run it twice when it changed
`sshd_config`: the second run removes the folder and the task).

## Parameters

| Parameter                          | Default                  | Meaning                                                                  |
| ---------------------------------- | ------------------------ | ------------------------------------------------------------------------ |
| `-PublicKey`                       |                          | The `ssh-ed25519 ...` line of the Termix credential HAW logs in with     |
| `-Sha256`                          |                          | The SHA-256 of `vmctl.ps1` this HAW version released (HAW shows it)      |
| `-Account`                         | `vmctl`                  | The local account                                                        |
| `-Source`                          | the script's folder      | Where `vmctl.ps1` is                                                     |
| `-NamePattern`                     | `^[a-z][a-z0-9-]{0,62}$` | VMs HAW may act on                                                       |
| `-Protected`                       | none                     | Names or wildcards of VMs HAW may start but never stop                   |
| `-CeilingCpus`, `-CeilingMemoryMB` | none                     | The most that running VMs may have together                              |
| `-CeilingDiskGB`                   | none                     | For VM creation, in a later HAW                                          |
| `-ConsoleHost`, `-ConsolePort`     | the machine's name, 2179 | What a console client connects to: the name on the console's certificate |
| `-ReplaceConfig`                   |                          | Write `vmctl.json` again from the parameters                             |
| `-Uninstall`                       |                          | Remove everything                                                        |

## Change the limits later

Run `install.ps1` again with `-ReplaceConfig` and the new values, or edit
`C:\ProgramData\haw\vmctl.json` as administrator. vmctl reads it on every
request. HAW can't change it: the vmctl account can only read it, and no verb
writes it.

## Notes

- A graceful **Shut down** needs the guest's shutdown integration service. vmctl
  waits up to 90 seconds and then answers with the state at that moment.
- `console-info` gives the machine's name (or `-ConsoleHost`), port 2179 and the
  VM's id. The Remote Desktop plugin connects with VMConnect, which needs a
  Windows login on the machine that may use Hyper-V.
