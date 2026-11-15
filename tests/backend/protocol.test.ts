import { describe, expect, it } from "vitest";
import {
  buildRequest,
  encodeRequest,
  MAX_REQUEST_BYTES,
  parseReply,
  ProtocolError,
  replyLine,
  toConsole,
  toInfo,
  toVm,
  toVmList,
} from "../../src/shared/protocol";

const request = buildRequest("req-1", "list");
const reply = (body: Record<string, unknown>) =>
  JSON.stringify({ haw: "vmctl", v: 1, id: "req-1", ...body });

describe("requests", () => {
  it("is one JSON line with the protocol fields", () => {
    const text = encodeRequest(
      buildRequest("abc-1", "show", { name: "web-1" }),
    );
    expect(text.endsWith("\n")).toBe(true);
    expect(text.split("\n")).toHaveLength(2);
    expect(JSON.parse(text)).toEqual({
      haw: "vmctl",
      v: 1,
      id: "abc-1",
      verb: "show",
      args: { name: "web-1" },
    });
  });

  it("refuses an id the back ends would refuse", () => {
    expect(() => buildRequest("has space", "list")).toThrow();
    expect(() => buildRequest("", "list")).toThrow();
    expect(() => buildRequest("x".repeat(65), "list")).toThrow();
  });

  it("refuses a request larger than a back end reads", () => {
    const big = buildRequest("a", "show", {
      name: "x".repeat(MAX_REQUEST_BYTES),
    });
    expect(() => encodeRequest(big)).toThrow("too large");
  });

  it("keeps a VM name with quotes and backslashes as data", () => {
    const name = `a"b\\c'; Remove-Item C:\\ -Recurse`;
    const text = encodeRequest(buildRequest("a", "show", { name }));
    expect(JSON.parse(text).args.name).toBe(name);
  });
});

describe("replies", () => {
  it("reads the last JSON line and skips other output", () => {
    const out = `WARNING: something\n${reply({ ok: true, result: { vms: [] } })}\n\n`;
    expect(parseReply(out, request)).toMatchObject({
      ok: true,
      result: { vms: [] },
    });
    expect(replyLine("no json here")).toBeNull();
  });

  it("refuses no reply, bad JSON, a foreign message, another id", () => {
    expect(() => parseReply("", request)).toThrow(ProtocolError);
    expect(() => parseReply("{not json", request)).toThrow("not JSON");
    expect(() => parseReply('{"hello":1}', request)).toThrow(
      "not a vmctl reply",
    );
    expect(() =>
      parseReply(
        JSON.stringify({
          haw: "vmctl",
          v: 1,
          id: "other",
          ok: true,
          result: {},
        }),
        request,
      ),
    ).toThrow("another request");
    expect(() => parseReply(reply({ ok: "maybe" }), request)).toThrow(
      "neither",
    );
  });

  it("refuses a result in another protocol version", () => {
    expect(() =>
      parseReply(
        JSON.stringify({
          haw: "vmctl",
          v: 2,
          id: "req-1",
          ok: true,
          result: {},
        }),
        request,
      ),
    ).toThrow("version 2");
  });

  it("reads errors, with the versions list and an id of null", () => {
    const parsed = parseReply(
      JSON.stringify({
        haw: "vmctl",
        v: 1,
        id: null,
        ok: false,
        error: { code: "version", message: "speaks 1", versions: [1, "x"] },
      }),
      request,
    );
    expect(parsed).toMatchObject({
      ok: false,
      error: { code: "version", versions: [1] },
    });
  });

  it("turns an unknown error code into backend", () => {
    const parsed = parseReply(
      reply({ ok: false, error: { code: "weird", message: "m" } }),
      request,
    );
    expect(parsed).toMatchObject({
      ok: false,
      error: { code: "backend", message: "m" },
    });
  });
});

describe("result checks", () => {
  it("keeps only the protocol's fields of a VM, with their types", () => {
    const vm = toVm({
      name: "web-1",
      id: "abc",
      state: "exploded",
      cpus: "4",
      memoryMB: 4096,
      addresses: ["192.0.2.1", 7, { x: 1 }],
      allowed: "yes",
      protected: true,
      script: "<img onerror=alert(1)>",
    });
    expect(vm).toEqual({
      name: "web-1",
      id: "abc",
      state: "other",
      cpus: 0,
      memoryMB: 4096,
      uptimeSeconds: 0,
      addresses: ["192.0.2.1"],
      allowed: false,
      protected: true,
    });
  });

  it("refuses a VM with no name, and a list that is not one", () => {
    expect(() => toVm({ id: "x" })).toThrow("no name");
    expect(() => toVmList(null)).toThrow(ProtocolError);
    expect(toVmList({ vms: "nope" })).toEqual([]);
  });

  it("reads info with defaults for what is missing", () => {
    const info = toInfo({
      host: { name: "hv1" },
      backend: { kind: "hyper-v", version: "1.0.0" },
      protocol: { versions: [1] },
      limits: {
        namePattern: "^a",
        protected: ["gb-*"],
        ceilings: { cpus: 8, memoryMB: "x" },
      },
    });
    expect(info.capacity).toEqual({
      cpus: 0,
      memoryMB: 0,
      freeMemoryMB: 0,
      disks: [],
    });
    expect(info.limits).toEqual({
      namePattern: "^a",
      protected: ["gb-*"],
      ceilings: { cpus: 8 },
    });
    expect(info.configProblem).toBeNull();
  });

  it("reads a console and refuses a kind or port it does not know", () => {
    expect(
      toConsole({
        console: { kind: "vmconnect", host: "hv1", port: 2179, vmId: "abc" },
      }),
    ).toEqual({ kind: "vmconnect", host: "hv1", port: 2179, vmId: "abc" });
    expect(() => toConsole({ console: { kind: "vnc", port: 1 } })).toThrow(
      "not known",
    );
    expect(() =>
      toConsole({ console: { kind: "vmconnect", port: 70000 } }),
    ).toThrow("port");
  });
});
