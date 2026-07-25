import { FileTreeNode, FileEntry, ListDirResult } from './FileTreeTypes';

/**
 * 文件树操作工具类
 *
 * 对 FileTreeNode 树的查找、合并、失效等操作，
 * 保持 Index.ets 中回调代码简洁。
 */
export class FileTreeModel {
  /**
   * 在树中查找指定路径的节点（深度优先）
   */
  static findNode(root: FileTreeNode | null, path: string): FileTreeNode | null {
    if (!root) {
      return null;
    }
    if (root.path === path) {
      return root;
    }
    if (root.children) {
      for (const child of root.children) {
        const found: FileTreeNode | null = FileTreeModel.findNode(child, path);
        if (found) {
          return found;
        }
      }
    }
    return null;
  }

  /**
   * 将 list_dir_result 合并到树中：
   * 找到 path 对应的节点，设置其 children、expanded=true、loading=false
   * @returns 是否成功找到目标节点并合并
   */
  static mergeResult(root: FileTreeNode | null, result: ListDirResult): boolean {
    const node: FileTreeNode | null = FileTreeModel.findNode(root, result.path);
    if (!node || node.type !== 'directory') {
      return false;
    }
    node.loading = false;
    if (result.error) {
      node.error = result.error;
      node.children = [];
      return true;
    }
    node.error = '';
    const depth: number = node.depth + 1;
    node.children = result.entries.map((e: FileEntry) => {
      return FileTreeModel.entryToNode(e, result.path, depth);
    });
    node.expanded = true;
    return true;
  }

  /**
   * 将指定路径节点的 children 置为 null（失效缓存），
   * 触发下次展开时重新加载
   */
  static invalidatePath(root: FileTreeNode | null, path: string): boolean {
    const node: FileTreeNode | null = FileTreeModel.findNode(root, path);
    if (!node) {
      return false;
    }
    node.children = null;
    node.expanded = false;
    node.error = '';
    return true;
  }

  /**
   * 构建根节点（从 CWD 和首次 list_dir_result）
   */
  static createRoot(cwd: string, result: ListDirResult): FileTreeNode {
    const root: FileTreeNode = new FileTreeNode();
    root.name = FileTreeModel.baseName(cwd);
    root.type = 'directory';
    root.path = cwd;
    root.depth = 0;
    root.expanded = true;
    root.loading = false;
    if (!result.error) {
      root.children = result.entries.map((e: FileEntry) => {
        return FileTreeModel.entryToNode(e, cwd, 1);
      });
    } else {
      root.error = result.error;
      root.children = [];
    }
    return root;
  }

  /**
   * 收集所有 expanded===true 的目录节点路径（用于轮询刷新）
   */
  static collectExpandedPaths(root: FileTreeNode | null): string[] {
    const paths: string[] = [];
    FileTreeModel.collectExpanded(root, paths);
    return paths;
  }

  private static collectExpanded(node: FileTreeNode | null, out: string[]): void {
    if (!node || node.type !== 'directory') {
      return;
    }
    if (node.expanded && node.children !== null && !node.loading) {
      out.push(node.path);
    }
    if (node.children) {
      for (const child of node.children) {
        FileTreeModel.collectExpanded(child, out);
      }
    }
  }

  /**
   * 将服务端 FileEntry 转换为客户端 FileTreeNode
   */
  private static entryToNode(entry: FileEntry, parentPath: string, depth: number): FileTreeNode {
    const node: FileTreeNode = new FileTreeNode();
    node.name = entry.name;
    node.type = entry.type;
    node.path = FileTreeModel.joinPath(parentPath, entry.name);
    node.size = entry.size;
    node.mtime = entry.mtime;
    node.children = null;
    node.expanded = false;
    node.loading = false;
    node.error = '';
    node.depth = depth;
    return node;
  }

  /**
   * 路径拼接（处理根目录 / 的情况避免 //）
   */
  private static joinPath(parent: string, name: string): string {
    if (parent === '/') {
      return '/' + name;
    }
    return parent + '/' + name;
  }

  /**
   * 从完整路径提取最后一段（目录名/文件名）
   */
  private static baseName(path: string): string {
    const parts: string[] = path.split('/').filter((s: string) => s.length > 0);
    if (parts.length === 0) {
      return '/';
    }
    return parts[parts.length - 1];
  }
}
