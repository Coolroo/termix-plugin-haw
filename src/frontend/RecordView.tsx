/** The record of actions: who did what on which host, and what it answered. */

import { useEffect, useState } from "react";
import {
  useCurrentUser,
  usePluginApi,
  useTranslation,
} from "@termix-ssh/plugin-sdk/frontend";
import { EmptyState, ListBadge } from "@termix-ssh/plugin-sdk/ui";
import { formatTime, refusal, type ActionView } from "./api";

export function RecordView() {
  const { t } = useTranslation();
  const me = useCurrentUser();
  const api = usePluginApi();
  const [actions, setActions] = useState<ActionView[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .get<ActionView[]>("/actions", { params: { limit: 200 } })
      .then((reply) => setActions(reply.data))
      .catch((failure) => setError(refusal(failure).error));
  }, [api]);

  // HAW can't read other users' names (no users:read): the person's own
  // actions say "you", others a short form of the user's id.
  const who = (userId: string) =>
    me?.userId === userId
      ? t("record.you")
      : t("record.other", { id: userId.slice(0, 8) });

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
            {action.hostName}
            {action.vmName ? ` / ${action.vmName}` : ""}
            {action.force ? " (force)" : ""}
          </span>
          <span className="text-xs text-muted-foreground">
            {t("record.line", {
              time: formatTime(action.at),
              user: who(action.userId),
              action: action.action,
            })}
          </span>
          {action.via && (
            // Plain text, not a badge: a badge's capitals would change the
            // plugin's own reference.
            <span
              className="rounded-sm border border-primary/40 px-1.5 text-xs text-primary"
              data-testid="via"
            >
              {action.ref
                ? t("record.viaRef", { plugin: action.via, ref: action.ref })
                : t("record.via", { plugin: action.via })}
            </span>
          )}
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
