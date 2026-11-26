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
  /** Hyper-V's status words; "Operating normally" when not set. */
  status?: string;
  /** Paused-Critical and the like. */
  critical?: boolean;
  drive?: FakeDrive;
}

export interface FakeDrive {
  name: string;
  sizeGB: number;
  freeGB: number;
}

export interface FakeState {
  host: string;
  vms: FakeVm[];
  /** The drive `show` gives for a VM without its own. */
  drive?: FakeDrive;
  /** Limits the verbs offered, as an older vmctl (no "resume"). */
  verbs?: string[];
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
