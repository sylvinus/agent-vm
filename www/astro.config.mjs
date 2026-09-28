// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Custom domain (public/CNAME) means the site is served from the root, so no
// `base`. If this ever moves to a project page, set base: '/agent-vm'.
export default defineConfig({
  site: 'https://www.agent-vm.org',
  trailingSlash: 'always',
  i18n: {
    locales: ['en', 'fr'],
    defaultLocale: 'en',
    routing: {
      // English stays at /, French at /fr/.
      prefixDefaultLocale: false,
    },
  },
  integrations: [
    sitemap({
      i18n: {
        defaultLocale: 'en',
        locales: { en: 'en', fr: 'fr' },
      },
    }),
  ],
  build: {
    inlineStylesheets: 'auto',
  },
});
