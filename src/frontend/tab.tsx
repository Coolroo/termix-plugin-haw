/**
 * The HAW tab: the VM hosts with their VMs, Add VM host, and the record.
 */

import { useCallback, useEffect, useState } from "react";
import {
  usePluginApi,
  useTranslation,
  type TabProps,
  type TermixApp,
} from "@termix-ssh/plugin-sdk/frontend";
import {
  BackButton,
  Button,
  EmptyState,
  PanelShell,
} from "@termix-ssh/plugin-sdk/ui";
import { refusal, type MeAnswer, type VmHostView } from "./api";
import { AddHost } from "./AddHost";
import { HostCard } from "./HostCard";
import { RecordView } from "./RecordView";
import { canManage } from "../shared/roles";

export function HawIcon(props: { className?: string }) {
  return (
    <svg
      {...props}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M10 10v.2A3 3 0 0 1 8.9 16H5a3 3 0 0 1-1-5.8V10a3 3 0 0 1 6 0Z" />
      <path d="M7 16v6" />
      <path d="M13 19v3" />
      <path d="M12 19h8.3a1 1 0 0 0 .7-1.7L18 14h.3a1 1 0 0 0 .7-1.7L16 9h.2a1 1 0 0 0 .8-1.7L13 3l-1.4 1.5" />
    </svg>
  );
}

type View = { kind: "hosts" } | { kind: "add" } | { kind: "record" };

export function createHawTab(app: TermixApp) {
  return function HawTab({ isVisible, shell }: TabProps) {
    const { t } = useTranslation();
    const api = usePluginApi();
    const [me, setMe] = useState<MeAnswer | null>(null);
    const [hosts, setHosts] = useState<VmHostView[] | null>(null);
    const [error, setError] = useState<string | null>(null);
    const [view, setView] = useState<View>({ kind: "hosts" });

    const load = useCallback(async () => {
      try {
        const who = (await api.get<MeAnswer>("/me")).data;
        setMe(who);
        if (who.role) setHosts((await api.get<VmHostView[]>("/hosts")).data);
        setError(null);
      } catch (failure) {
        setError(refusal(failure).error);
      }
    }, [api]);

    useEffect(() => {
      if (isVisible) void load();
    }, [isVisible, load]);

    if (error) {
      return (
        <PanelShell
          title={t("tab.title")}
          icon={<HawIcon className="size-4" />}
        >
          <p className="p-4 text-sm text-destructive">
            {t("errors.load", { error })}
          </p>
        </PanelShell>
      );
    }
    if (!me) return null;
    if (!me.role) {
      return (
        <PanelShell
          title={t("tab.title")}
          icon={<HawIcon className="size-4" />}
        >
          <p className="p-4 text-sm text-muted-foreground">{t("role.none")}</p>
        </PanelShell>
      );
    }

    if (view.kind === "add") {
      return (
        <PanelShell
          title={t("add.title")}
          icon={<HawIcon className="size-4" />}
          leading={<BackButton onClick={() => setView({ kind: "hosts" })} />}
          scroll
        >
          <AddHost
            me={me}
            shell={shell}
            onAdded={() => {
              setView({ kind: "hosts" });
              void load();
            }}
            onCancel={() => setView({ kind: "hosts" })}
          />
        </PanelShell>
      );
    }
    if (view.kind === "record") {
      return (
        <PanelShell
          title={t("record.title")}
          icon={<HawIcon className="size-4" />}
          leading={<BackButton onClick={() => setView({ kind: "hosts" })} />}
          scroll
        >
          <RecordView hosts={hosts ?? []} />
        </PanelShell>
      );
    }

    return (
      <PanelShell
        title={t("hosts.title")}
        icon={<HawIcon className="size-4" />}
        status={
          <span className="text-xs text-muted-foreground">
            {t(`role.${me.role}`)}
          </span>
        }
        actions={
          <div className="flex gap-2">
            <Button
              size="sm"
              variant="outline"
              onClick={() => setView({ kind: "record" })}
            >
              {t("hosts.record")}
            </Button>
            {canManage(me.role) && (
              <Button size="sm" onClick={() => setView({ kind: "add" })}>
                {t("hosts.add")}
              </Button>
            )}
          </div>
        }
        scroll
      >
        {hosts && hosts.length === 0 ? (
          <EmptyState title={t("hosts.empty")} hint={t("hosts.emptyHint")} />
        ) : (
          <div className="flex flex-col gap-4 p-3">
            {(hosts ?? []).map((host) => (
              <HostCard
                key={host.id}
                app={app}
                host={host}
                role={me.role}
                isVisible={isVisible}
                shell={shell}
                onRemoved={() => void load()}
              />
            ))}
          </div>
        )}
      </PanelShell>
    );
  };
}
