# Changelog

## 1.0.3

### Added

- The VM service `haw.vms` (version 1.0.0), for other plugins: `hosts`, `info`, `list`, `show`, `start`, `stop`, `restart` and `consoleInfo`, as the acting person, with their HAW role and the host's limits, through the same vmctl call as the tab. Runbooks uses it for VM steps. See [the VM service](docs/service.md).
- **Plugins that may act for a person**, an admin setting: the plugin ids that may use the service, one a line. Empty by default.
- A plugin proves who it is with a key HAW hands to a receiver under the plugin's own id (`<id>.hawVmsKey`), as OpenBao Secrets' service does. Every call carries it.
- A call for an agent token (`agent: true`) may only list hosts and VMs.
- HAW's record keeps the plugin that acted for the person and its reference ("via runbooks: runbook 12 step 3"). **Record** and a VM's last action show it; Termix's audit line has it in its details.

## 1.0.2

### Changed

- A new VM list. Each VM is one item of two lines: its name with the Protected or Not-managed badge, then its state, size and addresses, with the uptime at the right. The buttons sit at the right and move under the name in a narrow pane, so the list never scrolls to the side.
- A click on a VM opens its details in place: generation, size, checkpoints and ID; each disk with its use; each network with its switch, MAC and addresses; the notes; and the last action HAW recorded on that VM. Turn off and Reset are in the details; the row keeps Start, Shut down, Restart and Console.
- On a phone, the rows have no buttons. The details show every button the VM allows, large, two to a line.
- Each host's header shows its VM count, its memory in use as a bar, and a **Limits** button for the name pattern, protect list and ceilings.
- A filter box (name or address) and **All**, **Running** and **Stopped** buttons with counts, above all hosts.

### Added

- `GET /actions` takes `vmName`, with `hostId`, for the last action on one VM.

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
