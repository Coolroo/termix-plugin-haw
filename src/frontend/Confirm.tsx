/**
 * One question before an action: a title, what it does, Cancel and the
 * action. Shown inside the tab's pane (PanePrompt), so it works in every
 * shell; Esc cancels.
 */

import { useState } from "react";
import { useTranslation } from "@termix-ssh/plugin-sdk/frontend";
import { Button, PanePrompt } from "@termix-ssh/plugin-sdk/ui";

export interface ConfirmRequest {
  title: string;
  text: string;
  confirmLabel: string;
  destructive: boolean;
  resolve: (yes: boolean) => void;
}

/** ask(request) shows it; the promise says yes or no. */
export function useConfirm(): [
  ConfirmRequest | null,
  (request: Omit<ConfirmRequest, "resolve">) => Promise<boolean>,
] {
  const [open, setOpen] = useState<ConfirmRequest | null>(null);
  const ask = (request: Omit<ConfirmRequest, "resolve">) =>
    new Promise<boolean>((resolve) =>
      setOpen({
        ...request,
        resolve: (yes) => {
          setOpen(null);
          resolve(yes);
        },
      }),
    );
  return [open, ask];
}

export function ConfirmPrompt({ request }: { request: ConfirmRequest | null }) {
  const { t } = useTranslation();
  if (!request) return null;
  return (
    <PanePrompt
      open
      role="alertdialog"
      title={request.title}
      description={request.text}
      tone={request.destructive ? "destructive" : "default"}
      onCancel={() => request.resolve(false)}
      actions={
        <>
          <Button variant="outline" onClick={() => request.resolve(false)}>
            {t("actions.cancel")}
          </Button>
          <Button
            variant={request.destructive ? "destructive" : "default"}
            onClick={() => request.resolve(true)}
          >
            {request.confirmLabel}
          </Button>
        </>
      }
    />
  );
}
