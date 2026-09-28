/**
 * A small shell highlighter.
 *
 * Every snippet on this site is a shell command or an env file, so a full
 * grammar (and the dual-theme CSS a Shiki setup would need) buys nothing. This
 * handles comments, quoted strings, variables, flags and the leading command,
 * which is the whole visual vocabulary the page uses.
 *
 * The scanner walks raw text and escapes at render time, so a quote inside the
 * source is still a quote to the tokeniser rather than an `&quot;`.
 */

export type TokenKind =
  | 'plain'
  | 'command'
  | 'flag'
  | 'string'
  | 'variable'
  | 'comment';

export interface Token {
  kind: TokenKind;
  text: string;
}

const WORD_CHARS = /[A-Za-z0-9_./~@+:-]/;
const IDENT_START = /[A-Za-z_]/;
const IDENT = /[A-Za-z0-9_]/;

/** True when `#` at this index starts a comment rather than sitting inside a
 *  word (a fragment id, a colour). Shell only treats it as a comment at the
 *  start of a word. */
function startsComment(line: string, i: number): boolean {
  return i === 0 || /\s/.test(line[i - 1]!);
}

function tokenizeLine(line: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  // The first bare word on a line is the command being run. `ENV=value cmd`
  // and a continuation line are rare enough here not to matter.
  let seenWord = false;

  const push = (kind: TokenKind, text: string) => {
    if (text === '') return;
    const last = tokens[tokens.length - 1];
    if (last && last.kind === kind) last.text += text;
    else tokens.push({ kind, text });
  };

  while (i < line.length) {
    const ch = line[i]!;

    if (ch === '#' && startsComment(line, i)) {
      push('comment', line.slice(i));
      break;
    }

    if (ch === '"' || ch === "'") {
      const quote = ch;
      let j = i + 1;
      while (j < line.length) {
        if (line[j] === '\\' && quote === '"') j += 2;
        else if (line[j] === quote) {
          j += 1;
          break;
        } else j += 1;
      }
      push('string', line.slice(i, j));
      i = j;
      continue;
    }

    if (ch === '$' && i + 1 < line.length) {
      const next = line[i + 1]!;
      if (next === '(') {
        let depth = 0;
        let j = i + 1;
        while (j < line.length) {
          if (line[j] === '(') depth += 1;
          else if (line[j] === ')') {
            depth -= 1;
            if (depth === 0) {
              j += 1;
              break;
            }
          }
          j += 1;
        }
        push('variable', line.slice(i, j));
        i = j;
        continue;
      }
      if (next === '{') {
        const close = line.indexOf('}', i);
        const j = close === -1 ? line.length : close + 1;
        push('variable', line.slice(i, j));
        i = j;
        continue;
      }
      if (IDENT_START.test(next)) {
        let j = i + 1;
        while (j < line.length && IDENT.test(line[j]!)) j += 1;
        push('variable', line.slice(i, j));
        i = j;
        continue;
      }
    }

    if (ch === '-' && (i === 0 || /\s/.test(line[i - 1]!)) && i + 1 < line.length) {
      let j = i;
      while (j < line.length && (line[j] === '-' || WORD_CHARS.test(line[j]!))) j += 1;
      push('flag', line.slice(i, j));
      i = j;
      continue;
    }

    if (WORD_CHARS.test(ch)) {
      let j = i;
      while (j < line.length && WORD_CHARS.test(line[j]!)) j += 1;
      // The first word is the command, or the key of a `KEY=value` env line.
      // Both are what the eye should land on first.
      push(seenWord ? 'plain' : 'command', line.slice(i, j));
      seenWord = true;
      i = j;
      continue;
    }

    push('plain', ch);
    i += 1;
  }

  return tokens;
}

export function highlightShell(code: string): Token[][] {
  return code.replace(/\n+$/, '').split('\n').map(tokenizeLine);
}
