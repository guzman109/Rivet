/** Enhance rendered code without changing its copyable contents. */
export function codeTools(node: HTMLElement) {
	const cleanups: (() => void)[] = [];
	for (const pre of node.querySelectorAll('pre')) {
		const code = pre.querySelector('code');
		if (!code) continue;
		pre.tabIndex = 0;
		pre.setAttribute('role', 'region');
		pre.setAttribute('aria-label', 'Code example');
		const button = document.createElement('button');
		button.type = 'button';
		button.className = 'copy-code';
		button.textContent = 'Copy';
		button.setAttribute('aria-label', 'Copy code');
		button.setAttribute('aria-live', 'polite');
		let timer: ReturnType<typeof setTimeout> | undefined;
		const copy = async () => {
			try {
				await navigator.clipboard.writeText(code.textContent ?? '');
				button.textContent = 'Copied';
			} catch {
				button.textContent = 'Select to copy';
				const range = document.createRange();
				range.selectNodeContents(code);
				const selection = window.getSelection();
				selection?.removeAllRanges();
				selection?.addRange(range);
			}
			clearTimeout(timer);
			timer = setTimeout(() => {
				button.textContent = 'Copy';
			}, 2000);
		};
		button.addEventListener('click', copy);
		pre.append(button);
		cleanups.push(() => {
			clearTimeout(timer);
			button.removeEventListener('click', copy);
			button.remove();
		});
	}
	return { destroy: () => cleanups.forEach((cleanup) => cleanup()) };
}
