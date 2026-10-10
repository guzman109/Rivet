<script lang="ts">
	import { docHref } from '../lib/docs.ts';
	import { codeTools } from '../lib/code-tools.ts';
	let interfaceChoice = $state<'neovim' | 'terminal'>('neovim');
	const setup = `vim.opt.runtimepath:prepend(
  vim.fn.expand('/path/to/rivet.nvim')
)
require('rivet').setup()`;
	const terminal = `./bin/rivet new ./hello \\\n  --name hello --modules false --preview`;
	const guides = [
		{
			number: '01',
			slug: 'modules',
			title: 'C++ for your workload.',
			text: 'Headers or modules, from a first build to HPC and graphics.',
			tag: 'C++'
		},
		{
			number: '02',
			slug: 'python',
			title: 'A Python package that runs.',
			text: 'Choose your environment, edit a module, and run its tests.',
			tag: 'PYTHON'
		},
		{
			number: '03',
			slug: 'rust',
			title: 'Keep Cargo in charge.',
			text: 'Applications, libraries, and workspaces with native tasks.',
			tag: 'RUST'
		},
		{
			number: '04',
			slug: 'swift',
			title: 'Start with a Swift package.',
			text: 'Build reusable logic and hand Apple application work to Xcode.',
			tag: 'SWIFT'
		},
		{
			number: '05',
			slug: 'c',
			title: 'C with a clear build.',
			text: 'Strict C projects and ABI headers for C++ interoperability.',
			tag: 'C'
		}
	];
</script>

<svelte:head>
	<title>Rivet — projects, from the first file</title>
	<meta
		name="description"
		content="Create, preview, and work on C++, C, Python, Rust, and Swift projects from Neovim. Guides for native tools, HPC, graphics, and project templates."
	/>
</svelte:head>

<div class="home-page">
	<div class="breadcrumb">Documentation <span>/</span> <strong>Introduction</strong></div>
	<section class="hero" aria-labelledby="intro-title">
		<div class="hero-copy">
			<div class="eyebrow"><span class="small-rule"></span> YOUR NEXT PROJECT</div>
			<h1 id="intro-title">Start with<br />a solid <em>foundation.</em></h1>
			<p>
				From the first file to the next build. Create C, C++, Python, Rust, and Swift projects, then
				work with their native tools—right from Neovim.
			</p>
			<div class="hero-actions">
				<a class="primary-button" href={docHref('start-here')}
					>Get started <span aria-hidden="true">↗</span></a
				><a class="text-link" href={docHref('getting-started')}
					>Take the CLI route <span aria-hidden="true">→</span></a
				>
			</div>
			<div class="hero-footnote">Your files. Your toolchain. Native project tools.</div>
		</div>
		<div class="project-visual" aria-label="Example generated project structure">
			<div class="diagram-label">
				<span class="status-dot"></span> A C++ PROJECT <span>01—05</span>
			</div>
			<div class="project-root">
				<span class="folder-icon" aria-hidden="true">⌑</span><strong>hello/</strong><span
					>YOUR PROJECT</span
				>
			</div>
			<div class="tree-rows">
				<div><code>src/</code><span>Your implementation</span></div>
				<div><code>tests/</code><span>Correctness checks</span></div>
				<div><code>cmake/</code><span>A build you can read</span></div>
				<div><code>CMakePresets.json</code><span>Ready to run</span></div>
				<div><code>.clang-format</code><span>Your own style</span></div>
			</div>
			<div class="diagram-footer">
				<span>PREVIEW → REVIEW → CREATE</span><span aria-hidden="true">↳</span>
			</div>
		</div>
	</section>
	<div class="principles">
		<span><b>01</b> Preview before you write</span><span
			><b>02</b> Keep configuration in the project</span
		><span><b>03</b> Use the tools you know</span>
	</div>
	<section class="quickstart" aria-labelledby="quickstart-title">
		<div class="section-intro">
			<div class="eyebrow">A SMALL FIRST STEP</div>
			<h2 id="quickstart-title">Meet your new project.</h2>
			<p>Load the development checkout, then choose your language. The CLI is optional.</p>
			<a class="text-link" href={docHref('start-here')}
				>Installation & first run <span aria-hidden="true">↗</span></a
			>
		</div>
		<div class="start-panel">
			<div class="interface-tabs" aria-label="Setup interface">
				<button
					class:selected={interfaceChoice === 'neovim'}
					aria-pressed={interfaceChoice === 'neovim'}
					onclick={() => (interfaceChoice = 'neovim')}>Neovim</button
				><button
					class:selected={interfaceChoice === 'terminal'}
					aria-pressed={interfaceChoice === 'terminal'}
					onclick={() => (interfaceChoice = 'terminal')}>Terminal</button
				><span>{interfaceChoice === 'neovim' ? 'init.lua' : 'from your checkout'}</span>
			</div>
			{#key interfaceChoice}<div class="setup-code" use:codeTools>
					<pre><code>{interfaceChoice === 'neovim' ? setup : terminal}</code></pre>
				</div>{/key}
			<div class="setup-next">
				{#if interfaceChoice === 'neovim'}<span
						>Adjust the path, restart, then run <code>:RivetNew</code>.</span
					>{:else}<span>Review the files, then omit <code>--preview</code> to create.</span>{/if}<a
					href={docHref(interfaceChoice === 'neovim' ? 'neovim' : 'getting-started')}
					aria-label="Read the full setup guide">→</a
				>
			</div>
		</div>
	</section>
	<section class="explore" aria-labelledby="explore-title">
		<div class="section-heading">
			<h2 id="explore-title">Build it your way.</h2>
			<span>A FEW PLACES TO GO NEXT</span>
		</div>
		<div class="guide-grid">
			{#each guides as guide}<a class="guide-card" href={docHref(guide.slug)}
					><div class="guide-top">
						<span>{guide.number} / {guide.tag}</span><span aria-hidden="true">↗</span>
					</div>
					<h3>{guide.title}</h3>
					<p>{guide.text}</p></a
				>{/each}
		</div>
	</section>
	<footer class="site-footer">
		<span>Rivet <span aria-hidden="true">/</span> Tools for the work ahead.</span><a
			href={docHref('extending')}>Under the hood ↗</a
		>
	</footer>
</div>
