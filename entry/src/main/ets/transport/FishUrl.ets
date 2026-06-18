import { FishConnectConfig } from './TerminalDriver';

// Builds the fish-agent WebSocket URL. The server reads token/cols/rows/cwd/shell
// from the query string and returns HTTP 401 on token mismatch.
export function buildFishUrl(config: FishConnectConfig, cols: number, rows: number): string {
  const scheme: string = config.tls ? 'wss' : 'ws';
  const params: string[] = [];
  params.push('token=' + encodeURIComponent(config.token));
  params.push('cols=' + cols);
  params.push('rows=' + rows);
  if (config.cwd && config.cwd.length > 0) {
    params.push('cwd=' + encodeURIComponent(config.cwd));
  }
  if (config.shell && config.shell.length > 0) {
    params.push('shell=' + encodeURIComponent(config.shell));
  }
  return `${scheme}://${config.host}:${config.port}/ws?${params.join('&')}`;
}
