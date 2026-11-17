// Phase 2: the checks, through /plugin-api/haw/ as the browser calls it.
//   node checks.mjs main     every check but the host removal
//   node checks.mjs delete   DELETE /hosts/<id> (run.sh compares the fake
//                            host's state file around it)
// Each check prints PASS/FAIL with the status and the key part of the body;
// all of them land in $REH_DIR/results-<phase>.json.
import { randomBytes } from "node:crypto";
import { writeFileSync } from "node:fs";
import { DIR, load, login, recorder, req, save } from "./lib.mjs";

const phase = process.argv[2] ?? "main";
const state = load();
const admin = { cookie: state.adminCookie };
const { results, check } = recorder();
const H = state.hosts;
const api = (method, path, auth, body) =>
  req(method, `/plugin-api/haw${path}`, { auth, body });
const short = (b, n = 300) =>
  (typeof b === "string" ? b : JSON.stringify(b)).slice(0, n);

async function main() {
  // Who I am. The plugin answers 503 for a moment after its install.
  let r = await api("GET", "/me", admin);
  for (let attempt = 0; r.status === 503 && attempt < 15; attempt++) {
    await new Promise((done) => setTimeout(done, 2000));
    r = await api("GET", "/me", admin);
  }
  check(
    "GET /me: owner, version 1.0.x, hyper-v with setup steps",
    r.status === 200 &&
      r.body.role === "owner" &&
      /^1\.0\.\d+$/.test(r.body.version) &&
      r.body.interfaces?.[0]?.id === "hyper-v" &&
      r.body.interfaces[0].setup.length > 0,
    r.status,
    {
      role: r.body.role,
      version: r.body.version,
      interface: r.body.interfaces?.[0]?.id,
      steps: r.body.interfaces?.[0]?.setup?.length,
    },
  );

  r = await api("GET", "/termix-hosts", admin);
  check(
    "GET /termix-hosts lists the hosts",
    r.status === 200 &&
      ["vmctl", "nohaw", "garbage", "nokey", "console"].every((t) =>
        r.body.some((h) => h.id === H[t].id),
      ),
    r.status,
    r.body.map((h) => `${h.id}:${h.name}:${h.username}:${h.added}`).join(", "),
  );

  // The checks that must fail, each with its own code.
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.nohaw.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts/check nohaw: no-reply, detail shows the shell",
    r.status === 200 &&
      r.body.ok === false &&
      r.body.code === "no-reply" &&
      /not found|powershell/i.test(r.body.detail ?? ""),
    r.status,
    {
      ok: r.body.ok,
      code: r.body.code,
      error: r.body.error,
      detail: short(r.body.detail, 160),
    },
  );
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.garbage.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts/check garbage: protocol",
    r.status === 200 && r.body.ok === false && r.body.code === "protocol",
    r.status,
    {
      ok: r.body.ok,
      code: r.body.code,
      error: r.body.error,
      detail: short(r.body.detail, 160),
    },
  );
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.nokey.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts/check no stored host key: no-host-key",
    r.status === 200 && r.body.ok === false && r.body.code === "no-host-key",
    r.status,
    { ok: r.body.ok, code: r.body.code, error: r.body.error },
  );
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.console.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts/check console host (no SSH): 400 not-ssh",
    r.status === 400 && r.body.code === "not-ssh",
    r.status,
    r.body,
  );
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.vmctl.id,
    interface: "libvirt",
  });
  check(
    "POST /hosts/check unknown interface: 400",
    r.status === 400,
    r.status,
    r.body,
  );
  // Adding a host that fails its check is refused too.
  r = await api("POST", "/hosts", admin, {
    hostId: H.nohaw.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts nohaw: refused 409 no-reply",
    r.status === 409 && r.body.code === "no-reply",
    r.status,
    short(r.body, 200),
  );

  // The real one.
  r = await api("POST", "/hosts/check", admin, {
    hostId: H.vmctl.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts/check vmctl: ok, fake 1.0.0",
    r.status === 200 &&
      r.body.ok === true &&
      r.body.info?.backend?.kind === "fake" &&
      r.body.info.backend.version === "1.0.0",
    r.status,
    { ok: r.body.ok, backend: r.body.info?.backend, verbs: r.body.info?.verbs },
  );
  r = await api("POST", "/hosts", admin, {
    hostId: H.vmctl.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts vmctl: 201",
    r.status === 201 && Number.isInteger(r.body.id),
    r.status,
    r.body,
  );
  const vmHost = r.body.id;
  state.vmHost = vmHost;
  save(state);
  r = await api("POST", "/hosts", admin, {
    hostId: H.vmctl.id,
    interface: "hyper-v",
  });
  check(
    "POST /hosts vmctl again: 409 added",
    r.status === 409 && r.body.code === "added",
    r.status,
    r.body,
  );

  r = await api("GET", "/hosts", admin);
  const row = Array.isArray(r.body)
    ? r.body.find((h) => h.id === vmHost)
    : null;
  check(
    "GET /hosts: the host with info (fake 1.0.0, protected build-*)",
    r.status === 200 &&
      row?.info?.backend?.kind === "fake" &&
      row.info.backend.version === "1.0.0" &&
      JSON.stringify(row.info.limits?.protected) === '["build-*"]',
    r.status,
    {
      id: row?.id,
      name: row?.name,
      interface: row?.interface,
      backend: row?.info?.backend,
      limits: row?.info?.limits,
    },
  );

  // VMs.
  r = await api("GET", `/hosts/${vmHost}/vms`, admin);
  const names = r.body.vms?.map((v) => v.name);
  check(
    "GET /hosts/<id>/vms: build-1, test-vm1, web-1",
    r.status === 200 &&
      JSON.stringify(names) === '["build-1","test-vm1","web-1"]',
    r.status,
    r.body.vms
      ?.map(
        (v) =>
          `${v.name}:${v.state}:${v.cpus}cpu:${v.memoryMB}MB:protected=${v.protected}`,
      )
      .join(", "),
  );
  r = await api("GET", `/hosts/${vmHost}/vms/web-1`, admin);
  check(
    "GET /hosts/<id>/vms/web-1",
    r.status === 200 &&
      r.body.vm?.name === "web-1" &&
      Array.isArray(r.body.vm.disks),
    r.status,
    {
      name: r.body.vm?.name,
      state: r.body.vm?.state,
      generation: r.body.vm?.generation,
      disks: r.body.vm?.disks,
      networks: r.body.vm?.networks,
    },
  );
  r = await api("GET", `/hosts/${vmHost}/vms/nope-1`, admin);
  check(
    "GET /hosts/<id>/vms/nope-1: 404 not-found",
    r.status === 404 && r.body.code === "not-found",
    r.status,
    r.body,
  );

  // Power. test-vm1 has 4 CPUs on this host (run.sh resized it), so the
  // three VMs together pass the 8 CPU ceiling.
  const power = (name, verb, body, auth = admin) =>
    api("POST", `/hosts/${vmHost}/vms/${name}/${verb}`, auth, body);
  r = await power("web-1", "stop", { force: false });
  check(
    "POST stop web-1 {force:false}: off",
    r.status === 200 && r.body.vm?.state === "off",
    r.status,
    short(r.body.vm, 200),
  );
  r = await power("test-vm1", "start", {});
  check(
    "POST start test-vm1: running",
    r.status === 200 && r.body.vm?.state === "running",
    r.status,
    short(r.body.vm, 200),
  );
  r = await power("build-1", "stop", { force: false });
  check(
    "POST stop build-1: 409 protected",
    r.status === 409 && r.body.code === "protected",
    r.status,
    r.body,
  );
  r = await power("web-1", "start", {});
  check(
    "POST start web-1 past the CPU ceiling: 409 ceiling",
    r.status === 409 && r.body.code === "ceiling",
    r.status,
    r.body,
  );
  r = await power("test-vm1", "stop", { force: true });
  check(
    "POST stop test-vm1 {force:true}: off",
    r.status === 200 && r.body.vm?.state === "off",
    r.status,
    short(r.body.vm, 200),
  );
  r = await power("web-1", "start", {});
  check(
    "POST start web-1: running",
    r.status === 200 && r.body.vm?.state === "running",
    r.status,
    short(r.body.vm, 200),
  );
  r = await power("test-vm1", "start", {});
  check(
    "POST start test-vm1 past the CPU ceiling: 409 ceiling",
    r.status === 409 && r.body.code === "ceiling",
    r.status,
    r.body,
  );
  r = await power("web-1", "restart", { force: true });
  check(
    "POST restart web-1 {force:true}: running",
    r.status === 200 && r.body.vm?.state === "running",
    r.status,
    short(r.body.vm, 200),
  );
  r = await power("web-1", "start", {});
  check(
    "POST start web-1 while running: 409 wrong-state",
    r.status === 409 && r.body.code === "wrong-state",
    r.status,
    r.body,
  );
  r = await power("web-1", "frobnicate", {});
  check("POST unknown verb: 404", r.status === 404, r.status, r.body);
  r = await power("web-1", "stop", { force: "yes" });
  check("POST stop with force:'yes': 400", r.status === 400, r.status, r.body);

  // Console.
  r = await api("GET", `/hosts/${vmHost}/vms/web-1/console`, admin);
  const vmId = r.body.console?.vmId;
  check(
    "GET console web-1: vmconnect hv1.example.lan 2179 + vmId, not linked",
    r.status === 200 &&
      r.body.console?.kind === "vmconnect" &&
      r.body.console.host === "hv1.example.lan" &&
      r.body.console.port === 2179 &&
      typeof vmId === "string" &&
      r.body.consoleHost === null,
    r.status,
    r.body,
  );
  state.webVmId = vmId;
  save(state);
  r = await api("PUT", `/hosts/${vmHost}/consoles/${vmId}`, admin, {
    consoleHostId: H.console.id,
  });
  check(
    "PUT consoles/<vmId> {consoleHostId}",
    r.status === 200 && r.body.consoleHostId === H.console.id,
    r.status,
    r.body,
  );
  r = await api("GET", `/hosts/${vmHost}/vms/web-1/console`, admin);
  check(
    "GET console web-1 after link: consoleHost",
    r.status === 200 && r.body.consoleHost?.id === H.console.id,
    r.status,
    r.body.consoleHost,
  );
  r = await api("GET", `/hosts/${vmHost}/vms`, admin);
  check(
    "GET vms: web-1 carries consoleHostId",
    r.status === 200 &&
      r.body.vms.find((v) => v.name === "web-1")?.consoleHostId ===
        H.console.id,
    r.status,
    r.body.vms?.map((v) => `${v.name}:${v.consoleHostId}`).join(", "),
  );
  r = await api("PUT", `/hosts/${vmHost}/consoles/${vmId}`, admin, {
    consoleHostId: 99999,
  });
  check(
    "PUT consoles with a host that does not exist: 400",
    r.status === 400,
    r.status,
    r.body,
  );

  // The record, in HAW and in Termix's audit log.
  r = await api("GET", `/actions?hostId=${H.vmctl.id}`, admin);
  const actions = Array.isArray(r.body) ? r.body : [];
  const want = ["add-host", "start", "stop", "restart", "link-console"];
  check(
    "GET /actions: every action with ok/code",
    r.status === 200 &&
      want.every((a) => actions.some((x) => x.action === a)) &&
      actions.some((x) => x.ok === false && x.code === "protected") &&
      actions.some((x) => x.ok === false && x.code === "ceiling"),
    r.status,
    actions
      .map(
        (a) =>
          `${a.action}${a.vmName ? " " + a.vmName : ""}${a.force ? " force" : ""}:${a.ok ? "ok" : a.code}`,
      )
      .join(", "),
  );
  r = await api("GET", "/actions", admin);
  check(
    "GET /actions (all hosts): the failed add-host of nohaw is there",
    r.status === 200 &&
      r.body.some(
        (x) =>
          x.action === "add-host" && x.ok === false && x.code === "no-reply",
      ),
    r.status,
    `${r.body.length} actions`,
  );
  r = await req("GET", "/audit-logs?limit=200", { auth: admin });
  const logs = r.body.logs ?? [];
  const haw = logs.filter((l) => /haw/.test(l.action));
  const has = (a) => haw.some((l) => l.action.endsWith(a));
  check(
    "Termix audit log: haw.add-host, haw.start, haw.stop",
    r.status === 200 &&
      has("haw.add-host") &&
      has("haw.start") &&
      has("haw.stop"),
    r.status,
    [
      ...new Set(haw.map((l) => `${l.action}:${l.success ? "ok" : "fail"}`)),
    ].join(", "),
  );
  state.auditSample = haw.slice(0, 3);
  save(state);

  r = await api("POST", `/hosts/${vmHost}/refresh`, admin);
  check(
    "POST /hosts/<id>/refresh",
    r.status === 200 && r.body.info?.backend?.kind === "fake",
    r.status,
    {
      host: r.body.info?.host,
      backend: r.body.info?.backend,
      configProblem: r.body.info?.configProblem,
    },
  );

  await roles(vmHost);
  await apiKey();
}

/** A viewer (haw.view only) and an operator (haw.operate only). */
async function roles(vmHost) {
  const roleIds = {};
  for (const [name, perm] of [
    ["haw-viewer", "haw.view"],
    ["haw-operator", "haw.operate"],
  ]) {
    let r = await req("POST", "/rbac/roles", {
      auth: admin,
      body: { name, displayName: name, description: `HAW ${perm} only` },
    });
    const id = r.body.role?.id ?? r.body.id ?? r.body.roleId;
    check(
      `POST /rbac/roles ${name}`,
      r.status === 201 && Number.isInteger(id),
      r.status,
      short(r.body, 200),
    );
    r = await req("PUT", `/rbac/roles/${id}`, {
      auth: admin,
      body: { permissions: [perm] },
    });
    check(
      `PUT /rbac/roles/${id} permissions [${perm}]`,
      r.status === 200,
      r.status,
      r.body,
    );
    roleIds[name] = id;
  }
  const people = {};
  for (const [user, role] of [
    ["haw-viewer", "haw-viewer"],
    ["haw-operator", "haw-operator"],
  ]) {
    const password = randomBytes(18).toString("base64url");
    let r = await req("POST", "/users/create", {
      body: { username: user, password },
    });
    check(
      `POST /users/create ${user}`,
      r.status === 200,
      r.status,
      r.body.message ?? r.body,
    );
    const cookie = await login(user, password);
    const me = await req("GET", "/users/me", { auth: { cookie } });
    const userId = me.body.userId ?? me.body.id;
    r = await req("POST", `/rbac/users/${userId}/roles`, {
      auth: admin,
      body: { roleId: roleIds[role] },
    });
    check(
      `POST /rbac/users/<id>/roles ${role}`,
      [200, 201].includes(r.status),
      r.status,
      short(r.body, 160),
    );
    r = await req("POST", `/rbac/host/${state.hosts.vmctl.id}/share`, {
      auth: admin,
      body: {
        targets: [{ type: "user", id: userId }],
        permissionLevel: "connect",
      },
    });
    check(
      `POST /rbac/host/<vmctl>/share to ${user}`,
      [200, 201].includes(r.status),
      r.status,
      short(r.body, 160),
    );
    people[user] = { cookie: await login(user, password), userId, password };
  }
  const viewer = { cookie: people["haw-viewer"].cookie };
  const operator = { cookie: people["haw-operator"].cookie };
  state.people = people;
  save(state);

  let r = await api("GET", "/me", viewer);
  check(
    "viewer GET /me: role viewer",
    r.status === 200 && r.body.role === "viewer",
    r.status,
    { role: r.body.role },
  );
  r = await api("GET", "/hosts", viewer);
  check(
    "viewer GET /hosts: sees the shared VM host",
    r.status === 200 && r.body.some((h) => h.id === vmHost),
    r.status,
    short(r.body.map?.((h) => h.name) ?? r.body, 200),
  );
  r = await api("GET", `/hosts/${vmHost}/vms`, viewer);
  check(
    "viewer GET /hosts/<id>/vms: 200",
    r.status === 200 && r.body.vms?.length === 3,
    r.status,
    r.body.vms?.map((v) => `${v.name}:${v.state}`).join(", ") ?? r.body,
  );
  r = await api("POST", `/hosts/${vmHost}/vms/test-vm1/start`, viewer, {});
  check("viewer POST start: 403", r.status === 403, r.status, r.body);
  r = await api("POST", "/hosts", viewer, {
    hostId: state.hosts.nokey.id,
    interface: "hyper-v",
  });
  check("viewer POST /hosts: 403", r.status === 403, r.status, r.body);
  r = await api("GET", `/hosts/${vmHost}/vms/web-1/console`, viewer);
  check("viewer GET console: 403", r.status === 403, r.status, r.body);
  r = await api("GET", "/termix-hosts", viewer);
  check("viewer GET /termix-hosts: 403", r.status === 403, r.status, r.body);

  r = await api("GET", "/me", operator);
  check(
    "operator GET /me: role operator",
    r.status === 200 && r.body.role === "operator",
    r.status,
    { role: r.body.role },
  );
  r = await api("POST", `/hosts/${vmHost}/vms/web-1/stop`, operator, {
    force: false,
  });
  check(
    "operator POST stop web-1: 200 off",
    r.status === 200 && r.body.vm?.state === "off",
    r.status,
    short(r.body.vm ?? r.body, 200),
  );
  r = await api("POST", `/hosts/${vmHost}/vms/web-1/start`, operator, {});
  check(
    "operator POST start web-1: 200 running",
    r.status === 200 && r.body.vm?.state === "running",
    r.status,
    short(r.body.vm ?? r.body, 200),
  );
  r = await api("GET", `/hosts/${vmHost}/vms/web-1/console`, operator);
  check(
    "operator GET console: 200",
    r.status === 200 && r.body.console?.kind === "vmconnect",
    r.status,
    short(r.body, 200),
  );
  r = await api("PUT", `/hosts/${vmHost}/consoles/${state.webVmId}`, operator, {
    consoleHostId: null,
  });
  check("operator PUT consoles: 403", r.status === 403, r.status, r.body);
  r = await api("DELETE", `/hosts/${vmHost}`, operator);
  check("operator DELETE /hosts/<id>: 403", r.status === 403, r.status, r.body);

  // A person with no HAW permission at all.
  const password = randomBytes(18).toString("base64url");
  await req("POST", "/users/create", {
    body: { username: "haw-nobody", password },
  });
  const nobody = { cookie: await login("haw-nobody", password) };
  r = await api("GET", "/me", nobody);
  check(
    "no-permission GET /me: role null",
    r.status === 200 && r.body.role === null,
    r.status,
    { role: r.body.role },
  );
  r = await api("GET", "/hosts", nobody);
  check("no-permission GET /hosts: 403", r.status === 403, r.status, r.body);
  r = await api("GET", "/me", undefined);
  check("signed out GET /me: 401", r.status === 401, r.status, r.body);
}

/** A Termix API key is refused. */
async function apiKey() {
  const me = await req("GET", "/users/me", { auth: admin });
  const userId = me.body.userId ?? me.body.id;
  let r = await req("POST", "/users/api-keys", {
    auth: admin,
    body: { name: "haw-reh key", userId },
  });
  const token = r.body.token ?? r.body.key ?? r.body.apiKey;
  const keyId = r.body.id ?? r.body.apiKey?.id ?? r.body.keyId;
  check(
    "POST /users/api-keys (admin)",
    r.status === 201 && /^tmx_/.test(token ?? ""),
    r.status,
    { id: keyId, prefix: token?.slice(0, 8) },
  );
  r = await req("GET", "/plugin-api/haw/me", { auth: { bearer: token } });
  check(
    "API key GET /plugin-api/haw/me: 403",
    r.status === 403,
    r.status,
    r.body,
  );
  r = await req("GET", "/plugin-api/haw/hosts", { auth: { bearer: token } });
  check(
    "API key GET /plugin-api/haw/hosts: 403",
    r.status === 403,
    r.status,
    r.body,
  );
  r = await req("DELETE", `/users/api-keys/${keyId}`, { auth: admin });
  check(
    "DELETE /users/api-keys/<id>",
    r.status === 200 || r.status === 204,
    r.status,
    short(r.body, 120),
  );
}

async function remove() {
  const vmHost = state.vmHost;
  let r = await api("DELETE", `/hosts/${vmHost}`, admin);
  check(
    "DELETE /hosts/<id>",
    r.status === 200 && r.body.removed === true,
    r.status,
    r.body,
  );
  r = await api("GET", "/hosts", admin);
  check(
    "GET /hosts after delete: gone",
    r.status === 200 && !r.body.some((h) => h.id === vmHost),
    r.status,
    `${r.body.length} VM hosts`,
  );
  r = await api("GET", `/hosts/${vmHost}/vms`, admin);
  check("GET vms of the removed host: 404", r.status === 404, r.status, r.body);
  r = await req("GET", "/plugins/", { auth: admin });
  const list = Array.isArray(r.body) ? r.body : r.body.plugins;
  const haw = list.find((p) => p.id === "haw");
  check("plugin haw still active", haw?.state === "active", r.status, {
    state: haw?.state,
    version: haw?.version,
  });
}

try {
  if (phase === "main") await main();
  else if (phase === "delete") await remove();
  else throw new Error(`unknown phase ${phase}`);
} finally {
  writeFileSync(
    `${DIR}/results-${phase}.json`,
    JSON.stringify(results, null, 2),
  );
  const failed = results.filter((x) => x.result === "FAIL").length;
  console.log(`${phase}: ${results.length - failed} PASS, ${failed} FAIL`);
}
