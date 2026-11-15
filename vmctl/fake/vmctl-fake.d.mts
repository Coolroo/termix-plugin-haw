// Types of vmctl-fake.mjs, for the tests that import it.

export const VERSION: string;

export interface FakeVm {
  name: string;
  id: string;
  state: string;
  cpus: number;
  memoryMB: number;
  startedAt: number | null;
  addresses: string[];
  generation: number;
  disks: Array<{ sizeGB: number; usedGB: number }>;
  switch: string;
  mac: string;
  checkpoints: number;
  notes: string;
}

export interface FakeState {
  host: string;
  vms: FakeVm[];
}

export function defaultState(): FakeState;

export function readConfig(text: string | null): {
  config: {
    namePattern: string;
    protected: string[];
    ceilings: { cpus?: number; memoryMB?: number; diskGB?: number };
    console: { host: string | null; port: number };
  };
  problem: string | null;
};

export function handleLine(
  line: string,
  io: {
    load: () => { state: FakeState; configText: string | null };
    save: (state: FakeState) => void;
  },
): string;
