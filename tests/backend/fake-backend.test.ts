import { describe, expect, it } from "vitest";
import {
  defaultState,
  handleLine,
  readConfig,
} from "../../vmctl/fake/vmctl-fake.mjs";
import {
  buildRequest,
  encodeRequest,
  parseReply,
  type Verb,
} from "../../src/shared/protocol";

// The fake back end is what the tests and the rehearsal run against, so it
// must keep the protocol's rules as a real back end does.

function host(config: Record<string, unknown> | null = {}) {
  let state = defaultState();
  const configText = config === null ? null : JSON.stringify(config);
  const send = (verb: string, args: Record<string, unknown> = {}) => {
    const request = buildRequest("t-1", verb as Verb, args);
    const out = handleLine(encodeRequest(request).trim(), {
      load: () => ({ state, configText }),
      save: (next) => {
        state = next;
      },
    });
    return parseReply(out, request);
  };
  return { send, state: () => state };
}

const raw = (line: string) =>
  JSON.parse(
    handleLine(line, {
      load: () => ({ state: defaultState(), configText: "{}" }),
      save: () => {},
    }),
  );

describe("the fake back end", () => {
  it("answers info with its verbs and limits", () => {
    const reply = host({ protected: ["build-*"] }).send("info");
    expect(reply).toMatchObject({
      ok: true,
      result: {
        protocol: { versions: [1] },
        verbs: [
          "info",
          "list",
          "show",
          "start",
          "stop",
          "restart",
          "console-info",
        ],
        limits: { protected: ["build-*"] },
        configProblem: null,
      },
    });
  });

  it("refuses what is not a request", () => {
    expect(raw("not json").error.code).toBe("bad-request");
    expect(
      raw('{"haw":"vmctl","v":1,"id":"bad id","verb":"list","args":{}}').error
        .code,
    ).toBe("bad-request");
    expect(
      raw('{"haw":"vmctl","v":2,"id":"a","verb":"list","args":{}}').error,
    ).toMatchObject({
      code: "version",
      versions: [1],
    });
    expect(
      raw('{"haw":"vmctl","v":1,"id":"a","verb":"list","args":{"x":1}}').error
        .code,
    ).toBe("bad-request");
    expect(
      raw(
        '{"haw":"vmctl","v":1,"id":"a","verb":"stop","args":{"name":"web-1","force":"yes"}}',
      ).error.code,
    ).toBe("bad-request");
    expect(
      raw('{"haw":"vmctl","v":1,"id":"a","verb":"format-c","args":{}}').error
        .code,
    ).toBe("unknown-verb");
  });

  it.each(["create", "delete", "snapshot", "restore", "users"])(
    "answers %s with not-in-this-version",
    (verb) => {
      expect(host().send(verb)).toMatchObject({
        ok: false,
        error: { code: "not-in-this-version" },
      });
    },
  );

  it("lists VMs sorted by name, and shows one", () => {
    const h = host();
    const list = h.send("list");
    expect(
      list.ok &&
        (list.result as { vms: Array<{ name: string }> }).vms.map(
          (v) => v.name,
        ),
    ).toEqual(["build-1", "test-vm1", "web-1"]);
    expect(h.send("show", { name: "web-1" })).toMatchObject({
      ok: true,
      result: { vm: { name: "web-1", generation: 2 } },
    });
    expect(h.send("show", { name: "nope" })).toMatchObject({
      ok: false,
      error: { code: "not-found" },
    });
    expect(h.send("show", { name: "web-*" })).toMatchObject({
      ok: false,
      error: { code: "bad-request" },
    });
  });

  it("starts, stops and restarts, and refuses the wrong state", () => {
    const h = host();
    expect(h.send("start", { name: "test-vm1" })).toMatchObject({
      ok: true,
      result: { vm: { state: "running" } },
    });
    expect(h.send("start", { name: "test-vm1" })).toMatchObject({
      ok: false,
      error: { code: "wrong-state" },
    });
    expect(h.send("stop", { name: "test-vm1", force: true })).toMatchObject({
      ok: true,
      result: { vm: { state: "off" } },
    });
    expect(h.send("restart", { name: "test-vm1" })).toMatchObject({
      ok: false,
      error: { code: "wrong-state" },
    });
    expect(h.send("restart", { name: "web-1" })).toMatchObject({ ok: true });
  });

  it("refuses to stop or restart a protected VM, without case, and still starts it", () => {
    const h = host({ protected: ["BUILD-*", "test-vm?"] });
    expect(h.send("stop", { name: "build-1" })).toMatchObject({
      ok: false,
      error: { code: "protected" },
    });
    expect(h.send("restart", { name: "build-1", force: true })).toMatchObject({
      ok: false,
      error: { code: "protected" },
    });
    expect(h.send("start", { name: "test-vm1" })).toMatchObject({ ok: true });
    expect(h.state().vms.find((vm) => vm.name === "build-1")?.state).toBe(
      "running",
    );
  });

  it("refuses VMs outside the name pattern", () => {
    const h = host({ namePattern: "^web-" });
    expect(h.send("stop", { name: "build-1" })).toMatchObject({
      ok: false,
      error: { code: "name-not-allowed" },
    });
    const list = h.send("list");
    expect(
      list.ok &&
        (
          list.result as { vms: Array<{ name: string; allowed: boolean }> }
        ).vms.map((v) => v.allowed),
    ).toEqual([false, false, true]);
  });

  it("refuses a start past the ceilings", () => {
    // Running: build-1 (4 CPU, 8 GB) and web-1 (2 CPU, 4 GB); test-vm1 is 2 CPU, 4 GB.
    expect(
      host({ ceilings: { cpus: 7 } }).send("start", { name: "test-vm1" }),
    ).toMatchObject({
      ok: false,
      error: { code: "ceiling" },
    });
    expect(
      host({ ceilings: { memoryMB: 16383 } }).send("start", {
        name: "test-vm1",
      }),
    ).toMatchObject({
      ok: false,
      error: { code: "ceiling" },
    });
    expect(
      host({ ceilings: { cpus: 8, memoryMB: 16384 } }).send("start", {
        name: "test-vm1",
      }),
    ).toMatchObject({ ok: true });
  });

  it("answers info with the problem, and every other verb with config, when the config is missing or wrong", () => {
    const missing = host(null);
    expect(missing.send("info")).toMatchObject({
      ok: true,
      result: { configProblem: "the config file is missing" },
    });
    expect(missing.send("list")).toMatchObject({
      ok: false,
      error: { code: "config" },
    });
    expect(readConfig('{"namePattern":"("}').problem).toMatch(
      "regular expression",
    );
    expect(readConfig('{"ceilings":{"cpus":0}}').problem).toMatch(
      "ceilings.cpus",
    );
    expect(readConfig('{"protected":"x"}').problem).toMatch("protected");
  });

  it("gives what a console needs", () => {
    expect(
      host({ console: { host: "hv1.example.lan", port: 2179 } }).send(
        "console-info",
        { name: "web-1" },
      ),
    ).toMatchObject({
      ok: true,
      result: {
        console: {
          kind: "vmconnect",
          host: "hv1.example.lan",
          port: 2179,
          vmId: "9e8d7c6b-5a49-4382-9170-6f5e4d3c2b03",
        },
      },
    });
  });
});
