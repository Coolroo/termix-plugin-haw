#!/bin/sh
# Starts a throwaway rehearsal on this Docker host: the fake VM host and a
# fresh Termix on an internal network, no published port. Run it from a copy
# of the rehearsal folder that also holds vmctl-fake.mjs and the .tmxplug:
#
#   TERMIX_IMAGE=<termix image> PLUGIN=haw-1.0.0.tmxplug sh up.sh
#
# Everything it makes is named haw-reh-*; down.sh removes it all.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
TERMIX_IMAGE=${TERMIX_IMAGE:?set TERMIX_IMAGE to a Termix 26.11.0 or later image}
PLUGIN=${PLUGIN:-haw-1.0.0.tmxplug}
LOCK=${LOCK:-}   # optional: a flock file that serialises heavy jobs (builds)

build() {
  if [ -n "$LOCK" ]; then
    flock "$LOCK" docker build -q -t haw-reh-fakehost -f "$here/fakehost/Dockerfile" "$here"
  else
    docker build -q -t haw-reh-fakehost -f "$here/fakehost/Dockerfile" "$here"
  fi
}

[ -f "$here/vmctl-fake.mjs" ] || { echo "copy vmctl/fake/vmctl-fake.mjs next to up.sh" >&2; exit 1; }
[ -f "$here/$PLUGIN" ] || { echo "copy $PLUGIN next to up.sh" >&2; exit 1; }

build
docker network create --internal haw-reh-net >/dev/null
docker volume create haw-reh-termix-data >/dev/null

# Every container has a memory cap, so a rehearsal can't starve its host.
docker run -d --name haw-reh-fakehost --hostname fakehost \
  --memory 256m --memory-swap 256m \
  --network haw-reh-net --network-alias fakehost haw-reh-fakehost >/dev/null

# No -p: Termix is reached only from inside its own network namespace.
docker run -d --name haw-reh-termix --network haw-reh-net \
  --memory 1200m --memory-swap 1200m \
  -v haw-reh-termix-data:/app/data \
  -e TERMIX_REQUIRE_SIGNED_PLUGINS=false \
  -e ALLOW_REGISTRATION=true \
  "$TERMIX_IMAGE" >/dev/null

# The client keys the fake host made, into Termix's container (for the
# credentials), with the plugin file and the driver.
i=0
until docker exec haw-reh-fakehost test -f /keys/garbage; do
  i=$((i + 1)); [ $i -lt 20 ] || { echo "fake host made no keys" >&2; exit 1; }
  sleep 0.5
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/haw-reh-XXXXXX")
chmod 700 "$tmp"
docker cp -q haw-reh-fakehost:/keys "$tmp/keys"
docker exec haw-reh-termix mkdir -p /tmp/haw-reh
docker cp -q "$tmp/keys" haw-reh-termix:/tmp/haw-reh/keys
rm -rf "$tmp"
docker cp -q "$here/$PLUGIN" haw-reh-termix:/tmp/haw-reh/plugin.tmxplug
for f in lib.mjs setup.mjs checks.mjs; do docker cp -q "$here/$f" haw-reh-termix:/tmp/haw-reh/$f; done
echo "up: haw-reh-fakehost, haw-reh-termix on haw-reh-net"
