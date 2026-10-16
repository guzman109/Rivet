# Release and deployment

The current version is `0.1.2`. Publishing the source repository does not create a versioned release or deploy the website. Rivet.nvim's code is MIT licensed, copyright 2026 Carlos Guzman; bundled license templates and website font/theme notices retain their upstream terms.

## Source publication

The repository is [guzman109/Rivet](https://github.com/guzman109/Rivet). CI checks formatting (StyLua), annotations (lua-language-server), Lua, the Neovim UI and help file, licenses, Outset migration, generated C/C++ projects on Linux and macOS, and the Bun website in Wrangler's local runtime. GPU SDK/runtime tests remain local opt-in checks; CI does not certify a CUDA, Vulkan, Metal, WebGPU, or OpenGL device.

The plugin requires Neovim 0.11+. The optional CLI is `bin/rivet`, a relocatable shell launcher for portable Lua; it needs Lua 5.1+ or LuaJIT. It is **not a compiled standalone executable**. Do not label the source archive as an architecture-specific binary download.

## Before tagging a release

1. Run the unit tests and feature suites listed in README.md under Lua and LuaJIT, `tests/licenses.lua`, `tests/migration.lua`, all `tests/nvim*.lua` scripts, `stylua --check lua tests bin plugin`, and `lua-language-server --check .` (see the README for `VIMRUNTIME`).
2. Run `tests/integration.lua` with the documented CMake/compiler combination. Run `tests/batches.lua` for installed native tools and available graphics SDKs; record skipped cases rather than describing them as passed.
3. Run `bun install --frozen-lockfile`, `bun run verify`, and `bun run cf:check` in `docs/`.
4. Update `lua/rivet/version.lua`, add a dated entry to `CHANGELOG.md`, and document the version's changes and known platform limitations. Inspect the complete staged source and CI result before making a version tag.
5. Create a source archive with `python3 scripts/package-release.py`. It includes tracked source files and produces a SHA-256 checksum under ignored `dist/`. Extract it in a fresh directory and test `bin/rivet --version`, project creation, and loading the plugin before uploading it as a release asset.

The archive builder uses tracked files, including staged files; it is a packaging tool, not a substitute for committing and reviewing a release. It excludes local dependency caches because those paths are not tracked.

## Compatibility schedule

The Outset rename shims are deprecated and print a notice when used. Remove them in **0.3.0**:

- `bin/outset` and its `OUTSET_LUA` fallback
- `lua/outset.lua` (`require('outset')`)

`rivet migrate` / `:RivetMigrate` and reading `.outset.json` for migration stay until no supported release can produce an Outset project; they convert projects rather than keeping old names working. When removing a shim, delete its test in `tests/migration.lua` and the matching notes in `docs/src/content/cli.svx` and `neovim.svx`.

## Website deployment

The site remains SvelteKit, TypeScript, and mdsvex with the static adapter. Bun provides local development and builds. Wrangler serves and deploys the prerendered files as Cloudflare Worker static assets. The configuration uses Worker name `rivet-docs`; it has no account ID, token, or custom domain committed.

Cloudflare Workers Builds publishes the documentation through the existing repository connection. Keep that connection enabled. GitHub Actions runs formatting, types, Linux, macOS, and documentation checks only; it does not deploy or require Cloudflare secrets. Actions → Checks → Run workflow can also run these checks manually.

For a local deployment, authenticate with `bun x --no-install wrangler login` from `docs/`, verify the intended account and Worker name, then run `bun run deploy`. See [docs/README.md](docs/README.md) for deployment setup.

## Publish with GitHub CLI

Plugin managers use the Git tag, not the uploaded archive. Use an immutable semantic-version tag such as `v0.1.2`, matching `lua/rivet/version.lua`. The GitHub release adds changelog notes and optional source/checksum downloads. Users install through `vim.pack` or lazy.nvim; they do not need a manual checkout.

After committing and merging the verified release changes, confirm GitHub CI passes for that exact `main` commit. Push the annotated tag, then create a draft with the verified archive and notes:

```sh
git tag -a v0.1.2 -m 'Rivet.nvim 0.1.2'
git push origin v0.1.2
gh release create v0.1.2 \
  dist/rivet.nvim-0.1.2.tar.gz \
  dist/rivet.nvim-0.1.2.tar.gz.sha256 \
  --verify-tag --title 'Rivet.nvim 0.1.2' \
  --notes-file /path/to/release-notes.md --draft
```

Inspect the draft assets and notes, then publish:

```sh
gh release edit v0.1.2 --draft=false --latest
```

For a release candidate, use a prerelease version such as `0.1.2-rc.1` consistently in the version file and tag, and pass `--prerelease` when creating it. Do not move a published release tag. Fixes belong in a new patch version.

Document minimum Neovim versions, language-tool requirements, known limits, and how to update existing projects. No separate marketplace registration or compiled plugin asset is needed. Neovim 0.12+ `vim.pack` users can select `vim.version.range('0.1.x')`; lazy.nvim accepts `version = '0.1.x'`. A branch choice of `main` follows development commits rather than tagged releases.
