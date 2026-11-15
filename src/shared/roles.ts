/**
 * Who may do what in HAW. Three Termix permissions, one per role: a viewer
 * reads, an operator also powers VMs and opens consoles, an owner also adds
 * and removes VM hosts and links consoles. A higher role includes the lower
 * ones, so a person needs only the one permission of their role.
 */

export const PERMISSIONS = {
  view: "view",
  operate: "operate",
  manage: "manage",
} as const;

export type Role = "owner" | "operator" | "viewer";

/** The role a person's permissions give them, or null for none. */
export function roleOf(held: {
  view: boolean;
  operate: boolean;
  manage: boolean;
}): Role | null {
  if (held.manage) return "owner";
  if (held.operate) return "operator";
  if (held.view) return "viewer";
  return null;
}

export const canView = (role: Role | null) => role !== null;
export const canOperate = (role: Role | null) =>
  role === "owner" || role === "operator";
export const canManage = (role: Role | null) => role === "owner";
