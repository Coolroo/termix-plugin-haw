# A fake VM host for a HAW rehearsal: OpenSSH and node, with vmctl-fake.mjs
# forced for the account "vmctl". Build from the rehearsal folder:
#   docker build -t haw-reh-fakehost -f fakehost/Dockerfile .
# (the build context needs vmctl-fake.mjs copied next to fakehost/, see up.sh)
FROM node:22-alpine

RUN apk add --no-cache openssh-server \
 && ssh-keygen -A \
 # vmctl: the account HAW uses; its only command is the forced vmctl.
 # nohaw: a plain account with a shell and no vmctl, for the "not set up" path.
 # garbage: an account whose forced command answers with garbage.
 # "*" is no usable password; "!" would lock the account for sshd without PAM.
 && for u in vmctl nohaw garbage; do \
      adduser -D -s /bin/sh "$u" && sed -i "s/^$u:[^:]*:/$u:*:/" /etc/shadow; \
      install -d -m 0700 -o "$u" -g "$u" "/home/$u/.ssh"; \
    done \
 && install -d -m 0755 /opt/haw /etc/haw \
 && install -d -m 0755 -o vmctl -g vmctl /var/lib/haw

COPY vmctl-fake.mjs /opt/haw/vmctl-fake.mjs
COPY fakehost/vmctl.json /etc/haw/vmctl.json
COPY fakehost/garbage.sh /opt/haw/garbage.sh
COPY fakehost/sshd-haw.conf /tmp/sshd-haw.conf
COPY fakehost/entrypoint.sh /entrypoint.sh

RUN chown root:root /opt/haw/vmctl-fake.mjs /etc/haw/vmctl.json /opt/haw/garbage.sh \
 && chmod 0644 /opt/haw/vmctl-fake.mjs /etc/haw/vmctl.json \
 && chmod 0755 /opt/haw/garbage.sh /entrypoint.sh \
 && cat /tmp/sshd-haw.conf >> /etc/ssh/sshd_config && rm /tmp/sshd-haw.conf \
 && ln -sf /usr/local/bin/node /usr/bin/node \
 && /usr/sbin/sshd -t

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
