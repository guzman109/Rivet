<script lang="ts">
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import { asset, resolve } from '$app/paths';
	import { docs, docHref, sections } from '../lib/docs.ts';
	import Search from '../lib/Search.svelte';
	import '@fontsource/space-grotesk/latin-400.css';
	import '@fontsource/space-grotesk/latin-500.css';
	import '@fontsource/space-grotesk/latin-600.css';
	import '@fontsource/space-grotesk/latin-700.css';
	import '@fontsource/space-mono/latin-400.css';
	import '@fontsource/space-mono/latin-400-italic.css';
	import '../app.css';
	import '../lib/catppuccin.css';
	let { children }: { children: Snippet } = $props();
	let menuOpen = $state(false);
	let menuButton: HTMLButtonElement;
	function closeMenu() {
		menuOpen = false;
		menuButton?.focus();
	}
</script>

<svelte:head>
	<link rel="icon" type="image/svg+xml" href={asset('favicon.svg')} />
	<meta name="color-scheme" content="light dark" />
</svelte:head>
<svelte:window
	onkeydown={(event) => {
		if (event.key === 'Escape' && menuOpen) closeMenu();
	}}
/>
<a href="#main-content" class="skip-link">Skip to content</a>
<header class="topbar">
	<a class="brand" href={resolve('/')} aria-label="Rivet home" onclick={() => (menuOpen = false)}>
		<svg class="brand-mark" viewBox="0 0 32 32" fill="none" aria-hidden="true"
			><path d="M24 7a12 12 0 1 0 3 15M18 4h10v10" stroke="currentColor" stroke-width="3.5" /></svg
		>
		<span>rivet<span class="brand-dot">.</span></span>
	</a>
	<span class="header-divider"></span><span class="header-label">Documentation</span>
	<div class="header-search"><Search /></div>
	<nav class="header-links" aria-label="Quick links">
		<a href={docHref('neovim')}>Neovim</a><a href={docHref('cli')}
			>CLI reference <span aria-hidden="true">↗</span></a
		>
	</nav>
	<button
		bind:this={menuButton}
		class="menu-button"
		onclick={() => (menuOpen = !menuOpen)}
		aria-expanded={menuOpen}
		aria-controls="docs-navigation">{menuOpen ? 'Close' : 'Menu'}</button
	>
</header>
{#if menuOpen}<button class="nav-shade" aria-label="Close navigation" onclick={closeMenu}
	></button>{/if}
<div class="site-frame">
	<aside class="sidebar" class:mobile-open={menuOpen} id="docs-navigation">
		<nav aria-label="Documentation">
			<a
				class="overview-link"
				class:active={page.url.pathname === resolve('/')}
				href={resolve('/')}
				onclick={() => (menuOpen = false)}
				aria-current={page.url.pathname === resolve('/') ? 'page' : undefined}
				><span aria-hidden="true">◈</span> Introduction</a
			>
			{#each sections as section, index}
				<div class="nav-group">
					<h2><span>0{index + 1}</span>{section}</h2>
					{#each docs.filter((doc) => doc.section === section) as doc}
						<a
							href={docHref(doc.slug)}
							class:active={page.params.slug === doc.slug}
							aria-current={page.params.slug === doc.slug ? 'page' : undefined}
							onclick={() => (menuOpen = false)}>{doc.title}</a
						>
					{/each}
				</div>
			{/each}
		</nav>
		<div class="sidebar-note">
			<span class="status-dot"></span> Built for your editor.<small
				>Neovim + portable Lua · <a href="/licenses/rivet.txt">MIT</a></small
			>
		</div>
	</aside>
	<main id="main-content" tabindex="-1">{@render children()}</main>
</div>
