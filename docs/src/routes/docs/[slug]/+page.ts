import { error } from '@sveltejs/kit';
import { docs, loadDocument } from '../../../lib/docs.ts';
import type { PageLoad, EntryGenerator } from './$types';

export const entries: EntryGenerator = () => docs.map((doc) => ({ slug: doc.slug }));
export const load: PageLoad = async ({ params }) => {
	const index = docs.findIndex((doc) => doc.slug === params.slug);
	if (index < 0) error(404, 'That documentation page does not exist.');
	const component = await loadDocument(params.slug);
	if (!component) error(404, 'That documentation page does not exist.');
	return { doc: docs[index], component, previous: docs[index - 1], next: docs[index + 1] };
};
