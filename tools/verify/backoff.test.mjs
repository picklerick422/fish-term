import assert from 'node:assert';
import { test } from 'node:test';
import { Backoff } from './_backoff.mjs';

test('doubles from base and caps at max', () => {
  const b = new Backoff(1000, 30000);
  assert.deepEqual(
    [b.next(), b.next(), b.next(), b.next(), b.next(), b.next(), b.next()],
    [1000, 2000, 4000, 8000, 16000, 30000, 30000]);
});

test('reset returns to base', () => {
  const b = new Backoff(1000, 30000);
  b.next();
  b.next();
  b.reset();
  assert.equal(b.next(), 1000);
});
