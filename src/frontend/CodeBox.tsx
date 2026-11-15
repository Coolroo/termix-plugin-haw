/** Text in a monospace box with a Copy button. */

import { useState } from "react";
import { useTranslation } from "@termix-ssh/plugin-sdk/frontend";
import { Button } from "@termix-ssh/plugin-sdk/ui";

export function CodeBox({ text }: { text: string }) {
  const { t } = useTranslation();
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      setCopied(false);
    }
  }
  return (
    <div className="relative mt-2">
      <pre className="overflow-x-auto whitespace-pre-wrap break-all rounded-md border border-border bg-muted/40 p-2 pr-16 font-mono text-xs">
        {text}
      </pre>
      <Button
        size="xs"
        variant="outline"
        className="absolute right-2 top-2"
        onClick={() => void copy()}
      >
        {copied ? t("copy.copied") : t("copy.copy")}
      </Button>
    </div>
  );
}
