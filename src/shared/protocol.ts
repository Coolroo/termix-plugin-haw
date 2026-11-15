/**
 * The vmctl protocol, version 1 (docs/protocol.md): the request HAW sends to
 * a VM host's vmctl and the checks on the reply it reads back. The server
 * uses it to talk to hosts, the fake back end and the tests use it too. No
 * Node and no React here.
 */

export const PROTOCOL_VERSION = 1;

/** The verbs of protocol version 1. */
export const VERBS = [
  "info",
  "list",
  "show",
  "start",
  "stop",
  "restart",
  "console-info",
  "create",
  "delete",
  "snapshot",
  "restore",
  "users",
] as const;
export type Verb = (typeof VERBS)[number];

/** What HAW 1.0 asks of a host. The rest answer "not in this version". */
export const READ_VERBS = ["info", "list", "show", "console-info"] as const;
export const POWER_VERBS = ["start", "stop", "restart"] as const;
export type PowerVerb = (typeof POWER_VERBS)[number];

export const ERROR_CODES = [
  "bad-request",
  "version",
  "unknown-verb",
  "not-in-this-version",
  "name-not-allowed",
  "protected",
  "ceiling",
  "not-found",
  "wrong-state",
  "config",
  "backend",
] as const;
export type ErrorCode = (typeof ERROR_CODES)[number];

export const VM_STATES = [
  "running",
  "off",
  "paused",
  "saved",
  "starting",
  "stopping",
  "other",
] as const;
export type VmState = (typeof VM_STATES)[number];

/** Request ids: what the back ends accept and echo. */
export const REQUEST_ID = /^[A-Za-z0-9-]{1,64}$/;
/** The largest request a back end reads. */
export const MAX_REQUEST_BYTES = 64 * 1024;
/** The most of a reply HAW reads. */
export const MAX_REPLY_BYTES = 1024 * 1024;

export interface Request {
  haw: "vmctl";
  v: number;
  id: string;
  verb: Verb;
  args: Record<string, unknown>;
}

export interface VmctlError {
  code: ErrorCode;
  message: string;
  versions?: number[];
}

export type Reply =
  | { haw: "vmctl"; v: number; id: string | null; ok: true; result: unknown }
  | {
      haw: "vmctl";
      v: number;
      id: string | null;
      ok: false;
      error: VmctlError;
    };

export interface Vm {
  name: string;
  id: string;
  state: VmState;
  cpus: number;
  memoryMB: number;
  uptimeSeconds: number;
  addresses: string[];
  allowed: boolean;
  protected: boolean;
}

export interface VmDetail extends Vm {
  generation: number | null;
  disks: Array<{ sizeGB: number | null; usedGB: number | null }>;
  networks: Array<{ switch: string; mac: string; addresses: string[] }>;
  checkpoints: number;
  notes: string;
}

export interface HostLimits {
  namePattern: string;
  protected: string[];
  ceilings: { cpus?: number; memoryMB?: number; diskGB?: number };
}

export interface HostInfo {
  host: { name: string };
  backend: { kind: string; version: string };
  protocol: { versions: number[] };
  capacity: {
    cpus: number;
    memoryMB: number;
    freeMemoryMB: number;
    disks: Array<{ name: string; sizeGB: number; freeGB: number }>;
  };
  networks: Array<{ name: string; kind: string }>;
  verbs: string[];
  limits: HostLimits;
  configProblem: string | null;
}

export interface ConsoleInfo {
  kind: "vmconnect";
  host: string;
  port: number;
  vmId: string;
}

export function buildRequest(
  id: string,
  verb: Verb,
  args: Record<string, unknown> = {},
): Request {
  if (!REQUEST_ID.test(id)) throw new Error("bad request id");
  return { haw: "vmctl", v: PROTOCOL_VERSION, id, verb, args };
}

/** The request as vmctl reads it: one line of JSON and a newline. */
export function encodeRequest(request: Request): string {
  const line = JSON.stringify(request);
  if (new TextEncoder().encode(line).length + 1 > MAX_REQUEST_BYTES) {
    throw new Error("request too large");
  }
  return `${line}\n`;
}

/** Why a reply can't be used: the text the person sees. */
export class ProtocolError extends Error {}

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

/**
 * The reply line in vmctl's standard output: the last non-empty line that
 * starts with "{". Null when there is none.
 */
export function replyLine(stdout: string): string | null {
  const lines = stdout.split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (line.startsWith("{")) return line;
  }
  return null;
}

/** Reads and checks the reply to `request`. Throws ProtocolError. */
export function parseReply(stdout: string, request: Request): Reply {
  const line = replyLine(stdout);
  if (line === null) throw new ProtocolError("vmctl sent no reply");
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    throw new ProtocolError("vmctl's reply is not JSON");
  }
  if (!isObject(parsed) || parsed.haw !== "vmctl") {
    throw new ProtocolError("the reply is not a vmctl reply");
  }
  if (!Number.isInteger(parsed.v)) {
    throw new ProtocolError("the reply has no protocol version");
  }
  if (parsed.id !== request.id && parsed.id !== null) {
    throw new ProtocolError("the reply is for another request");
  }
  if (parsed.ok === true) {
    if (parsed.id !== request.id) {
      throw new ProtocolError("the reply is for another request");
    }
    if (parsed.v !== request.v) {
      throw new ProtocolError(`the reply is in protocol version ${parsed.v}`);
    }
    return {
      haw: "vmctl",
      v: parsed.v as number,
      id: request.id,
      ok: true,
      result: parsed.result,
    };
  }
  if (parsed.ok === false && isObject(parsed.error)) {
    const { code, message, versions } = parsed.error;
    const known = (ERROR_CODES as readonly unknown[]).includes(code);
    return {
      haw: "vmctl",
      v: parsed.v as number,
      id: (parsed.id as string | null) ?? null,
      ok: false,
      error: {
        code: known ? (code as ErrorCode) : "backend",
        message: typeof message === "string" ? clip(message, 500) : "",
        ...(Array.isArray(versions)
          ? { versions: versions.filter((v) => Number.isInteger(v)) }
          : {}),
      },
    };
  }
  throw new ProtocolError("the reply has neither a result nor an error");
}

export function clip(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max)}…` : text;
}

// The result checks below take what a back end sent and keep only the
// fields of the protocol, with the right types. Anything else is dropped,
// so a host can't put more than text and numbers on the page.

const str = (value: unknown, max = 200) =>
  typeof value === "string" ? clip(value, max) : "";
const num = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) ? value : 0;
const numOrNull = (value: unknown) =>
  typeof value === "number" && Number.isFinite(value) ? value : null;
const strings = (value: unknown, max = 64) =>
  Array.isArray(value)
    ? value
        .filter((item): item is string => typeof item === "string")
        .slice(0, max)
        .map((item) => clip(item, 200))
    : [];
const list = (value: unknown, max = 500): unknown[] =>
  Array.isArray(value) ? value.slice(0, max) : [];

function need(value: unknown, what: string): Record<string, unknown> {
  if (!isObject(value)) throw new ProtocolError(`the reply has no ${what}`);
  return value;
}

export function toVm(value: unknown): Vm {
  const vm = need(value, "VM");
  if (typeof vm.name !== "string" || !vm.name) {
    throw new ProtocolError("a VM in the reply has no name");
  }
  const state = (VM_STATES as readonly unknown[]).includes(vm.state)
    ? (vm.state as VmState)
    : "other";
  return {
    name: clip(vm.name, 200),
    id: str(vm.id, 64),
    state,
    cpus: num(vm.cpus),
    memoryMB: num(vm.memoryMB),
    uptimeSeconds: num(vm.uptimeSeconds),
    addresses: strings(vm.addresses),
    allowed: vm.allowed === true,
    protected: vm.protected === true,
  };
}

export function toVmDetail(value: unknown): VmDetail {
  const vm = need(value, "VM");
  return {
    ...toVm(vm),
    generation: numOrNull(vm.generation),
    disks: list(vm.disks, 64).map((disk) => {
      const d = isObject(disk) ? disk : {};
      return { sizeGB: numOrNull(d.sizeGB), usedGB: numOrNull(d.usedGB) };
    }),
    networks: list(vm.networks, 64).map((nic) => {
      const n = isObject(nic) ? nic : {};
      return {
        switch: str(n.switch),
        mac: str(n.mac, 32),
        addresses: strings(n.addresses),
      };
    }),
    checkpoints: num(vm.checkpoints),
    notes: str(vm.notes, 2000),
  };
}

export function toVmList(result: unknown): Vm[] {
  return list(need(result, "result").vms, 1000).map(toVm);
}

export function toInfo(result: unknown): HostInfo {
  const r = need(result, "result");
  const host = isObject(r.host) ? r.host : {};
  const backend = isObject(r.backend) ? r.backend : {};
  const protocol = isObject(r.protocol) ? r.protocol : {};
  const capacity = isObject(r.capacity) ? r.capacity : {};
  const limits = isObject(r.limits) ? r.limits : {};
  const ceilings = isObject(limits.ceilings) ? limits.ceilings : {};
  const ceiling = (key: string) => {
    const value = numOrNull(ceilings[key]);
    return value === null ? {} : { [key]: value };
  };
  return {
    host: { name: str(host.name) },
    backend: { kind: str(backend.kind, 40), version: str(backend.version, 40) },
    protocol: {
      versions: list(protocol.versions, 16).filter(
        (v): v is number => typeof v === "number" && Number.isInteger(v),
      ),
    },
    capacity: {
      cpus: num(capacity.cpus),
      memoryMB: num(capacity.memoryMB),
      freeMemoryMB: num(capacity.freeMemoryMB),
      disks: list(capacity.disks, 64).map((disk) => {
        const d = isObject(disk) ? disk : {};
        return {
          name: str(d.name, 64),
          sizeGB: num(d.sizeGB),
          freeGB: num(d.freeGB),
        };
      }),
    },
    networks: list(r.networks, 64).map((net) => {
      const n = isObject(net) ? net : {};
      return { name: str(n.name), kind: str(n.kind, 40) };
    }),
    verbs: strings(r.verbs, 32),
    limits: {
      namePattern: str(limits.namePattern, 500),
      protected: strings(limits.protected, 200),
      ceilings: {
        ...ceiling("cpus"),
        ...ceiling("memoryMB"),
        ...ceiling("diskGB"),
      },
    },
    configProblem:
      typeof r.configProblem === "string" ? clip(r.configProblem, 500) : null,
  };
}

export function toConsole(result: unknown): ConsoleInfo {
  const c = need(need(result, "result").console, "console");
  if (c.kind !== "vmconnect") {
    throw new ProtocolError("this console kind is not known to HAW 1.0");
  }
  const port = num(c.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ProtocolError("the console port is not a port");
  }
  return { kind: "vmconnect", host: str(c.host), port, vmId: str(c.vmId, 64) };
}
