/**
 * A heading's anchor. Built from the English text by the callers, so a link
 * copied from /fr/ still works on /, and the other way round.
 */
export function slug(text: string): string {
  return text
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}
