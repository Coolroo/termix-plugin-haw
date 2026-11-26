#!/usr/bin/env node
// A vmctl back end with no hypervisor, for tests and rehearsals. It speaks
// protocol version 1 (docs/protocol.md) exactly as vmctl.ps1 does, over VMs
// kept in a JSON state file, and follows the same host config: allow
// pattern, protect list, ceilings.
//
//   node vmctl-fake.mjs [--state <file>] [--config <file>]
//
// reads one request line on standard input and writes one reply line.
// Defaults: $HAW_FAKE_STATE and $HAW_FAKE_CONFIG, else state.json and
// vmctl.json next to this file. A missing state file starts with three VMs.
// Tests import handleLine() instead.
//
// A VM in the state may be "paused" with "critical": true and a "status"
// (Hyper-V's Paused-Critical), and may have a "drive" ({ name, sizeGB,
// freeGB }) that `show` gives. The state's "drive" is the default for every
// VM. The state's "verbs", when there, limits the verbs this fake offers, as
// an older vmctl would (an old host without "resume").

import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const VERSION = "1.1.0";
const PROTOCOL = 1;
const VERBS = [
  "info",
  "list",
  "show",
  "start",
  "stop",
  "restart",
  "resume",
  "console-info",
];
const LATER = ["create", "delete", "snapshot", "restore", "users"];
const ARGS = {
  info: [],
  list: [],
  show: ["name"],
  start: ["name"],
  stop: ["name", "force"],
  restart: ["name", "force"],
  resume: ["name"],
  "console-info": ["name"],
};
const DEFAULT_PATTERN = "^[a-z][a-z0-9-]{0,62}$";
const MAX_REQUEST = 64 * 1024;

export function defaultState() {
  const vm = (name, id, state, cpus, memoryMB) => ({
    name,
    id,
    state,
    cpus,
    memoryMB,
    startedAt: state === "running" ? Date.now() - 3600_000 : null,
    addresses: state === "running" ? ["192.0.2." + (10 + cpus)] : [],
    generation: 2,
    disks: [{ sizeGB: 40, usedGB: 12.5 }],
    switch: "LAN",
    mac: "00155D000000",
    checkpoints: 0,
    notes: "",
  });
  return {
    host: "fakehv",
    vms: [
      vm("build-1", "6f1d8f0e-0d0b-4bb7-9c1e-2a4b8d1c9e01", "running", 4, 8192),
      vm("test-vm1", "0b8a2c3d-5e6f-4a7b-8c9d-0e1f2a3b4c02", "off", 2, 4096),
      vm("web-1", "9e8d7c6b-5a49-4382-9170-6f5e4d3c2b03", "running", 2, 4096),
    ],
  };
}

const reply = (id, ok, body, v = PROTOCOL) =>
  JSON.stringify(
    ok
      ? { haw: "vmctl", v, id, ok: true, result: body }
      : { haw: "vmctl", v, id, ok: false, error: body },
  );
const fail = (id, code, message, extra = {}) =>
  reply(id, false, { code, message, ...extra });

class Refused extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/** The config's problem, or null; and the config with its defaults. */
export function readConfig(text) {
  const config = {
    namePattern: DEFAULT_PATTERN,
    protected: [],
    ceilings: {},
    console: { host: null, port: 2179 },
  };
  if (text === null) return { config, problem: "the config file is missing" };
  let raw;
  try {
    raw = JSON.parse(text);
  } catch {
    return { config, problem: "the config file is not JSON" };
  }
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    return { config, problem: "the config file is not an object" };
  }
  if (raw.namePattern !== undefined) {
    if (typeof raw.namePattern !== "string") {
      return { config, problem: "namePattern is not text" };
    }
    try {
      new RegExp(raw.namePattern);
    } catch {
      return { config, problem: "namePattern is not a regular expression" };
    }
    config.namePattern = raw.namePattern;
  }
  if (raw.protected !== undefined) {
    if (
      !Array.isArray(raw.protected) ||
      raw.protected.some((p) => typeof p !== "string")
    ) {
      return { config, problem: "protected is not a list of names" };
    }
    config.protected = raw.protected;
  }
  if (raw.ceilings !== undefined) {
    if (!raw.ceilings || typeof raw.ceilings !== "object") {
      return { config, problem: "ceilings is not an object" };
    }
    for (const key of ["cpus", "memoryMB", "diskGB"]) {
      const value = raw.ceilings[key];
      if (value === undefined) continue;
      if (typeof value !== "number" || !(value > 0)) {
        return { config, problem: `ceilings.${key} is not a number above 0` };
      }
      config.ceilings[key] = value;
    }
  }
  if (raw.console !== undefined) {
    const c = raw.console;
    if (!c || typeof c !== "object")
      return { config, problem: "console is not an object" };
    if (c.host !== undefined && typeof c.host !== "string") {
      return { config, problem: "console.host is not text" };
    }
    if (
      c.port !== undefined &&
      !(Number.isInteger(c.port) && c.port > 0 && c.port < 65536)
    ) {
      return { config, problem: "console.port is not a port" };
    }
    config.console = { host: c.host ?? null, port: c.port ?? 2179 };
  }
  return { config, problem: null };
}

// A protect entry is a name with * and ?, matched without case, as -like.
function wildcard(pattern) {
  const body = pattern
    .split("")
    .map((ch) =>
      ch === "*"
        ? ".*"
        : ch === "?"
          ? "."
          : ch.replace(/[\\^$.|+()[\]{}]/g, "\\$&"),
    )
    .join("");
  return new RegExp(`^${body}$`, "i");
}

const isProtected = (config, name) =>
  config.protected.some((p) => wildcard(p).test(name));
const isAllowed = (config, name) => new RegExp(config.namePattern).test(name);

function vmView(config, vm) {
  return {
    name: vm.name,
    id: vm.id,
    state: vm.state,
    cpus: vm.cpus,
    memoryMB: vm.memoryMB,
    uptimeSeconds: vm.startedAt
      ? Math.floor((Date.now() - vm.startedAt) / 1000)
      : 0,
    addresses: vm.state === "running" ? vm.addresses : [],
    allowed: isAllowed(config, vm.name),
    protected: isProtected(config, vm.name),
    status: vm.status ?? "Operating normally",
    critical: vm.critical === true,
  };
}

function detail(config, vm, state) {
  return {
    ...vmView(config, vm),
    generation: vm.generation,
    disks: vm.disks,
    networks: [
      {
        switch: vm.switch,
        mac: vm.mac,
        addresses: vm.state === "running" ? vm.addresses : [],
      },
    ],
    checkpoints: vm.checkpoints,
    notes: vm.notes,
    drive: vm.drive ?? state.drive ?? { name: "/", sizeGB: 500, freeGB: 300 },
  };
}

/** The verbs this fake offers: all, or the state's "verbs" (an old vmctl). */
const offered = (state) =>
  Array.isArray(state.verbs)
    ? VERBS.filter((verb) => state.verbs.includes(verb))
    : VERBS;

function findVm(state, name) {
  if (/[*?[\]]/.test(name))
    throw new Refused("bad-request", "a VM name can't hold * ? [ or ]");
  const vm = state.vms.find((v) => v.name === name);
  if (!vm) throw new Refused("not-found", `no VM named ${name}`);
  return vm;
}

function guard(config, vm, verb) {
  if (!isAllowed(config, vm.name)) {
    throw new Refused(
      "name-not-allowed",
      `${vm.name} does not match this host's name pattern`,
    );
  }
  if ((verb === "stop" || verb === "restart") && isProtected(config, vm.name)) {
    throw new Refused("protected", `${vm.name} is on this host's protect list`);
  }
}

// States in which a VM holds CPUs and memory, as vmctl-worker.ps1 counts them.
const LOAD_STATES = ["running", "paused", "starting", "stopping"];

function checkCeilings(config, state, vm) {
  const running = state.vms.filter(
    (v) => LOAD_STATES.includes(v.state) && v !== vm,
  );
  const cpus = running.reduce((sum, v) => sum + v.cpus, 0) + vm.cpus;
  const memory = running.reduce((sum, v) => sum + v.memoryMB, 0) + vm.memoryMB;
  const { ceilings } = config;
  if (ceilings.cpus !== undefined && cpus > ceilings.cpus) {
    throw new Refused(
      "ceiling",
      `running VMs would have ${cpus} CPUs; this host allows ${ceilings.cpus}`,
    );
  }
  if (ceilings.memoryMB !== undefined && memory > ceilings.memoryMB) {
    throw new Refused(
      "ceiling",
      `running VMs would have ${memory} MB; this host allows ${ceilings.memoryMB}`,
    );
  }
}

function run(verb, args, state, config, problem) {
  if (verb === "info") {
    return {
      host: { name: state.host },
      backend: { kind: "fake", version: VERSION },
      protocol: { versions: [PROTOCOL] },
      capacity: {
        cpus: 16,
        memoryMB: 65536,
        freeMemoryMB: 32768,
        disks: [{ name: "/", sizeGB: 500, freeGB: 300 }],
      },
      networks: [{ name: "LAN", kind: "external" }],
      verbs: offered(state),
      limits: {
        namePattern: config.namePattern,
        protected: config.protected,
        ceilings: config.ceilings,
      },
      configProblem: problem,
    };
  }
  if (problem) throw new Refused("config", problem);
  if (verb === "list") {
    const vms = [...state.vms].sort((a, b) => a.name.localeCompare(b.name));
    return { vms: vms.map((vm) => vmView(config, vm)) };
  }
  const vm = findVm(state, args.name);
  if (verb === "show") return { vm: detail(config, vm, state) };
  if (verb === "console-info") {
    // A console is control of the VM: only for VMs the pattern allows.
    if (!isAllowed(config, vm.name)) {
      throw new Refused(
        "name-not-allowed",
        `${vm.name} does not match this host's name pattern`,
      );
    }
    return {
      console: {
        kind: "vmconnect",
        host: config.console.host ?? state.host,
        port: config.console.port,
        vmId: vm.id,
      },
    };
  }
  guard(config, vm, verb);
  if (verb === "start") {
    if (vm.state === "paused")
      throw new Refused(
        "wrong-state",
        `${vm.name} is paused; resume it instead (start needs it off or saved)`,
      );
    if (vm.state === "running")
      throw new Refused("wrong-state", `${vm.name} is running`);
    checkCeilings(config, state, vm);
    vm.state = "running";
    vm.startedAt = Date.now();
    vm.addresses = ["192.0.2." + (10 + vm.cpus)];
  } else if (verb === "stop") {
    if (vm.state === "off")
      throw new Refused("wrong-state", `${vm.name} is off`);
    vm.state = "off";
    vm.startedAt = null;
  } else if (verb === "resume") {
    // Like start, the protect list allows it; a paused VM holds its CPUs
    // and memory already, so no ceiling changes.
    if (vm.state !== "paused")
      throw new Refused(
        "wrong-state",
        `${vm.name} is ${vm.state}; resume needs it paused`,
      );
    vm.state = "running";
    vm.critical = false;
    vm.status = "Operating normally";
    vm.addresses = ["192.0.2." + (10 + vm.cpus)];
  } else if (verb === "restart") {
    if (vm.state !== "running")
      throw new Refused("wrong-state", `${vm.name} is not running`);
    vm.startedAt = Date.now();
  }
  return { vm: vmView(config, vm), changed: true };
}

/**
 * One request line in, one reply line out. `load` gives the state and the
 * config text; `save` keeps a changed state.
 */
export function handleLine(line, { load, save }) {
  if (typeof line !== "string" || Buffer.byteLength(line) > MAX_REQUEST) {
    return fail(null, "bad-request", "the request is missing or too large");
  }
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    return fail(null, "bad-request", "the request is not JSON");
  }
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    return fail(null, "bad-request", "the request is not an object");
  }
  const id =
    typeof request.id === "string" && /^[A-Za-z0-9-]{1,64}$/.test(request.id)
      ? request.id
      : null;
  if (request.haw !== "vmctl")
    return fail(id, "bad-request", "not a vmctl request");
  if (id === null)
    return fail(null, "bad-request", "id must be 1-64 letters, digits or -");
  if (request.v !== PROTOCOL) {
    return fail(
      id,
      "version",
      `this vmctl speaks protocol version ${PROTOCOL}`,
      { versions: [PROTOCOL] },
    );
  }
  const { verb, args } = request;
  if (typeof verb !== "string")
    return fail(id, "bad-request", "verb is missing");
  if (LATER.includes(verb))
    return fail(
      id,
      "not-in-this-version",
      `${verb} is not in vmctl ${VERSION}`,
    );
  if (!VERBS.includes(verb))
    return fail(id, "unknown-verb", `${verb} is not a vmctl verb`);
  if (!args || typeof args !== "object" || Array.isArray(args)) {
    return fail(id, "bad-request", "args must be an object");
  }
  for (const key of Object.keys(args)) {
    if (!ARGS[verb].includes(key))
      return fail(id, "bad-request", `${verb} takes no argument ${key}`);
  }
  if (
    ARGS[verb].includes("name") &&
    (typeof args.name !== "string" || !args.name || args.name.length > 100)
  ) {
    return fail(id, "bad-request", "name must be text of 1-100 characters");
  }
  if (args.force !== undefined && typeof args.force !== "boolean") {
    return fail(id, "bad-request", "force must be true or false");
  }
  const { state, configText } = load();
  if (!offered(state).includes(verb))
    return fail(id, "unknown-verb", `${verb} is not a vmctl verb`);
  const { config, problem } = readConfig(configText);
  try {
    const result = run(verb, args, state, config, problem);
    if (result && result.changed) {
      delete result.changed;
      save(state);
    }
    return reply(id, true, result);
  } catch (error) {
    if (error instanceof Refused) return fail(id, error.code, error.message);
    return fail(id, "backend", String(error?.message ?? error));
  }
}

function main() {
  const here = dirname(fileURLToPath(import.meta.url));
  const flag = (name) => {
    const at = process.argv.indexOf(name);
    return at > 0 ? process.argv[at + 1] : undefined;
  };
  const statePath =
    flag("--state") ?? process.env.HAW_FAKE_STATE ?? join(here, "state.json");
  const configPath =
    flag("--config") ?? process.env.HAW_FAKE_CONFIG ?? join(here, "vmctl.json");
  const chunks = [];
  process.stdin.on("data", (chunk) => chunks.push(chunk));
  process.stdin.on("end", () => {
    const line = Buffer.concat(chunks).toString("utf8").split(/\r?\n/)[0];
    const out = handleLine(line, {
      load: () => ({
        state: existsSync(statePath)
          ? JSON.parse(readFileSync(statePath, "utf8"))
          : defaultState(),
        configText: existsSync(configPath)
          ? readFileSync(configPath, "utf8")
          : null,
      }),
      save: (state) => {
        writeFileSync(`${statePath}.tmp`, JSON.stringify(state, null, 2));
        renameSync(`${statePath}.tmp`, statePath);
      },
    });
    process.stdout.write(out + "\n");
  });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1])
  main();
