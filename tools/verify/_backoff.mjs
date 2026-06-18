// Kept equivalent to entry/src/main/ets/transport/Backoff.ets
export class Backoff {
  constructor(base = 1000, max = 30000) {
    this.base = base;
    this.max = max;
    this.attempt = 0;
  }
  next() {
    const delay = Math.min(this.max, this.base * Math.pow(2, this.attempt));
    this.attempt++;
    return delay;
  }
  reset() {
    this.attempt = 0;
  }
}
