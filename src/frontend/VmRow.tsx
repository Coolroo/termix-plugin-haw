/**
 * One VM in a host's list: two lines (name and badges, then state, size and
 * addresses), the uptime, and the buttons the person's role allows. A click
 * opens the VM's details in place: machine, disks, network, notes and the
 * last action HAW recorded for it. On a phone the row has no buttons; they
 * are in the details, large.
 */

import { useEffect, useState, type ReactNode } from "react";
import {
  useCurrentUser,
  usePluginApi,
  useTranslation,
} from "@termix-ssh/plugin-sdk/frontend";
import { Button, ListBadge } from "@termix-ssh/plugin-sdk/ui";
import {
  formatMemory,
  formatTime,
  formatUptime,
  refusal,
  type ActionView,
  type VmDetail,
  type VmView,
} from "./api";
import type { PowerAction } from "./HostCard";

/** The buttons on the row itself; the rest are in the details. */
const ROW_ACTIONS: ReadonlySet<PowerAction> = new Set([
  "start",
  "shutdown",
  "restart",
]);

const STATE_DOT = {
  running: "bg-emerald-500",
  off: "bg-muted-foreground/50",
  paused: "bg-amber-400",
  saved: "bg-amber-400",
  starting: "bg-sky-400",
  stopping: "bg-sky-400",
  other: "bg-muted-foreground/50",
} as const;

export function VmRow({
  vmHostId,
  termixHostId,
  vm,
  actions,
  canOperate,
  mobile,
  open,
  busy,
  onToggle,
  onPower,
  onConsole,
}: {
  vmHostId: number;
  termixHostId: number;
  vm: VmView;
  /** The power actions this VM's state allows, empty for a viewer. */
  actions: PowerAction[];
  canOperate: boolean;
  mobile: boolean;
  open: boolean;
  busy: boolean;
  onToggle: () => void;
  onPower: (action: PowerAction) => void;
  onConsole: () => void;
}) {
  const { t } = useTranslation();
  const rowActions = actions.filter((action) => ROW_ACTIONS.has(action));
  const button = (action: PowerAction, big = false) => (
    <Button
      key={action}
      size={big ? "default" : "xs"}
      variant={action === "start" ? "default" : "outline"}
      className={big ? "h-11" : undefined}
      disabled={busy}
      onClick={() => onPower(action)}
    >
      {t(`actions.${action}`)}
    </Button>
  );
  const consoleButton = (big = false) => (
    <Button
      size={big ? "default" : "xs"}
      variant="outline"
      className={big ? "h-11" : undefined}
      disabled={busy}
      onClick={onConsole}
    >
      {t("actions.console")}
    </Button>
  );

  return (
    <li data-testid={`vm-${vm.name}`} className={open ? "bg-muted/40" : ""}>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-2 px-3 py-2">
        <button
          type="button"
          className="flex min-h-11 min-w-0 flex-[1_1_18rem] items-center gap-3 text-left"
          aria-expanded={open}
          title={t("vms.expand", { name: vm.name })}
          onClick={onToggle}
        >
          <svg
            viewBox="0 0 24 24"
            className={`size-3 shrink-0 text-muted-foreground transition-transform ${open ? "rotate-90" : ""}`}
            fill="none"
            stroke="currentColor"
            strokeWidth={2}
            aria-hidden="true"
          >
            <path d="m9 6 6 6-6 6" />
          </svg>
          <span
            className={`size-2 shrink-0 rounded-full ${STATE_DOT[vm.state]}`}
            aria-hidden="true"
          />
          <span className="flex min-w-0 flex-1 flex-col gap-0.5">
            <span className="flex flex-wrap items-center gap-2">
              <span className="text-sm font-medium">{vm.name}</span>
              {vm.protected && (
                <span title={t("vms.protectedHint")}>
                  <ListBadge tone="warning">{t("vms.protected")}</ListBadge>
                </span>
              )}
              {!vm.allowed && (
                <span title={t("vms.notAllowedHint")}>
                  <ListBadge tone="muted">{t("vms.notAllowed")}</ListBadge>
                </span>
              )}
            </span>
            <span className="truncate text-xs text-muted-foreground">
              <span>{t(`vms.states.${vm.state}`)}</span>
              {` · ${t("vms.size_value", { cpus: vm.cpus, memory: formatMemory(vm.memoryMB) })}`}
              {vm.addresses.length > 0 && ` · ${vm.addresses.join(", ")}`}
            </span>
          </span>
          {vm.state === "running" && vm.uptimeSeconds > 0 && (
            <span className="shrink-0 text-xs text-muted-foreground">
              {t("vms.up", { time: formatUptime(vm.uptimeSeconds) })}
            </span>
          )}
        </button>
        {canOperate && !mobile && (
          <div className="ml-auto flex flex-wrap justify-end gap-1">
            {rowActions.map((action) => button(action))}
            {consoleButton()}
          </div>
        )}
      </div>
      {open && (
        <div className="flex flex-col gap-3 border-t border-dashed border-border px-3 pb-4 pt-3 md:pl-12">
          {canOperate && mobile && (
            <div className="grid grid-cols-2 gap-2" data-testid="vm-actions">
              {actions.map((action) => button(action, true))}
              {consoleButton(true)}
            </div>
          )}
          <VmDetails vmHostId={vmHostId} termixHostId={termixHostId} vm={vm} />
          {canOperate && !mobile && (
            <div className="flex flex-wrap gap-1">
              {actions
                .filter((action) => !ROW_ACTIONS.has(action))
                .map((action) => button(action))}
            </div>
          )}
        </div>
      )}
    </li>
  );
}

/** What `show` says about the VM, and the last action HAW recorded on it. */
function VmDetails({
  vmHostId,
  termixHostId,
  vm,
}: {
  vmHostId: number;
  termixHostId: number;
  vm: VmView;
}) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const me = useCurrentUser();
  const [detail, setDetail] = useState<VmDetail | null>(null);
  const [last, setLast] = useState<ActionView | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);

  // Read again when the state changes: a start or stop changes the
  // addresses, and records a new last action.
  useEffect(() => {
    let current = true;
    api
      .get<{ vm: VmDetail }>(
        `/hosts/${vmHostId}/vms/${encodeURIComponent(vm.name)}`,
      )
      .then((reply) => {
        if (!current) return;
        setDetail(reply.data.vm);
        setError(null);
      })
      .catch((failure) => current && setError(refusal(failure).error));
    api
      .get<ActionView[]>("/actions", {
        params: { hostId: termixHostId, vmName: vm.name, limit: 1 },
      })
      .then((reply) => current && setLast(reply.data[0] ?? null))
      .catch(() => current && setLast(null));
    return () => {
      current = false;
    };
  }, [api, vmHostId, termixHostId, vm.name, vm.state]);

  if (error) return <p className="text-xs text-destructive">{error}</p>;
  if (!detail)
    return (
      <p className="text-xs text-muted-foreground">{t("vms.detailsLoading")}</p>
    );

  const who = (userId: string) =>
    me?.userId === userId
      ? t("record.you")
      : t("record.other", { id: userId.slice(0, 8) });

  return (
    <div
      className="grid grid-cols-[repeat(auto-fit,minmax(12rem,1fr))] gap-x-6 gap-y-4 text-xs"
      data-testid="vm-details"
    >
      <Section title={t("vms.machine")}>
        {detail.generation !== null && (
          <span>{t("vms.generation", { generation: detail.generation })}</span>
        )}
        <span>
          {t("vms.size_value", {
            cpus: detail.cpus,
            memory: formatMemory(detail.memoryMB),
          })}
        </span>
        <span>{t("vms.checkpoints", { count: detail.checkpoints })}</span>
        <span className="break-all text-muted-foreground">
          {t("vms.id", { id: detail.id })}
        </span>
      </Section>
      <Section title={t("vms.disks")}>
        {detail.disks.length === 0 && (
          <span className="text-muted-foreground">{t("vms.noDisks")}</span>
        )}
        {detail.disks.map((disk, index) => (
          <DiskLine key={index} disk={disk} />
        ))}
      </Section>
      <Section title={t("vms.network")}>
        {detail.networks.map((net, index) => (
          <span key={index} className="flex flex-col">
            <span>{net.switch}</span>
            <span className="text-muted-foreground">{net.mac}</span>
            <span className="break-all">
              {net.addresses.join(", ") || t("vms.noAddress")}
            </span>
          </span>
        ))}
        {detail.networks.length === 0 && (
          <span className="text-muted-foreground">{t("vms.noAddress")}</span>
        )}
      </Section>
      <Section title={t("vms.notes")}>
        <span className="whitespace-pre-line break-words">
          {detail.notes || "—"}
        </span>
        <span className="mt-2 text-[10px] uppercase tracking-wider text-muted-foreground">
          {t("vms.lastAction")}
        </span>
        <span className="text-muted-foreground" data-testid="vm-last-action">
          {last
            ? `${t("record.line", {
                time: formatTime(last.at),
                user: who(last.userId),
                action: last.action,
              })}${last.force ? " (force)" : ""}${last.via ? ` · ${last.ref ? t("record.viaRef", { plugin: last.via, ref: last.ref }) : t("record.via", { plugin: last.via })}` : ""}${last.ok ? "" : ` · ${t("record.failed", { message: last.message ?? "" })}`}`
            : last === null
              ? t("vms.noAction")
              : ""}
        </span>
      </Section>
    </div>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <span className="text-[10px] uppercase tracking-wider text-muted-foreground">
        {title}
      </span>
      {children}
    </div>
  );
}

function DiskLine({
  disk,
}: {
  disk: { sizeGB: number | null; usedGB: number | null };
}) {
  const { t } = useTranslation();
  const { sizeGB, usedGB } = disk;
  if (sizeGB === null) return <span className="text-muted-foreground">?</span>;
  if (usedGB === null)
    return <span>{t("vms.diskSize", { size: sizeGB })}</span>;
  const percent = sizeGB > 0 ? Math.min(100, (usedGB / sizeGB) * 100) : 0;
  return (
    <span className="flex flex-col gap-1">
      <span>{t("vms.disk", { used: usedGB, size: sizeGB })}</span>
      <span className="h-1.5 overflow-hidden rounded-full bg-muted">
        <span
          className="block h-full rounded-full bg-accent-brand"
          style={{ width: `${percent}%` }}
        />
      </span>
    </span>
  );
}
