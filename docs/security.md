# Security

## What HAW can do on a host

Only what vmctl does, and vmctl does only the verbs of the
[protocol](protocol.md): read the host and its VMs, start, stop and restart a
VM, and say how to reach its console. HAW 1.0 has no verb that makes, deletes
or changes a VM, or that changes the host.

- **One command.** The account HAW logs in as has `ForceCommand` in sshd: sshd
  runs vmctl whatever HAW sends. No shell, no terminal (`PermitTTY no`), no
  port forwarding, no agent forwarding, no sftp.
- **No rights of its own.** On Hyper-V the account is a plain user (Users
  only). Its password is random, made on the machine and never shown; it logs
  in with a key only. It can drop a request into a queue folder and start one
  task, `haw-vmctl-worker`, which runs as SYSTEM. The worker is the trust
  boundary: it checks the whole request again, with the host's limits, and
  only then runs the Hyper-V command. Windows refuses Hyper-V to a non-admin
  account that logs in over SSH with a key, so this split is what keeps the
  account out of Administrators. The task takes only a job id (a GUID) as its
  argument; the worker refuses anything else.
- **Data, never code.** The request is JSON on standard input. vmctl reads VM
  names as data and passes them to the hypervisor as parameter values; a name
  with a wildcard is refused before any lookup.
- **The host's own limits.** The allow pattern, the protect list and the
  ceilings live in a file on the host that only the worker reads and only
  administrators can change. The worker checks them on every request, whatever
  HAW thinks.

## What HAW keeps

- Its own tables: the VM hosts (a Termix host id, the interface, the last
  `vmctl info`), console links (a VM id and a Termix host id), and the record
  of actions. No password, key or token.
- Termix's audit log gets a line per action, as the person who clicked.

## How HAW connects

Through Termix's SSH pipeline (`ctx.ssh.exec`), as the person who clicked,
with the host's stored login. HAW refuses a host with no stored host key, so a
connection never takes an unknown key on trust.

## Capabilities

| Capability                       | Why                                                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `ssh:connect`, `credentials:use` | Run vmctl on a VM host with its stored login                                                                       |
| `hosts:read`                     | List the Termix hosts a person can see, to pick a VM host and a console host                                       |
| `network:serve`                  | The tab's own routes. HAW has no public route: every request needs a Termix login, and Termix API keys are refused |
| `db:own`                         | HAW's own tables                                                                                                   |
| `ui:surface`                     | The tab                                                                                                            |

HAW 1.0 has no `hosts:write`: it never makes, changes or deletes a Termix host.

## Report a problem

Open an issue at https://github.com/Coolroo/termix-plugin-haw/issues. For a
security problem, use GitHub's private vulnerability report on the repo.
