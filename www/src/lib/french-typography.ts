/**
 * French typographic fixes, applied once to the French dictionary at load.
 *
 * Doing it here rather than in the source strings keeps `fr.ts` writable with
 * an ordinary keyboard, and keeps the two dictionaries looking like each other.
 *
 * Two rules:
 *  - a straight apostrophe between letters becomes a typographic one;
 *  - the space before `;` `!` `?` `»` and after `«` becomes a narrow no-break
 *    space, and the one before `:` a full no-break space, so the punctuation
 *    never starts a line on its own.
 */

const NARROW_NBSP = ' ';
const NBSP = ' ';

export function frenchTypography(text: string): string {
  return text
    .replace(/(\p{L})'(\p{L})/gu, '$1’$2')
    .replace(/ :/g, `${NBSP}:`)
    .replace(/ ([;!?»])/g, `${NARROW_NBSP}$1`)
    .replace(/« /g, `«${NARROW_NBSP}`);
}

/** Keys whose values are shell snippets, identifiers or URLs. Reflowing those
 *  would corrupt a command the reader is meant to paste. */
function isVerbatimKey(key: string): boolean {
  return key === 'code' || key === 'href' || key === 'lang' || key.endsWith('Code');
}

export function applyFrenchTypography<T>(value: T, key = ''): T {
  if (typeof value === 'string') {
    return (isVerbatimKey(key) ? value : frenchTypography(value)) as T;
  }
  if (Array.isArray(value)) {
    return value.map((item) => applyFrenchTypography(item, key)) as T;
  }
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) out[k] = applyFrenchTypography(v, k);
    return out as T;
  }
  return value;
}
