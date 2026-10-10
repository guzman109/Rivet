import { test } from 'bun:test';
import { highlightCode } from '../scripts/highlight.ts';

function renderedText(markup: string): string {
	const expression = markup.match(/^\{@html ([\s\S]*)\}$/)?.[1];
	if (!expression) throw new Error('Expected a Svelte HTML expression');
	// Evaluate the generated expression just as Svelte does. Parsing HTML before
	// this step would miss JavaScript consuming backslash-newline and \n escapes.
	const html: string = new Function(`return (${expression});`)();
	const code = html.match(/<code\b[^>]*>([\s\S]*?)<\/code>/)?.[1];
	if (code === undefined) throw new Error('Expected a rendered code block');
	const named: Record<string, string> = {
		amp: '&',
		lt: '<',
		gt: '>',
		quot: '"',
		apos: "'",
		nbsp: '\u00a0'
	};
	return code
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/<[^>]*>/g, '')
		.replace(/&(#x[\da-f]+|#\d+|[a-z]+);/gi, (entity, key: string) =>
			key.startsWith('#')
				? String.fromCodePoint(
						Number.parseInt(
							key.slice(key[1].toLowerCase() === 'x' ? 2 : 1),
							key[1].toLowerCase() === 'x' ? 16 : 10
						)
					)
				: (named[key] ?? entity)
		);
}

const fixtures = [
	{
		language: 'sh',
		source:
			'outset new demo \\\n  --name demo \\\n  --modules true\n\nprintf "%s\\n" "${HOME}" `pwd`'
	},
	{
		language: 'cpp',
		source:
			String.raw`const char* escaped = "\n\t\u00e9\x41\\path";` +
			'\nconst char* markup = "` ${template} </script> <!--literal--> <span> &amp;";\n' +
			'\n  // Preserve blank lines and indentation.\n'
	},
	{
		language: 'lua',
		source:
			String.raw`local text = "one\ntwo\\three"` + '\nlocal braces = "${value} `literal` <tag>"'
	},
	{
		language: 'cmake',
		source: 'message("${CMAKE_SOURCE_DIR}\\n")\nset(path "C:\\\\work\\\\demo")'
	}
];

for (const fixture of fixtures) {
	test(`highlighter preserves ${fixture.language} source through Svelte expression evaluation`, async () => {
		const output = await highlightCode(fixture.source, fixture.language, undefined);
		const actual = renderedText(output);
		if (actual !== fixture.source) {
			throw new Error(
				`Expected ${JSON.stringify(fixture.source)}; received ${JSON.stringify(actual)}`
			);
		}
	});
}
