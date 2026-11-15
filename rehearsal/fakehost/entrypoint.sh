#!/bin/sh
# On first start, makes one client key pair per account in /keys (root only)
# and puts each public key in the account's authorized_keys. The rehearsal
# copies the private keys into Termix as credentials. Then runs sshd.
set -e
install -d -m 0700 /keys
for u in vmctl nohaw garbage; do
  if [ ! -f "/keys/$u" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "haw-reh-$u" -f "/keys/$u"
  fi
  install -m 0600 -o "$u" -g "$u" "/keys/$u.pub" "/home/$u/.ssh/authorized_keys"
done
exec /usr/sbin/sshd -D -e
