import { code_highlighter } from 'mdsvex';

/** Keep Prism's syntax tokens while preserving every source character. */
export async function highlightCode(
	code: string,
	language: string | null | undefined,
	metadata: string | null | undefined,
	filename?: string
): Promise<string> {
	// Disable mdsvex's template-literal wrapper: JavaScript otherwise consumes
	// line-continuation backslashes and escape sequences in copyable code.
	const html = await code_highlighter(code, language, metadata, filename, false);
	return `{@html ${JSON.stringify(html)}}`;
}
