/**
 * The service haw.vms 1.0.0, for other plugins (docs/service.md): VM actions
 * for a person, the way the tab does them.
 *
 * Core checks the "haw.view" permission for the acting user before every
 * call and runs the call as that user, so the person comes from
 * ctx.currentActor() and never from an argument. The caller's `user` must be
 * that same person, so a consumer that thinks it acts for someone else is
 * refused, not served as another. Then HAW checks the person's HAW role as
 * the tab's routes do, and runs vmctl through the same vmctl.ts, as that
 * person and with the same host checks.
 *
 * Core does not say which plugin calls, so every call carries the plugin's
 * key (callers.ts), and the plugin must be on the admin's allow-list. A
 * caller marked `agent` (a read for an agent token, as the person who made
 * it) may only list hosts and VMs.
 */

import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import { InputError } from "./errors.js";
import type { Store, VmHostRow } from "./store.js";
import type { Vmctl } from "./vmctl.js";
import { checked, refuse, VM_NAME } from "./calls.js";
import { CallerError, type Callers } from "./callers.js";
import { currentRole } from "./role.js";
import {
  ProtocolError,
  toConsole,
  toInfo,
  toVmDetail,
  toVmList,
  type HostInfo,
  type PowerVerb,
  type Vm,
  type VmDetail,
} from "../shared/protocol.js";
import { canOperate, canView, type Role } from "../shared/roles.js";
import type { InterfaceId } from "../shared/interfaces.js";
import type { ConsoleAnswer, VmView } from "../shared/api.js";

export const SERVICE = "haw.vms";

/** Who calls: the plugin, its key, the person, and what it is for. */
export interface Caller {
  plugin: string;
  key: string;
  /** The acting user's id; must be the user core runs the call as. */
  user: string;
  /** The caller's own reference for the record, e.g. "runbook 12 step 3". */
  ref?: string;
  /** A read for an agent token, as the person who made it: list only. */
  agent?: boolean;
}

export interface ServiceHost {
  /** The Termix host id: what every other call takes as `host`. */
  hostId: number;
  name: string;
  address: string;
  interface: InterfaceId;
  /** The verbs vmctl listed at its last `info`; [] before one. */
  verbs: string[];
  lastCheckedAt: string | null;
}

export interface VmService {
  bindPlugin(pluginId: string): Promise<void>;
  me(caller: Caller): Promise<{ role: Role | null; version: string }>;
  hosts(caller: Caller): Promise<ServiceHost[]>;
  info(caller: Caller, host: number): Promise<HostInfo>;
  list(caller: Caller, host: number): Promise<VmView[]>;
  show(caller: Caller, host: number, name: string): Promise<VmDetail>;
  start(caller: Caller, host: number, name: string): Promise<Vm>;
  stop(
    caller: Caller,
    host: number,
    name: string,
    options?: { force?: boolean },
  ): Promise<Vm>;
  restart(
    caller: Caller,
    host: number,
    name: string,
    options?: { force?: boolean },
  ): Promise<Vm>;
  consoleInfo(
    caller: Caller,
    host: number,
    name: string,
  ): Promise<ConsoleAnswer>;
}

/**
 * Every refusal the service throws: a message, a code (the protocol's,
 * HAW's own, or the service's) and the HTTP status the tab would answer.
 */
export class VmServiceError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly status: number,
    readonly detail?: string,
    readonly versions?: number[],
  ) {
    super(message);
    this.name = "VmServiceError";
  }
}

function toServiceError(error: unknown): unknown {
  if (error instanceof VmServiceError) return error;
  if (error instanceof CallerError) {
    return new VmServiceError(error.message, error.code, error.status);
  }
  if (error instanceof InputError) {
    const { code, detail, versions } = error.extra as {
      code?: string;
      detail?: string;
      versions?: number[];
    };
    return new VmServiceError(
      error.message,
      code ?? (error.status === 404 ? "not-found" : "refused"),
      error.status,
      detail,
      versions,
    );
  }
  return error;
}

/** The verbs a caller marked `agent` may use (H3). */
const AGENT_VERBS = new Set(["hosts", "list"]);
const MAX_REF = 200;

/** A reference as record text: one line, short. */
function cleanRef(ref: unknown): string | null {
  if (typeof ref !== "string") return null;
  const text = ref.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  return text ? text.slice(0, MAX_REF) : null;
}

export function createVmService(
  ctx: PluginContext,
  store: Store,
  vmctl: Vmctl,
  callers: Callers,
): VmService {
  interface Checked {
    plugin: string;
    userId: string;
    ref: string | null;
    agent: boolean;
  }

  /** The caller, checked: key, allow-list, person, agent limit. */
  async function admit(method: string, caller: unknown): Promise<Checked> {
    const userId = ctx.currentActor();
    if (!userId) {
      throw new VmServiceError("haw.vms needs an acting user", "no-actor", 401);
    }
    if (!caller || typeof caller !== "object") {
      throw new VmServiceError(
        "the first argument is the caller, { plugin, key, user }",
        "bad-request",
        400,
      );
    }
    const given = caller as Partial<Caller>;
    const plugin = await callers.verify(given.plugin, given.key);
    if (given.user !== userId) {
      throw new VmServiceError(
        "caller.user is not the user this call runs as",
        "not-acting-user",
        403,
      );
    }
    const agent = given.agent === true;
    if (agent && !AGENT_VERBS.has(method)) {
      throw new VmServiceError(
        `a call for an agent token may only list hosts and VMs, not ${method}`,
        "agent-read-only",
        403,
      );
    }
    return { plugin, userId, ref: cleanRef(given.ref), agent };
  }

  async function need(check: (role: Role | null) => boolean, what: string) {
    if (!check(await currentRole(ctx))) {
      throw new VmServiceError(`you may not ${what}`, "role", 403);
    }
  }

  /** A VM host the person can see, by its Termix host id. */
  async function vmHost(host: unknown): Promise<VmHostRow> {
    const missing = () =>
      new VmServiceError("no such VM host", "not-a-vm-host", 404);
    if (!Number.isInteger(host) || (host as number) <= 0) throw missing();
    const row = await store.vmHostByHostId(host as number);
    if (!row || !(await ctx.hosts.get(row.hostId))) throw missing();
    return row;
  }

  function vmName(name: unknown): string {
    if (typeof name !== "string" || !VM_NAME.test(name)) {
      throw new VmServiceError("not a VM name", "bad-request", 400);
    }
    return name;
  }

  /** What the audit line says about the caller, never more than that. */
  const viaText = (who: Pick<Checked, "plugin" | "ref" | "agent">) =>
    `via ${who.plugin}${who.agent ? " (agent token)" : ""}${who.ref ? `: ${who.ref}` : ""}`.slice(
      0,
      500,
    );

  /**
   * Runs one call: a refusal of the caller goes to Termix's audit log, and
   * every error leaves as a VmServiceError.
   */
  async function serve<T>(
    method: string,
    caller: unknown,
    fn: (who: Checked) => Promise<T>,
  ): Promise<T> {
    let who: Checked;
    try {
      who = await admit(method, caller);
    } catch (error) {
      const refused = toServiceError(error);
      const given = (caller ?? {}) as Partial<Caller>;
      await ctx.audit.record({
        action: `haw.service.${method}`,
        resourceType: "plugin",
        resourceName:
          typeof given.plugin === "string"
            ? given.plugin.replace(/[^a-z0-9-]/g, "?").slice(0, 40)
            : "unknown",
        success: false,
        errorMessage:
          refused instanceof Error ? refused.message.slice(0, 500) : "refused",
      });
      throw refused;
    }
    try {
      return await fn(who);
    } catch (error) {
      throw toServiceError(error);
    }
  }

  /**
   * A power action or a console, as the tab does it, recorded in HAW's
   * record with the plugin and its reference, and in Termix's audit log.
   */
  async function act<T>(
    who: Checked,
    row: VmHostRow,
    action: PowerVerb | "console",
    name: string,
    force: boolean,
    run: () => ReturnType<Vmctl>,
    read: (result: unknown) => Promise<T> | T,
  ): Promise<T> {
    const result = await run();
    const message = result.ok ? null : result.message;
    await store.record({
      userId: who.userId,
      hostId: row.hostId,
      action,
      vmName: name,
      force,
      ok: result.ok,
      code: result.ok ? null : result.code,
      message,
      via: who.plugin,
      ref: who.ref,
    });
    await ctx.audit.record({
      action: `haw.${action}`,
      resourceType: "host",
      resourceId: String(row.hostId),
      resourceName: name,
      details: viaText(who),
      success: result.ok,
      ...(message ? { errorMessage: message } : {}),
    });
    if (!result.ok) refuse(result);
    try {
      return await read(result.result);
    } catch (error) {
      if (error instanceof ProtocolError) {
        throw new VmServiceError(error.message, "protocol", 502);
      }
      throw error;
    }
  }

  async function power(
    verb: PowerVerb,
    caller: Caller,
    host: number,
    name: string,
    options?: { force?: boolean },
  ): Promise<Vm> {
    return serve(verb, caller, async (who) => {
      await need(canOperate, "start or stop VMs");
      const row = await vmHost(host);
      const vm = vmName(name);
      const force = options?.force;
      if (force !== undefined && typeof force !== "boolean") {
        throw new VmServiceError(
          "force must be true or false",
          "bad-request",
          400,
        );
      }
      const args =
        verb === "start" ? { name: vm } : { name: vm, force: force === true };
      return act(
        who,
        row,
        verb,
        vm,
        force === true,
        () => vmctl(row.hostId, row.interface, verb, args),
        (result) => toVmList({ vms: [(result as { vm?: unknown })?.vm] })[0],
      );
    });
  }

  return {
    bindPlugin: (pluginId) => bind(pluginId),

    me: (caller) =>
      serve("me", caller, async () => ({
        role: await currentRole(ctx),
        version: ctx.manifest.version,
      })),

    hosts: (caller) =>
      serve("hosts", caller, async () => {
        await need(canView, "see VM hosts");
        const out: ServiceHost[] = [];
        for (const row of await store.listVmHosts()) {
          const host = await ctx.hosts.get(row.hostId);
          if (!host) continue;
          out.push({
            hostId: row.hostId,
            name: host.name || host.ip,
            address: host.ip,
            interface: row.interface,
            verbs: row.lastInfo?.verbs ?? [],
            lastCheckedAt: row.lastCheckedAt,
          });
        }
        return out;
      }),

    info: (caller, host) =>
      serve("info", caller, async () => {
        await need(canView, "see VM hosts");
        const row = await vmHost(host);
        const result = await vmctl(row.hostId, row.interface, "info");
        if (!result.ok) refuse(result);
        const info = checked(() => toInfo(result.result));
        await store.saveInfo(row.id, info);
        return info;
      }),

    list: (caller, host) =>
      serve("list", caller, async () => {
        await need(canView, "see VMs");
        const row = await vmHost(host);
        const result = await vmctl(row.hostId, row.interface, "list");
        if (!result.ok) refuse(result);
        const vms = checked(() => toVmList(result.result));
        const links = new Map(
          (await store.consoleLinksFor(row.id)).map((link) => [
            link.vmId,
            link.consoleHostId,
          ]),
        );
        return vms.map((vm) => ({
          ...vm,
          consoleHostId: links.get(vm.id) ?? null,
        }));
      }),

    show: (caller, host, name) =>
      serve("show", caller, async () => {
        await need(canView, "see VMs");
        const row = await vmHost(host);
        const result = await vmctl(row.hostId, row.interface, "show", {
          name: vmName(name),
        });
        if (!result.ok) refuse(result);
        return checked(() =>
          toVmDetail((result.result as { vm?: unknown })?.vm),
        );
      }),

    start: (caller, host, name) => power("start", caller, host, name),
    stop: (caller, host, name, options) =>
      power("stop", caller, host, name, options),
    restart: (caller, host, name, options) =>
      power("restart", caller, host, name, options),

    consoleInfo: (caller, host, name) =>
      serve("consoleInfo", caller, async (who) => {
        await need(canOperate, "open consoles");
        const row = await vmHost(host);
        const vm = vmName(name);
        return act(
          who,
          row,
          "console",
          vm,
          false,
          () => vmctl(row.hostId, row.interface, "console-info", { name: vm }),
          async (result): Promise<ConsoleAnswer> => {
            const console = toConsole(result);
            const link = (await store.consoleLinksFor(row.id)).find(
              (entry) => entry.vmId === console.vmId,
            );
            const linked = link
              ? await ctx.hosts.get(link.consoleHostId)
              : null;
            return {
              console,
              consoleHost: linked
                ? { id: linked.id, name: linked.name || linked.ip }
                : null,
            };
          },
        );
      }),
  };

  /** bindPlugin, with a refusal in Termix's audit log. */
  async function bind(pluginId: string): Promise<void> {
    try {
      await callers.bind(pluginId);
    } catch (error) {
      const refused = toServiceError(error);
      await ctx.audit.record({
        action: "haw.service.bindPlugin",
        resourceType: "plugin",
        resourceName:
          typeof pluginId === "string"
            ? pluginId.replace(/[^a-z0-9-]/g, "?").slice(0, 40)
            : "unknown",
        success: false,
        errorMessage:
          refused instanceof Error ? refused.message.slice(0, 500) : "refused",
      });
      throw refused;
    }
    await ctx.audit.record({
      action: "haw.service.bindPlugin",
      resourceType: "plugin",
      resourceName: pluginId,
      success: true,
    });
  }
}
