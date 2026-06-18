// Validates the streaming-decode contract used by Utf8Framer.ets.
// ArkTS util.TextDecoder.decodeWithStream({stream:true}) <=> Node TextDecoder.decode({stream:true}).
import assert from 'node:assert';
import { test } from 'node:test';

function makeFramer() {
  const dec = new TextDecoder('utf-8', { fatal: false, ignoreBOM: true });
  return { push: (u8) => dec.decode(u8, { stream: true }) };
}

test('decodes ASCII in one frame', () => {
  const f = makeFramer();
  assert.equal(f.push(new Uint8Array([0x68, 0x69])), 'hi');
});

test('reassembles a multibyte char split across two frames', () => {
  // U+4E2D (中) = E4 B8 AD
  const f = makeFramer();
  let out = f.push(new Uint8Array([0xE4, 0xB8])); // partial
  assert.equal(out, '');                          // nothing emitted yet
  out += f.push(new Uint8Array([0xAD]));          // completion
  assert.equal(out, '中');
});

test('reassembles an emoji split across three frames', () => {
  // U+1F600 = F0 9F 98 80
  const f = makeFramer();
  let out = f.push(new Uint8Array([0xF0]));
  out += f.push(new Uint8Array([0x9F, 0x98]));
  out += f.push(new Uint8Array([0x80]));
  assert.equal(out, '😀');
});

test('does not throw on invalid bytes', () => {
  const f = makeFramer();
  assert.doesNotThrow(() => f.push(new Uint8Array([0xFF, 0xFE])));
});
