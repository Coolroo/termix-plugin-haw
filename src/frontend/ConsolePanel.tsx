/**
 * A VM's console. The Remote Desktop plugin opens a Hyper-V console from a
 * saved Termix host that carries the VM's id; HAW 1.0 can't make hosts, so
 * an owner links one once and every operator then opens it with one click.
 * Without a link the panel says what that host needs.
 */

import { useEffect, useState } from "react";
import {
  usePluginApi,
  useTranslation,
  type ShellApi,
  type TermixApp,
} from "@termix-ssh/plugin-sdk/frontend";
import { Button, PanePrompt, SelectField } from "@termix-ssh/plugin-sdk/ui";
import { toast } from "sonner";
import {
  refusal,
  type ConsoleAnswer,
  type TermixHostView,
  type VmHostView,
  type VmView,
} from "./api";
import { CodeBox } from "./CodeBox";
import { canManage, type Role } from "../shared/roles";

/** The Remote Desktop plugin's tab type for RDP sessions. */
export const RDP_TAB = "rdp";

export function ConsolePanel({
  app,
  shell,
  host,
  vm,
  role,
  onClose,
}: {
  app: TermixApp;
  shell: ShellApi;
  host: VmHostView;
  vm: VmView;
  role: Role | null;
  onClose: () => void;
}) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const [answer, setAnswer] = useState<ConsoleAnswer | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [hosts, setHosts] = useState<TermixHostView[]>([]);
  const [pick, setPick] = useState("");

  async function load() {
    try {
      setAnswer(
        (
          await api.get<ConsoleAnswer>(
            `/hosts/${host.id}/vms/${encodeURIComponent(vm.name)}/console`,
          )
        ).data,
      );
    } catch (failure) {
      setError(refusal(failure).error);
    }
  }

  useEffect(() => {
    void load();
    if (canManage(role)) {
      api
        .get<TermixHostView[]>("/termix-hosts")
        .then((reply) => setHosts(reply.data))
        .catch(() => setHosts([]));
    }
    // Loaded once per panel.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function open() {
    if (!answer?.consoleHost) return;
    const record =
      app.getHost(answer.consoleHost.id) ??
      (await app.listHosts()).find(
        (h) => String(h.id) === String(answer.consoleHost!.id),
      );
    if (!record) {
      toast.error(t("console.noRd"));
      return;
    }
    shell.openTab(record, RDP_TAB, { label: vm.name });
    onClose();
  }

  async function link(consoleHostId: number | null) {
    if (!answer) return;
    try {
      await api.put(
        `/hosts/${host.id}/consoles/${encodeURIComponent(answer.console.vmId)}`,
        { consoleHostId },
      );
      await load();
    } catch (failure) {
      toast.error(refusal(failure).error);
    }
  }

  return (
    <PanePrompt
      open
      title={t("console.title", { name: vm.name })}
      onCancel={onClose}
      actions={
        <>
          <Button variant="outline" onClick={onClose}>
            {t("console.close")}
          </Button>
          {answer?.consoleHost && (
            <Button onClick={() => void open()}>{t("console.open")}</Button>
          )}
        </>
      }
    >
      {error && <p className="text-sm text-destructive">{error}</p>}
      {answer && (
        <div className="flex flex-col gap-3 text-sm" data-testid="console">
          {answer.consoleHost ? (
            <p>{t("console.linked", { name: answer.consoleHost.name })}</p>
          ) : (
            <>
              <p>{t("console.notLinked")}</p>
              <p className="text-muted-foreground">
                {t("console.fields", {
                  port: answer.console.port,
                  host: answer.console.host,
                })}
              </p>
            </>
          )}
          <div>
            <span className="text-xs text-muted-foreground">
              {t("console.vmId")}
            </span>
            <CodeBox text={answer.console.vmId} />
          </div>
          {canManage(role) && (
            <div className="flex flex-col gap-2">
              <SelectField
                label={t("console.link")}
                hint={t("console.linkHint")}
                value={pick}
                onChange={setPick}
                options={hosts.map((h) => ({
                  value: String(h.id),
                  label: `${h.name} (${h.address})`,
                }))}
              />
              <div className="flex gap-2">
                <Button
                  size="sm"
                  disabled={!pick}
                  onClick={() => void link(Number(pick))}
                >
                  {t("console.link")}
                </Button>
                {answer.consoleHost && (
                  <Button
                    size="sm"
                    variant="outline"
                    onClick={() => void link(null)}
                  >
                    {t("console.unlink")}
                  </Button>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </PanePrompt>
  );
}
