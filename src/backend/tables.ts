import {
  boolean,
  defineTable,
  id,
  integer,
  text,
  timestamp,
  varchar,
} from "@termix-ssh/plugin-sdk/db";

/*
 * Stored as p_haw_<name>. A host id here is a plain integer, not refHost():
 * deleting a Termix host never deletes the record of what HAW did on it, and
 * HAW drops a VM host whose Termix host is gone when it next reads it.
 *
 * Times are ISO strings set by the plugin. JSON columns are text the plugin
 * encodes itself. No text column has a default: MySQL refuses defaults on
 * TEXT.
 */

/** A Termix host that HAW manages VMs on, and the interface it speaks. */
export const vmHosts = defineTable(
  "vm_hosts",
  {
    id: id(),
    hostId: integer().notNull(),
    // hyper-v (libvirt later)
    interface: varchar(32).notNull(),
    addedBy: varchar(255).notNull(),
    addedAt: timestamp().notNull(),
    // JSON: the last `vmctl info` result, as the protocol checks keep it.
    lastInfo: text(),
    lastCheckedAt: timestamp(),
  },
  {
    uniques: [{ name: "uq_p_haw_vm_hosts_host", columns: ["hostId"] }],
  },
);

/**
 * The Termix host the Remote Desktop plugin opens a VM's console on. HAW
 * 1.0 can't make hosts, so a person links one they made.
 */
export const consoleLinks = defineTable(
  "console_links",
  {
    id: id(),
    vmHostId: integer().notNull(),
    vmId: varchar(64).notNull(),
    consoleHostId: integer().notNull(),
    linkedBy: varchar(255).notNull(),
    linkedAt: timestamp().notNull(),
  },
  {
    uniques: [
      { name: "uq_p_haw_console_links_vm", columns: ["vmHostId", "vmId"] },
    ],
  },
);

/** Every action a person took, and what the host answered. No secrets. */
export const actions = defineTable(
  "actions",
  {
    id: id(),
    at: timestamp().notNull(),
    userId: varchar(255).notNull(),
    hostId: integer().notNull(),
    // add-host, remove-host, start, stop, restart, link-console, ...
    action: varchar(32).notNull(),
    vmName: varchar(255),
    force: boolean().notNull(),
    ok: boolean().notNull(),
    // The vmctl error code, or HAW's own (unreachable, no-reply, ...).
    code: varchar(32),
    message: text(),
    // 1.0.3: the plugin that acted for the person through the service
    // haw.vms, and its own reference ("runbook 12 step 3"). Null for the tab.
    via: varchar(64),
    ref: varchar(255),
  },
  {
    indexes: [
      { name: "idx_p_haw_actions_at", columns: ["at"] },
      { name: "idx_p_haw_actions_host", columns: ["hostId"] },
    ],
  },
);

/** Every table, for `termix-plugin migrations`. */
export const tables = [vmHosts, consoleLinks, actions];
