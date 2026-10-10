import { readFileSync } from 'node:fs';
import type { Plugin } from 'vite';
import { parse } from 'yaml';

const query = '?metadata';
const prefix = '\0rivet-page-metadata:';
const suffix = '.js';

/** Parse metadata without importing a page's component or example code. */
export function frontmatter(source: string): Record<string, unknown> {
	const block = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(source)?.[1];
	if (!block) return {};
	const metadata: unknown = parse(block);
	if (typeof metadata !== 'object' || metadata === null || Array.isArray(metadata)) {
		throw new Error('Documentation frontmatter must be a YAML mapping.');
	}
	return metadata as Record<string, unknown>;
}

/** Keep eager navigation metadata separate from lazily loaded .svx pages. */
export function pageMetadata(): Plugin {
	return {
		name: 'rivet-page-metadata',
		enforce: 'pre',
		async resolveId(id, importer) {
			if (!id.endsWith(`.svx${query}`)) return null;
			const resolved = await this.resolve(id.slice(0, -query.length), importer, { skipSelf: true });
			return resolved ? prefix + resolved.id + suffix : null;
		},
		load(id) {
			if (!id.startsWith(prefix)) return null;
			const file = id.slice(prefix.length, -suffix.length);
			this.addWatchFile(file);
			return `export default ${JSON.stringify(frontmatter(readFileSync(file, 'utf8')))};`;
		},
		handleHotUpdate({ file, modules, server }) {
			if (!file.endsWith('.svx')) return;
			const metadata = server.moduleGraph.getModuleById(prefix + file + suffix);
			return metadata ? [...modules, metadata] : undefined;
		}
	};
}
