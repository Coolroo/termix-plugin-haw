/**
 * One VM host: what its vmctl said last, its VMs, and the power and console
 * buttons the person's role allows. The host itself refuses what its limits
 * forbid; the page only hides buttons that can't work.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import {
  usePluginApi,
  useTranslation,
  type ShellApi,
  type TermixApp,
} from "@termix-ssh/plugin-sdk/frontend";
import { Button, ListBadge, useIsMobile } from "@termix-ssh/plugin-sdk/ui";
import { toast } from "sonner";
import {
  formatMemory,
  formatTime,
  isStopped,
  matchesFilter,
  refusal,
  type VmFilter,
  type VmHostView,
  type VmListAnswer,
  type VmView,
} from "./api";
import { ConfirmPrompt, useConfirm } from "./Confirm";
import { ConsolePanel } from "./ConsolePanel";
import { VmRow } from "./VmRow";
import { canManage, canOperate, type Role } from "../shared/roles";

/** A power button: the verb it sends and whether it forces. */
export type PowerAction =
  "start" | "shutdown" | "turnoff" | "restart" | "reset";
const POWER: Record<
  PowerAction,
  { verb: string; force: boolean; destructive: boolean }
> = {
  start: { verb: "start", force: false, destructive: false },
  shutdown: { verb: "stop", force: false, destructive: true },
  turnoff: { verb: "stop", force: true, destructive: true },
  restart: { verb: "restart", force: false, destructive: true },
  reset: { verb: "restart", force: true, destructive: true },
};

/**
 * How long the list waits after one read before the next, while the tab is
 * on screen. A read only starts when the last one ended, so a slow host is
 * never asked twice at once.
 */
export const POLL_MS = 2000;

/** The buttons a VM in this state gets. */
export function powerActions(vm: VmView): PowerAction[] {
  if (!vm.allowed) return [];
  const startable =
    vm.state === "off" || vm.state === "saved" || vm.state === "paused";
  if (startable) return ["start"];
  if (vm.state !== "running") return [];
  return vm.protected ? [] : ["shutdown", "turnoff", "restart", "reset"];
}

export function HostCard({
  app,
  host,
  role,
  isVisible,
  shell,
  filter,
  onVms,
  onRemoved,
}: {
  app: TermixApp;
  host: VmHostView;
  role: Role | null;
  isVisible: boolean;
  shell: ShellApi;
  filter: VmFilter;
  /** Each read of the list, so the tab can count VMs over all hosts. */
  onVms: (vmHostId: number, vms: VmView[]) => void;
  onRemoved: () => void;
}) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const mobile = useIsMobile();
  const [vms, setVms] = useState<VmView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [consoleOf, setConsoleOf] = useState<VmView | null>(null);
  const [open, setOpen] = useState<ReadonlySet<string>>(new Set());
  const [showLimits, setShowLimits] = useState(false);
  const [question, ask] = useConfirm();
  const info = host.info;

  const load = useCallback(async () => {
    try {
      setVms((await api.get<VmListAnswer>(`/hosts/${host.id}/vms`)).data.vms);
      setError(null);
    } catch (failure) {
      setError(refusal(failure).error);
    }
  }, [api, host.id]);

  useEffect(() => {
    if (vms) onVms(host.id, vms);
  }, [vms, host.id, onVms]);

  // An action in flight reads the list itself when it ends.
  const busyRef = useRef(false);

  useEffect(() => {
    if (!isVisible) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      if (!busyRef.current) await load();
      if (!stopped) timer = setTimeout(() => void tick(), POLL_MS);
    };
    void tick();
    return () => {
      stopped = true;
      if (timer) clearTimeout(timer);
    };
  }, [isVisible, load]);

  async function power(vm: VmView, action: PowerAction) {
    const { verb, force, destructive } = POWER[action];
    const yes = await ask({
      title: t(`actions.confirm.${action}`, { name: vm.name }),
      text: t(`actions.explain.${action}`),
      confirmLabel: t(`actions.${action}`),
      destructive,
    });
    if (!yes) return;
    setBusy(vm.name);
    busyRef.current = true;
    try {
      const done = (
        await api.post<{ vm: VmView }>(
          `/hosts/${host.id}/vms/${encodeURIComponent(vm.name)}/${verb}`,
          verb === "start" ? {} : { force },
        )
      ).data.vm;
      toast.success(
        t("actions.done", {
          name: done.name,
          state: t(`vms.states.${done.state}`),
        }),
      );
    } catch (failure) {
      toast.error(refusal(failure).error);
    } finally {
      busyRef.current = false;
      setBusy(null);
      void load();
    }
  }

  async function remove() {
    const yes = await ask({
      title: t("hosts.removeTitle", { name: host.name }),
      text: t("hosts.removeText"),
      confirmLabel: t("hosts.remove"),
      destructive: true,
    });
    if (!yes) return;
    try {
      await api.delete(`/hosts/${host.id}`);
      onRemoved();
    } catch (failure) {
      toast.error(refusal(failure).error);
    }
  }

  async function refresh() {
    try {
      await api.post(`/hosts/${host.id}/refresh`);
    } catch (failure) {
      toast.error(refusal(failure).error);
    }
    void load();
  }

  function toggle(key: string) {
    setOpen((now) => {
      const next = new Set(now);
      if (!next.delete(key)) next.add(key);
      return next;
    });
  }

  const ceilings = info?.limits.ceilings ?? {};
  const memory = info?.capacity.memoryMB ?? 0;
  const used = memory - (info?.capacity.freeMemoryMB ?? 0);
  const shown = (vms ?? []).filter((vm) => matchesFilter(vm, filter));
  const operate = canOperate(role);
  return (
    <section
      className="overflow-hidden rounded-md border border-border"
      data-testid={`host-${host.id}`}
    >
      <header className="flex flex-wrap items-center gap-x-6 gap-y-2 border-b border-border p-3">
        <div className="min-w-0 flex-[1_1_16rem]">
          <div className="flex flex-wrap items-center gap-2">
            <h3 className="truncate text-sm font-medium">{host.name}</h3>
            {info && <ListBadge tone="muted">{info.backend.kind}</ListBadge>}
            {vms && (
              <span className="text-xs text-muted-foreground">
                {t("hosts.counts", {
                  count: vms.length,
                  running: vms.filter((vm) => !isStopped(vm)).length,
                })}
              </span>
            )}
          </div>
          {info && (
            <p className="text-xs text-muted-foreground">
              {`vmctl ${info.backend.version} · ${info.capacity.cpus} CPUs`}
              {host.lastCheckedAt &&
                ` · ${t("hosts.checked", { time: formatTime(host.lastCheckedAt) })}`}
            </p>
          )}
        </div>
        {info && memory > 0 && (
          <div className="flex w-48 flex-col gap-1" data-testid="host-memory">
            <div className="flex justify-between text-xs">
              <span className="text-muted-foreground">{t("hosts.memory")}</span>
              <span>
                {t("hosts.memoryUsed", {
                  used: formatMemory(used),
                  total: formatMemory(memory),
                })}
              </span>
            </div>
            <div className="h-1.5 overflow-hidden rounded-full bg-muted">
              <div
                className="h-full rounded-full bg-accent-brand"
                style={{ width: `${Math.min(100, (used / memory) * 100)}%` }}
              />
            </div>
          </div>
        )}
        <div className="flex gap-2">
          {info && (
            <Button
              size="sm"
              variant="outline"
              aria-expanded={showLimits}
              onClick={() => setShowLimits((now) => !now)}
            >
              {t("hosts.limitsButton")}
            </Button>
          )}
          <Button size="sm" variant="outline" onClick={() => void refresh()}>
            {t("hosts.refresh")}
          </Button>
          {canManage(role) && (
            <Button size="sm" variant="outline" onClick={() => void remove()}>
              {t("hosts.remove")}
            </Button>
          )}
        </div>
      </header>
      {info && showLimits && (
        <p
          className="border-b border-border px-3 py-2 text-xs text-muted-foreground"
          data-testid="host-limits"
        >
          {t("hosts.limits", {
            pattern: info.limits.namePattern,
            protected:
              info.limits.protected.join(", ") || t("hosts.noProtected"),
          })}
          {ceilings.cpus !== undefined &&
            ceilings.memoryMB !== undefined &&
            ` · ${t("hosts.ceilings", { cpus: ceilings.cpus, memory: formatMemory(ceilings.memoryMB) })}`}
        </p>
      )}
      {info?.configProblem && (
        <p className="border-b border-border p-3 text-xs text-destructive">
          {t("hosts.configProblem", { problem: info.configProblem })}
        </p>
      )}
      {error && <p className="p-3 text-sm text-destructive">{error}</p>}
      {!error && vms === null && (
        <p className="p-3 text-sm text-muted-foreground">{t("vms.loading")}</p>
      )}
      {vms && vms.length === 0 && (
        <p className="p-3 text-sm text-muted-foreground">{t("vms.empty")}</p>
      )}
      {vms && vms.length > 0 && shown.length === 0 && (
        <p className="p-3 text-sm text-muted-foreground">
          {t("hosts.noMatch")}
        </p>
      )}
      {shown.length > 0 && (
        <ul className="divide-y divide-border">
          {shown.map((vm) => {
            const key = vm.id || vm.name;
            return (
              <VmRow
                key={key}
                vmHostId={host.id}
                termixHostId={host.hostId}
                vm={vm}
                actions={operate ? powerActions(vm) : []}
                canOperate={operate}
                mobile={mobile}
                open={open.has(key)}
                busy={busy !== null}
                onToggle={() => toggle(key)}
                onPower={(action) => void power(vm, action)}
                onConsole={() => setConsoleOf(vm)}
              />
            );
          })}
        </ul>
      )}
      {consoleOf && (
        <ConsolePanel
          app={app}
          shell={shell}
          host={host}
          vm={consoleOf}
          role={role}
          onClose={() => {
            setConsoleOf(null);
            void load();
          }}
        />
      )}
      <ConfirmPrompt request={question} />
    </section>
  );
}
