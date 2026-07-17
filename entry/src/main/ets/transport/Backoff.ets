// Exponential backoff for reconnects: base, 2x each attempt, capped at max (spec §4.3).
export class Backoff {
  private readonly base: number;
  private readonly max: number;
  private attempt: number = 0;

  constructor(base: number = 1000, max: number = 30000) {
    this.base = base;
    this.max = max;
  }

  next(): number {
    const delay: number = Math.min(this.max, this.base * Math.pow(2, this.attempt));
    this.attempt++;
    return delay;
  }

  reset(): void {
    this.attempt = 0;
  }
}
