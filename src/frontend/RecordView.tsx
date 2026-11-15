/** The record of actions: who did what on which host, and what it answered. */

import { useEffect, useState } from "react";
import { usePluginApi, useTranslation } from "@termix-ssh/plugin-sdk/frontend";
import { EmptyState, ListBadge } from "@termix-ssh/plugin-sdk/ui";
import { formatTime, refusal, type ActionView, type VmHostView } from "./api";

export function RecordView({ hosts }: { hosts: VmHostView[] }) {
  const { t } = useTranslation();
  const api = usePluginApi();
  const [actions, setActions] = useState<ActionView[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .get<ActionView[]>("/actions", { params: { limit: 200 } })
      .then((reply) => setActions(reply.data))
      .catch((failure) => setError(refusal(failure).error));
  }, [api]);

  const hostName = (hostId: number) =>
    hosts.find((host) => host.hostId === hostId)?.name ?? `#${hostId}`;

  if (error) return <p className="p-4 text-sm text-destructive">{error}</p>;
  if (actions && actions.length === 0)
    return <EmptyState title={t("record.empty")} />;
  return (
    <ul className="divide-y divide-border">
      {(actions ?? []).map((action) => (
        <li
          key={action.id}
          className="flex flex-wrap items-center gap-2 p-3 text-sm"
          data-testid="action"
        >
          <ListBadge tone={action.ok ? "success" : "destructive"}>
            {action.action}
          </ListBadge>
          <span>
            {hostName(action.hostId)}
            {action.vmName ? ` / ${action.vmName}` : ""}
            {action.force ? " (force)" : ""}
          </span>
          <span className="text-xs text-muted-foreground">
            {t("record.line", {
              time: formatTime(action.at),
              user: action.userId,
              action: action.action,
            })}
          </span>
          {!action.ok && action.message && (
            <span className="text-xs text-destructive">
              {t("record.failed", { message: action.message })}
            </span>
          )}
        </li>
      ))}
    </ul>
  );
}
