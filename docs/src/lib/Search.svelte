<script lang="ts">
	import { docHref, searchDocs } from './docs.ts';
	let dialog: HTMLDialogElement;
	let input: HTMLInputElement;
	let query = $state('');
	const results = $derived(searchDocs(query));

	function open() {
		query = '';
		dialog.showModal();
		requestAnimationFrame(() => input.focus());
	}
	function shortcut(event: KeyboardEvent) {
		const element = event.target;
		const editing =
			element instanceof HTMLElement &&
			(element.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(element.tagName));
		if (
			(event.key.toLowerCase() === 'k' && (event.metaKey || event.ctrlKey)) ||
			(event.key === '/' && !editing)
		) {
			event.preventDefault();
			if (!dialog.open) open();
		}
	}
	function move(event: KeyboardEvent) {
		if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
		const links = [...dialog.querySelectorAll<HTMLAnchorElement>('.search-result')];
		if (!links.length) return;
		event.preventDefault();
		const current = links.indexOf(document.activeElement as HTMLAnchorElement);
		const index =
			current < 0
				? event.key === 'ArrowDown'
					? 0
					: links.length - 1
				: (current + (event.key === 'ArrowDown' ? 1 : -1) + links.length) % links.length;
		links[index].focus();
	}
</script>

<svelte:window onkeydown={shortcut} />
<button class="search-trigger" onclick={open} aria-label="Search documentation">
	<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"
		><circle cx="10.5" cy="10.5" r="6.5" /><path d="m16 16 4.5 4.5" /></svg
	>
	<span>Search the docs…</span><kbd>⌘ K</kbd>
</button>
<dialog bind:this={dialog} class="search-dialog" aria-labelledby="search-title" onkeydown={move}>
	<div class="search-input-row">
		<label id="search-title" for="docs-search" class="sr-only">Search documentation</label>
		<input
			bind:this={input}
			bind:value={query}
			id="docs-search"
			type="search"
			placeholder="Search modules, CMake, commands…"
			autocomplete="off"
			autocorrect="off"
			autocapitalize="off"
			spellcheck={false}
		/>
		<button class="escape-button" onclick={() => dialog.close()} aria-label="Close search"
			>Esc</button
		>
	</div>
	<div class="search-results">
		<p class="search-label" aria-live="polite">
			{query.trim() ? `${results.length} matching guides` : 'Start exploring'}
		</p>
		{#each results as result}
			<a class="search-result" href={docHref(result.doc.slug)} onclick={() => dialog.close()}>
				<span class="search-section">{result.doc.section}</span>
				<strong>{result.doc.title}<span aria-hidden="true">↗</span></strong>
				<span>{result.excerpt}</span>
			</a>
		{:else}
			<div class="empty-search">
				<strong>No matching guides</strong>
				<p>Try “modules”, “compiler”, “layout”, or “build”.</p>
			</div>
		{/each}
	</div>
	<div class="search-footer">
		<span>↑ ↓ navigate · Enter open · Esc close</span><span>Search stays in your browser</span>
	</div>
</dialog>
