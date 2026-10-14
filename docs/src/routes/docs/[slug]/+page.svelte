<script lang="ts">
	import { docHref } from '../../../lib/docs.ts';
	import { codeTools } from '../../../lib/code-tools.ts';
	import type { PageData } from './$types';
	let { data }: { data: PageData } = $props();
	const Content = $derived(data.component);
</script>

<svelte:head
	><title>{data.doc.title} — Rivet</title><meta
		name="description"
		content={data.doc.description}
	/></svelte:head
>
<div class="doc-page">
	<div class="doc-main">
		<header class="doc-header">
			<div class="eyebrow">
				{data.doc.section}<span aria-hidden="true"> / </span> RIVET
			</div>
			<h1>{data.doc.title}</h1>
			<p class="doc-description">{data.doc.description}</p>
			<div class="doc-meta">
				<span>{data.doc.minutes} min read</span><span aria-hidden="true">·</span><span
					>Updated <time datetime={data.doc.updated}>{data.doc.updated}</time></span
				>
			</div>
		</header>
		{#key data.doc.slug}<article class="prose" use:codeTools><Content /></article>{/key}
		<nav class="page-neighbours" aria-label="Previous and next pages">
			{#if data.previous}<a href={docHref(data.previous.slug)}
					><span>← Previous</span><strong>{data.previous.title}</strong></a
				>{:else}<div></div>{/if}
			{#if data.next}<a class="next-page" href={docHref(data.next.slug)}
					><span>Next →</span><strong>{data.next.title}</strong></a
				>{/if}
		</nav>
	</div>
	<aside class="toc">
		<nav aria-label="On this page">
			<h2>On this page</h2>
			{#each data.doc.headings as heading}<a
					class:nested={heading.level === 3}
					href={`#${heading.id}`}>{heading.title}</a
				>{/each}
		</nav>
	</aside>
</div>
