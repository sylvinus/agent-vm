# www.agent-vm.org

The agent-vm website. One page, two languages, no runtime: Astro builds it to
static HTML and GitHub Pages serves it.

## Run it

```bash
npm install
npm run dev      # http://localhost:4321
npm run build    # -> dist/
npm run preview  # serve dist/ locally
```

## Where the content lives

All copy is in `src/i18n/`. `en.ts` is the source of truth for the shape;
`fr.ts` is typed against it, so a missing or renamed key fails the build rather
than falling back to English silently. Shell snippets are not translated.

French strings are written with plain apostrophes and ordinary spaces.
`src/lib/french-typography.ts` converts them at load: apostrophes become
typographic, and the space before `;` `!` `?` `»` and `:` becomes a no-break
one. Keys named `code`, `href`, `lang` or ending in `Code` are left alone, so a
command stays pasteable.

Adding a section means adding a key in both dictionaries, a component in
`src/components/`, an entry in `Landing.astro`, and a link in `Nav.astro`.

## Adding a language

1. Add the code to `locales` in `astro.config.mjs` and to `LOCALES` in
   `src/i18n/index.ts`.
2. Copy `fr.ts`, translate, register it in the `dictionaries` map.
3. Add `src/pages/<code>/index.astro`, two lines like the French one.

English is served from `/` (`prefixDefaultLocale: false`), every other language
from `/<code>/`.

## The installer

`public/install.sh` is served as-is at `/install.sh`, for
`curl -fsSL https://www.agent-vm.org/install.sh | sh`. It is plain `sh`, not
bash. Its tests are in `../tests/17-curl-installer.sh`, and CI runs `sh -n` on it. A change goes
live with the next deploy of the site, not with a release.

## Social image

`public/og.png` is committed. Regenerate it after changing the wording:

```bash
npm run og
```

That needs `sharp` (a devDependency) and a font on the machine. The deploy does
not: it only reads the committed PNG.

## Deploying

`.github/workflows/www.yml` builds on every push to `main` that touches `www/`
and publishes to GitHub Pages. A pull request builds but does not publish.

Two things have to be set once in the repository settings:

- **Settings → Pages → Source: GitHub Actions.**
- **Settings → Pages → Custom domain: `www.agent-vm.org`**, with a `CNAME`
  record at the DNS provider pointing `www` to `sylvinus.github.io`. Tick
  *Enforce HTTPS* once the certificate is issued.

`public/CNAME` carries the domain into every build; the workflow fails if it
goes missing, because losing it silently reverts the site to the `github.io`
URL.
