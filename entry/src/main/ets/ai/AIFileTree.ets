import { FileTreeNode } from './AITypes';

/**
 * 文件树数据构造器
 *
 * 从 Glob 工具返回的扁平路径列表（如 ["src/auth/service.ts", "src/auth/login.ts"]），
 * 构造嵌套的 FileTreeNode[] 树形结构，供 WebView filetree.js 渲染。
 */
export class AIFileTreeBuilder {
  /**
   * 从路径字符串数组构造文件树
   */
  static build(paths: string[]): FileTreeNode[] {
    const root: FileTreeNode = { name: '', type: 'directory', children: [] };

    for (const path of paths) {
      const trimmed: string = path.trim();
      if (trimmed.length === 0) {
        continue;
      }
      const parts: string[] = trimmed.split('/').filter((s: string) => s.length > 0);
      if (parts.length === 0) {
        continue;
      }
      let current: FileTreeNode = root;
      for (let i: number = 0; i < parts.length; i++) {
        const isFile: boolean = i === parts.length - 1;
        let child: FileTreeNode | undefined = current.children?.find(
          (c: FileTreeNode) => c.name === parts[i]
        );
        if (!child) {
          child = {
            name: parts[i],
            type: isFile ? 'file' : 'directory',
            path: isFile ? trimmed : undefined,
            children: isFile ? undefined : []
          };
          if (!current.children) {
            current.children = [];
          }
          current.children.push(child);
        }
        current = child;
      }
    }

    return root.children || [];
  }

  /**
   * 从 Glob 工具的输出文本构造文件树
   * Glob 输出是多行文本，每行一个路径
   */
  static buildFromOutput(globOutput: string): FileTreeNode[] {
    const lines: string[] = globOutput.split('\n');
    return AIFileTreeBuilder.build(lines);
  }

  /**
   * 将 FileTreeNode[] 序列化为 JSON 字符串，供 postEvent 注入
   */
  static toJSON(tree: FileTreeNode[]): string {
    return JSON.stringify(tree);
  }
}
