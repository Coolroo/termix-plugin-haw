/**
 * Add VM host: pick a Termix host (or add one in Termix's own form), choose
 * its interface, and check it with `vmctl info`. When vmctl does not answer,
 * the one-time setup of that interface shows, and Check runs again.
 */

import { useCallback, useEffect, useState } from "react";
import {
  usePluginApi,
  useTranslation,
  type ShellApi,
} from "@termix-ssh/plugin-sdk/frontend";
import { Button, SelectField } from "@termix-ssh/plugin-sdk/ui";
import { toast } from "sonner";
import {
  refusal,
  type CheckAnswer,
  type Failure,
  type MeAnswer,
  type TermixHostView,
} from "./api";
import { CodeBox } from "./CodeBox";

/** Codes that mean vmctl is not there (yet): the setup steps help. */
const NEEDS_SETUP = new Set(["no-reply", "unreachable", "protocol", "version"]);

export function AddHost({
  me,
  shell,
  onAdded,
  onCancel,
}: {
  me: MeAnswer;
  shell: ShellApi;
  onAdded: () => void;
  onCancel: () => void;
}) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const [hosts, setHosts] = useState<TermixHostView[]>([]);
  const [hostId, setHostId] = useState("");
  const [iface, setIface] = useState<string>(me.interfaces[0]?.id ?? "");
  const [busy, setBusy] = useState(false);
  const [check, setCheck] = useState<CheckAnswer | null>(null);

  const loadHosts = useCallback(async () => {
    try {
      setHosts((await api.get<TermixHostView[]>("/termix-hosts")).data);
    } catch (failure) {
      toast.error(refusal(failure).error);
    }
  }, [api]);

  useEffect(() => {
    void loadHosts();
  }, [loadHosts]);

  const chosen = { hostId: Number(hostId), interface: iface };

  async function runCheck() {
    setBusy(true);
    setCheck(null);
    try {
      setCheck((await api.post<CheckAnswer>("/hosts/check", chosen)).data);
    } catch (failure) {
      const { error, code, detail } = refusal(failure);
      setCheck({
        ok: false,
        error,
        code: code ?? "failed",
        ...(detail ? { detail } : {}),
      });
    } finally {
      setBusy(false);
    }
  }

  async function save() {
    setBusy(true);
    try {
      await api.post("/hosts", chosen);
      onAdded();
    } catch (failure) {
      const { error, code, detail } = refusal(failure);
      setCheck({
        ok: false,
        error,
        code: code ?? "failed",
        ...(detail ? { detail } : {}),
      });
    } finally {
      setBusy(false);
    }
  }

  const setup = me.interfaces.find((entry) => entry.id === iface)?.setup ?? [];
  const failed = check && !check.ok ? (check as Failure) : null;

  return (
    <div className="flex max-w-3xl flex-col gap-4 p-4">
      <SelectField
        label={t("add.host")}
        hint={t("add.hostHint")}
        value={hostId}
        placeholder={t("add.pickHost")}
        onChange={(value) => {
          setHostId(value);
          setCheck(null);
        }}
        options={hosts.map((host) => ({
          value: String(host.id),
          label: `${host.name} (${host.username}@${host.address})${host.added ? ` ${t("add.added")}` : ""}`,
        }))}
      />
      <div className="flex flex-wrap gap-2">
        {shell.openHostEditor && (
          <Button
            variant="outline"
            size="sm"
            onClick={() =>
              shell.openHostEditor?.({ username: "vmctl", port: 22 })
            }
          >
            {t("add.newHost")}
          </Button>
        )}
        <Button variant="outline" size="sm" onClick={() => void loadHosts()}>
          {t("add.reload")}
        </Button>
      </div>
      <SelectField
        label={t("add.interface")}
        value={iface}
        onChange={(value) => {
          setIface(value);
          setCheck(null);
        }}
        options={me.interfaces.map((entry) => ({
          value: entry.id,
          label: t(entry.labelKey),
        }))}
      />
      <div className="flex gap-2">
        <Button
          disabled={!hostId || !iface || busy}
          onClick={() => void runCheck()}
        >
          {busy ? t("add.checking") : t("add.check")}
        </Button>
        <Button variant="outline" onClick={onCancel}>
          {t("add.cancel")}
        </Button>
      </div>

      {check?.ok && (
        <div
          className="flex flex-col gap-3 rounded-md border border-border p-3"
          data-testid="check-ok"
        >
          <p className="text-sm">
            {t("add.ok", {
              backend: check.info.backend.kind,
              version: check.info.backend.version,
              name: check.info.host.name,
            })}
          </p>
          <div>
            <Button disabled={busy} onClick={() => void save()}>
              {t("add.save")}
            </Button>
          </div>
        </div>
      )}

      {failed && (
        <div className="flex flex-col gap-3" data-testid="check-failed">
          <p className="text-sm text-destructive">
            {t("add.failed", { error: failed.error })}
          </p>
          {failed.detail && (
            <details>
              <summary className="cursor-pointer text-xs text-muted-foreground">
                {t("add.detail")}
              </summary>
              <CodeBox text={failed.detail} />
            </details>
          )}
          {NEEDS_SETUP.has(failed.code) && setup.length > 0 && (
            <div
              className="flex flex-col gap-2 rounded-md border border-border p-3"
              data-testid="setup"
            >
              <h3 className="text-sm font-medium">{t("add.setupTitle")}</h3>
              <p className="text-sm text-muted-foreground">
                {t("add.setupIntro")}
              </p>
              <ol className="ml-5 flex list-decimal flex-col gap-2 text-sm">
                {setup.map((step) => (
                  <li key={step.textKey}>
                    {t(step.textKey)}
                    {step.code && <CodeBox text={step.code} />}
                  </li>
                ))}
              </ol>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
