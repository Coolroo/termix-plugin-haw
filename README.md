<div align="center">

<h1>Hundred Acre Wood</h1>

<p>A VM manager for Termix: every VM on every host you add, in one tab, through one fixed command on each host</p>

</div>

<br />

## Overview

Hundred Acre Wood (HAW, the HAW VM Manager) is a [Termix](https://github.com/Termix-SSH/Termix) plugin. You add any Termix host as a VM host and choose its interface (Hyper-V in 1.0). HAW then lists the host's VMs and starts, stops and restarts them, and opens their consoles through the Remote Desktop plugin.

HAW can't run a command of its choosing on a host. Each host has a small script, `vmctl`, that sshd forces for an account with no rights of its own; on Hyper-V a worker task that runs as SYSTEM checks each request again and does the work. HAW sends it one JSON request at a time. The host keeps its own limits, in a file HAW can't change: which VMs HAW may act on, which VMs it may never stop, and how much CPU and memory running VMs may take.

Read the [docs](docs/index.md) to set it up and use it.

<br />

## Features

- Add any Termix host as a VM host and choose its interface; HAW checks it with `vmctl info`, and shows the one-time setup when vmctl is not there yet
- Every VM with its state, CPUs, memory, addresses and uptime
- Start, shut down, turn off, restart and reset, each after a confirm
- A protect list, a name pattern and ceilings kept on the host, checked by the host on every request
- Open a VM's console in the Remote Desktop plugin (Hyper-V VMConnect)
- Three roles: owner, operator and viewer
- Every action recorded with who, what, where and the answer, in HAW and in Termix's audit log
- A VM service for other plugins (Runbooks VM steps), for the plugins an admin allows, as the person who acts
- One protocol for every hypervisor ([vmctl protocol](docs/protocol.md)); Hyper-V first, more back ends later

<br />

## Docs

- [Setup and use](docs/index.md)
- [Hyper-V hosts](docs/hyper-v.md)
- [The vmctl protocol](docs/protocol.md)
- [Security](docs/security.md)
- [For other plugins: the VM service](docs/service.md)

<br />

## Requirements

Termix 26.11.0 or later (plugin API 1.13). Consoles need the Remote Desktop plugin. A Hyper-V host needs Windows with Hyper-V and the OpenSSH server.

<br />

## Install

From the community registry, once listed: Plugins, Browse.

From a release file: an admin turns on developer mode and uses Plugins, Install from file with the `.tmxplug` from [Releases](https://github.com/Coolroo/termix-plugin-haw/releases). A file installed this way is unverified.

<br />

## Development

```bash
npm ci
npm run typecheck
npm test
npm run build
npm run validate
node tools/release-files.mjs --check
```

`vmctl/fake/vmctl-fake.mjs` is a back end with no hypervisor, for tests and rehearsals. The Hyper-V back end's tests are Pester 5 tests in `vmctl/hyperv/tests`.

<br />

## License

Apache-2.0. See [LICENSE](LICENSE).
