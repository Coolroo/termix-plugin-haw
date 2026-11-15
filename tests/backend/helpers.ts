import { fileURLToPath } from "node:url";
import { afterEach } from "vitest";
import express, { type Router } from "express";
import { inject } from "light-my-request";
import {
  createMockCtx,
  createTestDb,
  type MockPluginContext,
  type TestDb,
} from "@termix-ssh/plugin-sdk/testing";
import type {
  PluginHostSummary,
  PluginSshExecOptions,
  PluginSshExecResult,
  PluginSshHost,
} from "@termix-ssh/plugin-sdk/backend";
import type { PluginManifest } from "@termix-ssh/plugin-sdk/manifest";
import manifestJson from "../../manifest.json";
import { defaultState, handleLine } from "../../vmctl/fake/vmctl-fake.mjs";

export const pluginDir = fileURLToPath(new URL("../..", import.meta.url));
export const manifest = manifestJson as unknown as PluginManifest;

export const OWNER = ["haw.view", "haw.operate", "haw.manage"];
export const OPERATOR = ["haw.view", "haw.operate"];
export const VIEWER = ["haw.view"];

export function host(id: number, userId = "alice"): PluginHostSummary {
  return {
    id,
    userId,
    name: `hv-${id}`,
    ip: `192.0.2.${id}`,
    port: 22,
    username: "vmctl",
    tags: null,
    folder: null,
    authType: "key",
  };
}

/** Hosts 1 and 3 have a stored host key; host 2 does not. */
export function sshHost(id: number, fingerprint: string | null): PluginSshHost {
  return {
    id,
    ip: `192.0.2.${id}`,
    port: 22,
    username: "vmctl",
    userId: "alice",
    hostKeyFingerprint: fingerprint,
  };
}

export type ExecFn = (
  host: number | PluginSshHost,
  command: string,
  options?: PluginSshExecOptions,
) => Promise<PluginSshExecResult>;

export const execResult = (
  stdout: string,
  extra: Partial<PluginSshExecResult> = {},
): PluginSshExecResult => ({
  stdout,
  stderr: "",
  code: 0,
  truncated: false,
  timedOut: false,
  ...extra,
});

/** A fake vmctl host: its VMs and its vmctl.json, kept between calls. */
export interface FakeHost {
  state: ReturnType<typeof defaultState>;
  config: string | null;
}

export function fakeHost(
  config: Record<string, unknown> | null = {},
): FakeHost {
  return {
    state: defaultState(),
    config: config === null ? null : JSON.stringify(config),
  };
}

/** Exec that answers with the fake back end of the host it is sent to. */
export function fakeExec(hosts: Record<number, FakeHost>): ExecFn {
  return async (target, _command, options) => {
    const id = typeof target === "number" ? target : target.id;
    const fake = hosts[id];
    if (!fake) throw new Error("connect ECONNREFUSED");
    const line = String(options?.stdin ?? "").split("\n")[0];
    const out = handleLine(line, {
      load: () => ({ state: fake.state, configText: fake.config }),
      save: (state: FakeHost["state"]) => {
        fake.state = state;
      },
    });
    return execResult(`${out}\n`);
  };
}

export interface Reply {
  status: number;
  // Route bodies vary per test; asserting on them is the point.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  body: any;
}

export interface TestServer {
  db: TestDb;
  mock: MockPluginContext;
  execCalls: Array<{
    host: unknown;
    command: string;
    options?: PluginSshExecOptions;
  }>;
  setExec: (fn: ExecFn) => void;
  call: (
    method: string,
    path: string,
    body?: unknown,
    options?: { user?: string | null; apiKey?: boolean },
  ) => Promise<Reply>;
  close: () => Promise<void>;
}

/**
 * The plugin activated against a real in-memory database, its router served
 * the way core serves it: JSON parsed and the acting user set from a login.
 */
export async function startServer(
  options: {
    permissions?: string[];
    hosts?: PluginHostSummary[];
    sshHosts?: PluginSshHost[];
    fakes?: Record<number, FakeHost>;
  } = {},
): Promise<TestServer> {
  const db = await createTestDb(pluginDir);
  for (const user of ["alice", "bob"]) {
    db.sqlite
      .prepare("INSERT INTO users (id, username) VALUES (?, ?)")
      .run(user, user);
  }
  let router: Router | null = null;
  const mock = createMockCtx({
    pluginId: manifest.id,
    manifest,
    capabilities: manifest.capabilities,
    db: db.database,
    router: () => (router = express.Router()),
    permissions: options.permissions ?? OWNER,
    hosts: options.hosts ?? [host(1), host(2), host(3)],
    sshHosts: options.sshHosts ?? [
      sshHost(1, "aa11"),
      sshHost(2, null),
      sshHost(3, "cc33"),
    ],
  });
  const execCalls: TestServer["execCalls"] = [];
  let exec: ExecFn = fakeExec(
    options.fakes ?? { 1: fakeHost(), 2: fakeHost(), 3: fakeHost() },
  );
  (mock.ctx.ssh as unknown as { exec: ExecFn }).exec = async (
    h,
    command,
    opts,
  ) => {
    execCalls.push({ host: h, command, options: opts });
    return exec(h, command, opts);
  };

  const { activate } = await import("../../src/backend/index.js");
  await activate(mock.ctx);

  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    if (req.header("x-test-api-key")) {
      (req as unknown as { apiKeyId: string }).apiKeyId = "key-1";
    }
    mock.setActor(req.header("x-test-user") || undefined);
    next();
  });
  app.use((req, res, next) => router!(req, res, next));

  const server: TestServer = {
    db,
    mock,
    execCalls,
    setExec: (fn) => {
      exec = fn;
    },
    call: async (method, path, body, opts = {}) => {
      const user = opts.user === undefined ? "alice" : opts.user;
      const response = await inject(app, {
        method: method as "GET",
        url: path,
        headers: {
          ...(user ? { "x-test-user": user } : {}),
          ...(opts.apiKey ? { "x-test-api-key": "1" } : {}),
          ...(body !== undefined ? { "content-type": "application/json" } : {}),
        },
        payload: body !== undefined ? JSON.stringify(body) : undefined,
      });
      let parsed: unknown = null;
      try {
        parsed = response.payload ? JSON.parse(response.payload) : null;
      } catch {
        parsed = response.payload;
      }
      return { status: response.statusCode, body: parsed };
    },
    close: async () => {
      for (const dispose of [...mock.disposals].reverse()) {
        await Promise.resolve(dispose()).catch(() => {});
      }
      db.close();
    },
  };
  return server;
}

const started: TestServer[] = [];

/** Call once at the top of a test file: servers close after each test. */
export function useTestServer(): typeof startServer {
  afterEach(async () => {
    for (const server of started.splice(0)) await server.close();
  });
  return async (options) => {
    const server = await startServer(options);
    started.push(server);
    return server;
  };
}

/** A server with host 1 added as a Hyper-V VM host; returns its VM host id. */
export async function withVmHost(
  start: typeof startServer,
  options: Parameters<typeof startServer>[0] = {},
) {
  const server = await start(options);
  const added = await server.call(
    "POST",
    "/hosts",
    { hostId: 1, interface: "hyper-v" },
    {},
  );
  if (added.status !== 201) throw new Error(JSON.stringify(added.body));
  return { server, id: added.body.id as number };
}

/** Adds a VM host row straight to the database, for servers without manage. */
export function seedVmHost(db: TestDb, hostId: number, id = hostId): void {
  db.sqlite
    .prepare(
      "INSERT INTO p_haw_vm_hosts (id, host_id, interface, added_by, added_at) VALUES (?, ?, 'hyper-v', 'alice', '2026-11-14T00:00:00.000Z')",
    )
    .run(id, hostId);
}
