# HAW rehearsal

An end-to-end run of the packed plugin in a throwaway Termix, against a fake
VM host, on any Docker host (rootless Docker works). Nothing is published on
a port: Termix and the fake host share an internal Docker network, the driver
runs inside the Termix container and talks to it over loopback, and the
browser for screenshots shares Termix's network namespace. Everything the
rehearsal makes is named `haw-reh-*`; `down.sh` removes all of it.

## What is in this folder

| File                     | What it does                                                                                                                                                                                                                                                                                                         |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fakehost/Dockerfile`    | The fake VM host: node 22 and OpenSSH. Account `vmctl` runs only `vmctl-fake.mjs` (sshd `ForceCommand`, no TTY, no forwarding); `nohaw` has a plain shell and no vmctl; `garbage` is forced to a script that answers with text that is not a vmctl reply. Key logins only. `/etc/haw/vmctl.json` is root-owned 0644. |
| `fakehost/entrypoint.sh` | On first start, makes one ed25519 client key per account in `/keys` and installs the public keys.                                                                                                                                                                                                                    |
| `up.sh`                  | Builds the fake host image, makes the network `haw-reh-net` (`--internal`) and the volume, starts `haw-reh-fakehost` and `haw-reh-termix` (no `-p`), and copies the client keys, the `.tmxplug` and the driver into the Termix container.                                                                            |
| `run.sh`                 | Runs the rehearsal: `setup.mjs`, `checks.mjs main`, the screenshots (optional), `checks.mjs delete`, then the fake host's sshd log and state file, and Termix's log.                                                                                                                                                 |
| `lib.mjs`                | Requests over loopback with the `jwt` cookie, as the browser sends them, and the SSH terminal's socket for the host key prompt.                                                                                                                                                                                      |
| `setup.mjs`              | First admin, developer mode, the plugin from file (with the capabilities it asks for), three key credentials, the hosts, and the host keys.                                                                                                                                                                          |
| `checks.mjs`             | Every check, each printed as `PASS`/`FAIL` with the HTTP status and the key part of the body.                                                                                                                                                                                                                        |
| `shots/shots.mjs`        | Screenshots with Playwright (owner at 1280, 820 and 390 wide, a VM's details on desktop and phone, the filter and Limits, the Turn off confirm, both console panels, the record, Add VM host with the setup steps, the viewer).                                                                                      |
| `down.sh`                | Removes every container, volume, network and image named `haw-reh-*`.                                                                                                                                                                                                                                                |

## Run it

On the Docker host, in a private work folder:

```sh
mkdir -m 700 work && cd work
cp -r <repo>/rehearsal/. .
cp <repo>/vmctl/fake/vmctl-fake.mjs <repo>/haw-1.0.0.tmxplug .

# Optional: LOCK=<file> makes the image build wait on flock(1).
TERMIX_IMAGE=<a Termix 26.11.0 or later image> PLUGIN=haw-1.0.0.tmxplug sh up.sh

# Without screenshots:
sh run.sh

# With screenshots: playwright-core next to the script, then a Playwright image.
mkdir pw && (cd pw && npm init -y >/dev/null && npm i playwright-core@1.49.1)
PW_DIR=$PWD/pw SHOTS_OUT=$PWD/out sh run.sh   # PNGs in ./out

sh down.sh && cd .. && rm -rf work
```

`run.sh` takes `PW_IMAGE` (default `mcr.microsoft.com/playwright:v1.49.1-noble`)
and `CHROME` (the Chromium binary inside that image) when another version is used.

## How the throwaway Termix is set up

- `TERMIX_REQUIRE_SIGNED_PLUGINS=false`: a file install is refused otherwise,
  even in developer mode. `ALLOW_REGISTRATION=true` for the extra people.
- The plugin goes in through `POST /plugins/upload` and
  `POST /plugins/upload/<token>/install` with exactly the capabilities the
  upload lists; core grants them and starts the plugin.
- Host keys are stored the way Termix stores them: `setup.mjs` opens the SSH
  terminal's socket (`/plugin-ws/ssh-terminal/terminal`), sends
  `connectToHost` for the saved host, and answers the
  `host_key_verification_required` prompt with `accept`. The login after it
  fails for `vmctl` and `garbage` (no TTY), as the setup steps say it will.
  The host "fakehv (no host key)" is the same account, never prompted, so it
  has no stored key.
- Roles: `POST /rbac/roles`, then `PUT /rbac/roles/<id>` with
  `permissions: ["haw.view"]` (or `haw.operate`), then
  `POST /rbac/users/<userId>/roles`. The VM host's Termix host is shared with
  each person (`POST /rbac/host/<id>/share`, level `connect`; the host has
  `shareSshAuth` on), because HAW reaches only hosts the person can connect to.

## The ceiling check

The fake back end's three default VMs together need exactly the ceilings in
`vmctl.json` (8 CPUs, 16384 MB), so no start can pass them. `run.sh` gives
`test-vm1` 4 CPUs in the fake host's state file before the first call, as the
host's administrator would. The checks then stop web-1, start test-vm1 (8 CPUs),
and a start of web-1 is refused with `ceiling` (10 CPUs); later, with web-1
running again, a start of test-vm1 is refused the same way.

## Proof that every call ran the forced command

`run.sh` counts sshd's `Starting session: forced-command (config) 'node
/opt/haw/vmctl-fake.mjs ...' for vmctl` lines and prints the state file. The
host removal is checked with the state file's SHA-256 and the count of vmctl
logins before and after `DELETE /hosts/<id>`: both stay the same.
