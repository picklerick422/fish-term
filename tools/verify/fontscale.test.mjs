import assert from 'node:assert';
import { test } from 'node:test';
import { clampFontSize, stepFontSize, DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE } from './_fontscale.mjs';

test('clamp keeps in-range, rounds, and bounds', () => {
  assert.equal(clampFontSize(16), 16);
  assert.equal(clampFontSize(16.4), 16);
  assert.equal(clampFontSize(MIN_FONT_SIZE - 5), MIN_FONT_SIZE);
  assert.equal(clampFontSize(MAX_FONT_SIZE + 5), MAX_FONT_SIZE);
});

test('clamp falls back to default on non-finite', () => {
  assert.equal(clampFontSize(NaN), DEFAULT_FONT_SIZE);
  assert.equal(clampFontSize(Infinity), DEFAULT_FONT_SIZE);
});

test('step moves by FONT_STEP and clamps at bounds', () => {
  assert.equal(stepFontSize(16, 1), 18);
  assert.equal(stepFontSize(16, -1), 14);
  assert.equal(stepFontSize(MAX_FONT_SIZE, 1), MAX_FONT_SIZE);
  assert.equal(stepFontSize(MIN_FONT_SIZE, -1), MIN_FONT_SIZE);
});
