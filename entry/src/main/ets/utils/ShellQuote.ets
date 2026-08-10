// Shell quoting for commands written to the remote PTY.
//
// Paths coming from the file tree are user-visible file names and may contain
// spaces, quotes, `$`, backticks, etc. Wrapping them in DOUBLE quotes is not
// enough — inside double quotes `$`, backticks and backslashes stay active, so
// a crafted file name can inject commands into mv/touch/mkdir/rm/cd/cat.
// Single quotes make every byte literal; an embedded single quote is emitted
// as the standard '\'' (close, escaped quote, reopen) sequence.

export function shellQuote(value: string): string {
  return "'" + value.replace(/'/g, "'\\''") + "'";
}
