/**
 * The interfaces a VM host can have: which vmctl back end runs there, the
 * command HAW sends to start it, and the one-time setup the page shows when
 * vmctl does not answer. HAW 1.0 has Hyper-V; libvirt comes later.
 */

import { RELEASE_FILES, REPO_RAW } from "./release-files.js";

export const INTERFACE_IDS = ["hyper-v"] as const;
export type InterfaceId = (typeof INTERFACE_IDS)[number];

export interface SetupStep {
  /** i18n key of the step's text. */
  textKey: string;
  /** A command to copy, when the step has one. */
  code?: string;
}

export interface InterfaceDef {
  id: InterfaceId;
  labelKey: string;
  /**
   * What HAW runs over SSH. A host set up as documented forces vmctl for the
   * account, so sshd ignores this; it runs vmctl on a host that does not.
   */
  command: string;
  /** The steps that put vmctl on a host, for this plugin version. */
  setup: (version: string) => SetupStep[];
}

const HYPERV_COMMAND =
  "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:/ProgramData/haw/vmctl.ps1";

/** The PowerShell lines that fetch the released files and run install.ps1. */
export function hypervInstallScript(version: string): string {
  const files = RELEASE_FILES["hyper-v"];
  return [
    `$base = '${REPO_RAW}/v${version}/vmctl/hyperv'`,
    "$d = Join-Path $env:TEMP 'haw-vmctl'",
    "New-Item -ItemType Directory -Force $d | Out-Null",
    "foreach ($f in 'vmctl.ps1', 'vmctl-worker.ps1', 'install.ps1') { Invoke-WebRequest \"$base/$f\" -OutFile (Join-Path $d $f) -UseBasicParsing }",
    `if ((Get-FileHash (Join-Path $d 'install.ps1')).Hash -ne '${files["install.ps1"]}') { throw 'install.ps1 is not the released file' }`,
    `& (Join-Path $d 'install.ps1') -Sha256 '${files["vmctl.ps1"]}' -WorkerSha256 '${files["vmctl-worker.ps1"]}' -PublicKey 'PASTE THE PUBLIC KEY HERE' -Protected @()`,
  ].join("\n");
}

export const INTERFACES: Record<InterfaceId, InterfaceDef> = {
  "hyper-v": {
    id: "hyper-v",
    labelKey: "interfaces.hyper-v.label",
    command: HYPERV_COMMAND,
    setup: (version) => [
      { textKey: "setup.hyper-v.key" },
      { textKey: "setup.hyper-v.host" },
      { textKey: "setup.hyper-v.hostKey" },
      { textKey: "setup.hyper-v.install", code: hypervInstallScript(version) },
      { textKey: "setup.hyper-v.protect" },
      { textKey: "setup.hyper-v.check" },
    ],
  },
};

export function isInterfaceId(value: unknown): value is InterfaceId {
  return (INTERFACE_IDS as readonly unknown[]).includes(value);
}
