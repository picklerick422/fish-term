/**
 * Phase 2 自动验证脚本
 *
 * 在浏览器 Console 中粘贴运行此脚本 → 自动执行所有测试 → 打印结果。
 *
 * 前置条件：浏览器已打开 http://172.16.105.2:8080
 */

(async function runAllTests() {
  const results = [];
  let passed = 0;
  let failed = 0;

  function assert(label, condition, detail = '') {
    if (condition) { passed++; results.push(`✅ ${label}`); }
    else { failed++; results.push(`❌ ${label} ${detail}`); }
  }

  function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

  console.clear();
  console.log('═══ Phase 2 自动验证开始 ═══\n');

  // ── Test 1: 页面结构 ──
  console.log('── 1. DOM 结构');
  assert('  #app 存在', !!document.getElementById('app'));
  assert('  #filetree 存在', !!document.getElementById('filetree'));
  assert('  #messages 存在', !!document.getElementById('messages'));
  assert('  #user-input 存在', !!document.getElementById('user-input'));
  assert('  #btn-send 存在', !!document.getElementById('btn-send'));
  assert('  #btn-cancel 存在', !!document.getElementById('btn-cancel'));

  // ── Test 2: 库加载 ──
  console.log('── 2. 第三方库');
  assert('  marked 已加载', typeof marked !== 'undefined' && typeof marked.parse === 'function');
  assert('  hljs 已加载', typeof hljs !== 'undefined' && typeof hljs.highlightElement === 'function');
  assert('  Diff2Html 已加载', typeof Diff2Html !== 'undefined' && typeof Diff2Html.parse === 'function');
  assert('  DOMPurify 已加载', typeof DOMPurify !== 'undefined' && typeof DOMPurify.sanitize === 'function');

  // ── Test 3: 应用模块 ──
  console.log('── 3. 应用模块');
  assert('  window.onEvent 已注册', typeof window.onEvent === 'function');
  assert('  renderFileTree 已定义', typeof renderFileTree === 'function');
  assert('  showDiffPanel 已定义', typeof showDiffPanel === 'function');
  assert('  state 对象存在', typeof state !== 'undefined');

  // ── Test 4: 流式文本渲染 ──
  console.log('── 4. 流式文本渲染');
  const $msgs = document.getElementById('messages');
  const beforeCount = $msgs.children.length;

  window.onEvent({ type: 'text_delta', content: '## Hello **World**\n\n' });
  await sleep(100);
  window.onEvent({ type: 'text_delta', content: '```js\nconst a = 1;\n```' });
  await sleep(100);

  const afterCount = $msgs.children.length;
  assert('  消息气泡已创建', afterCount > beforeCount);
  const msg = $msgs.querySelector('.message.assistant');
  assert('  元素 class=assistant', !!msg);
  const h2 = msg?.querySelector('h2');
  assert('  Markdown 标题渲染', h2 && h2.textContent.includes('Hello'));
  const strong = msg?.querySelector('strong');
  assert('  Markdown 粗体渲染', strong && strong.textContent.includes('World'));
  const code = msg?.querySelector('pre code');
  assert('  代码块存在', !!code);
  assert('  光标闪烁元素存在', !!msg?.querySelector('.cursor-blink'));

  // ── Test 5: 工具卡片 ──
  console.log('── 5. 工具卡片');
  window.onEvent({ type: 'tool_start', id: 't_test', name: 'Read', input: { path: '/x' } });
  await sleep(50);
  const card = document.querySelector('.tool-card');
  assert('  工具卡片已创建', !!card);
  assert('  卡片 class=running', card?.classList.contains('running'));
  assert('  显示工具名 Read', card?.textContent.includes('Read'));

  window.onEvent({ type: 'tool_end', id: 't_test', output: 'file content', is_error: false });
  await sleep(50);
  assert('  完成后面 class=done', card?.classList.contains('done'));
  assert('  有 tool-output', !!card?.querySelector('.tool-output'));
  assert('  output 包含内容', card?.querySelector('.tool-output')?.textContent.includes('file content'));

  // ── Test 6: Diff 面板 ──
  console.log('── 6. Diff 面板');
  window.onEvent({ type: 'tool_start', id: 't_diff', name: 'Edit', input: {} });
  await sleep(50);
  window.onEvent({ type: 'tool_end', id: 't_diff',
    output: '--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new',
    is_error: false });
  await sleep(100);
  const diffPanel = document.querySelector('.diff-panel');
  assert('  diff-panel 已创建', !!diffPanel);
  assert('  Apply 按钮存在', !!document.querySelector('.diff-actions'));
  assert('  Revert 按钮存在', diffPanel?.textContent.includes('Revert'));

  // ── Test 7: 文件树渲染 ──
  console.log('── 7. 文件树渲染');
  window.onEvent({ type: 'filetree', tree: [
    { name: 'src', type: 'directory', children: [
      { name: 'index.ts', type: 'file', path: 'src/index.ts' }
    ]}
  ]});
  await sleep(50);
  const ft = document.getElementById('filetree');
  assert('  filetree 面板可见', ft && !ft.classList.contains('collapsed'));
  assert('  目录节点存在', ft?.textContent.includes('📁'));
  assert('  文件节点存在', ft?.textContent.includes('📄'));

  // ── Test 8: 错误消息 ──
  console.log('── 8. 错误处理');
  window.onEvent({ type: 'done', total_tokens: 42 });
  await sleep(50);
  window.onEvent({ type: 'error', message: 'Test error message' });
  await sleep(50);
  const errEl = $msgs.querySelector('.message.assistant:last-child .content');
  assert('  错误消息已渲染', errEl?.textContent.includes('Test error message'));

  // ── Test 9: done 事件清理 ──
  console.log('── 9. done 清理');
  // 上一个 done 已经清理了光标
  const cursors = document.querySelectorAll('.cursor-blink');
  assert('  done 后无残余光标', cursors.length === 0);

  // ── Test 10: 输入框交互 ──
  console.log('── 10. 输入交互');
  const input = document.getElementById('user-input');
  assert('  输入框存在且可用', input && !input.disabled);
  input.value = 'test message';
  input.dispatchEvent(new Event('input', { bubbles: true }));
  assert('  auto-resize 生效', parseInt(input.style.height) > 0);

  // ── Report ──
  console.log('\n═══ 验证结果 ═══');
  for (const r of results) console.log(r);
  console.log(`\n总计: ${passed} 通过 / ${failed} 失败 / ${passed + failed} 项`);

  if (failed === 0) {
    console.log('\n🎉 Phase 2 验证全部通过！');
  } else {
    console.log(`\n⚠ ${failed} 项失败，需要修复`);
  }
})();
