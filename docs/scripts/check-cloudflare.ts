/** Exercise the built site in Cloudflare's local runtime without account credentials. */
import { readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const port = 8791;
const origin = `http://127.0.0.1:${port}`;
const server = Bun.spawn(
	[
		process.execPath,
		'x',
		'--no-install',
		'wrangler',
		'dev',
		'--local',
		'--ip',
		'127.0.0.1',
		'--port',
		String(port),
		'--inspector-port',
		'0'
	],
	{
		cwd: fileURLToPath(new URL('../', import.meta.url)),
		stdout: 'pipe',
		stderr: 'pipe',
		env: { ...process.env, CI: 'true', WRANGLER_SEND_METRICS: 'false' }
	}
);
const output = new Response(server.stdout).text();
const errors = new Response(server.stderr).text();
function check(condition: unknown, message: string): asserts condition {
	if (!condition) throw new Error(message);
}
async function get(path: string) {
	return fetch(`${origin}${path}`, { redirect: 'manual' });
}
try {
	let ready = false;
	for (let attempt = 0; attempt < 100; attempt++) {
		if (server.exitCode !== null) throw new Error('Wrangler exited before it was ready');
		try {
			ready = (await get('/')).status === 200;
		} catch {
			/* Wait for local startup. */
		}
		if (ready) break;
		await Bun.sleep(200);
	}
	check(ready, 'Wrangler did not become ready');
	const home = await get('/');
	check((await home.text()).includes('rivet'), 'Homepage branding missing');
	check(
		home.headers.get('x-content-type-options') === 'nosniff',
		'Cloudflare headers were not applied'
	);
	let pages = 0;
	for (const entry of await readdir(new URL('../build/docs/', import.meta.url), {
		withFileTypes: true
	})) {
		if (!entry.isDirectory()) continue;
		const response = await get(`/docs/${entry.name}/`);
		check(response.status === 200, `Deep link failed: ${entry.name}`);
		check((await response.text()).includes('<h1'), `Missing page content: ${entry.name}`);
		pages++;
	}
	const redirect = await get('/docs/modules');
	check([301, 307, 308].includes(redirect.status), 'Missing trailing-slash redirect');
	check(
		new URL(redirect.headers.get('location')!, origin).pathname === '/docs/modules/',
		'Wrong canonical URL'
	);
	const missing = await get('/docs/this-page-does-not-exist/');
	check(
		missing.status === 404 && (await missing.text()).includes("couldn't find that page"),
		'Missing pages must return the custom 404, not the homepage'
	);
	const missingAsset = await get('/_app/immutable/missing.js');
	check(missingAsset.status === 404, 'Missing assets must not return a successful HTML response');
	const assets = await readdir(new URL('../build/_app/immutable/', import.meta.url), {
		recursive: true
	});
	const js = assets.find((path) => path.endsWith('.js'));
	check(js, 'No JavaScript assets in build');
	const asset = await get('/_app/immutable/' + js);
	check(
		asset.status === 200 && /javascript/.test(asset.headers.get('content-type') ?? ''),
		'JavaScript is not served with the correct MIME type'
	);
	check(
		asset.headers.get('cache-control')?.includes('immutable'),
		'Immutable assets are not cached'
	);
	const font = assets.find((path) => path.endsWith('.woff2'));
	check(font && (await get('/_app/immutable/' + font)).status === 200, 'Bundled font missing');
	check(
		(await get('/licenses/rivet.txt')).status === 200,
		'Project license missing from deployment'
	);
	console.log(
		`Cloudflare local checks passed: ${pages} guides, homepage, deep links, redirect, custom 404, JS, fonts, headers and license.`
	);
} catch (error) {
	server.kill();
	await server.exited;
	console.error(await output, await errors);
	throw error;
} finally {
	if (server.exitCode === null) server.kill();
	await server.exited;
}
