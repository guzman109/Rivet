<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';
</script>

<svelte:head><title>Page unavailable — Rivet</title></svelte:head>
<div class="error-page">
	<span class="eyebrow">{page.status}</span>
	<h1>This page is off the map.</h1>
	<p>{page.error?.message ?? 'Try a guide from the navigation or search the documentation.'}</p>
	<a class="primary-button" href={resolve('/')}>Return to the overview →</a>
</div>
