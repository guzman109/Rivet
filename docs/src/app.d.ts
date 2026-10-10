declare namespace App {}

declare module '*.svx' {
	import type { Component } from 'svelte';
	export const metadata: Record<string, unknown>;
	const component: Component;
	export default component;
}

declare module '*.svx?metadata' {
	const metadata: Record<string, unknown>;
	export default metadata;
}
