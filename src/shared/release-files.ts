// Made by tools/release-files.mjs. Do not edit: run `node tools/release-files.mjs`.

export const REPO_RAW = "https://raw.githubusercontent.com/Coolroo/termix-plugin-haw";

/** SHA-256 (upper case hex) of each file a host's setup downloads. */
export const RELEASE_FILES = {
  "hyper-v": {
    "vmctl.ps1": "4A2881C2B8A6D3A80FEC378C5F0E575A26E7E733412658436B51F492639DE990",
    "vmctl-worker.ps1": "DE7B4BE4772EFA36F366DAA21401C7ABB50F67825E1638EAFDFFBB5C4C790859",
    "install.ps1": "0B8598F67B4A3A64DAB5C308836CCE99C3A860ECCAF3CFD210CA52041DE36815",
  },
} as const;
