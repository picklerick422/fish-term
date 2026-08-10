/**
 * filetree.js — 文件树组件
 *
 * 纯 Vanilla JS 递归渲染文件树。
 * 数据由 ArkTS 侧从 Glob 工具结果构造，通过 window.onEvent({ type: 'filetree', tree: [...] }) 推送。
 *
 * 数据格式：
 * [
 *   { name: 'src', type: 'directory', children: [
 *     { name: 'auth', type: 'directory', children: [
 *       { name: 'service.ts', type: 'file', path: 'src/auth/service.ts' }
 *     ]}
 *   ]}
 * ]
 */

const $filetree = document.getElementById('filetree');

/**
 * 渲染文件树。
 * ArkTS 侧推送 filetree 事件时调用。
 *
 * @param {Array} tree — FileTreeNode[]
 */
function renderFileTree(tree) {
  if (!$filetree) return;
  $filetree.innerHTML = '';

  if (!tree || tree.length === 0) {
    $filetree.innerHTML = '<div style="padding:12px;color:var(--color-text-secondary)">No files</div>';
    return;
  }

  $filetree.classList.remove('collapsed');
  $filetree.appendChild(buildTreeNodes(tree, 0));
}

/**
 * 递归构建 DOM 树。
 *
 * @param {Array} nodes
 * @param {number} depth
 * @returns {HTMLUListElement}
 */
function buildTreeNodes(nodes, depth) {
  const ul = document.createElement('ul');
  ul.className = 'tree-level';

  for (const node of nodes) {
    const li = document.createElement('li');
    li.className = node.type;  // 'directory' or 'file'

    const label = document.createElement('span');
    label.className = 'tree-label';
    label.style.paddingLeft = `${depth * 16 + 4}px`;

    if (node.type === 'directory') {
      label.textContent = `📁 ${node.name}`;
    } else {
      label.textContent = `📄 ${node.name}`;
    }
    li.appendChild(label);

    // 点击文件 → 通知 ArkTS 打开文件
    if (node.type === 'file' && node.path) {
      li.addEventListener('click', () => {
        if (window.harmonyOS && window.harmonyOS.postMessage) {
          window.harmonyOS.postMessage(JSON.stringify({
            action: 'open_file',
            path: node.path,
          }));
        }
      });
    }

    // 目录：递归子节点 + 展开/收起
    if (node.children && node.children.length > 0) {
      li.appendChild(buildTreeNodes(node.children, depth + 1));
      li.classList.add('collapsible', 'expanded');

      label.addEventListener('click', (e) => {
        e.stopPropagation();
        li.classList.toggle('expanded');
      });
    }

    ul.appendChild(li);
  }

  return ul;
}

/**
 * 切换文件树面板的展开/收起。
 */
function toggleFileTree() {
  if (!$filetree) return;
  $filetree.classList.toggle('collapsed');
}
