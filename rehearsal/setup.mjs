// Phase 1: a fresh Termix gets its admin, developer mode, the HAW plugin
// from file, three key credentials, the hosts, and the stored host keys.
//   node setup.mjs        (inside the Termix container, files in $REH_DIR)
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { answerHostKey, DIR, load, login, req, save } from "./lib.mjs";

const FAKEHOST = process.env.FAKEHOST ?? "fakehost";
const state = load();
const say = (...a) => console.log("setup:", ...a);
const must = (r, what, ok = [200, 201]) => {
  if (!ok.includes(r.status)) {
    throw new Error(
      `${what}: ${r.status} ${JSON.stringify(r.body).slice(0, 400)}`,
    );
  }
  return r.body;
};

// Termix answers once its backend is up (nginx says 502 before).
for (let i = 0; ; i++) {
  const r = await req("GET", "/users/setup-required").catch(() => ({
    status: 0,
  }));
  if (r.status === 200) break;
  if (i >= 90) throw new Error(`Termix is not up: ${r.status}`);
  await new Promise((done) => setTimeout(done, 1000));
}

// The admin: the first user. The password stays in the state file only.
state.admin ??= {
  username: "haw-admin",
  password: randomBytes(18).toString("base64url"),
};
if (!state.adminCreated) {
  must(
    await req("POST", "/users/create", { body: state.admin }),
    "create admin",
  );
  state.adminCreated = true;
}
const admin = {
  cookie: await login(state.admin.username, state.admin.password),
};
state.adminCookie = admin.cookie;
save(state);
say("admin signed in");

// Developer mode, then the plugin from file with the capabilities it asks for.
must(
  await req("PUT", "/plugins/developer-mode", {
    auth: admin,
    body: { enabled: true },
  }),
  "developer mode",
);
const dev = must(
  await req("GET", "/plugins/developer-mode", { auth: admin }),
  "read developer mode",
);
say("developer mode", JSON.stringify(dev));
if (!state.installed) {
  const staged = must(
    await req("POST", "/plugins/upload", {
      auth: admin,
      raw: readFileSync(`${DIR}/plugin.tmxplug`),
    }),
    "upload",
  );
  say(
    "staged",
    JSON.stringify({
      id: staged.id,
      version: staged.version,
      capabilities: staged.capabilities,
    }),
  );
  const installed = must(
    await req("POST", `/plugins/upload/${staged.token}/install`, {
      auth: admin,
      body: { capabilities: staged.capabilities },
    }),
    "install",
  );
  say("installed", JSON.stringify(installed));
  state.installed = installed;
  save(state);
}

// Key credentials, one per fake host account.
state.credentials ??= {};
for (const user of ["vmctl", "nohaw", "garbage"]) {
  if (state.credentials[user]) continue;
  const key = readFileSync(`${DIR}/keys/${user}`, "utf8");
  const r = must(
    await req("POST", "/credentials", {
      auth: admin,
      body: {
        name: `haw-reh ${user}`,
        authType: "key",
        username: user,
        key,
        keyType: "ssh-ed25519",
      },
    }),
    `credential ${user}`,
  );
  state.credentials[user] = r.id;
  say("credential", user, r.id);
}
save(state);

// Hosts. "nokey" is vmctl@fakehost again, but its host key is never stored.
const hosts = [
  { tag: "vmctl", user: "vmctl", name: "fakehv (vmctl)", shareSshAuth: true },
  { tag: "nohaw", user: "nohaw", name: "fakehv (no vmctl)" },
  { tag: "garbage", user: "garbage", name: "fakehv (garbage)" },
  { tag: "nokey", user: "vmctl", name: "fakehv (no host key)" },
];
state.hosts ??= {};
for (const h of hosts) {
  if (state.hosts[h.tag]) continue;
  const r = must(
    await req("POST", "/host/db/host", {
      auth: admin,
      body: {
        name: h.name,
        ip: FAKEHOST,
        port: 22,
        username: h.user,
        authType: "credential",
        credentialId: state.credentials[h.user],
        enableSsh: true,
        shareSshAuth: h.shareSshAuth === true,
        statusCheckEnabled: false,
      },
    }),
    `host ${h.tag}`,
  );
  state.hosts[h.tag] = {
    id: r.id,
    ip: FAKEHOST,
    port: 22,
    username: h.user,
    credentialId: state.credentials[h.user],
  };
  say("host", h.tag, r.id);
}
// The console host: only linked to a VM, never connected.
if (!state.hosts.console) {
  const r = must(
    await req("POST", "/host/db/host", {
      auth: admin,
      body: {
        name: "hv1 console",
        ip: "hv1.example.lan",
        port: 2179,
        username: "console",
        authType: "none",
        enableSsh: false,
        statusCheckEnabled: false,
      },
    }),
    "host console",
  );
  state.hosts.console = { id: r.id };
  say("host console", r.id);
}
save(state);

// Host keys, the way Termix stores them: the terminal's prompt, answered
// accept. Not for "nokey".
state.hostKeys ??= {};
for (const tag of ["vmctl", "nohaw", "garbage"]) {
  if (state.hostKeys[tag]) continue;
  // The terminal plugin activates a moment after the first hosts exist; its
  // socket answers 503 until then.
  let answer;
  for (let attempt = 0; attempt < 15; attempt++) {
    answer = await answerHostKey(admin.cookie, state.hosts[tag], "accept");
    if (!String(answer.error ?? "").includes("503")) break;
    await new Promise((done) => setTimeout(done, 2000));
  }
  say("host key", tag, JSON.stringify(answer));
  if (!answer.prompted) throw new Error(`no host key prompt for ${tag}`);
  state.hostKeys[tag] = answer.prompted.fingerprint;
}
save(state);
say("done");
