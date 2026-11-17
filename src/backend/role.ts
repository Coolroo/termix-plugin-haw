/** The acting person's HAW role, read from core's RBAC on every call. */

import type { PluginContext } from "@termix-ssh/plugin-sdk/backend";
import { PERMISSIONS, roleOf, type Role } from "../shared/roles.js";

export async function currentRole(ctx: PluginContext): Promise<Role | null> {
  const [view, operate, manage] = await Promise.all([
    ctx.rbac.has(PERMISSIONS.view),
    ctx.rbac.has(PERMISSIONS.operate),
    ctx.rbac.has(PERMISSIONS.manage),
  ]);
  return roleOf({ view, operate, manage });
}
