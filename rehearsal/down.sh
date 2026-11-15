#!/bin/sh
# Removes everything a rehearsal made: only names that start with haw-reh-.
set -u
for c in $(docker ps -a --format '{{.Names}}' | grep '^haw-reh-'); do
  docker rm -f "$c" >/dev/null && echo "removed container $c"
done
for v in $(docker volume ls --format '{{.Name}}' | grep '^haw-reh-'); do
  docker volume rm "$v" >/dev/null && echo "removed volume $v"
done
for n in $(docker network ls --format '{{.Name}}' | grep '^haw-reh-'); do
  docker network rm "$n" >/dev/null && echo "removed network $n"
done
for i in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^haw-reh-'); do
  docker rmi "$i" >/dev/null && echo "removed image $i"
done
rm -rf "${TMPDIR:-/tmp}"/haw-reh-* 2>/dev/null
echo "left: $(docker ps -a --format '{{.Names}}' | grep -c '^haw-reh-') containers"
