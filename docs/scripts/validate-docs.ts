/** Offline content and prerender audit. Run after `bun run build`.
 * bun scripts/validate-docs.ts [--source-only] [--build=build] [--base=/prefix]
 */
import { readdir, readFile } from 'node:fs/promises';
const readTextFile = (path: URL) => readFile(path, 'utf8');

type Metadata = {
	title: string;
	description: string;
	section: string;
	order: number;
	updated: string;
};
type Document = { slug: string; metadata: Metadata; source: string };
type CodeFence = { language: string; text: string };
type Reference = { value: string; attribute: string; navigation: boolean };
type Page = {
	path: string;
	html: string;
	ids: Set<string>;
	references: Reference[];
};

const docsRoot = new URL('../', import.meta.url);
const errors: string[] = [];
const requiredSlugs = [
	'start-here',
	'getting-started',
	'neovim',
	'first-project',
	'comment-headers',
	'modules',
	'cmake',
	'templates',
	'dependencies',
	'styles-layouts',
	'cli',
	'troubleshooting',
	'extending'
];
let sourceOnly = false;
let buildDirectory = 'build';
let base = '';
const positional: string[] = [];
for (const arg of process.argv.slice(2)) {
	if (arg === '--source-only') sourceOnly = true;
	else if (arg.startsWith('--build=')) buildDirectory = arg.slice(8);
	else if (arg.startsWith('--base=')) base = arg.slice(7);
	else if (arg.startsWith('--')) throw new Error(`Unknown argument: ${arg}`);
	else positional.push(arg);
}
if (positional.length > 2) {
	throw new Error('Expected at most build directory and base path');
}
buildDirectory = positional[0] ?? buildDirectory;
base = (positional[1] ?? base).replace(/\/$/, '');
if (base && (!base.startsWith('/') || /[?#]|\/\//.test(base) || base.split('/').includes('..'))) {
	throw new Error('Base path must be empty or an absolute path such as /rivet');
}
const buildRoot = new URL(`${buildDirectory.replace(/\/$/, '')}/`, docsRoot);

function check(condition: unknown, message: string): void {
	if (!condition) errors.push(message);
}

function decodeEntities(value: string): string {
	const named: Record<string, string> = {
		amp: '&',
		lt: '<',
		gt: '>',
		quot: '"',
		apos: "'",
		nbsp: '\u00a0'
	};
	return value.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (entity, key: string) => {
		if (key.startsWith('#')) {
			const code =
				key[1].toLowerCase() === 'x'
					? Number.parseInt(key.slice(2), 16)
					: Number.parseInt(key.slice(1), 10);
			return Number.isFinite(code) && code >= 0 && code <= 0x10ffff
				? String.fromCodePoint(code)
				: entity;
		}
		return named[key] ?? entity;
	});
}

function textContent(html: string): string {
	return decodeEntities(html.replace(/<[^>]*>/g, ''))
		.replace(/\s+/g, ' ')
		.trim();
}

function codeFences(doc: Document): CodeFence[] {
	const fences: CodeFence[] = [];
	const opening = /^(`{3,}|~{3,})([^\r\n]*)\r?\n/gm;
	for (let start = opening.exec(doc.source); start; start = opening.exec(doc.source)) {
		const closing = new RegExp(`^${start[1][0]}{${start[1].length},}[ \\t]*\\r?$`, 'gm');
		closing.lastIndex = opening.lastIndex;
		const end = closing.exec(doc.source);
		check(end, `${doc.slug}: unclosed code fence ${fences.length + 1}`);
		if (!end) break;
		fences.push({
			language: start[2].trim().split(/\s/)[0],
			text: doc.source.slice(opening.lastIndex, end.index)
		});
		opening.lastIndex = closing.lastIndex;
	}
	return fences;
}

function renderedCode(html: string): string[] {
	// Preserve whitespace and escapes exactly. Decode only after removing markup,
	// so literal code such as "<span>" or "<!-- -->" remains part of the example.
	return Array.from(
		html.matchAll(/<pre\b[^>]*>[\s\S]*?<code\b[^>]*>([\s\S]*?)<\/code>[\s\S]*?<\/pre>/gi),
		(match) => decodeEntities(match[1].replace(/<!--[\s\S]*?-->/g, '').replace(/<[^>]*>/g, ''))
	);
}

function withoutFinalNewline(value: string): string {
	// Markdown renderers differ on whether to keep the final fence newline.
	// Do not trim any other whitespace, blank lines, or line-continuation escapes.
	return value.replace(/\n$/, '');
}

function codeDifference(expected: string, actual: string): string {
	let offset = 0;
	while (offset < Math.min(expected.length, actual.length) && expected[offset] === actual[offset])
		offset++;
	const contextStart = Math.max(0, offset - 20);
	return `at character ${offset}: expected ${JSON.stringify(
		expected.slice(contextStart, offset + 60)
	)}, received ${JSON.stringify(actual.slice(contextStart, offset + 60))}`;
}

function attributes(tag: string): Map<string, string> {
	const values = new Map<string, string>();
	for (const match of tag.matchAll(/\s([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g)) {
		values.set(match[1].toLowerCase(), decodeEntities(match[2] ?? match[3] ?? match[4]));
	}
	return values;
}

function scalar(value: string): string {
	value = value.trim();
	if (value.startsWith('"') && value.endsWith('"')) {
		try {
			return JSON.parse(value);
		} catch {
			return value.slice(1, -1);
		}
	}
	if (value.startsWith("'") && value.endsWith("'")) {
		return value.slice(1, -1).replace(/''/g, "'");
	}
	return value;
}

function parseDocument(slug: string, source: string): Document | undefined {
	const frontmatter = source.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/);
	check(frontmatter, `${slug}: missing opening frontmatter`);
	if (!frontmatter) return;
	const raw: Record<string, string> = {};
	for (const line of frontmatter[1].split(/\r?\n/)) {
		if (!line.trim() || line.trim().startsWith('#')) continue;
		const pair = line.match(/^([a-zA-Z][\w-]*):\s*(.*?)\s*$/);
		check(pair, `${slug}: frontmatter must use simple key/value scalars: ${line}`);
		if (pair) {
			check(!(pair[1] in raw), `${slug}: duplicate metadata key ${pair[1]}`);
			raw[pair[1]] = scalar(pair[2]);
		}
	}
	for (const field of ['title', 'description', 'section']) {
		check(
			typeof raw[field] === 'string' && raw[field].trim().length > 0,
			`${slug}: missing ${field}`
		);
	}
	const order = Number(raw.order);
	check(Number.isSafeInteger(order) && order > 0, `${slug}: order must be a positive integer`);
	const date = raw.updated ?? '';
	check(
		/^\d{4}-\d{2}-\d{2}$/.test(date) &&
			!Number.isNaN(Date.parse(date)) &&
			new Date(date).toISOString().slice(0, 10) === date,
		`${slug}: updated must be a valid YYYY-MM-DD date`
	);
	const body = source.slice(frontmatter[0].length);
	const prose = body
		.replace(/^```[^\n]*\n[\s\S]*?^```\s*$/gm, '')
		.replace(/^~~~[^\n]*\n[\s\S]*?^~~~\s*$/gm, '');
	check(!/^#\s+/m.test(prose), `${slug}: content must not add an H1; the page supplies its title`);
	return {
		slug,
		metadata: {
			title: raw.title,
			description: raw.description,
			section: raw.section,
			order,
			updated: date
		},
		source: body
	};
}

async function filesUnder(directory: URL, prefix = ''): Promise<string[]> {
	const files: string[] = [];
	for (const entry of await readdir(directory, { withFileTypes: true })) {
		const path = `${prefix}${entry.name}`;
		if (entry.isDirectory()) {
			files.push(
				...(await filesUnder(new URL(`${encodeURIComponent(entry.name)}/`, directory), `${path}/`))
			);
		} else if (entry.isFile()) files.push(path);
	}
	return files;
}

function routeFor(path: string): string {
	if (path === 'index.html') return `${base}/`;
	if (path.endsWith('/index.html')) return `${base}/${path.slice(0, -10)}`;
	return `${base}/${path}`;
}

const contentRoot = new URL('src/content/', docsRoot);
const documents: Document[] = [];
try {
	for (const entry of await readdir(contentRoot, { withFileTypes: true })) {
		if (!entry.isFile() || !entry.name.endsWith('.svx')) continue;
		const slug = entry.name.slice(0, -4);
		check(/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug), `Invalid document slug: ${slug}`);
		const parsed = parseDocument(slug, await readTextFile(new URL(entry.name, contentRoot)));
		if (parsed) documents.push(parsed);
	}
} catch (error) {
	errors.push(`Cannot read content directory: ${error}`);
}
const slugs = new Set(documents.map((doc) => doc.slug));
for (const slug of requiredSlugs) {
	check(slugs.has(slug), `Required documentation page missing: ${slug}`);
}
const ordering = new Set<string>();
const sectionOrder = ['Start here', 'Guides', 'Reference'];
const readingOrder = [...documents].sort(
	(a, b) =>
		sectionOrder.indexOf(a.metadata.section) - sectionOrder.indexOf(b.metadata.section) ||
		a.metadata.order - b.metadata.order
);
for (const doc of documents) {
	const key = `${doc.metadata.section}:${doc.metadata.order}`;
	check(
		!ordering.has(key),
		`${doc.slug}: duplicate order ${doc.metadata.order} in ${doc.metadata.section}`
	);
	ordering.add(key);
}

// Verify documented Rivet options against the actual parser, without
// executing any examples or treating flags for CMake/clangd as Rivet flags.
try {
	const cli = await readTextFile(new URL('../lua/rivet/cli.lua', docsRoot));
	const allowedBlock = cli.match(/local allowed\s*=\s*\{([\s\S]*?)\n\s*\}/)?.[1] ?? '';
	const flags = new Set(
		Array.from(allowedBlock.matchAll(/([a-z_]+)\s*=\s*true/g), (match) =>
			match[1].replaceAll('_', '-')
		)
	);
	const commands = new Set(
		Array.from(cli.matchAll(/^rivet ([a-z][a-z-]*(?:\|[a-z][a-z-]*)*)/gm), (match) =>
			match[1].split('|')
		).flat()
	);
	commands.add('help');
	check(
		flags.size > 0 && commands.size > 0,
		'Could not extract Rivet CLI interface from implementation'
	);
	const editor = await readTextFile(new URL('../lua/rivet/init.lua', docsRoot));
	const editorCommands = new Set(
		Array.from(
			editor.matchAll(/nvim_create_user_command\(\s*['"]([^'"]+)['"]/g),
			(match) => match[1]
		)
	);
	// Command table rows: { ':Rivet subcommand', ':RivetX command', function, description }
	const subcommands = new Set(['task']);
	for (const row of editor.matchAll(/\{\s*'([a-z][a-z-]*)',\s*'(Rivet\w+)'/g)) {
		subcommands.add(row[1]);
		editorCommands.add(row[2]);
	}
	check(editorCommands.size > 1, 'Could not extract Neovim commands from implementation');
	for (const doc of documents) {
		for (const command of doc.source.matchAll(/:Rivet ([a-z][a-z-]*)\b/g)) {
			check(subcommands.has(command[1]), `${doc.slug}: unknown :Rivet subcommand ${command[1]}`);
		}
	}
	for (const doc of documents) {
		for (const command of doc.source.matchAll(/:(Rivet[A-Za-z]+)\b/g)) {
			check(editorCommands.has(command[1]), `${doc.slug}: unknown Neovim command :${command[1]}`);
		}
		if (doc.slug === 'cli') {
			for (const option of doc.source.matchAll(/--([a-z][a-z0-9-]*)\b/g)) {
				check(flags.has(option[1]), `${doc.slug}: unknown Rivet flag --${option[1]}`);
			}
		}
		for (const block of doc.source.matchAll(
			/^```(?:sh|bash|shell|console)?\s*\n([\s\S]*?)^```\s*$/gm
		)) {
			const logicalLines = block[1].replace(/\\\s*\n\s*/g, ' ').split('\n');
			for (const line of logicalLines) {
				if (line.trim().startsWith('#')) continue;
				const command = line.match(/(?:^|\s)(?:\S*\/)?rivet(?:\.lua)?\s+([a-z][a-z-]*)\b/);
				if (!command) continue;
				check(commands.has(command[1]), `${doc.slug}: unknown Rivet command ${command[1]}`);
				for (const option of line.matchAll(/--([a-z][a-z0-9-]*)\b/g)) {
					check(flags.has(option[1]), `${doc.slug}: unknown Rivet flag --${option[1]}`);
				}
			}
		}
	}
} catch (error) {
	errors.push(`Cannot validate CLI examples: ${error}`);
}

let pageCount = 0;
let referenceCount = 0;
let codeFenceCount = 0;
if (!sourceOnly) {
	try {
		const paths = await filesUnder(buildRoot);
		const fileSet = new Set(paths);
		const pages = new Map<string, Page>();
		for (const path of paths.filter((path) => path.endsWith('.html'))) {
			const html = await readTextFile(new URL(path, buildRoot));
			const visible = html.replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, '<script></script>');
			const ids = new Set<string>();
			for (const tag of visible.matchAll(/<[a-z][^>]*>/gi)) {
				const id = attributes(tag[0]).get('id');
				if (id !== undefined) {
					check(!ids.has(id), `${path}: duplicate element id ${id}`);
					ids.add(id);
				}
			}
			const references: Reference[] = [];
			// Extract script/link attributes from the original document, but ignore
			// script bodies so code strings cannot masquerade as navigation links.
			const tags = html.replace(/(<script\b[^>]*>)[\s\S]*?<\/script\s*>/gi, '$1</script>');
			for (const match of tags.matchAll(
				/<(a|link|script|img|source|video|audio|iframe)\b[^>]*>/gi
			)) {
				const attrs = attributes(match[0]);
				for (const attribute of ['href', 'src', 'poster']) {
					const value = attrs.get(attribute);
					if (value !== undefined) {
						references.push({
							value,
							attribute,
							navigation: match[1].toLowerCase() === 'a' && attribute === 'href'
						});
					}
				}
			}
			check(
				/<html\b[^>]*\blang=["']en["']/i.test(html),
				`${path}: HTML document is missing lang="en"`
			);
			check(/<title>[^<]+<\/title>/i.test(html), `${path}: HTML document is missing a title`);
			if (!path.endsWith('404.html')) {
				check(
					Array.from(visible.matchAll(/<h1\b/gi)).length === 1,
					`${path}: expected exactly one H1`
				);
			}
			pages.set(routeFor(path), { path, html, ids, references });
		}
		pageCount = pages.size;
		const edges = new Map<string, Set<string>>();
		for (const [route, page] of pages) {
			edges.set(route, new Set());
			for (const reference of page.references) {
				const href = reference.value;
				if (/^(?:https?:|mailto:|tel:|data:|blob:|\/\/)/i.test(href)) continue;
				check(!/^[a-z][a-z\d+.-]*:/i.test(href), `${page.path}: unsupported URL scheme in ${href}`);
				const target = new URL(href, `https://docs.example${route}`);
				if (base && target.pathname !== base && !target.pathname.startsWith(`${base}/`)) {
					errors.push(`${page.path}: local URL escapes base path ${base}: ${href}`);
					continue;
				}
				const relative = decodeURIComponent(target.pathname.slice(base.length)).replace(/^\//, '');
				const normalized = relative.replace(/\/$/, '');
				const candidates =
					relative === '' ? ['index.html'] : [relative, `${normalized}/index.html`];
				const file = candidates.find((candidate) => fileSet.has(candidate));
				check(file, `${page.path}: missing local ${reference.attribute} target ${href}`);
				referenceCount++;
				if (!file) continue;
				const destination = file.endsWith('.html') ? routeFor(file) : undefined;
				if (reference.navigation && destination) {
					edges.get(route)!.add(destination);
				}
				if (target.hash && destination) {
					const id = decodeURIComponent(target.hash.slice(1));
					check(
						pages.get(destination)?.ids.has(id),
						`${page.path}: missing heading/anchor ${href}`
					);
				}
			}
		}
		const home = `${base}/`;
		check(pages.has(home), 'Homepage was not prerendered');
		const reachable = new Set<string>();
		const pending = [home];
		while (pending.length) {
			const next = pending.pop()!;
			if (reachable.has(next)) continue;
			reachable.add(next);
			pending.push(...(edges.get(next) ?? []));
		}
		for (const doc of documents) {
			const route = `${base}/docs/${doc.slug}/`;
			const page = pages.get(route);
			check(page, `${doc.slug}: document was not prerendered at ${route}`);
			check(
				reachable.has(route),
				`${doc.slug}: document is unreachable through links from the homepage`
			);
			if (page) {
				const index = readingOrder.findIndex((entry) => entry.slug === doc.slug);
				const expectedNeighbours = [readingOrder[index - 1], readingOrder[index + 1]]
					.filter(Boolean)
					.map((entry) => `${base}/docs/${entry.slug}/`);
				const neighbours =
					page.html.match(
						/<nav\b[^>]*aria-label="Previous and next guides"[^>]*>([\s\S]*?)<\/nav>/i
					)?.[1] ?? '';
				const actualNeighbours = Array.from(neighbours.matchAll(/<a\b[^>]*>/gi), (match) =>
					attributes(match[0]).get('href')
				);
				check(
					JSON.stringify(actualNeighbours) === JSON.stringify(expectedNeighbours),
					`${doc.slug}: previous/next navigation does not follow sidebar section order`
				);
				const article = page.html.match(/<article\b[^>]*>([\s\S]*?)<\/article>/i)?.[1];
				check(article !== undefined, `${doc.slug}: rendered content article is missing`);
				const sourceFences = codeFences(doc);
				const builtFences = renderedCode(article ?? '');
				check(
					sourceFences.length === builtFences.length,
					`${doc.slug}: expected ${sourceFences.length} code fences, rendered ${builtFences.length}`
				);
				for (let index = 0; index < sourceFences.length; index++) {
					if (builtFences[index] === undefined) continue;
					const expected = withoutFinalNewline(sourceFences[index].text);
					const actual = withoutFinalNewline(builtFences[index]);
					check(
						expected === actual,
						`${doc.slug}: code fence ${index + 1} (${
							sourceFences[index].language || 'plain text'
						}) changed ${codeDifference(expected, actual)}`
					);
					codeFenceCount++;
				}
				const h1 = page.html.match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i)?.[1] ?? '';
				check(
					textContent(h1) === doc.metadata.title,
					`${doc.slug}: rendered H1 does not match metadata title`
				);
				const description = Array.from(page.html.matchAll(/<meta\b[^>]*>/gi))
					.map((match) => attributes(match[0]))
					.find((attrs) => attrs.get('name') === 'description')
					?.get('content');
				check(
					description === doc.metadata.description,
					`${doc.slug}: rendered description does not match metadata`
				);
			}
		}
	} catch (error) {
		errors.push(`Cannot audit prerendered site: ${error}`);
	}
}

if (errors.length) {
	for (const error of errors) console.error(`FAIL ${error}`);
	console.error(`\n${errors.length} documentation validation error(s).`);
	process.exit(1);
}
console.log(
	`Validated ${documents.length} documentation pages${
		sourceOnly
			? ' (source only)'
			: `, ${pageCount} prerendered pages, ${codeFenceCount} unchanged code fences, and ${referenceCount} local links/assets${
					base ? ` under ${base}` : ''
				}`
	}.`
);
