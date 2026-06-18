#!/usr/bin/env node
// Quick test runner for debugging
import { clampFontSize, stepFontSize, DEFAULT_FONT_SIZE, MIN_FONT_SIZE, MAX_FONT_SIZE } from './tools/verify/_fontscale.mjs';

console.log('Testing fontscale...');

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    console.log('✓', name);
    passed++;
  } catch (e) {
    console.log('✗', name, e.message);
    failed++;
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, message) {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${expected}, got ${actual}`);
  }
}

// Test 1: clamp keeps in-range, rounds, and bounds
test('clamp keeps in-range, rounds, and bounds', () => {
  assertEqual(clampFontSize(16), 16, 'clampFontSize(16)');
  assertEqual(clampFontSize(16.4), 16, 'clampFontSize(16.4)');
  assertEqual(clampFontSize(MIN_FONT_SIZE - 5), MIN_FONT_SIZE, 'clampFontSize(MIN - 5)');
  assertEqual(clampFontSize(MAX_FONT_SIZE + 5), MAX_FONT_SIZE, 'clampFontSize(MAX + 5)');
});

// Test 2: clamp falls back to default on non-finite
test('clamp falls back to default on non-finite', () => {
  assertEqual(clampFontSize(NaN), DEFAULT_FONT_SIZE, 'clampFontSize(NaN)');
  assertEqual(clampFontSize(Infinity), DEFAULT_FONT_SIZE, 'clampFontSize(Infinity)');
});

// Test 3: step moves by FONT_STEP and clamps at bounds
test('step moves by FONT_STEP and clamps at bounds', () => {
  assertEqual(stepFontSize(16, 1), 18, 'stepFontSize(16, 1)');
  assertEqual(stepFontSize(16, -1), 14, 'stepFontSize(16, -1)');
  assertEqual(stepFontSize(MAX_FONT_SIZE, 1), MAX_FONT_SIZE, 'stepFontSize(MAX, 1)');
  assertEqual(stepFontSize(MIN_FONT_SIZE, -1), MIN_FONT_SIZE, 'stepFontSize(MIN, -1)');
});

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed > 0 ? 1 : 0);
