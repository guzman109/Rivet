# Release and deployment

The current version is `0.1.0-dev`. Publishing the source repository does not create a versioned release or deploy the website. Rivet.nvim's code is MIT licensed, copyright 2026 Carlos Guzman; bundled license templates and website font/theme notices retain their upstream terms.

## Source publication

The repository is [guzman109/Rivet](https://github.com/guzman109/Rivet). CI checks Lua, the Neovim UI, licenses, Outset migration, generated C/C++ projects on Linux, and the Bun website in Wrangler's local runtime. GPU SDK/runtime tests remain local opt-in checks; CI does not certify a CUDA, Vulkan, Metal, WebGPU, or OpenGL device.

The plugin requires Neovim 0.11+. The optional CLI is `bin/rivet`, a relocatable shell launcher for portable Lua; it needs Lua 5.1+ or LuaJIT. It is **not a compiled standalone executable**. Do not label the source archive as an architecture-specific binary download.

## Before tagging a release

1. Run the unit tests under Lua and LuaJIT, `tests/licenses.lua`, `tests/migration.lua`, and all `tests/nvim*.lua` scripts.
2. Run `tests/integration.lua` with the documented CMake/compiler combination. Run `tests/batches.lua` for installed native tools and available graphics SDKs; record skipped cases rather than describing them as passed.
3. Run `bun install --frozen-lockfile`, `bun run verify`, and `bun run cf:check` in `docs/`.
4. Update `lua/rivet/version.lua` and document the version's changes and known platform limitations. Inspect the complete staged source and CI result before making a version tag.
5. Create a source archive with `python3 scripts/package-release.py`. It includes tracked source files and produces a SHA-256 checksum under ignored `dist/`. Extract it in a fresh directory and test `bin/rivet --version`, project creation, and loading the plugin before uploading it as a release asset.

The archive builder uses tracked files, including staged files; it is a packaging tool, not a substitute for committing and reviewing a release. It excludes local dependency caches because those paths are not tracked.

## Website deployment

The site remains SvelteKit, TypeScript, and mdsvex with the static adapter. Bun provides local development and builds. Wrangler serves and deploys the prerendered files as Cloudflare Worker static assets. The configuration uses Worker name `rivet-docs`; it has no account ID, token, or custom domain committed.

Authenticate with `bun x --no-install wrangler login` from `docs/`, verify the intended account, then run `bun run deploy`. Choose the production hostname separately; no Keen Eyes domain is assumed. See [docs/README.md](docs/README.md) for local preview, dry-run, and CI secret configuration. A GitHub push only runs checks; it does not deploy to Cloudflare.
