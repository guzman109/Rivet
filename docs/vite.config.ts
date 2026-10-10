import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';
import { mdsvex } from 'mdsvex';
import rehypeSlug from 'rehype-slug';
import { defineConfig } from 'vite';
import { pageMetadata } from './scripts/metadata.ts';
import { highlightCode } from './scripts/highlight.ts';

export default defineConfig({
	plugins: [
		pageMetadata(),
		sveltekit({
			extensions: ['.svelte', '.svx'],
			preprocess: [
				vitePreprocess(),
				mdsvex({
					extensions: ['.svx'],
					rehypePlugins: [rehypeSlug],
					highlight: { highlighter: highlightCode }
				})
			],
			adapter: adapter({ pages: 'build', assets: 'build', strict: true }),
			compilerOptions: {
				// mdsvex 0.12 emits legacy module-script syntax for frontmatter exports.
				warningFilter: (warning) =>
					!(warning.code === 'script_context_deprecated' && warning.filename?.endsWith('.svx'))
			},
			paths: { relative: false },
			prerender: {
				entries: ['*'],
				handleHttpError: 'fail',
				handleMissingId: 'fail'
			}
		})
	]
});
