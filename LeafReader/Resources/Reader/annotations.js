import { Overlayer } from './foliate/overlayer.js';

// Paint existing ranges outside the book DOM. Text nodes, CFI offsets, and layout
// stay unchanged. Resolving an anchor never opens an unloaded chapter.
export function createAnnotations(view, initial, post) {
    let items = [];
    let revision = 0;
    const currentItems = value => Array.isArray(value) ? value.filter(item =>
        typeof item.id === 'string' && typeof item.value === 'string' && item.value.startsWith('epubcfi(')
        && /^#[0-9A-Fa-f]{6}$/.test(item.color)) : [];
    const drawLoaded = async () => {
        const version = revision;
        const loaded = new Set((view.renderer?.getContents?.() ?? []).map(({ index }) => index));
        for (const item of items) {
            if (version !== revision) return;
            try {
                const { index } = view.resolveCFI(item.value);
                if (loaded.has(index)) await view.addAnnotation(item);
            } catch { /* A stale individual anchor must not stop reading. */ }
        }
    };
    view.addEventListener('draw-annotation', ({ detail }) => {
        const { annotation, draw } = detail;
        if (!items.some(item => item.id === annotation.id)) return;
        draw((rects, options) => {
            const group = Overlayer.highlight(rects, options);
            group.setAttribute('data-leaf-highlight', annotation.id);
            return group;
        }, { color: annotation.color });
    });
    view.addEventListener('create-overlay', () => {
        // Foliate attaches the new overlayer after this synchronous event returns.
        queueMicrotask(drawLoaded);
    });
    view.addEventListener('show-annotation', ({ detail }) => {
        const item = items.find(item => item.value === detail.value);
        if (item) post('annotationSelected', { id: item.id });
    });
    const set = async value => {
        const previous = items;
        items = currentItems(value);
        revision++;
        for (const item of previous) {
            if (!items.some(next => next.value === item.value)) {
                try { await view.deleteAnnotation(item); } catch { }
            }
        }
        await drawLoaded();
    };
    items = currentItems(initial);
    return {
        set,
        hit: (content, point) => {
            const [value] = content.overlayer?.hitTest(point) ?? [];
            const item = items.find(item => item.value === value);
            if (!item) return false;
            post('annotationSelected', { id: item.id });
            return true;
        },
    };
}
