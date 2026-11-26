# The VM service, for other plugins

HAW 1.0.3 provides the service `haw.vms`, version 1.0.0; HAW 1.0.6 provides
version 1.1.0, which adds `resume`. Another plugin uses
it to do VM actions for the person who uses that plugin: Runbooks runs a VM
step when a person presses its button, for example. HAW checks that person's
HAW role, runs `vmctl` exactly as its own tab does, and records the action
with the plugin that asked.

A person always acts. The service never acts for an agent: a call marked for
an agent token can only list hosts and VMs (see [Agent tokens](#agent-tokens)).

## Turn it on

An admin lists the plugins that may use the service, in HAW's settings
(**Plugins that may act for a person**): plugin ids, one a line. The list is
empty by default, and HAW refuses every call from a plugin that is not on it,
also from a plugin that bound earlier. For VM steps in Runbooks, add
`runbooks`.

## Use it

Declare it in your manifest, as optional, so your plugin works without HAW:

```json
"requires": [
  { "service": "haw.vms", "versionRange": "^1.0.0", "optional": true }
]
```

Then get it in your backend. While HAW is not running, the handle is an
empty object. Under plugin API 2 (Termix 26.11.2 and later) `services.get`
answers with a Promise; `await` works on both versions:

```ts
const vms = await ctx.services.get<VmService>("haw.vms");
if (!("list" in vms)) {
  // HAW is not installed or not running.
}
```

Core runs every call as the acting user and checks first that the user holds
**See VMs** (`haw.view`). Call it from the person's request, or from
background work wrapped in `ctx.asUser`.

## How HAW knows it is you

Core does not tell a service which plugin is calling, so HAW can't trust a
plugin id given as an argument. It hands each plugin a key instead, through
an entry only that plugin can make. This is the handshake of OpenBao Secrets'
service.

1. In `activate`, provide a receiver at `<your plugin id>.hawVmsKey` in
   `ctx.registry`. Core lets a plugin provide registry keys under its own id
   only, so no other plugin can put a receiver there.
2. Call `bindPlugin("<your plugin id>")`. HAW calls your receiver with your
   key. The key is never returned to the caller, so another plugin that calls
   `bindPlugin` with your id only sends your key to you. HAW gives a key only
   to a plugin on the admin's list.
3. Pass the key in the caller, the first argument of every call.

Under plugin API 2, your manifest must list the receiver's key in its
`sandbox` block (`"sandbox": { "registry": ["<your plugin id>.hawVmsKey"] }`),
or `ctx.registry.provide` throws. HAW 1.0.5 and later wait for the receiver
that core hands over as a Promise there.

Anyone may call your receiver, so take a key only while your own
`bindPlugin` call runs. HAW makes new keys each time it starts: when a call
fails with code `bad-key`, bind again and repeat the call once.

## The caller

```ts
interface Caller {
  plugin: string; // your plugin id
  key: string; // from bindPlugin
  user: string; // the acting user's id: ctx.currentActor()
  ref?: string; // your reference, for HAW's record: "runbook 12 step 3"
  agent?: boolean; // a read for an agent token: hosts and list only
}
```

- `user` must be the user core runs the call as. HAW never acts for a user
  named in an argument: a different `user` is refused with
  `not-acting-user`, so a mistake in your plugin fails instead of acting as
  someone else.
- `ref` is one line of at most 200 characters. HAW's record shows it next to
  the plugin ("via runbooks: runbook 12 step 3"), and Termix's audit line
  has it in its details.

## Methods

All methods are async. `host` is a **Termix host id** that HAW manages as a VM
host. `name` is a VM's name, without wildcards.

| Method                                    | Role     | Answers                                                        |
| ----------------------------------------- | -------- | -------------------------------------------------------------- |
| `bindPlugin(pluginId)`                    | any      | nothing; hands your key to your receiver                       |
| `me(caller)`                              | any      | `{ role, version }`: `"owner"`, `"operator"`, `"viewer"`, null |
| `hosts(caller)`                           | viewer   | `[{ hostId, name, address, interface, verbs, lastCheckedAt }]` |
| `info(caller, host)`                      | viewer   | the host's `vmctl info` (protocol `info` result)               |
| `list(caller, host)`                      | viewer   | `[Vm & { consoleHostId }]`                                     |
| `show(caller, host, name)`                | viewer   | the VM's details (protocol `show` result's `vm`)               |
| `start(caller, host, name)`               | operator | the VM after the action (`Vm`)                                 |
| `resume(caller, host, name)` (1.1.0)      | operator | the VM after a paused VM runs on (`Vm`)                        |
| `stop(caller, host, name, { force? })`    | operator | the VM; `force: true` turns it off instead of a shutdown       |
| `restart(caller, host, name, { force? })` | operator | the VM; `force: true` is a hard reset                          |
| `consoleInfo(caller, host, name)`         | operator | `{ console: { kind, host, port, vmId }, consoleHost }`         |

- `hosts` lists only the VM hosts whose Termix host the person can see.
  `verbs` are the verbs `vmctl info` listed when HAW last read the host; offer
  only those.
- `resume` is like `start`: who may start may resume, and the protect list
  allows it. Offer it for a `paused` VM, and only when the service has the
  method (`typeof vms.resume === "function"`, HAW 1.0.6 or later) and the
  host's `verbs` list `"resume"` (vmctl 1.1.0 or later). A host with an older
  vmctl answers `unknown-verb`, with a message that says to update vmctl.
- A `paused` VM with `critical: true` was paused by the hypervisor itself,
  most often because the drive with its disk is almost full. `show` gives
  that drive's free space as `drive` (or null); say it to the person before
  a resume, since the VM pauses again while the drive stays full.
- `Vm`, the VM details and the console are the shapes in the
  [protocol](protocol.md#verbs). `consoleHost` is the Termix host linked to
  open the console in the Remote Desktop plugin, `{ id, name }`, or null.
- `force` asks the host to turn off or reset without asking the guest. HAW
  records it. Asking the person to confirm it is your plugin's job.
- The host's own limits apply to every call, as in the tab: the name pattern,
  the protect list and the ceilings.

## Errors

Every refusal is an `Error` with a `code`, the HTTP `status` the tab would
answer, and, for some codes, `detail` (what vmctl printed) or `versions`.

| Code                   | Status | Why                                                                                                                              |
| ---------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------- |
| `no-actor`             | 401    | No acting user                                                                                                                   |
| `bad-request`          | 400    | A caller, host, VM name or `force` that is not valid                                                                             |
| `bad-key`              | 403    | The key is not this plugin's: bind again                                                                                         |
| `plugin-not-allowed`   | 403    | The plugin is not on the admin's list                                                                                            |
| `no-receiver`          | 409    | `bindPlugin`: no `<id>.hawVmsKey` receiver, or it refused the key                                                                |
| `not-acting-user`      | 403    | `caller.user` is not the acting user                                                                                             |
| `agent-read-only`      | 403    | A call for an agent token, other than `hosts` and `list`                                                                         |
| `role`                 | 403    | The person's HAW role is too low                                                                                                 |
| `not-a-vm-host`        | 404    | `host` is not a VM host, or the person can't see its Termix host                                                                 |
| `no-access`, `not-ssh` | 403    | The person can't connect to the host, or it has no SSH                                                                           |
| `no-host-key`          | 409    | Termix has no stored host key for the host                                                                                       |
| `unreachable`          | 502    | The SSH login failed                                                                                                             |
| `timeout`              | 504    | vmctl did not answer in time                                                                                                     |
| `no-reply`             | 502    | vmctl sent no reply (`detail` has what it printed)                                                                               |
| `protocol`             | 502    | vmctl's reply breaks the protocol                                                                                                |
| the protocol's codes   | varies | vmctl refused: `not-found`, `protected`, `name-not-allowed`, `ceiling`, `wrong-state`, ... ([protocol](protocol.md#error-codes)) |

A call refused before it reaches a host (key, list, user, agent, role) has a
line in Termix's audit log, `haw.service.<method>`.

## The record

Every power action and every `consoleInfo` goes into HAW's record, done or
refused by the host, with the person, the plugin and its `ref`. The tab's
**Record** and a VM's last action show "via `<plugin>`: `<ref>`". Termix's
audit log gets `haw.start`, `haw.resume`, `haw.stop`, `haw.restart` or `haw.console`, as the
person, with "via `<plugin>`: `<ref>`" in its details. Core also writes its
own audit line for every service call, with the calling plugin.

Reads (`hosts`, `info`, `list`, `show`) are not in HAW's record, so a plugin
that polls `show` while it waits for a state does not fill it. Core's audit
line for each service call still has them.

## Agent tokens

To write a correct VM step, an agent needs the VM names. A plugin that serves
agents with tokens (Runbooks' agent API) can read the list for a token as the
person who made the token (`ctx.asUser`) and set `agent: true`. HAW then
answers `hosts` and `list` only; any other call is refused with
`agent-read-only`. Show the agent only the hosts its token may name.

## Example

A consumer plugin with the id `runbooks`:

```ts
let binding = false;
let key: string | null = null;
await ctx.registry.provide("runbooks.hawVmsKey", (given: string) => {
  if (!binding) throw new Error("not binding");
  key = given;
});

async function bind(vms: VmService) {
  binding = true;
  try {
    await vms.bindPlugin("runbooks");
  } finally {
    binding = false;
  }
}

const vms = await ctx.services.get<VmService>("haw.vms");
if (!key) await bind(vms);
const caller = {
  plugin: "runbooks",
  key: key!,
  user: ctx.currentActor()!,
  ref: "runbook 12 step 3",
};
const vm = await vms.start(caller, 4, "wyatt-pc-builder");
// { name: "wyatt-pc-builder", state: "running", addresses: [...], ... }
```

The types, to copy into your plugin:

```ts
type VmState =
  "running" | "off" | "starting" | "stopping" | "saved" | "paused" | "other";

interface Vm {
  name: string;
  id: string;
  state: VmState;
  cpus: number;
  memoryMB: number;
  uptimeSeconds: number;
  addresses: string[];
  /** Inside the host's name pattern. */
  allowed: boolean;
  /** On the host's protect list: never stopped from HAW. */
  protected: boolean;
  /** 1.1.0: the hypervisor's words for the VM's health; "" before. */
  status: string;
  /** 1.1.0: the hypervisor marks it critical (Hyper-V Paused-Critical). */
  critical: boolean;
}

interface VmDetail extends Vm {
  generation: number | null;
  disks: Array<{ sizeGB: number | null; usedGB: number | null }>;
  networks: Array<{ switch: string; mac: string; addresses: string[] }>;
  checkpoints: number;
  notes: string;
  /** 1.1.0: the drive with the first disk file, or null. */
  drive: { name: string; sizeGB: number; freeGB: number } | null;
}

interface Caller {
  plugin: string;
  key: string;
  user: string;
  ref?: string;
  agent?: boolean;
}

interface VmService {
  bindPlugin(pluginId: string): Promise<void>;
  me(caller: Caller): Promise<{
    role: "owner" | "operator" | "viewer" | null;
    version: string;
  }>;
  hosts(caller: Caller): Promise<
    Array<{
      hostId: number;
      name: string;
      address: string;
      interface: string;
      verbs: string[];
      lastCheckedAt: string | null;
    }>
  >;
  info(caller: Caller, host: number): Promise<unknown>;
  list(
    caller: Caller,
    host: number,
  ): Promise<Array<Vm & { consoleHostId: number | null }>>;
  show(caller: Caller, host: number, name: string): Promise<VmDetail>;
  start(caller: Caller, host: number, name: string): Promise<Vm>;
  /** 1.1.0 (HAW 1.0.6). */
  resume?(caller: Caller, host: number, name: string): Promise<Vm>;
  stop(
    caller: Caller,
    host: number,
    name: string,
    options?: { force?: boolean },
  ): Promise<Vm>;
  restart(
    caller: Caller,
    host: number,
    name: string,
    options?: { force?: boolean },
  ): Promise<Vm>;
  consoleInfo(
    caller: Caller,
    host: number,
    name: string,
  ): Promise<{
    console: { kind: "vmconnect"; host: string; port: number; vmId: string };
    consoleHost: { id: number; name: string } | null;
  }>;
}
```
