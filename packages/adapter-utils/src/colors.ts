// Terminal colors for the CLI and the adapters' event formatters.
//
// This replaces the `picocolors` dependency with the eleven styles the tree
// uses. Color detection matches picocolors, so output is unchanged: off under
// NO_COLOR or --no-color; on under FORCE_COLOR, --color, Windows, CI, or a TTY
// stdout whose TERM is not "dumb".

type Style = (input: unknown) => string;

function detectColorSupport(): boolean {
  const env = process.env;
  const argv = process.argv;
  if ("NO_COLOR" in env || argv.includes("--no-color")) return false;
  return (
    "FORCE_COLOR" in env ||
    argv.includes("--color") ||
    process.platform === "win32" ||
    (process.stdout?.isTTY === true && env.TERM !== "dumb") ||
    "CI" in env
  );
}

// A style nested inside another closes with a code that would also end the
// outer one, so each inner close is replaced by close + reopen of the outer
// style, as picocolors does.
function formatter(open: string, close: string, replace = open): Style {
  return (input) => {
    const text = String(input);
    let index = text.indexOf(close, open.length);
    if (index === -1) return open + text + close;
    let result = "";
    let cursor = 0;
    do {
      result += text.substring(cursor, index) + replace;
      cursor = index + close.length;
      index = text.indexOf(close, cursor);
    } while (index !== -1);
    return open + result + text.substring(cursor) + close;
  };
}

export function createColors(enabled: boolean = detectColorSupport()) {
  const f = (open: string, close: string, replace?: string): Style =>
    enabled ? formatter(open, close, replace) : (input) => String(input);
  return {
    isColorSupported: enabled,
    bold: f("\x1b[1m", "\x1b[22m", "\x1b[22m\x1b[1m"),
    dim: f("\x1b[2m", "\x1b[22m", "\x1b[22m\x1b[2m"),
    black: f("\x1b[30m", "\x1b[39m"),
    red: f("\x1b[31m", "\x1b[39m"),
    green: f("\x1b[32m", "\x1b[39m"),
    yellow: f("\x1b[33m", "\x1b[39m"),
    blue: f("\x1b[34m", "\x1b[39m"),
    cyan: f("\x1b[36m", "\x1b[39m"),
    white: f("\x1b[37m", "\x1b[39m"),
    gray: f("\x1b[90m", "\x1b[39m"),
    bgCyan: f("\x1b[46m", "\x1b[49m"),
  };
}

export const pc = createColors();
export default pc;
