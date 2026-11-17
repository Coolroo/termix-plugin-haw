/**
 * What the HAW routes send, typed once for the server and the page.
 */

import type { ConsoleInfo, HostInfo, Vm } from "./protocol.js";
import type { InterfaceId, SetupStep } from "./interfaces.js";
import type { Role } from "./roles.js";

export interface MeAnswer {
  role: Role | null;
  version: string;
  interfaces: Array<{ id: InterfaceId; labelKey: string; setup: SetupStep[] }>;
}

export interface VmHostView {
  id: number;
  hostId: number;
  name: string;
  address: string;
  interface: InterfaceId;
  info: HostInfo | null;
  lastCheckedAt: string | null;
}

export interface TermixHostView {
  id: number;
  name: string;
  address: string;
  username: string;
  /** A VM host already. */
  added: boolean;
}

/** A refused request's body: the message, HAW's or vmctl's code, details. */
export interface Failure {
  error: string;
  code: string;
  detail?: string;
  versions?: number[];
}

export type CheckAnswer =
  { ok: true; info: HostInfo } | ({ ok: false } & Failure);

export interface VmView extends Vm {
  /** The Termix host linked to open this VM's console, if any. */
  consoleHostId: number | null;
}

export interface VmListAnswer {
  vms: VmView[];
}

export interface ConsoleAnswer {
  console: ConsoleInfo;
  consoleHost: { id: number; name: string } | null;
}

export interface ActionView {
  id: number;
  at: string;
  userId: string;
  hostId: number;
  /** The Termix host's name as the person sees it. */
  hostName: string;
  action: string;
  vmName: string | null;
  force: boolean;
  ok: boolean;
  code: string | null;
  message: string | null;
  /** The plugin that acted for the person (1.0.3), or null for the tab. */
  via: string | null;
  /** That plugin's reference, such as "runbook 12 step 3". */
  ref: string | null;
}
