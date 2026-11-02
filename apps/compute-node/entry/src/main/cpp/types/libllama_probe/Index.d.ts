export const start: (
  modelPath: string,
  request: string,
  waitSeconds: number,
  contextSize: number,
  runtimeOptions?: string
) => number;
export const preload: (modelPath: string, contextSize: number, runtimeOptions?: string) => number;
export const status: () => string;
export const setdistconfig: (rank: number, ranks: number, endpoints: string, split: string) => number;
export const getnetworkips: () => string;
export const getnetworkneighbors: () => string;
export const takeEvents: () => string[];
export const cancel: (jobId?: number) => void;
export const complete: (jobId?: number) => void;
export const release: () => void;
