import assert from 'node:assert';
import { test } from 'node:test';
import { buildWandUrl } from './_wandurl.mjs';

test('builds ws url with token/cols/rows', () => {
  const u = buildWandUrl({ host: '10.0.0.5', port: 8765, token: 'abc', tls: false }, 80, 24);
  assert.equal(u, 'ws://10.0.0.5:8765/ws?token=abc&cols=80&rows=24');
});

test('uses wss when tls', () => {
  const u = buildWandUrl({ host: 'h', port: 443, token: 't', tls: true }, 100, 40);
  assert.equal(u, 'wss://h:443/ws?token=t&cols=100&rows=40');
});

test('url-encodes token and optional cwd/shell', () => {
  const u = buildWandUrl(
    { host: 'h', port: 1, token: 'a b/c', tls: false, cwd: '/tmp/x y', shell: '/bin/zsh' }, 80, 24);
  assert.equal(
    u,
    'ws://h:1/ws?token=a%20b%2Fc&cols=80&rows=24&cwd=%2Ftmp%2Fx%20y&shell=%2Fbin%2Fzsh');
});

test('omits empty cwd/shell', () => {
  const u = buildWandUrl({ host: 'h', port: 1, token: 't', tls: false, cwd: '', shell: '' }, 80, 24);
  assert.equal(u, 'ws://h:1/ws?token=t&cols=80&rows=24');
});
