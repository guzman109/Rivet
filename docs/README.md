# Rivet documentation site

Contributor guide for the SvelteKit/mdsvex site. User documentation lives in
`src/content/`; routes, navigation, and search live in `src/routes/` and `src/lib/`.
Exact tool versions are pinned in `package.json` and `bun.lock`. CI uses Bun 1.4.2
and Node.js 24.

## Develop locally

Run from this `docs/` directory:

```sh
bun install --frozen-lockfile
bun run dev
```

Open the URL printed by Vite. For the built site in Cloudflare's local runtime,
run `bun run preview` and open `http://127.0.0.1:8787`.

`vite.config.ts` configures SvelteKit, mdsvex, and the static adapter. Builds go to
`build/`. Generated output, dependencies, and local Wrangler state are ignored
by Git.

## Write or edit a page

Add an `.svx` file in `src/content/` with frontmatter:

```yaml
---
title: Page title
description: The specific outcome or information this page provides.
section: How-to guides
order: 20
updated: '2026-10-14'
---
```

Use one of `Start here`, `Tutorials`, `How-to guides`, `Reference`, or
`Explanation`. Give each page a unique positive `order` within its section.
The filename becomes `/docs/<filename>/`; keep published filenames stable.
Navigation and previous/next links use section order, then page order.

Choose a page's purpose before writing, following
[Diátaxis](https://diataxis.fr/start-here/):

- **Start here** orients readers and links them to installation and first projects.
- **Tutorials** teach through one complete example. Include prerequisites,
  fixed choices, steps, and observable results. Link to optional topics.
- **How-to guides** solve a specific task. State the starting conditions, give
  the procedure, and show how to check its result.
- **Reference** describes commands, fields, defaults, constraints, and outputs.
  Use consistent tables and examples; link to procedures rather than repeating them.
- **Explanation** develops the reasons behind behavior and design choices.
  Keep detailed command syntax in reference pages.

Keep each page focused on that purpose. Remove repeated background, unrelated
features, and historical test claims without traceable results. Verify Rivet
commands, defaults, and examples against `../lua/rivet/`, `../bin/`, and the
relevant `../tests/` files. Check external tool claims against primary upstream
documentation. Distinguish a test's existence from a recorded passing run.

The layout supplies the page title; start body headings at `##`. Use descriptive
headings and link labels, language-tagged code fences, and alt text for images.
Internal page links use `/docs/<filename>/`. Heading IDs come from `rehype-slug`;
`github-slugger` generates matching table-of-contents links. Svelte expressions
in prose need escaping or code formatting.

Update `updated` when changing content. Run the checks below after editing;
changing headings can break incoming fragment links.

## Validate changes

```sh
bun run verify
bun run cf:check
```

`verify` runs the following in order:

| Check             | Purpose                                                                          |
| ----------------- | -------------------------------------------------------------------------------- |
| `check`           | SvelteKit type generation and Svelte/TypeScript diagnostics; warnings fail       |
| `lint`            | Prettier formatting                                                              |
| `test:highlight`  | Source-character preservation in highlighted code                                |
| `build`           | Prerender the site into `build/`                                                 |
| `check:docs`      | Metadata, documented Rivet commands/options, links, code fences, and navigation  |
| `test:cloudflare` | Local routes, redirects, 404s, asset types, caching, fonts, and license delivery |

`cf:check` rebuilds and runs a Wrangler deployment dry run. It does not publish.
For a content-only check before building, run
`bun scripts/validate-docs.ts --source-only`.

`bun run format` formats site code and tooling. `.svx` files are excluded to
preserve authored examples. Read and exercise those examples separately:
metadata and link checks cannot establish their technical accuracy.

## Refresh editor screenshots

From the repository root:

```sh
python3 docs/scripts/capture-neovim.py
```

The script uses Neovim's UI grid for the wizard and review panels, then builds a
temporary C++17 CPU starter to capture CTest output. It needs Neovim, Lua, CMake,
Ninja, a compatible C++ compiler, Pillow, and msgpack. Set `RIVET_CAPTURE_FONT`
to a monospace font path if macOS Menlo is unavailable. `RIVET_CAPTURE_LIBS` can
supply a Python dependency directory. Images are written to `static/images/`.

The site bundles Space Grotesk, Space Mono, and Catppuccin color definitions;
retain their notices in `static/licenses/`.

## Deploy to Cloudflare

`wrangler.jsonc` configures the `rivet-docs` Worker to serve `build/` as static
assets, with trailing-slash URLs and a custom 404 page. Response headers live in
`static/_headers`. Only the build output is uploaded. The configuration targets
the domain root; a subdirectory needs coordinated base-path and link changes.

For manual deployment from `docs/`:

```sh
bun run cf:check
bun x --no-install wrangler login
bun run deploy
```

Select the intended Cloudflare account. `deploy` runs verification before
uploading. A custom domain can be attached after deployment; the Worker can also
use its `workers.dev` address. For authentication details, see
[Cloudflare's deployment guide](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/).

### Cloudflare repository deployment

Cloudflare Workers Builds handles automatic deployment through the existing
GitHub repository connection. Keep that connection enabled; pushes to the
configured production branch trigger Cloudflare's build and deployment.

The repository's [Checks workflow](../.github/workflows/ci.yml) runs formatting,
types, Linux, macOS, and documentation checks only. It does not publish the site
or require Cloudflare repository secrets. **Actions → Checks → Run workflow**
runs these checks manually. Cloudflare builds run independently of GitHub checks.

See [Cloudflare Workers Builds](https://developers.cloudflare.com/workers/ci-cd/builds/)
for connected-repository settings.

## Update dependencies

Edit the exact versions in `package.json`, run `bun install`, and review both
`package.json` and `bun.lock`. Run `bun run verify` and `bun run cf:check` before
committing. Use `bun install --frozen-lockfile` for routine installs so the
committed dependency graph remains unchanged.
