import type { Component } from 'svelte';
import GithubSlugger from 'github-slugger';
import { resolve } from '$app/paths';

export interface DocMetadata {
	title: string;
	description: string;
	section: 'Start here' | 'Guides' | 'Reference';
	order: number;
	updated: string;
}
export interface Heading {
	id: string;
	title: string;
	level: number;
}
export interface Doc extends DocMetadata {
	slug: string;
	headings: Heading[];
	text: string;
	minutes: number;
}

const metadata = import.meta.glob<DocMetadata>('/src/content/*.svx', {
	query: '?metadata',
	import: 'default',
	eager: true
});
const raw = import.meta.glob<string>('/src/content/*.svx', {
	query: '?raw',
	import: 'default',
	eager: true
});
const components = import.meta.glob<{ default: Component }>('/src/content/*.svx');

function headings(source: string): Heading[] {
	const slugger = new GithubSlugger();
	const withoutCode = source
		.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '')
		.replace(/^(```|~~~)[\s\S]*?^\1.*$/gm, '');
	return Array.from(withoutCode.matchAll(/^(#{2,3})\s+(.+)$/gm), ([, hashes, text]) => {
		const title = text
			.replace(/`([^`]+)`/g, '$1')
			.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
			.replace(/[*_]/g, '')
			.trim();
		return { id: slugger.slug(title), title, level: hashes.length };
	});
}

export const sections = ['Start here', 'Guides', 'Reference'] as const;

export const docs: Doc[] = Object.entries(metadata)
	.map(([path, meta]) => {
		const slug = path
			.split('/')
			.at(-1)!
			.replace(/\.svx$/, '');
		if (!meta.title || !meta.description || !Number.isFinite(meta.order)) {
			throw new Error(`Invalid documentation metadata in ${path}`);
		}
		const source = raw[path];
		const text = source
			.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '')
			.replace(/<script[\s\S]*?<\/script>/g, '')
			.replace(/<[^>]+>/g, '')
			.replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
			.replace(/[#*`|]/g, '')
			.replace(/\s+/g, ' ')
			.trim();
		return {
			...meta,
			slug,
			headings: headings(source),
			text,
			minutes: Math.max(1, Math.ceil(text.split(' ').length / 200))
		};
	})
	.sort((a, b) => sections.indexOf(a.section) - sections.indexOf(b.section) || a.order - b.order);

export function docHref(slug: string): string {
	const href = resolve('/docs/[slug]', { slug });
	return href.endsWith('/') ? href : `${href}/`;
}

export async function loadDocument(slug: string) {
	const loader = components[`/src/content/${slug}.svx`];
	return loader ? (await loader()).default : undefined;
}

export function searchDocs(query: string): { doc: Doc; excerpt: string }[] {
	const terms = query.toLowerCase().trim().split(/\s+/).filter(Boolean);
	if (!terms.length) return docs.slice(0, 5).map((doc) => ({ doc, excerpt: doc.description }));
	return docs
		.map((doc) => {
			const title = doc.title.toLowerCase();
			const description = doc.description.toLowerCase();
			const text = doc.text.toLowerCase();
			const score = terms.every((term) => `${title} ${description} ${text}`.includes(term))
				? terms.reduce(
						(sum, term) =>
							sum +
							(title.includes(term) ? 12 : 0) +
							(description.includes(term) ? 6 : 0) +
							(text.includes(term) ? 1 : 0),
						0
					)
				: 0;
			const index = Math.max(0, text.indexOf(terms[0]) - 45);
			const excerpt = index > 0 ? `…${doc.text.slice(index, index + 160)}…` : doc.description;
			return { doc, excerpt, score };
		})
		.filter((result) => result.score > 0)
		.sort((a, b) => b.score - a.score)
		.slice(0, 8);
}
