// Made by tools/release-files.mjs. Do not edit: run `node tools/release-files.mjs`.

export const REPO_RAW = "https://raw.githubusercontent.com/Coolroo/termix-plugin-haw";

/** SHA-256 (upper case hex) of each file a host's setup downloads. */
export const RELEASE_FILES = {
  "hyper-v": {
    "vmctl.ps1": "0A2AEF07A163623E15CB76AD8DCF28784863FD925F32CFDF526AE728C5120A20",
    "install.ps1": "A9419385997204F12A4E9D26BE45F3FD577487FD109D57DD42A1B924A95562F3",
  },
} as const;
