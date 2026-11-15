#!/bin/sh
# Runs the rehearsal after up.sh: setup, the checks, the host removal with
# the fake host's state compared around it, and the after-run log checks.
# Prints PASS/FAIL lines; results land in the Termix container's /tmp/haw-reh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
T=haw-reh-termix
F=haw-reh-fakehost

tar -C "$here" -cf - lib.mjs setup.mjs checks.mjs | docker cp - "$T:/tmp/haw-reh/"
docker exec -w /tmp/haw-reh "$T" node setup.mjs

# The host's admin gives test-vm1 4 CPUs, so the three VMs together pass the
# 8 CPU ceiling in vmctl.json and a start can be refused with "ceiling".
docker exec -u vmctl "$F" node --input-type=module -e '
import { existsSync, writeFileSync } from "node:fs";
const { defaultState } = await import("/opt/haw/vmctl-fake.mjs");
const file = "/var/lib/haw/state.json";
if (!existsSync(file)) {
  const s = defaultState();
  s.vms.find((v) => v.name === "test-vm1").cpus = 4;
  writeFileSync(file, JSON.stringify(s, null, 2));
}'

docker exec -w /tmp/haw-reh "$T" node checks.mjs main

# Screenshots, when PW_DIR holds playwright-core (npm i playwright-core@1.49.1)
# and SHOTS_OUT is where the PNGs go. The browser shares Termix's network
# namespace; the state file (passwords) goes in through a private temp dir.
if [ -n "${PW_DIR:-}" ] && [ -n "${SHOTS_OUT:-}" ]; then
  PW_IMAGE=${PW_IMAGE:-mcr.microsoft.com/playwright:v1.49.1-noble}
  CHROME=${CHROME:-/ms-playwright/chromium-1148/chrome-linux/chrome}
  in=$(mktemp -d "${TMPDIR:-/tmp}/haw-reh-in-XXXXXX")
  chmod 700 "$in"
  docker cp -q "$T:/tmp/haw-reh/state.json" "$in/state.json"
  cp "$here/shots/shots.mjs" "$PW_DIR/shots.mjs"
  mkdir -p "$SHOTS_OUT"
  docker run --rm --name haw-reh-shots --network "container:$T" -e CHROME="$CHROME" \
    -v "$PW_DIR":/pw:ro -v "$in":/in:ro -v "$SHOTS_OUT":/out -w /pw "$PW_IMAGE" node shots.mjs \
    || echo "FAIL screenshots [-] see above"
  rm -rf "$in"
fi

# Removing the VM host must make no call: the state file and sshd's count of
# vmctl logins stay the same.
before=$(docker exec "$F" sha256sum /var/lib/haw/state.json)
logins_before=$(docker logs "$F" 2>&1 | grep -c 'Accepted publickey for vmctl' || true)
docker exec -w /tmp/haw-reh "$T" node checks.mjs delete
after=$(docker exec "$F" sha256sum /var/lib/haw/state.json)
logins_after=$(docker logs "$F" 2>&1 | grep -c 'Accepted publickey for vmctl' || true)
if [ "$before" = "$after" ] && [ "$logins_before" = "$logins_after" ]; then
  echo "PASS DELETE made no call on the host [-] state $(echo "$after" | cut -c1-16), vmctl logins $logins_after"
else
  echo "FAIL DELETE made no call on the host [-] state $before -> $after, logins $logins_before -> $logins_after"
fi

echo "--- fake host: sessions per account (sshd log)"
for u in vmctl nohaw garbage; do
  echo "$u: $(docker logs "$F" 2>&1 | grep -c "Accepted publickey for $u") logins, $(docker logs "$F" 2>&1 | grep -c "Starting session: forced-command (config) .* for $u ") forced-command sessions, $(docker logs "$F" 2>&1 | grep -c "Starting session: command for $u ") plain command sessions"
done
docker logs "$F" 2>&1 | grep 'Starting session' | sed 's/ from .*//' | sort | uniq -c
echo "--- fake host: state file"
docker exec "$F" node -e '
const s = JSON.parse(require("fs").readFileSync("/var/lib/haw/state.json", "utf8"));
console.log(s.vms.map((v) => `${v.name}:${v.state}:${v.cpus}cpu`).join(", "));'
docker exec "$F" ls -l /var/lib/haw/state.json
echo "--- termix log: lines about haw that warn or fail"
docker logs "$T" 2>&1 | grep -i 'haw' | grep -i -E 'error|warn|fail' | tail -20 || true
