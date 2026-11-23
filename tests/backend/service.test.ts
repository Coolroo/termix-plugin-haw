import { describe, expect, it } from "vitest";
import {
  fakeHost,
  OPERATOR,
  seedVmHost,
  useTestServer,
  VIEWER,
  withVmHost,
  type TestServer,
} from "./helpers";
import type { Caller, VmService } from "../../src/backend/service";

const start = useTestServer();

const ALLOW = { servicePlugins: "runbooks\nother-plugin" };

/** The service as another plugin gets it, called as `user`. */
function service(server: TestServer, user = "alice") {
  const vms = server.mock.services.get("haw.vms") as VmService;
  return new Proxy(vms, {
    get:
      (target, method: keyof VmService) =>
      (...args: unknown[]) =>
        server.mock.actAs(user, () =>
          (target[method] as (...a: unknown[]) => Promise<unknown>)(...args),
        ),
  }) as VmService;
}

/**
 * A consumer plugin's side of the handshake: a receiver under its own id
 * that takes a key only while its own bind runs.
 */
function consumer(server: TestServer, pluginId: string) {
  let key: string | null = null;
  let binding = false;
  server.registry.set(`${pluginId}.hawVmsKey`, (given: string) => {
    if (!binding) throw new Error("not binding");
    key = given;
  });
  return {
    key: () => key,
    async bind(user = "alice") {
      binding = true;
      try {
        await service(server, user).bindPlugin(pluginId);
      } finally {
        binding = false;
      }
      return key!;
    },
    caller(extra: Partial<Caller> = {}): Caller {
      return { plugin: pluginId, key: key!, user: "alice", ...extra };
    },
  };
}

async function bound(
  options: Parameters<typeof start>[0] = {},
  vmHost: "route" | "seed" = "route",
) {
  const settings = { settings: ALLOW, ...options };
  const server =
    vmHost === "route"
      ? (await withVmHost(start, settings)).server
      : await start(settings);
  if (vmHost === "seed") seedVmHost(server.db, 1);
  const runbooks = consumer(server, "runbooks");
  await runbooks.bind();
  return { server, runbooks, vms: service(server) };
}

describe("the handshake", () => {
  it("hands an allowed plugin its key through its own receiver", async () => {
    const { runbooks, vms } = await bound();
    expect(runbooks.key()).toMatch(/^[0-9a-f]{64}$/);
    const hosts = await vms.hosts(runbooks.caller());
    expect(hosts).toEqual([
      expect.objectContaining({
        hostId: 1,
        name: "hv-1",
        interface: "hyper-v",
      }),
    ]);
    expect(hosts[0].verbs).toContain("start");
  });

  it("binds when ctx.registry.consume answers with a Promise (plugin API 2)", async () => {
    const { server } = await withVmHost(start, { settings: ALLOW });
    const runbooks = consumer(server, "runbooks");
    const registry = server.mock.ctx.registry as {
      consume: (key: string) => unknown;
    };
    const sync = registry.consume;
    // Under plugin API 2 the receiver lives in the consumer's own process,
    // and core hands it over as a Promise.
    registry.consume = (key) => Promise.resolve(sync(key));
    await runbooks.bind();
    expect(runbooks.key()).toMatch(/^[0-9a-f]{64}$/);
    await expect(service(server).hosts(runbooks.caller())).resolves.toEqual([
      expect.objectContaining({ hostId: 1, name: "hv-1" }),
    ]);
  });

  it("allows no plugin by default", async () => {
    const { server } = await withVmHost(start);
    const runbooks = consumer(server, "runbooks");
    await expect(runbooks.bind()).rejects.toMatchObject({
      code: "plugin-not-allowed",
      status: 403,
    });
    expect(runbooks.key()).toBeNull();
    expect(server.mock.audits.at(-1)).toMatchObject({
      action: "haw.service.bindPlugin",
      success: false,
    });
  });

  it("refuses a call with no key or a wrong key", async () => {
    const { runbooks, vms } = await bound();
    await expect(
      vms.hosts({ plugin: "runbooks", user: "alice" } as Caller),
    ).rejects.toMatchObject({ code: "bad-request" });
    await expect(
      vms.hosts(runbooks.caller({ key: "0".repeat(64) })),
    ).rejects.toMatchObject({ code: "bad-key", status: 403 });
    await expect(vms.hosts(null as unknown as Caller)).rejects.toMatchObject({
      code: "bad-request",
    });
  });

  it("does not let a plugin use another plugin's key, or get it by binding", async () => {
    const { server, runbooks, vms } = await bound();
    const other = consumer(server, "other-plugin");
    await other.bind();
    // other-plugin sends Runbooks' key under its own id: refused.
    await expect(
      vms.hosts({
        plugin: "other-plugin",
        key: runbooks.key()!,
        user: "alice",
      }),
    ).rejects.toMatchObject({ code: "bad-key" });
    // ...and under Runbooks' id it would need Runbooks' key, which a bind
    // for "runbooks" sends only to Runbooks' receiver, never back.
    const before = runbooks.key();
    await expect(service(server).bindPlugin("runbooks")).rejects.toMatchObject({
      code: "no-receiver",
    });
    expect(runbooks.key()).toBe(before);
    expect(other.key()).not.toBe(runbooks.key());
  });

  it("refuses a plugin taken off the list, though it holds a key", async () => {
    const { server, runbooks, vms } = await bound();
    await server.mock.ctx.settings.set("servicePlugins", "other-plugin");
    await expect(vms.hosts(runbooks.caller())).rejects.toMatchObject({
      code: "plugin-not-allowed",
    });
  });

  it("refuses a caller whose user is not the acting user, and a call with none", async () => {
    const { server, runbooks } = await bound();
    await expect(
      service(server, "bob").hosts(runbooks.caller()),
    ).rejects.toMatchObject({ code: "not-acting-user" });
    server.mock.setActor(undefined);
    const vms = server.mock.services.get("haw.vms") as VmService;
    await expect(vms.hosts(runbooks.caller())).rejects.toMatchObject({
      code: "no-actor",
      status: 401,
    });
  });

  it("checks the allow-list setting when an admin saves it", async () => {
    const server = await start();
    expect(
      await server.mock.validateSettings("admin", {
        servicePlugins: "runbooks\nNot An Id",
      }),
    ).toHaveProperty("servicePlugins");
    expect(
      await server.mock.validateSettings("admin", { servicePlugins: "haw" }),
    ).toHaveProperty("servicePlugins");
    expect(
      await server.mock.validateSettings("admin", {
        servicePlugins: "runbooks, other-plugin\n",
      }),
    ).toEqual({});
  });
});

describe("roles", () => {
  it("lets a viewer read but not power or open consoles", async () => {
    const { runbooks, vms } = await bound({ permissions: VIEWER }, "seed");
    expect((await vms.list(runbooks.caller(), 1)).map((vm) => vm.name)).toEqual(
      ["build-1", "test-vm1", "web-1"],
    );
    expect((await vms.show(runbooks.caller(), 1, "web-1")).name).toBe("web-1");
    await expect(
      vms.start(runbooks.caller(), 1, "test-vm1"),
    ).rejects.toMatchObject({ code: "role", status: 403 });
    await expect(
      vms.consoleInfo(runbooks.caller(), 1, "web-1"),
    ).rejects.toMatchObject({ code: "role" });
  });

  it("lets an operator power VMs", async () => {
    const { runbooks, vms } = await bound({ permissions: OPERATOR }, "seed");
    expect(await vms.me(runbooks.caller())).toMatchObject({
      role: "operator",
    });
    expect((await vms.start(runbooks.caller(), 1, "test-vm1")).state).toBe(
      "running",
    );
  });

  it("gives a person with no HAW role nothing", async () => {
    const { runbooks, vms } = await bound(
      { permissions: ["other.thing"] },
      "seed",
    );
    await expect(vms.hosts(runbooks.caller())).rejects.toMatchObject({
      code: "role",
    });
  });
});

describe("the verbs", () => {
  it("reads the host's info and saves it", async () => {
    const { server, runbooks, vms } = await bound();
    const info = await vms.info(runbooks.caller(), 1);
    expect(info.protocol.versions).toContain(1);
    const sent = JSON.parse(String(server.execCalls.at(-1)?.options?.stdin));
    expect(sent.verb).toBe("info");
  });

  it("starts, stops with force and restarts, as vmctl gets them from the tab", async () => {
    const { server, runbooks, vms } = await bound();
    const caller = runbooks.caller({ ref: "runbook 12 step 3" });
    expect((await vms.start(caller, 1, "test-vm1")).state).toBe("running");
    expect((await vms.restart(caller, 1, "test-vm1")).name).toBe("test-vm1");
    expect((await vms.stop(caller, 1, "test-vm1", { force: true })).state).toBe(
      "off",
    );
    const sent = server.execCalls
      .slice(-3)
      .map((call) => JSON.parse(String(call.options?.stdin)));
    expect(sent.map((r) => [r.verb, r.args])).toEqual([
      ["start", { name: "test-vm1" }],
      ["restart", { name: "test-vm1", force: false }],
      ["stop", { name: "test-vm1", force: true }],
    ]);
    // The host and login are the tab's: the fixed command, as the person.
    expect(server.execCalls.at(-1)?.command).toBe(server.execCalls[0].command);
  });

  it("gives a console with its linked host", async () => {
    const { server, runbooks, vms } = await bound();
    const id = (await server.call("GET", "/hosts")).body[0].id;
    const answer = await vms.consoleInfo(runbooks.caller(), 1, "web-1");
    expect(answer.console).toMatchObject({ kind: "vmconnect", port: 2179 });
    expect(answer.consoleHost).toBeNull();
    await server.call("PUT", `/hosts/${id}/consoles/${answer.console.vmId}`, {
      consoleHostId: 3,
    });
    expect(
      (await vms.consoleInfo(runbooks.caller(), 1, "web-1")).consoleHost,
    ).toEqual({ id: 3, name: "hv-3" });
  });

  it("refuses bad arguments before calling the host", async () => {
    const { server, runbooks, vms } = await bound();
    const calls = server.execCalls.length;
    await expect(vms.show(runbooks.caller(), 1, "web-*")).rejects.toMatchObject(
      { code: "bad-request" },
    );
    await expect(
      vms.stop(runbooks.caller(), 1, "web-1", {
        force: "yes" as unknown as boolean,
      }),
    ).rejects.toMatchObject({ code: "bad-request" });
    await expect(vms.list(runbooks.caller(), 3)).rejects.toMatchObject({
      code: "not-a-vm-host",
      status: 404,
    });
    await expect(
      vms.list(runbooks.caller(), "1" as unknown as number),
    ).rejects.toMatchObject({ code: "not-a-vm-host" });
    expect(server.execCalls.length).toBe(calls);
  });

  it("passes the host's refusals and HAW's host checks on, with their codes", async () => {
    const { server, runbooks, vms } = await bound({
      fakes: { 1: fakeHost({ protected: ["build-*"] }), 2: fakeHost() },
    });
    await expect(
      vms.stop(runbooks.caller(), 1, "build-1"),
    ).rejects.toMatchObject({ code: "protected", status: 409 });
    await expect(vms.start(runbooks.caller(), 1, "nope")).rejects.toMatchObject(
      { code: "not-found", status: 404 },
    );
    // Host 2 has no stored host key: refused before connecting.
    seedVmHost(server.db, 2);
    const calls = server.execCalls.length;
    await expect(vms.list(runbooks.caller(), 2)).rejects.toMatchObject({
      code: "no-host-key",
    });
    expect(server.execCalls.length).toBe(calls);
  });
});

describe("agent tokens (H3)", () => {
  it("lets a call for an agent token list hosts and VMs, and nothing else", async () => {
    const { runbooks, vms } = await bound();
    const agent = runbooks.caller({ agent: true, ref: "agent token 7" });
    expect(await vms.hosts(agent)).toHaveLength(1);
    expect(await vms.list(agent, 1)).toHaveLength(3);
    for (const call of [
      () => vms.show(agent, 1, "web-1"),
      () => vms.info(agent, 1),
      () => vms.start(agent, 1, "test-vm1"),
      () => vms.stop(agent, 1, "web-1"),
      () => vms.consoleInfo(agent, 1, "web-1"),
    ]) {
      await expect(call()).rejects.toMatchObject({
        code: "agent-read-only",
        status: 403,
      });
    }
  });
});

describe("the record", () => {
  it("records each action with the plugin and its reference, in HAW and in the audit log", async () => {
    const { server, runbooks, vms } = await bound();
    const caller = runbooks.caller({ ref: "runbook 12 step 3" });
    await vms.start(caller, 1, "test-vm1");
    await expect(vms.stop(caller, 1, "nope")).rejects.toBeDefined();
    await vms.consoleInfo(caller, 1, "web-1");
    await vms.list(caller, 1);
    const record = (await server.call("GET", "/actions")).body;
    expect(
      record
        .slice(0, 3)
        .map((a: Record<string, unknown>) => [
          a.action,
          a.vmName,
          a.ok,
          a.via,
          a.ref,
          a.userId,
        ]),
    ).toEqual([
      ["console", "web-1", true, "runbooks", "runbook 12 step 3", "alice"],
      ["stop", "nope", false, "runbooks", "runbook 12 step 3", "alice"],
      ["start", "test-vm1", true, "runbooks", "runbook 12 step 3", "alice"],
    ]);
    // The tab's own actions have no plugin.
    expect(record.at(-1)).toMatchObject({
      action: "add-host",
      via: null,
      ref: null,
    });
    const lines = server.mock.audits.filter((line) =>
      String(line.details ?? "").startsWith("via"),
    );
    expect(lines.map((line) => [line.action, line.success])).toEqual([
      ["haw.start", true],
      ["haw.stop", false],
      ["haw.console", true],
    ]);
    expect(lines[0].details).toBe("via runbooks: runbook 12 step 3");
  });

  it("keeps the force and a one-line reference", async () => {
    const { server, runbooks, vms } = await bound();
    await vms.stop(
      runbooks.caller({ ref: `step\n3${"x".repeat(300)}` }),
      1,
      "web-1",
      { force: true },
    );
    const [last] = (await server.call("GET", "/actions")).body;
    expect(last.force).toBe(true);
    expect(last.ref.startsWith("step 3x")).toBe(true);
    expect(last.ref.length).toBe(200);
  });

  it("puts a refused caller in the audit log", async () => {
    const { server, runbooks, vms } = await bound();
    await expect(
      vms.start(runbooks.caller({ key: "f".repeat(64) }), 1, "test-vm1"),
    ).rejects.toMatchObject({ code: "bad-key" });
    expect(server.mock.audits.at(-1)).toMatchObject({
      action: "haw.service.start",
      resourceName: "runbooks",
      success: false,
    });
  });
});
