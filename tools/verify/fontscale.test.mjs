import assert from 'node:assert';
import { test } from 'node:test';
import {
  clampFontSize, stepFontSize, DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE,
  clampLineSpacing, stepLineSpacing, DEFAULT_LINE_SPACING, MIN_LINE_SPACING, MAX_LINE_SPACING
} from './_fontscale.mjs';

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

test('line spacing clamp rounds to step and bounds', () => {
  assert.equal(clampLineSpacing(DEFAULT_LINE_SPACING), DEFAULT_LINE_SPACING);
  assert.equal(clampLineSpacing(1.07), 1.05);
  assert.equal(clampLineSpacing(MIN_LINE_SPACING - 0.5), MIN_LINE_SPACING);
  assert.equal(clampLineSpacing(MAX_LINE_SPACING + 0.5), MAX_LINE_SPACING);
  assert.equal(clampLineSpacing(NaN), DEFAULT_LINE_SPACING);
});

test('line spacing step moves by LINE_SPACING_STEP and clamps', () => {
  assert.equal(stepLineSpacing(1.05, 1), 1.1);
  assert.equal(stepLineSpacing(1.05, -1), 1.0);
  assert.equal(stepLineSpacing(MAX_LINE_SPACING, 1), MAX_LINE_SPACING);
  assert.equal(stepLineSpacing(MIN_LINE_SPACING, -1), MIN_LINE_SPACING);
});
