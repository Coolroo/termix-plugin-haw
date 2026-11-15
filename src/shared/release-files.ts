// Made by tools/release-files.mjs. Do not edit: run `node tools/release-files.mjs`.

export const REPO_RAW =
  "https://raw.githubusercontent.com/Coolroo/termix-plugin-haw";

/** SHA-256 (upper case hex) of each file a host's setup downloads. */
export const RELEASE_FILES = {
  "hyper-v": {
    "vmctl.ps1": "PENDING",
    "install.ps1": "PENDING",
  },
} as const;
