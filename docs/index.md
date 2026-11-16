# Hundred Acre Wood: setup and use

HAW (Hundred Acre Wood, the HAW VM Manager) shows the VMs of each host you
add, and starts, stops and restarts them from one Termix tab. HAW 1.0 reads
and powers VMs. Making and deleting VMs, users and a shared file area come in
later versions.

- [The vmctl protocol](protocol.md): what HAW sends to a host and what it reads back
- [Hyper-V hosts](hyper-v.md): the one-time setup of a Windows machine
- [Security](security.md): what HAW can and can't do on a host

## How it works

HAW never runs a command of its choosing on a host. On each VM host, a small
script, **vmctl**, is the only thing HAW can run: sshd forces it for an
account that HAW logs in as, and that account has no rights of its own. On
Hyper-V, vmctl hands each request to a worker task that runs as SYSTEM and
checks it again before it acts ([Hyper-V hosts](hyper-v.md)). HAW sends one
JSON request and reads one JSON reply. The host keeps
its own limits in a file HAW can't change: which VM names HAW may act on, a
protect list of VMs that are never stopped from HAW, and ceilings for CPUs and
memory.

## Roles

An admin gives each person one of three permissions, under Roles in Termix's
admin settings. Each includes the ones below it.

| Permission      | Role     | Can                                                              |
| --------------- | -------- | ---------------------------------------------------------------- |
| Manage VM hosts | owner    | Add and remove VM hosts, link consoles                           |
| Power VMs       | operator | Start, shut down, turn off, restart and reset VMs; open consoles |
| See VMs         | viewer   | See VM hosts, their VMs and the record                           |

By default only admins hold them. A person also needs access to the Termix
host itself: HAW connects as the person who clicks, through Termix's own SSH
pipeline, so Termix's sharing rules apply.

## Add a VM host

1. Set up vmctl on the machine ([Hyper-V](hyper-v.md)). The steps also show in
   HAW when a check finds no vmctl.
2. In the **VMs** tab, press **Add VM host**.
3. Choose the Termix host that logs in as the vmctl account (or press **Add a
   host in Termix** to make one, then **Reload hosts**).
4. Choose its interface (**Hyper-V** in HAW 1.0) and press **Check**. HAW runs
   `vmctl info`. When it answers, press **Add VM host**.

HAW refuses a host whose host key Termix has not stored yet: open an SSH
terminal to it once and accept the key after you compare its fingerprint.

Removing a VM host only makes HAW forget it. Its VMs, and the Termix host, are
not touched.

## VMs

Each VM host lists its VMs with their state, CPUs, memory, addresses and
uptime. A VM marked **protected** is on the host's protect list: it can be
started but never stopped from HAW. A VM marked **not managed** has a name
outside the host's name pattern: HAW only shows it.

Power buttons ask first:

- **Start**
- **Shut down**: the guest shuts down (it needs the guest's integration services)
- **Turn off**: the VM stops at once, like pulling the plug
- **Restart**: shut down, then start
- **Reset**: a hard reset

The host checks its own limits again on every action, so a button HAW shows
can still be refused, for example when a start would go past the host's
ceilings.

## Consoles

HAW opens a VM's console in the **Remote Desktop** plugin. For a Hyper-V VM,
Remote Desktop needs a saved Termix host with Remote Desktop on, port 2179,
security **VMConnect**, the Hyper-V machine's address, a Windows login on that
machine, and the VM's id as the preconnection blob. HAW 1.0 can't make hosts,
so an owner makes that host once and links it in the VM's **Console** panel,
which shows the VM id and port. After that, every operator opens the console
with one click.

## The record

Every action (adding or removing a host, each power action, each console link)
is kept with who did it, when, and what the host answered, in HAW's own tables
and in Termix's audit log (`haw.<action>`). **Record** in the tab shows it.
