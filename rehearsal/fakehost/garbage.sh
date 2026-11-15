#!/bin/sh
# Reads the request, then answers with text that is not a vmctl reply.
cat >/dev/null
echo "Welcome to a host that does not speak vmctl"
echo '{"hello":"this is JSON but not a vmctl reply"}'
exit 0
