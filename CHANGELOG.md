# Changelog

## 1.0.0

### Added

- VM hosts: any Termix host, with an interface (Hyper-V). **Add VM host** checks the host with `vmctl info` before it adds it, and shows that interface's one-time setup when vmctl does not answer. A host with no stored host key is refused.
- The vmctl protocol, version 1: one JSON request on standard input, one JSON reply. Verbs `info`, `list`, `show`, `start`, `stop`, `restart` and `console-info`; `create`, `delete`, `snapshot`, `restore` and `users` answer "not in this version".
- The Hyper-V back end `vmctl.ps1`, with `install.ps1` for the one-time setup: an account in Hyper-V Administrators only, key login, `ForceCommand`, and a host config with a name pattern, a protect list and ceilings that the plugin can't change.
- A fake back end for tests and rehearsals (`vmctl/fake/vmctl-fake.mjs`).
- The VMs tab: each VM host with its VMs, state, size, addresses and uptime; Start, Shut down, Turn off, Restart and Reset with a confirm; protected and not-managed VMs marked.
- Consoles through the Remote Desktop plugin, from a Termix host an owner links to the VM.
- Roles: See VMs (viewer), Power VMs (operator) and Manage VM hosts (owner).
- The record of actions, in HAW's tables and in Termix's audit log.
