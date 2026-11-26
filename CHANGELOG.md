# Changelog

## 1.0.6

### Added

- **Resume a paused VM.** vmctl has a new verb, `resume`, for a VM that is paused. It is a power verb like `start`, for operators, and it works on a protected VM too. HAW has the route `POST /hosts/:id/vms/:name/resume`, recorded and audited as `resume`. A VM that is not paused gets `wrong-state`, and `start` on a paused VM now says to resume it instead.
- **VM status and drive space.** `list` and `show` give each VM's `status` (Hyper-V's own words for its health) and `critical` (Hyper-V marks the VM critical, as in Paused-Critical). `show` gives `drive`: the host drive that holds the VM's first disk file, with its size and free space in GB, or `null` for a share, a VM with no disk, or a drive that Windows does not measure.
- **Resume on the card.** A paused VM gets **Resume**, never **Start**, when the host's vmctl lists `resume`. Under its row, HAW shows Paused-Critical in words, Hyper-V's status and the free space of the VM's drive. Under 10 GB free, it adds "Hyper-V pauses a VM when its disk drive is almost full: free space first, then Resume." The details of every VM show the drive line.

### Changed

- **The VM service `haw.vms` is version 1.1.0.** It adds `resume(caller, host, name)`, with the same role rules as `start`, and the new `status`, `critical` and `drive` fields. The agent limit refuses `resume`. See [the VM service](docs/service.md).
- **The Hyper-V back end (`vmctl-worker.ps1`) is version 1.1.0.** `vmctl.ps1` and `install.ps1` did not change. HAW does not update a host by itself: run the host's setup of this version again (see [Update vmctl](docs/hyper-v.md#update-vmctl)). Until then, HAW works as before, without Resume, and says what to do for a paused VM.
- **Refresh updates the host's info.** After a host's vmctl is updated, its new verbs show when you press **Refresh**, without a reload of the page.

## 1.0.5

### Changed

- **One build for Termix 26.11.0 and 26.11.2 or later.** The manifest allows plugin API 1.13 and plugin API 2.9 (`"api": "^1.13 || ^2.9"`). On Termix 26.11.0, HAW runs as before. On Termix 26.11.2 or later, HAW runs in its own process and its tab in a sandboxed frame. HAW needs no `sandbox` block: it has no timers, event listeners or registry values of its own.
- HAW's icon is Lucide's **Trees** icon, the same drawing. Termix 26.11.2 draws only Lucide icons in the rail and on the tab; it showed a puzzle piece for the old icon.

### Fixed

- **The VM service binds under plugin API 2.** `bindPlugin` now waits for the consumer's receiver from `ctx.registry.consume`, which plugin API 2 gives as a Promise. Before, a plugin like Runbooks got `no-receiver` and could not use VM steps on Termix 26.11.2.

### Security

- **Termix API keys under plugin API 2.** Termix 26.11.2 and later do not tell a plugin process whether a request came in on a Termix API key (`tmx_...`), so HAW can't refuse API keys there as it does on Termix 26.11.0: a request with an admin's API key reaches HAW's routes as that admin. On Termix 26.11.0 nothing changes.

## 1.0.4

### Fixed

- **The queue's OWNER RIGHTS entry works.** `install.ps1` set the queue folder's owner after its entries, and Windows then drops the OWNER RIGHTS entry's "files" flag, so the entry did nothing: the vmctl account could change the access list of a request file it made. `install.ps1` now sets the owner first, and removes a dead entry before it grants the entry again. Run `install.ps1` once on each Hyper-V host to repair the queue.
- **`install.ps1` reports only real changes.** It reported SET for the queue access and the worker task on every run: the queue because of the dead entry, the task because Task Scheduler stores the account's "read and run" right as `0x1200a9`, not as the `GRGX` that `install.ps1` writes. It now compares the right as a number, so a second run ends with `CHANGED 0`.

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
