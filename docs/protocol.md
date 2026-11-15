# The vmctl protocol, version 1

HAW never runs a shell command of its choosing on a VM host. It connects over
SSH as an account whose only command is `vmctl`, sends one request, and reads
one reply. Every back end (Hyper-V's `vmctl.ps1`, a later libvirt `vmctl`)
speaks this same protocol, so the plugin does not know which hypervisor it
talks to.

## Transport

- HAW runs the interface's command on the host through Termix's SSH pipeline
  (the host's stored login and its stored host key). For Hyper-V the command is
  `powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:/ProgramData/haw/vmctl.ps1`.
  On a host set up as documented, sshd forces that command for the vmctl
  account (`ForceCommand`), so the command HAW sends is ignored and nothing
  else can run.
- The request is **one line of JSON on standard input**, ended by a newline.
- The reply is **one line of JSON on standard output**: the last non-empty line
  that starts with `{`. A back end writes nothing else to standard output; its
  logs go to standard error, which HAW shows only in errors, cut to 2 KB.
- The exit code is 0 when the reply was written, also for `"ok": false`. Any
  other exit code with no reply means vmctl did not run (not installed, crashed).
- A request is at most 64 KB and a reply at most 1 MB.

## Request

```json
{
  "haw": "vmctl",
  "v": 1,
  "id": "5f0c...",
  "verb": "show",
  "args": { "name": "web-1" }
}
```

| Field  | Type                           | Meaning                                                            |
| ------ | ------------------------------ | ------------------------------------------------------------------ |
| `haw`  | `"vmctl"`                      | Marks the message. Anything else is refused.                       |
| `v`    | integer                        | The protocol version the plugin speaks.                            |
| `id`   | string, 1-64 of `[A-Za-z0-9-]` | Echoed in the reply, so a reply can't be mistaken for another one. |
| `verb` | string                         | One of the verbs below.                                            |
| `args` | object                         | The verb's arguments. Unknown keys are refused.                    |

## Reply

```json
{ "haw": "vmctl", "v": 1, "id": "5f0c...", "ok": true, "result": { } }
{ "haw": "vmctl", "v": 1, "id": "5f0c...", "ok": false, "error": { "code": "protected", "message": "web-1 is on this host's protect list" } }
```

`v` in a reply is the version the back end answered in. When the request's
`v` is one the back end does not speak, it answers `ok: false` with code
`version` and `error.versions`, the list it does speak. `id` is the request's
id, or `null` when the request could not be read.

### Error codes

| Code                  | Meaning                                                                     |
| --------------------- | --------------------------------------------------------------------------- |
| `bad-request`         | Not JSON, a missing or wrong field, an unknown argument.                    |
| `version`             | The back end does not speak this `v`. `error.versions` lists those it does. |
| `unknown-verb`        | Not a verb of this protocol.                                                |
| `not-in-this-version` | A verb of the protocol that this back end version does not do yet.          |
| `name-not-allowed`    | The VM's name does not match the host's allow pattern.                      |
| `protected`           | The VM is on the host's protect list.                                       |
| `ceiling`             | The action would take the host past one of its ceilings.                    |
| `not-found`           | No VM of that name.                                                         |
| `wrong-state`         | The VM can't do that now (start a running VM, stop an off one).             |
| `config`              | The host-side config file is missing or wrong. `info` still answers.        |
| `backend`             | The hypervisor refused or failed. `message` says why.                       |

## The host's own limits

Each host keeps a config file that only its administrators can change (for
Hyper-V `C:\ProgramData\haw\vmctl.json`, readable by the vmctl account, never
writable by it). No verb changes it.

```json
{
  "namePattern": "^[a-z][a-z0-9-]{0,62}$",
  "protected": ["test-*", "build-1"],
  "ceilings": { "cpus": 16, "memoryMB": 32768, "diskGB": 500 },
  "console": { "host": "hv1.example.lan", "port": 2179 }
}
```

- `namePattern`: a regular expression for the VMs that HAW may act on. A VM
  whose name does not match is listed with `allowed: false`. `show` still
  answers; every action on it, and `console-info` (a console is control of the
  VM), is refused with `name-not-allowed`. Default `^[a-z][a-z0-9-]{0,62}$`.
- `protected`: names or wildcards (`*` and `?`, no case). A protected VM is
  listed with `protected: true`. It can be started, but `stop`, `restart` (and
  in later versions `delete`, `snapshot`, `restore`) are refused with
  `protected`.
- `ceilings`: the most CPUs and memory that running VMs may have together, and
  the most disk that VMs may take. `start` is refused with `ceiling` when the VM
  would take running VMs past `cpus` or `memoryMB`. `diskGB` is for `create`.
  A missing ceiling means no limit.
- `console`: the name and port a console client connects to. The name is the
  one the console's certificate carries. Default: the machine's name, 2179.

## Verbs

A VM in a result:

```json
{
  "name": "web-1",
  "id": "8d1c3a8e-9a51-4c47-8a0d-5d0f5b3e7d10",
  "state": "running",
  "cpus": 2,
  "memoryMB": 4096,
  "uptimeSeconds": 3600,
  "addresses": ["192.0.2.10"],
  "allowed": true,
  "protected": false
}
```

`state` is one of `running`, `off`, `paused`, `saved`, `starting`, `stopping`,
`other`. `memoryMB` is the memory the VM has now when it runs, else its
startup memory. `addresses` may be empty (no guest services).

| Verb                                               | Args               | Result                                                                                                                 |
| -------------------------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `info`                                             | none               | `{ host, backend, protocol, capacity, networks, verbs, limits }` (below)                                               |
| `list`                                             | none               | `{ vms: [VM, ...] }`, sorted by name                                                                                   |
| `show`                                             | `{ name }`         | `{ vm: VM + { generation, disks: [{ sizeGB, usedGB }], networks: [{ switch, mac, addresses }], checkpoints, notes } }` |
| `start`                                            | `{ name }`         | `{ vm: VM }` after the start                                                                                           |
| `stop`                                             | `{ name, force? }` | `{ vm: VM }`. `force: false` (default) asks the guest to shut down; `true` turns it off.                               |
| `restart`                                          | `{ name, force? }` | `{ vm: VM }`. Default: shut down, then start. `force: true`: a hard reset.                                             |
| `console-info`                                     | `{ name }`         | `{ console: { kind: "vmconnect", host, port, vmId } }`                                                                 |
| `create`, `delete`, `snapshot`, `restore`, `users` | any                | `not-in-this-version` in version 1.0 of every back end                                                                 |

`info`:

```json
{
  "host": { "name": "HV1" },
  "backend": { "kind": "hyper-v", "version": "1.0.0" },
  "protocol": { "versions": [1] },
  "capacity": {
    "cpus": 16,
    "memoryMB": 65536,
    "freeMemoryMB": 20480,
    "disks": [{ "name": "C:", "sizeGB": 930, "freeGB": 410 }]
  },
  "networks": [{ "name": "LAN", "kind": "external" }],
  "verbs": ["info", "list", "show", "start", "stop", "restart", "console-info"],
  "limits": {
    "namePattern": "^[a-z][a-z0-9-]{0,62}$",
    "protected": ["test-*"],
    "ceilings": { "cpus": 16, "memoryMB": 32768, "diskGB": 500 }
  },
  "configProblem": null
}
```

`verbs` lists only the verbs this back end does. `configProblem` is a message
when the config file is missing or wrong; then every verb but `info` answers
`config`, and `limits` may be `null` or the defaults.

## Rules for a back end

- Check the request fully before acting; refuse unknown arguments.
- Check the allow pattern, the protect list and the ceilings itself. The plugin
  checks nothing on the host's behalf and can be wrong or old.
- Never run a VM name, or any other request text, as code.
- Answer within 120 seconds; HAW gives up after that.
