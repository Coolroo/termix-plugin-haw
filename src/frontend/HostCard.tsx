/**
 * One VM host: what its vmctl said last, its VMs, and the power and console
 * buttons the person's role allows. The host itself refuses what its limits
 * forbid; the page only hides buttons that can't work.
 */

import { useCallback, useEffect, useState } from "react";
import {
  usePluginApi,
  useTranslation,
  type ShellApi,
  type TermixApp,
} from "@termix-ssh/plugin-sdk/frontend";
import { Button, ListBadge } from "@termix-ssh/plugin-sdk/ui";
import { toast } from "sonner";
import {
  formatMemory,
  formatTime,
  formatUptime,
  refusal,
  type VmHostView,
  type VmListAnswer,
  type VmView,
} from "./api";
import { ConfirmPrompt, useConfirm } from "./Confirm";
import { ConsolePanel } from "./ConsolePanel";
import { canManage, canOperate, type Role } from "../shared/roles";

/** A power button: the verb it sends and whether it forces. */
type PowerAction = "start" | "shutdown" | "turnoff" | "restart" | "reset";
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

/** The buttons a VM in this state gets. */
export function powerActions(vm: VmView): PowerAction[] {
  if (!vm.allowed) return [];
  const startable =
    vm.state === "off" || vm.state === "saved" || vm.state === "paused";
  if (startable) return ["start"];
  if (vm.state !== "running") return [];
  return vm.protected ? [] : ["shutdown", "turnoff", "restart", "reset"];
}

const STATE_TONE = {
  running: "success",
  off: "muted",
  paused: "warning",
  saved: "warning",
  starting: "brand",
  stopping: "brand",
  other: "muted",
} as const;

export function HostCard({
  app,
  host,
  role,
  isVisible,
  shell,
  onRemoved,
}: {
  app: TermixApp;
  host: VmHostView;
  role: Role | null;
  isVisible: boolean;
  shell: ShellApi;
  onRemoved: () => void;
}) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const [vms, setVms] = useState<VmView[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [consoleOf, setConsoleOf] = useState<VmView | null>(null);
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
    if (isVisible) void load();
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

  const ceilings = info?.limits.ceilings ?? {};
  return (
    <section
      className="rounded-md border border-border"
      data-testid={`host-${host.id}`}
    >
      <header className="flex flex-wrap items-center justify-between gap-2 border-b border-border p-3">
        <div className="min-w-0">
          <h3 className="truncate text-sm font-medium">{host.name}</h3>
          {info && (
            <p className="text-xs text-muted-foreground">
              {t("hosts.summary", {
                backend: info.backend.kind,
                version: info.backend.version,
                cpus: info.capacity.cpus,
                free: formatMemory(info.capacity.freeMemoryMB),
                memory: formatMemory(info.capacity.memoryMB),
              })}
              {host.lastCheckedAt &&
                ` · ${t("hosts.checked", { time: formatTime(host.lastCheckedAt) })}`}
            </p>
          )}
          {info && (
            <p className="text-xs text-muted-foreground">
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
        </div>
        <div className="flex gap-2">
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
      {vms && vms.length > 0 && (
        <ul className="divide-y divide-border">
          {vms.map((vm) => (
            <li
              key={vm.id || vm.name}
              className="flex flex-wrap items-center gap-3 p-3"
              data-testid={`vm-${vm.name}`}
            >
              <div className="min-w-40 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="text-sm font-medium">{vm.name}</span>
                  <ListBadge tone={STATE_TONE[vm.state]}>
                    {t(`vms.states.${vm.state}`)}
                  </ListBadge>
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
                </div>
                <p className="text-xs text-muted-foreground">
                  {t("vms.size_value", {
                    cpus: vm.cpus,
                    memory: formatMemory(vm.memoryMB),
                  })}
                  {vm.addresses.length > 0 && ` · ${vm.addresses.join(", ")}`}
                  {vm.state === "running" &&
                    vm.uptimeSeconds > 0 &&
                    ` · ${t("vms.uptime")} ${formatUptime(vm.uptimeSeconds)}`}
                </p>
              </div>
              {canOperate(role) && (
                <div className="flex flex-wrap gap-1">
                  {powerActions(vm).map((action) => (
                    <Button
                      key={action}
                      size="xs"
                      variant={action === "start" ? "default" : "outline"}
                      disabled={busy !== null}
                      onClick={() => void power(vm, action)}
                    >
                      {t(`actions.${action}`)}
                    </Button>
                  ))}
                  <Button
                    size="xs"
                    variant="outline"
                    disabled={busy !== null}
                    onClick={() => setConsoleOf(vm)}
                  >
                    {t("actions.console")}
                  </Button>
                </div>
              )}
            </li>
          ))}
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
