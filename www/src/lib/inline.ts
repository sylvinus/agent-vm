const ESCAPES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
};

export function escapeHtml(text: string): string {
  return text.replace(/[&<>"]/g, (ch) => ESCAPES[ch]!);
}

/**
 * Turns `backticks` in the dictionary strings into <code> elements, and
 * [text](target) into links: to another site for an https URL, opened in a
 * new tab, or to a heading of this page for a #anchor.
 *
 * Everything is escaped first, so the only markup that survives is the one
 * this function emits. The input is our own copy, not user input, but escaping
 * is what makes that stay true when someone adds a `<` to a sentence. Any
 * other target is left as text.
 */
export function inline(text: string): string {
  return escapeHtml(text)
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\((https:\/\/[^)\s]+|#[a-z0-9-]+)\)/g, (_, label: string, target: string) =>
      target.startsWith('#')
        ? `<a href="${target}">${label}</a>`
        : `<a href="${target}" target="_blank" rel="noopener noreferrer">${label}</a>`,
    );
}
