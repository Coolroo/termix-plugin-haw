/**
 * The routes of the HAW tab. Every route needs a Termix login (no public
 * routes) and refuses a core API key: VMs are managed by a person in the
 * tab, never by a key. The role comes from three permissions (see
 * src/shared/roles.ts), and every host call runs as the person through
 * Termix's SSH pipeline, so a person reaches only hosts they can connect to.
 */

import type { Request, Router } from "express";
import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import { body, idParam, refuseApiKey, requireSignedIn, wrap } from "./http.js";
import { InputError } from "./errors.js";
import type { Store, VmHostRow } from "./store.js";
import type { Vmctl } from "./vmctl.js";
import { checked, failure, refuse, VM_NAME } from "./calls.js";
import {
  POWER_VERBS,
  toConsole,
  toInfo,
  toVmDetail,
  toVmList,
  type PowerVerb,
} from "../shared/protocol.js";
import {
  INTERFACE_IDS,
  INTERFACES,
  isInterfaceId,
} from "../shared/interfaces.js";
import { canManage, canOperate, canView, type Role } from "../shared/roles.js";
import { currentRole } from "./role.js";
import { isSshHost } from "../shared/hosts.js";
import type {
  ActionView,
  CheckAnswer,
  ConsoleAnswer,
  MeAnswer,
  TermixHostView,
  VmHostView,
  VmListAnswer,
} from "../shared/api.js";

const VM_ID = /^[A-Za-z0-9-]{1,64}$/;
const MAX_ACTIONS = 200;

export function registerRoutes(
  router: Router,
  ctx: PluginContext,
  store: Store,
  vmctl: Vmctl,
): void {
  const signedIn = requireSignedIn(ctx, "sign in to use HAW");
  const noApiKey = refuseApiKey("HAW does not take Termix API keys");
  const gate = [signedIn, noApiKey];
  const actor = () => ctx.currentActor()!;

  const role = () => currentRole(ctx);

  async function need(check: (role: Role | null) => boolean, what: string) {
    if (!check(await role())) throw new InputError(`you may not ${what}`, 403);
  }

  /** A VM host the person can see: their role, and the Termix host itself. */
  async function vmHostFor(
    req: Request,
  ): Promise<{ row: VmHostRow; name: string }> {
    const row = await store.getVmHost(idParam(req, "no such VM host"));
    if (!row) throw new InputError("no such VM host", 404);
    const host = await ctx.hosts.get(row.hostId);
    if (!host) throw new InputError("no such VM host", 404);
    return { row, name: host.name || host.ip };
  }

  function vmName(req: Request): string {
    const name = String(req.params.name ?? "");
    if (!VM_NAME.test(name)) throw new InputError("not a VM name", 400);
    return name;
  }

  async function audit(
    req: Request,
    entry: {
      action: string;
      hostId: number;
      vm?: string;
      ok: boolean;
      error?: string;
    },
  ) {
    await ctx.audit.record({
      action: `haw.${entry.action}`,
      resourceType: "host",
      resourceId: String(entry.hostId),
      ...(entry.vm ? { resourceName: entry.vm } : {}),
      success: entry.ok,
      ...(entry.error ? { errorMessage: entry.error } : {}),
      request: req,
    });
  }

  router.get(
    "/me",
    ...gate,
    wrap(async (): Promise<MeAnswer> => ({
      role: await role(),
      version: ctx.manifest.version,
      interfaces: INTERFACE_IDS.map((id) => ({
        id,
        labelKey: INTERFACES[id].labelKey,
        setup: INTERFACES[id].setup(ctx.manifest.version),
      })),
    })),
  );

  // The VM hosts this person can see. A VM host whose Termix host is gone,
  // or not shared with them, is left out.
  router.get(
    "/hosts",
    ...gate,
    wrap(async (): Promise<VmHostView[]> => {
      await need(canView, "see VM hosts");
      const out: VmHostView[] = [];
      for (const row of await store.listVmHosts()) {
        const host = await ctx.hosts.get(row.hostId);
        if (!host) continue;
        out.push({
          id: row.id,
          hostId: row.hostId,
          name: host.name || host.ip,
          address: host.ip,
          interface: row.interface,
          info: row.lastInfo,
          lastCheckedAt: row.lastCheckedAt,
        });
      }
      return out;
    }),
  );

  // Termix hosts an owner can add, for the Add VM host picker.
  router.get(
    "/termix-hosts",
    ...gate,
    wrap(async (): Promise<TermixHostView[]> => {
      await need(canManage, "add VM hosts");
      const added = new Set(
        (await store.listVmHosts()).map((row) => row.hostId),
      );
      return (await ctx.hosts.list()).map((host) => ({
        id: host.id,
        name: host.name || host.ip,
        address: host.ip,
        username: host.username,
        added: added.has(host.id),
      }));
    }),
  );

  /** `vmctl info` on a Termix host, for the Add VM host check. */
  async function checkHost(
    hostId: unknown,
    iface: unknown,
  ): Promise<CheckAnswer> {
    if (!Number.isInteger(hostId) || (hostId as number) <= 0) {
      throw new InputError("hostId must be a Termix host id", 400);
    }
    if (!isInterfaceId(iface)) {
      throw new InputError(
        `interface must be one of ${INTERFACE_IDS.join(", ")}`,
        400,
      );
    }
    const host = await ctx.hosts.get(hostId as number);
    if (!host) throw new InputError("no such Termix host", 404);
    const resolved = await ctx.ssh.resolveHost(hostId as number);
    if (resolved && !isSshHost(resolved)) {
      throw new InputError("this Termix host has no SSH", 400, {
        code: "not-ssh",
      });
    }
    const result = await vmctl(hostId as number, iface, "info");
    if (!result.ok) return { ok: false, ...failure(result) };
    const info = checked(() => toInfo(result.result));
    if (!info.protocol.versions.includes(1)) {
      return {
        ok: false,
        error: "vmctl on this host does not speak protocol version 1",
        code: "version",
        versions: info.protocol.versions,
      };
    }
    return { ok: true, info };
  }

  router.post(
    "/hosts/check",
    ...gate,
    wrap(async (req): Promise<CheckAnswer> => {
      await need(canManage, "add VM hosts");
      const { hostId, interface: iface } = body(req);
      return checkHost(hostId, iface);
    }),
  );

  router.post(
    "/hosts",
    ...gate,
    wrap(async (req, res) => {
      await need(canManage, "add VM hosts");
      const { hostId, interface: iface } = body(req);
      if (
        Number.isInteger(hostId) &&
        (await store.vmHostByHostId(hostId as number))
      ) {
        throw new InputError("this Termix host is a VM host already", 409, {
          code: "added",
        });
      }
      // The check runs again here: a host is added only while vmctl answers.
      const check = await checkHost(hostId, iface);
      if (!check.ok) {
        const { error, ...extra } = check;
        await audit(req, {
          action: "add-host",
          hostId: hostId as number,
          ok: false,
          error,
        });
        await store.record({
          userId: actor(),
          hostId: hostId as number,
          action: "add-host",
          vmName: null,
          force: false,
          ok: false,
          code: check.code,
          message: error,
        });
        throw new InputError(error, 409, extra);
      }
      const id = await store.addVmHost({
        hostId: hostId as number,
        interface: iface as VmHostRow["interface"],
        addedBy: actor(),
        info: check.info,
      });
      await store.record({
        userId: actor(),
        hostId: hostId as number,
        action: "add-host",
        vmName: null,
        force: false,
        ok: true,
        code: null,
        message: null,
      });
      await audit(req, {
        action: "add-host",
        hostId: hostId as number,
        ok: true,
      });
      res.status(201);
      return { id };
    }),
  );

  // Removing a VM host forgets it in HAW. Its VMs are not touched.
  router.delete(
    "/hosts/:id",
    ...gate,
    wrap(async (req) => {
      await need(canManage, "remove VM hosts");
      const { row } = await vmHostFor(req);
      await store.removeVmHost(row.id);
      await store.record({
        userId: actor(),
        hostId: row.hostId,
        action: "remove-host",
        vmName: null,
        force: false,
        ok: true,
        code: null,
        message: null,
      });
      await audit(req, { action: "remove-host", hostId: row.hostId, ok: true });
      return { removed: true };
    }),
  );

  router.post(
    "/hosts/:id/refresh",
    ...gate,
    wrap(async (req) => {
      await need(canView, "see VM hosts");
      const { row } = await vmHostFor(req);
      const result = await vmctl(row.hostId, row.interface, "info");
      if (!result.ok) refuse(result);
      const info = checked(() => toInfo(result.result));
      await store.saveInfo(row.id, info);
      return { info };
    }),
  );

  router.get(
    "/hosts/:id/vms",
    ...gate,
    wrap(async (req): Promise<VmListAnswer> => {
      await need(canView, "see VMs");
      const { row } = await vmHostFor(req);
      const result = await vmctl(row.hostId, row.interface, "list");
      if (!result.ok) refuse(result);
      const vms = checked(() => toVmList(result.result));
      const links = new Map(
        (await store.consoleLinksFor(row.id)).map((link) => [
          link.vmId,
          link.consoleHostId,
        ]),
      );
      return {
        vms: vms.map((vm) => ({
          ...vm,
          consoleHostId: links.get(vm.id) ?? null,
        })),
      };
    }),
  );

  router.get(
    "/hosts/:id/vms/:name",
    ...gate,
    wrap(async (req) => {
      await need(canView, "see VMs");
      const { row } = await vmHostFor(req);
      const result = await vmctl(row.hostId, row.interface, "show", {
        name: vmName(req),
      });
      if (!result.ok) refuse(result);
      return {
        vm: checked(() => toVmDetail((result.result as { vm?: unknown })?.vm)),
      };
    }),
  );

  router.post(
    "/hosts/:id/vms/:name/:verb",
    ...gate,
    wrap(async (req) => {
      const verb = String(req.params.verb) as PowerVerb;
      if (!(POWER_VERBS as readonly string[]).includes(verb)) {
        throw new InputError("no such action", 404);
      }
      await need(canOperate, "start or stop VMs");
      const { row } = await vmHostFor(req);
      const name = vmName(req);
      const { force } = body(req);
      if (force !== undefined && typeof force !== "boolean") {
        throw new InputError("force must be true or false", 400);
      }
      const args =
        verb === "start" ? { name } : { name, force: force === true };
      const result = await vmctl(row.hostId, row.interface, verb, args);
      const message = result.ok ? null : result.message;
      await store.record({
        userId: actor(),
        hostId: row.hostId,
        action: verb,
        vmName: name,
        force: force === true,
        ok: result.ok,
        code: result.ok ? null : result.code,
        message,
      });
      await audit(req, {
        action: verb,
        hostId: row.hostId,
        vm: name,
        ok: result.ok,
        ...(message ? { error: message } : {}),
      });
      if (!result.ok) refuse(result);
      return checked(() => ({
        vm: toVmList({ vms: [(result.result as { vm?: unknown })?.vm] })[0],
      }));
    }),
  );

  router.get(
    "/hosts/:id/vms/:name/console",
    ...gate,
    wrap(async (req): Promise<ConsoleAnswer> => {
      await need(canOperate, "open consoles");
      const { row } = await vmHostFor(req);
      const result = await vmctl(row.hostId, row.interface, "console-info", {
        name: vmName(req),
      });
      if (!result.ok) refuse(result);
      const console = checked(() => toConsole(result.result));
      const link = (await store.consoleLinksFor(row.id)).find(
        (entry) => entry.vmId === console.vmId,
      );
      const linked = link ? await ctx.hosts.get(link.consoleHostId) : null;
      return {
        console,
        consoleHost: linked
          ? { id: linked.id, name: linked.name || linked.ip }
          : null,
      };
    }),
  );

  // Links the Termix host that opens a VM's console (null unlinks).
  router.put(
    "/hosts/:id/consoles/:vmId",
    ...gate,
    wrap(async (req) => {
      await need(canManage, "link consoles");
      const { row } = await vmHostFor(req);
      const vmId = String(req.params.vmId ?? "");
      if (!VM_ID.test(vmId)) throw new InputError("not a VM id", 400);
      const { consoleHostId, vmName: named } = body(req);
      // The VM's name, for the record only: links are by the VM's id.
      if (
        named !== undefined &&
        (typeof named !== "string" || !VM_NAME.test(named))
      ) {
        throw new InputError("vmName must be a VM name", 400);
      }
      if (consoleHostId !== null) {
        if (
          !Number.isInteger(consoleHostId) ||
          !(await ctx.hosts.get(consoleHostId as number))
        ) {
          throw new InputError(
            "consoleHostId must be a Termix host you can see",
            400,
          );
        }
      }
      await store.setConsoleLink(
        row.id,
        vmId,
        consoleHostId as number | null,
        actor(),
      );
      await store.record({
        userId: actor(),
        hostId: row.hostId,
        action: consoleHostId === null ? "unlink-console" : "link-console",
        vmName: (named as string | undefined) ?? vmId,
        force: false,
        ok: true,
        code: null,
        message: null,
      });
      await audit(req, {
        action: consoleHostId === null ? "unlink-console" : "link-console",
        hostId: row.hostId,
        vm: (named as string | undefined) ?? vmId,
        ok: true,
      });
      return { consoleHostId };
    }),
  );

  router.get(
    "/actions",
    ...gate,
    wrap(async (req): Promise<ActionView[]> => {
      await need(canView, "see the record");
      const hostId =
        req.query.hostId === undefined ? undefined : Number(req.query.hostId);
      if (hostId !== undefined && !Number.isInteger(hostId)) {
        throw new InputError("hostId must be a number", 400);
      }
      const vmName =
        req.query.vmName === undefined ? undefined : String(req.query.vmName);
      if (vmName !== undefined && !VM_NAME.test(vmName)) {
        throw new InputError("not a VM name", 400);
      }
      const limit = Math.min(Number(req.query.limit) || 50, MAX_ACTIONS);
      // Names of the hosts the person can see, also for a host that is no
      // VM host (a failed add, a removed host).
      const names = new Map(
        (await ctx.hosts.list()).map((host) => [host.id, host.name || host.ip]),
      );
      return (await store.listActions({ hostId, vmName, limit }))
        .filter((action) => names.has(action.hostId))
        .map((action) => ({ ...action, hostName: names.get(action.hostId)! }));
    }),
  );
}
