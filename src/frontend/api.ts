/**
 * The page's side of the routes: the shared answer types, and how a refused
 * request reads (status, HAW's code, the message, what the host said).
 */

export type {
  ActionView,
  CheckAnswer,
  ConsoleAnswer,
  Failure,
  MeAnswer,
  TermixHostView,
  VmHostView,
  VmListAnswer,
  VmView,
} from "../shared/api";
export type { HostInfo, VmDetail, VmState } from "../shared/protocol";
import type { VmView } from "../shared/api";

/** The list's state buttons: everything, VMs that run, VMs that don't. */
export type StateFilter = "all" | "running" | "stopped";

export interface VmFilter {
  text: string;
  state: StateFilter;
}

/** Off, saved and paused VMs run nothing; every other state counts as running. */
export function isStopped(vm: VmView): boolean {
  return vm.state === "off" || vm.state === "saved" || vm.state === "paused";
}

/** The filter box matches part of the name or of an address, in any case. */
export function matchesFilter(vm: VmView, filter: VmFilter): boolean {
  if (filter.state === "running" && isStopped(vm)) return false;
  if (filter.state === "stopped" && !isStopped(vm)) return false;
  const text = filter.text.trim().toLowerCase();
  if (!text) return true;
  return [vm.name, ...vm.addresses].some((value) =>
    value.toLowerCase().includes(text),
  );
}

export interface Refusal {
  status: number | null;
  code: string | null;
  error: string;
  detail: string | null;
}

/** What a refused request said, or the error's own text. */
export function refusal(error: unknown): Refusal {
  const response = (error as { response?: { status?: number; data?: unknown } })
    ?.response;
  const data =
    response?.data && typeof response.data === "object"
      ? (response.data as Record<string, unknown>)
      : {};
  return {
    status: response?.status ?? null,
    code: typeof data.code === "string" ? data.code : null,
    error:
      typeof data.error === "string"
        ? data.error
        : error instanceof Error
          ? error.message
          : String(error),
    detail: typeof data.detail === "string" ? data.detail : null,
  };
}

const MB = 1024;

/** 4096 -> "4 GB", 1536 -> "1.5 GB", 512 -> "512 MB". */
export function formatMemory(mb: number): string {
  if (mb < MB) return `${Math.round(mb)} MB`;
  const gb = mb / MB;
  return `${Number.isInteger(gb) ? gb : gb.toFixed(1)} GB`;
}

/** 90 -> "1m", 7200 -> "2h", 200000 -> "2d 7h". */
export function formatUptime(seconds: number): string {
  if (!seconds) return "";
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (days) return hours ? `${days}d ${hours}h` : `${days}d`;
  if (hours) return `${hours}h`;
  return `${Math.max(minutes, 1)}m`;
}

export function formatTime(iso: string | null): string {
  if (!iso) return "";
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? iso : date.toLocaleString();
}
