/**
 * HAW's tables, read and written through Drizzle on every database Termix
 * supports. No RETURNING (MySQL has none) except through insertId.
 */

import { and, desc, eq } from "drizzle-orm";
import type { PluginDatabase } from "@termix-ssh/plugin-sdk/backend";
import {
  actions as actionsDef,
  consoleLinks as consoleLinksDef,
  vmHosts as vmHostsDef,
} from "./tables.js";
import { toInfo, type HostInfo } from "../shared/protocol.js";
import { isInterfaceId, type InterfaceId } from "../shared/interfaces.js";

// Drizzle's table and client types are per dialect; the store treats them
// loosely and returns its own row types.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Table = any;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Drizzle = any;

export const now = () => new Date().toISOString();

export interface VmHostRow {
  id: number;
  hostId: number;
  interface: InterfaceId;
  addedBy: string;
  addedAt: string;
  lastInfo: HostInfo | null;
  lastCheckedAt: string | null;
}

export interface ConsoleLinkRow {
  vmHostId: number;
  vmId: string;
  consoleHostId: number;
  linkedBy: string;
  linkedAt: string;
}

export interface ActionRow {
  id: number;
  at: string;
  userId: string;
  hostId: number;
  action: string;
  vmName: string | null;
  force: boolean;
  ok: boolean;
  code: string | null;
  message: string | null;
  /** The plugin that acted for the person (service haw.vms), or null. */
  via: string | null;
  /** That plugin's reference, such as "runbook 12 step 3". */
  ref: string | null;
}

export type NewAction = Omit<ActionRow, "id" | "at" | "via" | "ref"> &
  Partial<Pick<ActionRow, "via" | "ref">>;

function parseInfo(text: unknown): HostInfo | null {
  if (typeof text !== "string" || !text) return null;
  try {
    return toInfo(JSON.parse(text));
  } catch {
    return null;
  }
}

function toVmHost(row: Record<string, unknown>): VmHostRow | null {
  // A row from a later version with an interface this one doesn't know
  // stays in the table, unused.
  if (!isInterfaceId(row.interface)) return null;
  return {
    id: Number(row.id),
    hostId: Number(row.hostId),
    interface: row.interface,
    addedBy: String(row.addedBy),
    addedAt: String(row.addedAt),
    lastInfo: parseInfo(row.lastInfo),
    lastCheckedAt: (row.lastCheckedAt as string | null) ?? null,
  };
}

const bool = (value: unknown) => value === true || value === 1 || value === "1";

function toAction(row: Record<string, unknown>): ActionRow {
  return {
    id: Number(row.id),
    at: String(row.at),
    userId: String(row.userId),
    hostId: Number(row.hostId),
    action: String(row.action),
    vmName: (row.vmName as string | null) ?? null,
    force: bool(row.force),
    ok: bool(row.ok),
    code: (row.code as string | null) ?? null,
    message: (row.message as string | null) ?? null,
    via: (row.via as string | null) ?? null,
    ref: (row.ref as string | null) ?? null,
  };
}

export type Store = Awaited<ReturnType<typeof createStore>>;

export async function createStore(db: PluginDatabase) {
  const vmHosts: Table = await db.define(vmHostsDef);
  const consoleLinks: Table = await db.define(consoleLinksDef);
  const actions: Table = await db.define(actionsDef);
  const client = (): Promise<Drizzle> => db.client<Drizzle>();

  async function insertId(
    table: Table,
    values: Record<string, unknown>,
  ): Promise<number> {
    const drizzle = await client();
    if (db.dialect === "mysql") {
      const result = await drizzle.insert(table).values(values);
      const header = Array.isArray(result) ? result[0] : result;
      return Number(header?.insertId);
    }
    const rows = await drizzle
      .insert(table)
      .values(values)
      .returning({ id: table.id });
    return Number(rows[0].id);
  }

  async function listVmHosts(): Promise<VmHostRow[]> {
    const rows = await (
      await client()
    )
      .select()
      .from(vmHosts)
      .orderBy(vmHosts.id);
    return rows.map(toVmHost).filter(Boolean) as VmHostRow[];
  }

  async function getVmHost(id: number): Promise<VmHostRow | null> {
    if (!Number.isInteger(id)) return null;
    const rows = await (
      await client()
    )
      .select()
      .from(vmHosts)
      .where(eq(vmHosts.id, id))
      .limit(1);
    return rows[0] ? toVmHost(rows[0]) : null;
  }

  async function vmHostByHostId(hostId: number): Promise<VmHostRow | null> {
    const rows = await (
      await client()
    )
      .select()
      .from(vmHosts)
      .where(eq(vmHosts.hostId, hostId))
      .limit(1);
    return rows[0] ? toVmHost(rows[0]) : null;
  }

  async function addVmHost(input: {
    hostId: number;
    interface: InterfaceId;
    addedBy: string;
    info: HostInfo;
  }): Promise<number> {
    const at = now();
    const id = await insertId(vmHosts, {
      hostId: input.hostId,
      interface: input.interface,
      addedBy: input.addedBy,
      addedAt: at,
      lastInfo: JSON.stringify(input.info),
      lastCheckedAt: at,
    });
    await db.persist();
    return id;
  }

  async function saveInfo(id: number, info: HostInfo): Promise<void> {
    await (
      await client()
    )
      .update(vmHosts)
      .set({ lastInfo: JSON.stringify(info), lastCheckedAt: now() })
      .where(eq(vmHosts.id, id));
    await db.persist();
  }

  async function removeVmHost(id: number): Promise<void> {
    const drizzle = await client();
    await drizzle.delete(consoleLinks).where(eq(consoleLinks.vmHostId, id));
    await drizzle.delete(vmHosts).where(eq(vmHosts.id, id));
    await db.persist();
  }

  async function consoleLinksFor(vmHostId: number): Promise<ConsoleLinkRow[]> {
    const rows = await (
      await client()
    )
      .select()
      .from(consoleLinks)
      .where(eq(consoleLinks.vmHostId, vmHostId));
    return rows.map((row: Record<string, unknown>) => ({
      vmHostId: Number(row.vmHostId),
      vmId: String(row.vmId),
      consoleHostId: Number(row.consoleHostId),
      linkedBy: String(row.linkedBy),
      linkedAt: String(row.linkedAt),
    }));
  }

  async function setConsoleLink(
    vmHostId: number,
    vmId: string,
    consoleHostId: number | null,
    userId: string,
  ): Promise<void> {
    const drizzle = await client();
    await drizzle
      .delete(consoleLinks)
      .where(
        and(eq(consoleLinks.vmHostId, vmHostId), eq(consoleLinks.vmId, vmId)),
      );
    if (consoleHostId !== null) {
      await drizzle.insert(consoleLinks).values({
        vmHostId,
        vmId,
        consoleHostId,
        linkedBy: userId,
        linkedAt: now(),
      });
    }
    await db.persist();
  }

  async function record(action: NewAction): Promise<void> {
    await insertId(actions, {
      ...action,
      at: now(),
      message: action.message ? action.message.slice(0, 1000) : null,
      via: action.via ?? null,
      ref: action.ref ? action.ref.slice(0, 255) : null,
    });
    await db.persist();
  }

  async function listActions(filter: {
    hostId?: number;
    vmName?: string;
    limit: number;
  }): Promise<ActionRow[]> {
    let query = (await client()).select().from(actions);
    const where = and(
      filter.hostId === undefined
        ? undefined
        : eq(actions.hostId, filter.hostId),
      filter.vmName === undefined
        ? undefined
        : eq(actions.vmName, filter.vmName),
    );
    if (where) query = query.where(where);
    const rows = await query.orderBy(desc(actions.id)).limit(filter.limit);
    return rows.map(toAction);
  }

  return {
    listVmHosts,
    getVmHost,
    vmHostByHostId,
    addVmHost,
    saveInfo,
    removeVmHost,
    consoleLinksFor,
    setConsoleLink,
    record,
    listActions,
  };
}
