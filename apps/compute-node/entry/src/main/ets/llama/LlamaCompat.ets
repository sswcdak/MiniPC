/**
 * Compatibility surface for the original llama-server-ohos page.
 * The HTTP/llama.cpp server is intentionally not started here: inference is
 * owned by libllama_probe.so in the MiniPC compute-node process.
 */
import llamaProbe from 'libllama_probe.so';

export class LlamaNativeCompat {
  private lastCommand: string = '';

  openllama(command: string): string {
    this.lastCommand = command;
    return 'direct-native';
  }

  getllama(): string {
    return this.lastCommand;
  }

  getnetworkips(): string {
    return llamaProbe.getnetworkips();
  }

  getnetworkneighbors(): string {
    return llamaProbe.getnetworkneighbors();
  }

  setbisect(_k1: number, _k2: number): number {
    return 0;
  }

  setdistconfig(rank: number, nRanks: number, endpoints: string, split: string): number {
    return llamaProbe.setdistconfig(rank, nRanks, endpoints, split);
  }

  togglerpcserver(_command: string): string {
    return 'direct-native';
  }

  getrpcstatus(): string {
    return 'stopped';
  }
}

export const nativeBridge: LlamaNativeCompat = new LlamaNativeCompat();
