import { en, type Dictionary } from './en';
import { fr } from './fr';
import { applyFrenchTypography } from '../lib/french-typography';

export const LOCALES = ['en', 'fr'] as const;
export type Locale = (typeof LOCALES)[number];
export const DEFAULT_LOCALE: Locale = 'en';

// Done once at module load rather than per render: the French copy is written
// with plain apostrophes and ordinary spaces, and reaches the page with the
// right characters.
const dictionaries: Record<Locale, Dictionary> = {
  en,
  fr: applyFrenchTypography(fr),
};

export function isLocale(value: string | undefined): value is Locale {
  return value !== undefined && (LOCALES as readonly string[]).includes(value);
}

/** Dictionary for a locale. Falls back to the default rather than throwing:
 *  an unknown locale can only come from a URL, and a 404 is the router's job. */
export function t(locale: string | undefined): Dictionary {
  return isLocale(locale) ? dictionaries[locale] : dictionaries[DEFAULT_LOCALE];
}

/** Root-relative path for a locale. English is unprefixed (prefixDefaultLocale
 *  is false), French lives under /fr/. */
export function localeHref(locale: Locale): string {
  return locale === DEFAULT_LOCALE ? '/' : `/${locale}/`;
}

/** The other locales, for the language switcher. */
export function otherLocales(current: Locale): Locale[] {
  return LOCALES.filter((l) => l !== current);
}

export type { Dictionary };
