/**
 * diff-renderer.js — diff2html 封装
 *
 * 当 AI 使用 Write/Edit 工具修改文件时，在工具卡片下方展示可视化的 diff 面板。
 * 使用 diff2html 库——GitHub 风格的 side-by-side 视图 + 确认/撤销按钮。
 */

// diff 面板状态
let diffState = {
  panel: null,
  toolId: null,
};

/**
 * 渲染 diff 面板并插入到 parentCard 之后。
 *
 * @param {string} diffText  — unified diff 文本
 * @param {HTMLElement} parentCard — 工具卡片 DOM
 * @param {string} toolId — tool_use id
 */
function showDiffPanel(diffText, parentCard, toolId) {
  if (!diffText) return;

  // 移除已有 diff 面板
  if (diffState.panel) {
    diffState.panel.remove();
    diffState = { panel: null, toolId: null };
  }

  try {
    const diffJson = Diff2Html.parse(diffText);
    const diffHtml = Diff2Html.html(diffJson, {
      drawFileList: true,
      matching: 'lines',
      outputFormat: 'side-by-side',
      rawTemplates: {},
    });

    const panel = createElement('div', 'diff-panel');
    panel.innerHTML = diffHtml;

    // 操作按钮
    const actions = createElement('div', 'diff-actions');
    actions.innerHTML = `
      <button onclick="approveEdit()">✅ Apply</button>
      <button onclick="rejectEdit()">❌ Revert</button>
    `;
    panel.appendChild(actions);

    parentCard.after(panel);
    diffState = { panel, toolId };
  } catch (e) {
    console.warn('diff2html render failed:', e);
  }
}

/**
 * 确认 diff 修改——通知 ArkTS 批准权限响应。
 */
function approveEdit() {
  if (window.harmonyOS && window.harmonyOS.postMessage) {
    window.harmonyOS.postMessage(JSON.stringify({
      action: 'permission_response',
      approved: true,
    }));
  }
  if (diffState.panel) {
    diffState.panel.remove();
    diffState = { panel: null, toolId: null };
  }
}

/**
 * 拒绝 diff 修改——通知 ArkTS 拒绝权限响应。
 */
function rejectEdit() {
  if (window.harmonyOS && window.harmonyOS.postMessage) {
    window.harmonyOS.postMessage(JSON.stringify({
      action: 'permission_response',
      approved: false,
    }));
  }
  if (diffState.panel) {
    diffState.panel.remove();
    diffState = { panel: null, toolId: null };
  }
}
