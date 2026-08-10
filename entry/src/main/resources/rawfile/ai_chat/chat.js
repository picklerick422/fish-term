/**
 * chat.js — fish-ai 消息编排引擎
 *
 * 职责：
 * 1. 接收 window.onEvent(event) 流式事件 → DOM 渲染
 * 2. 管理消息状态（messages[] + streamingMsg + toolCards）
 * 3. JS → ArkTS 通信桥
 */

// ── 全局状态 ──
const state = {
  messages: [],              // 已完成的消息 [{role, content, toolResults}]
  streamingMsg: null,        // 当前正在流式的 AI 消息 DOM 元素
  streamingText: '',         // 已累积的原始文本
  toolCards: new Map(),      // tool_id → {card: DOM, pending: bool}
  highlightedBlocks: new Set(),  // 已高亮过的 <pre><code> block 索引
  scrollPending: false,
};

// ── Marked 初始化 ──
marked.setOptions({
  breaks: true,
  gfm: true,
});

// ── 支持的 HTML tags（DOMPurify 白名单） ──
const ALLOWED_TAGS = [
  'h1','h2','h3','h4','h5','h6','p','br','hr',
  'ul','ol','li','blockquote','pre','code','em','strong','del','ins',
  'a','img','table','thead','tbody','tr','th','td','caption',
  'span','div','input','details','summary',
];
const ALLOWED_ATTRS = ['href','src','alt','title','class','id','type','checked','open','start','line'];

// ── DOM 引用 ──
const $messages = document.getElementById('messages');
const $input = document.getElementById('user-input');
const $btnSend = document.getElementById('btn-send');
const $btnCancel = document.getElementById('btn-cancel');

// ── ArkTS → JS 入口 ──
window.onEvent = (event) => {
  switch (event.type) {
    case 'text_delta':    appendText(event.content); break;
    case 'tool_start':    createToolCard(event); break;
    case 'tool_progress': updateToolProgress(event); break;
    case 'tool_end':      completeToolCard(event); break;
    case 'done':          finalizeMessage(); break;
    case 'error':         showError(event.message); break;
    case 'filetree':      renderFileTree(event.tree); break;
  }
};

// ── JS → ArkTS ──
function postToArkTS(obj) {
  if (window.harmonyOS && window.harmonyOS.postMessage) {
    window.harmonyOS.postMessage(JSON.stringify(obj));
  }
}

// ── 发送消息 ──
function sendMessage() {
  const text = $input.value.trim();
  if (!text) return;

  if (!state.streamingMsg) {
    appendUserMessage(text);
  }

  postToArkTS({ action: 'send', text: text });
  $input.value = '';
  $input.style.height = 'auto';
  setSending(true);
}

function cancelGeneration() {
  postToArkTS({ action: 'cancel' });
  setSending(false);
}

function setSending(sending) {
  $btnSend.classList.toggle('hidden', sending);
  $btnCancel.classList.toggle('hidden', !sending);
  $input.disabled = sending;
}

// ── 用户消息 DOM ──
function appendUserMessage(text) {
  const el = createElement('div', 'message user');
  el.innerHTML = `<div class="content">${escapeHtml(text)}</div>`;
  $messages.appendChild(el);
  scrollToBottom(true);
}

// ── AI 消息气泡（首次流式文本时创建） ──
function ensureStreamingMsg() {
  if (state.streamingMsg) return;
  state.streamingMsg = createElement('div', 'message assistant');
  state.streamingMsg.innerHTML = '<div class="content"></div>';
  state.streamingText = '';
  $messages.appendChild(state.streamingMsg);
}

// ── 流式文本追加（性能关键路径） ──
function appendText(text) {
  ensureStreamingMsg();
  state.streamingText += text;

  const contentEl = state.streamingMsg.querySelector('.content');

  // 1. Markdown → HTML
  let html = marked.parse(state.streamingText);

  // 2. DOMPurify 净化（AI 输出的 HTML 不可信）
  html = DOMPurify.sanitize(html, { ALLOWED_TAGS, ALLOWED_ATTRS });

  // 3. 更新 DOM（保留光标）
  contentEl.innerHTML = html + '<span class="cursor-blink">▌</span>';

  // 4. 增量语法高亮——只处理新的未高亮代码块
  const allBlocks = contentEl.querySelectorAll('pre code');
  allBlocks.forEach((el, i) => {
    if (!state.highlightedBlocks.has(i) && el.textContent.length > 0) {
      state.highlightedBlocks.add(i);
      hljs.highlightElement(el);
    }
  });

  scrollToBottom();
}

// ── 工具调用卡片 ──
function createToolCard(event) {
  ensureStreamingMsg();
  const card = createElement('div', 'tool-card running');
  card.innerHTML = `
    <div class="tool-header">
      <span class="tool-icon">🔧</span>
      <span class="tool-name">${escapeHtml(event.name)}</span>
      <span class="tool-spinner"></span>
    </div>
    <div class="tool-output"></div>
  `;
  state.streamingMsg.appendChild(card);
  state.toolCards.set(event.id, { card, pending: true });
  scrollToBottom();
}

function updateToolProgress(event) {
  // tool_progress——增量工具输入（暂时仅记录）
}

function completeToolCard(event) {
  const entry = state.toolCards.get(event.id);
  if (!entry) return;

  entry.card.classList.remove('running');
  entry.pending = false;

  const spinner = entry.card.querySelector('.tool-spinner');

  if (event.is_error) {
    entry.card.classList.add('error');
    if (spinner) spinner.textContent = '✗';
  } else {
    entry.card.classList.add('done');
    if (spinner) spinner.textContent = '✓';

    // 检查是否是文件修改——是则渲染 diff
    const diff = extractDiff(event);
    if (diff) {
      showDiffPanel(diff, entry.card, event.id);
    }
  }

  // 输出内容
  const output = entry.card.querySelector('.tool-output');
  if (output && event.output) {
    output.textContent = truncateOutput(event.output);
  }

  // 点击展开/收起输出
  entry.card.addEventListener('click', () => {
    const out = entry.card.querySelector('.tool-output');
    if (out && out.textContent) {
      out.classList.toggle('expanded');
    }
  });
}

// ── 从 tool_end 提取 diff ──
function extractDiff(event) {
  const output = event.output || '';
  // 检测 unified diff 格式：以 --- 或 +++ 开头
  if (/^--- /.test(output) && /^\+\+\+ /.test(output)) {
    return output;
  }
  // 检测 @@ -N,N +N,N @@ 格式
  if (/^@@ -\d+(,\d+)? \+\d+(,\d+)? @@/m.test(output)) {
    return output;
  }
  // Edit 工具输出包含 old/new
  return null;
}

function truncateOutput(output) {
  const maxLen = 4000;
  if (output.length <= maxLen) return output;
  return output.slice(0, maxLen) + '\n\n... (output truncated)';
}

// ── 消息完成 ──
function finalizeMessage() {
  setSending(false);
  if (state.streamingMsg) {
    // 移除光标
    const cursor = state.streamingMsg.querySelector('.cursor-blink');
    if (cursor) cursor.remove();
  }
  // 重置流式状态
  state.streamingMsg = null;
  state.streamingText = '';
  state.highlightedBlocks.clear();
  scrollToBottom(true);
}

// ── 错误展示 ──
function showError(message) {
  setSending(false);
  const el = createElement('div', 'message assistant');
  el.style.borderColor = 'var(--color-danger)';
  el.innerHTML = `<div class="content" style="color:var(--color-danger)">⚠ ${escapeHtml(message)}</div>`;
  $messages.appendChild(el);
  state.streamingMsg = null;
  state.streamingText = '';
  scrollToBottom(true);
}

// ── 滚动辅助 ──
function scrollToBottom(force) {
  if (force) {
    $messages.scrollTop = $messages.scrollHeight;
    return;
  }
  if (!state.scrollPending) {
    state.scrollPending = true;
    requestAnimationFrame(() => {
      $messages.scrollTop = $messages.scrollHeight;
      state.scrollPending = false;
    });
  }
}

// ── 事件绑定 ──
$input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
  if (e.key === 'Escape') {
    cancelGeneration();
  }
});

// 自动调整输入框高度
$input.addEventListener('input', () => {
  $input.style.height = 'auto';
  $input.style.height = Math.min($input.scrollHeight, 120) + 'px';
});

$btnSend.addEventListener('click', sendMessage);
$btnCancel.addEventListener('click', cancelGeneration);

// ── 工具函数 ──
function createElement(tag, className) {
  const el = document.createElement(tag);
  if (className) el.className = className;
  return el;
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.appendChild(document.createTextNode(str));
  return div.innerHTML;
}
