import { describe, expect, it } from "vitest";
import {
  execResult,
  fakeHost,
  host,
  manifest,
  OPERATOR,
  OWNER,
  seedVmHost,
  sshHost,
  useTestServer,
  VIEWER,
  withVmHost,
} from "./helpers";
import { INTERFACES } from "../../src/shared/interfaces";

const start = useTestServer();

describe("who may do what", () => {
  it("needs a login and refuses Termix API keys", async () => {
    const server = await start();
    expect(
      (await server.call("GET", "/me", undefined, { user: null })).status,
    ).toBe(401);
    expect(
      (await server.call("GET", "/me", undefined, { apiKey: true })).status,
    ).toBe(403);
  });

  it("tells the page the role and the interfaces with their setup", async () => {
    const server = await start({ permissions: OPERATOR });
    const me = await server.call("GET", "/me");
    expect(me.body.role).toBe("operator");
    expect(me.body.version).toBe(manifest.version);
    expect(me.body.interfaces[0].id).toBe("hyper-v");
    expect(
      me.body.interfaces[0].setup.map((s: { textKey: string }) => s.textKey),
    ).toContain("setup.hyper-v.install");
  });

  it("gives a person with no HAW permission nothing", async () => {
    const server = await start({ permissions: ["other.thing"] });
    expect((await server.call("GET", "/me")).body.role).toBeNull();
    expect((await server.call("GET", "/hosts")).status).toBe(403);
  });

  it("lets a viewer read but not power, and an operator power but not add", async () => {
    const viewer = await start({ permissions: VIEWER });
    seedVmHost(viewer.db, 1);
    expect((await viewer.call("GET", "/hosts/1/vms")).status).toBe(200);
    expect(
      (await viewer.call("POST", "/hosts/1/vms/test-vm1/start")).status,
    ).toBe(403);
    expect(
      (await viewer.call("GET", "/hosts/1/vms/web-1/console")).status,
    ).toBe(403);

    const operator = await start({ permissions: OPERATOR });
    seedVmHost(operator.db, 1);
    expect(
      (await operator.call("POST", "/hosts/1/vms/test-vm1/start")).status,
    ).toBe(200);
    expect(
      (
        await operator.call("POST", "/hosts", {
          hostId: 3,
          interface: "hyper-v",
        })
      ).status,
    ).toBe(403);
    expect((await operator.call("DELETE", "/hosts/1")).status).toBe(403);
    expect((await operator.call("GET", "/termix-hosts")).status).toBe(403);
  });
});

describe("Add VM host", () => {
  it("checks the host with vmctl info, as the person, over the interface's command", async () => {
    const server = await start();
    const check = await server.call("POST", "/hosts/check", {
      hostId: 1,
      interface: "hyper-v",
    });
    expect(check.body).toMatchObject({
      ok: true,
      info: { backend: { kind: "fake" }, protocol: { versions: [1] } },
    });
    const call = server.execCalls[0];
    expect(call.command).toBe(INTERFACES["hyper-v"].command);
    expect(JSON.parse(String(call.options?.stdin))).toMatchObject({
      haw: "vmctl",
      v: 1,
      verb: "info",
      args: {},
    });
    expect(call.options?.timeoutMs).toBeGreaterThanOrEqual(120_000);
  });

  it("adds a host only while vmctl answers, once", async () => {
    const server = await start();
    const added = await server.call("POST", "/hosts", {
      hostId: 1,
      interface: "hyper-v",
    });
    expect(added.status).toBe(201);
    expect(
      (await server.call("POST", "/hosts", { hostId: 1, interface: "hyper-v" }))
        .body.code,
    ).toBe("added");
    const hosts = await server.call("GET", "/hosts");
    expect(hosts.body).toHaveLength(1);
    expect(hosts.body[0]).toMatchObject({
      hostId: 1,
      name: "hv-1",
      interface: "hyper-v",
      info: { host: { name: "fakehv" } },
    });
  });

  it("says no-reply, with what the host printed, when vmctl is not installed", async () => {
    const server = await start();
    server.setExec(async () =>
      execResult("", {
        stderr:
          "The argument 'C:/ProgramData/haw/vmctl.ps1' to the -File parameter does not exist.",
        code: 4294770688,
      }),
    );
    const check = await server.call("POST", "/hosts/check", {
      hostId: 1,
      interface: "hyper-v",
    });
    expect(check.body).toMatchObject({ ok: false, code: "no-reply" });
    expect(check.body.detail).toContain("does not exist");
    const add = await server.call("POST", "/hosts", {
      hostId: 1,
      interface: "hyper-v",
    });
    expect(add.status).toBe(409);
    expect(add.body.code).toBe("no-reply");
    expect((await server.call("GET", "/hosts")).body).toEqual([]);
  });

  it("refuses a host with no stored host key, before connecting", async () => {
    const server = await start();
    const check = await server.call("POST", "/hosts/check", {
      hostId: 2,
      interface: "hyper-v",
    });
    expect(check.body).toMatchObject({ ok: false, code: "no-host-key" });
    expect(server.execCalls).toHaveLength(0);
  });

  it("says unreachable when the login fails", async () => {
    const server = await start();
    server.setExec(async () => {
      throw new Error("All configured authentication methods failed");
    });
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: 1,
          interface: "hyper-v",
        })
      ).body,
    ).toMatchObject({
      ok: false,
      code: "unreachable",
      error: "All configured authentication methods failed",
    });
  });

  it("refuses an unknown interface, a host that is not there, and a non-SSH host", async () => {
    const server = await start({
      sshHosts: [sshHost(1, "aa11"), { ...sshHost(3, "cc"), enableSsh: false }],
    });
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: 1,
          interface: "vmware",
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: 99,
          interface: "hyper-v",
        })
      ).status,
    ).toBe(404);
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: "1",
          interface: "hyper-v",
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: 3,
          interface: "hyper-v",
        })
      ).body.code,
    ).toBe("not-ssh");
  });

  it("refuses a vmctl that does not speak protocol version 1", async () => {
    const server = await start();
    server.setExec(async (_h, _c, options) => {
      const id = JSON.parse(String(options?.stdin)).id;
      return execResult(
        JSON.stringify({
          haw: "vmctl",
          v: 1,
          id,
          ok: true,
          result: { protocol: { versions: [2] } },
        }),
      );
    });
    expect(
      (
        await server.call("POST", "/hosts/check", {
          hostId: 1,
          interface: "hyper-v",
        })
      ).body,
    ).toMatchObject({
      ok: false,
      code: "version",
      versions: [2],
    });
  });

  it("lists Termix hosts to pick, marking those added", async () => {
    const { server } = await withVmHost(start);
    const list = await server.call("GET", "/termix-hosts");
    expect(
      list.body.map((h: { id: number; added: boolean }) => [h.id, h.added]),
    ).toEqual([
      [1, true],
      [2, false],
      [3, false],
    ]);
  });

  it("removes a VM host without a call to the host", async () => {
    const { server, id } = await withVmHost(start);
    const calls = server.execCalls.length;
    expect((await server.call("DELETE", `/hosts/${id}`)).status).toBe(200);
    expect(server.execCalls.length).toBe(calls);
    expect((await server.call("GET", "/hosts")).body).toEqual([]);
  });

  it("leaves out a VM host whose Termix host the person can't see", async () => {
    const server = await start({ hosts: [host(1)] });
    seedVmHost(server.db, 3);
    expect((await server.call("GET", "/hosts")).body).toEqual([]);
    expect((await server.call("GET", "/hosts/3/vms")).status).toBe(404);
  });
});

describe("VMs", () => {
  it("lists a host's VMs with their console links", async () => {
    const { server, id } = await withVmHost(start);
    const list = await server.call("GET", `/hosts/${id}/vms`);
    expect(list.status).toBe(200);
    expect(list.body.vms.map((vm: { name: string }) => vm.name)).toEqual([
      "build-1",
      "test-vm1",
      "web-1",
    ]);
    expect(list.body.vms[0].consoleHostId).toBeNull();
  });

  it("shows one VM", async () => {
    const { server, id } = await withVmHost(start);
    const shown = await server.call("GET", `/hosts/${id}/vms/web-1`);
    expect(shown.body.vm).toMatchObject({
      name: "web-1",
      generation: 2,
      disks: [{ sizeGB: 40 }],
    });
  });

  it("refuses a wildcard or control character in a VM name before calling the host", async () => {
    const { server, id } = await withVmHost(start);
    const calls = server.execCalls.length;
    expect((await server.call("GET", `/hosts/${id}/vms/web-%2A`)).status).toBe(
      400,
    );
    expect(
      (await server.call("POST", `/hosts/${id}/vms/a%0Ab/start`)).status,
    ).toBe(400);
    expect(server.execCalls.length).toBe(calls);
  });

  it("starts and stops, records each action and audits it", async () => {
    const { server, id } = await withVmHost(start);
    const started = await server.call(
      "POST",
      `/hosts/${id}/vms/test-vm1/start`,
    );
    expect(started.body.vm).toMatchObject({
      name: "test-vm1",
      state: "running",
    });
    const stopped = await server.call(
      "POST",
      `/hosts/${id}/vms/test-vm1/stop`,
      { force: true },
    );
    expect(stopped.body.vm.state).toBe("off");
    const sent = server.execCalls.map((call) =>
      JSON.parse(String(call.options?.stdin)),
    );
    expect(sent.at(-1)).toMatchObject({
      verb: "stop",
      args: { name: "test-vm1", force: true },
    });
    const record = await server.call("GET", "/actions");
    expect(
      record.body.map((a: { action: string; ok: boolean }) => [a.action, a.ok]),
    ).toEqual([
      ["stop", true],
      ["start", true],
      ["add-host", true],
    ]);
    expect(server.mock.audits.map((line) => line.action)).toEqual([
      "haw.add-host",
      "haw.start",
      "haw.stop",
    ]);
  });

  it("passes the host's refusals on, and records them", async () => {
    const { server, id } = await withVmHost(start, {
      fakes: {
        1: fakeHost({ protected: ["build-*"], namePattern: "^(build|web)-" }),
      },
    });
    const stop = await server.call("POST", `/hosts/${id}/vms/build-1/stop`);
    expect(stop.status).toBe(409);
    expect(stop.body).toMatchObject({ code: "protected" });
    const notAllowed = await server.call(
      "POST",
      `/hosts/${id}/vms/test-vm1/start`,
    );
    expect(notAllowed.body.code).toBe("name-not-allowed");
    const missing = await server.call("POST", `/hosts/${id}/vms/nope/start`);
    expect(missing.status).toBe(404);
    const record = await server.call("GET", "/actions");
    expect(
      record.body.slice(0, 3).map((a: { code: string }) => a.code),
    ).toEqual(["not-found", "name-not-allowed", "protected"]);
  });

  it("refuses an action that is not power, and a force that is not a boolean", async () => {
    const { server, id } = await withVmHost(start);
    expect(
      (await server.call("POST", `/hosts/${id}/vms/web-1/delete`)).status,
    ).toBe(404);
    expect(
      (
        await server.call("POST", `/hosts/${id}/vms/web-1/stop`, {
          force: "yes",
        })
      ).status,
    ).toBe(400);
  });

  it("says 502 for a reply that breaks the protocol", async () => {
    const { server, id } = await withVmHost(start);
    server.setExec(async () => execResult("garbage\n{bad"));
    const list = await server.call("GET", `/hosts/${id}/vms`);
    expect(list.status).toBe(502);
    expect(list.body.code).toBe("protocol");
  });

  it("refreshes a host's info", async () => {
    const { server, id } = await withVmHost(start, {
      fakes: { 1: fakeHost(null) },
    });
    const refreshed = await server.call("POST", `/hosts/${id}/refresh`);
    expect(refreshed.body.info.configProblem).toBe(
      "the config file is missing",
    );
    expect(
      (await server.call("GET", "/hosts")).body[0].info.configProblem,
    ).toBe("the config file is missing");
  });
});

describe("consoles", () => {
  it("gives the console and links a Termix host to it", async () => {
    const { server, id } = await withVmHost(start);
    const before = await server.call("GET", `/hosts/${id}/vms/web-1/console`);
    expect(before.body).toMatchObject({
      console: { kind: "vmconnect", port: 2179 },
      consoleHost: null,
    });
    const vmId = before.body.console.vmId;
    expect(
      (
        await server.call("PUT", `/hosts/${id}/consoles/${vmId}`, {
          consoleHostId: 3,
        })
      ).status,
    ).toBe(200);
    const after = await server.call("GET", `/hosts/${id}/vms/web-1/console`);
    expect(after.body.consoleHost).toEqual({ id: 3, name: "hv-3" });
    const list = await server.call("GET", `/hosts/${id}/vms`);
    expect(
      list.body.vms.find((vm: { name: string }) => vm.name === "web-1")
        .consoleHostId,
    ).toBe(3);
    expect(
      (
        await server.call("PUT", `/hosts/${id}/consoles/${vmId}`, {
          consoleHostId: null,
        })
      ).status,
    ).toBe(200);
    expect(
      (await server.call("GET", `/hosts/${id}/vms/web-1/console`)).body
        .consoleHost,
    ).toBeNull();
  });

  it("refuses a console host the person can't see, and a bad VM id", async () => {
    const { server, id } = await withVmHost(start);
    expect(
      (
        await server.call("PUT", `/hosts/${id}/consoles/abc`, {
          consoleHostId: 99,
        })
      ).status,
    ).toBe(400);
    expect(
      (
        await server.call("PUT", `/hosts/${id}/consoles/a%20b`, {
          consoleHostId: 3,
        })
      ).status,
    ).toBe(400);
  });

  it("lets only an owner link consoles", async () => {
    const server = await start({ permissions: OPERATOR });
    seedVmHost(server.db, 1);
    expect(
      (await server.call("PUT", "/hosts/1/consoles/abc", { consoleHostId: 3 }))
        .status,
    ).toBe(403);
  });
});

describe("the record", () => {
  it("shows only actions on hosts the person can see", async () => {
    const { server, id } = await withVmHost(start);
    await server.call("POST", `/hosts/${id}/vms/test-vm1/start`);
    const other = await start({ hosts: [host(2)], permissions: OWNER });
    expect((await other.call("GET", "/actions")).body).toEqual([]);
    expect((await server.call("GET", "/actions?limit=1")).body).toHaveLength(1);
  });
});

describe("the record of console links", () => {
  it("names the VM, reaches Termix's audit log, and names hosts that are no VM host", async () => {
    const { server, id } = await withVmHost(start);
    const vmId = (await server.call("GET", `/hosts/${id}/vms/web-1/console`))
      .body.console.vmId;
    await server.call("PUT", `/hosts/${id}/consoles/${vmId}`, {
      consoleHostId: 3,
      vmName: "web-1",
    });
    expect(
      (
        await server.call("PUT", `/hosts/${id}/consoles/${vmId}`, {
          consoleHostId: 3,
          vmName: "a*b",
        })
      ).status,
    ).toBe(400);
    server.setExec(async () => execResult(""));
    await server.call("POST", "/hosts", { hostId: 2, interface: "hyper-v" });
    const record = await server.call("GET", "/actions");
    expect(record.body[0]).toMatchObject({
      action: "add-host",
      ok: false,
      hostName: "hv-2",
    });
    expect(record.body[1]).toMatchObject({
      action: "link-console",
      vmName: "web-1",
      hostName: "hv-1",
    });
    expect(server.mock.audits.map((line) => line.action)).toContain(
      "haw.link-console",
    );
  });
});
