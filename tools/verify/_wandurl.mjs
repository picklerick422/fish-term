// Kept byte-for-byte equivalent to entry/src/main/ets/transport/WandUrl.ets
export function buildWandUrl(config, cols, rows) {
  const scheme = config.tls ? 'wss' : 'ws';
  const params = [];
  params.push('token=' + encodeURIComponent(config.token));
  params.push('cols=' + cols);
  params.push('rows=' + rows);
  if (config.cwd && config.cwd.length > 0) {
    params.push('cwd=' + encodeURIComponent(config.cwd));
  }
  if (config.shell && config.shell.length > 0) {
    params.push('shell=' + encodeURIComponent(config.shell));
  }
  return scheme + '://' + config.host + ':' + config.port + '/ws?' + params.join('&');
}
