# Changelog

## 1.0.1

### Changed

- The VM list keeps up by itself: while the tab is on screen, it reads each host's VMs again 2 seconds after the last read ended, so a VM that starts, stops or changes on the host shows without a click. A read never starts while another one or a power action is still running.

## 1.0.0

### Added

- VM hosts: any Termix host, with an interface (Hyper-V). **Add VM host** checks the host with `vmctl info` before it adds it, and shows that interface's one-time setup when vmctl does not answer. A host with no stored host key is refused.
- The vmctl protocol, version 1: one JSON request on standard input, one JSON reply. Verbs `info`, `list`, `show`, `start`, `stop`, `restart` and `console-info`; `create`, `delete`, `snapshot`, `restore` and `users` answer "not in this version".
- The Hyper-V back end, with `install.ps1` for the one-time setup. `vmctl.ps1` is the forced command of a plain account (key login, no TTY, no forwarding); it hands each request to the task `haw-vmctl-worker`, which runs `vmctl-worker.ps1` as SYSTEM, checks the request again and runs Hyper-V. Windows refuses Hyper-V to a non-admin account over an SSH key login, even in Hyper-V Administrators; the worker keeps the account out of Administrators. The host config holds a name pattern, a protect list and ceilings that the plugin can't change.
- A fake back end for tests and rehearsals (`vmctl/fake/vmctl-fake.mjs`).
- The VMs tab: each VM host with its VMs, state, size, addresses and uptime; Start, Shut down, Turn off, Restart and Reset with a confirm; protected and not-managed VMs marked.
- Consoles through the Remote Desktop plugin, from a Termix host an owner links to the VM.
- Roles: See VMs (viewer), Power VMs (operator) and Manage VM hosts (owner).
- The record of actions, in HAW's tables and in Termix's audit log.
