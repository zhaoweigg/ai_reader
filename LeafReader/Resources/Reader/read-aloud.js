// Each request returns one bounded passage and a CFI cursor. Detached chapter
// documents are temporary; speech never renders or retains the whole book.
const excluded = 'script,style,noscript,template,rt, [hidden], [aria-hidden="true"]';
const limit = 800;
const sources = new WeakMap();
export function clearReadAloud(view) {
    const source = sources.get(view);
    if (source) { source.epoch++; source.doc = null; source.index = null; }
}

function readable(node) {
    if (!node.data || node.parentElement?.closest(excluded)) return false;
    const win = node.ownerDocument.defaultView;
    if (win) {
        const style = win.getComputedStyle(node.parentElement);
        if (style.display === 'none' || style.visibility === 'hidden') return false;
    }
    return true;
}

function passageEnd(text, start) {
    let end = Math.min(text.length, start + limit);
    if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1])) --end;
    const candidate = text.slice(start, end);
    // Prefer complete sentences; otherwise break at a word or at a safe UTF-16
    // boundary for languages that do not use spaces between words.
    const matches = [...candidate.matchAll(/[.!?。！？](?:[”’"']|\s|$)/gu)];
    const sentence = matches.at(-1);
    if (sentence && sentence.index > 80) return start + sentence.index + sentence[0].length;
    if (end < text.length) {
        const space = candidate.lastIndexOf(' ');
        if (space > limit / 2) end = start + space + 1;
    }
    return end;
}

export async function readAloudChunk(view, locator) {
    if (!view?.book) throw new Error('Open a book before listening.');
    let source = sources.get(view);
    if (!source) { source = { epoch: 0 }; sources.set(view, source); }
    const epoch = source.epoch;
    const resolved = locator?.startsWith('section:') ? { index: Number(locator.slice(8)) }
        : locator ? view.resolveNavigation(locator) : view.resolveNavigation(view.lastLocation?.cfi);
    if (!resolved || !Number.isInteger(resolved.index) || resolved.index < 0) throw new Error('This listening position is unavailable. Start again from the page.');
    const book = view.book;
    for (let index = resolved.index; index < book.sections.length; ++index) {
        if (view.book !== book || source.epoch !== epoch) throw new Error('Listening was stopped.');
        const section = book.sections[index];
        if (index !== resolved.index && section.linear === 'no') continue;
        const mounted = view.renderer.getContents?.().find(item => item.index === index)?.doc;
        const doc = mounted ?? (source.index === index ? source.doc : null) ?? await section.createDocument?.();
        if (view.book !== book || source.epoch !== epoch) throw new Error('Listening was stopped.');
        // Keep at most one detached text document. Never retain mounted iframe
        // documents: their lifetime belongs to the reader's bounded window.
        source.doc = mounted ? null : doc; source.index = index;
        if (!doc?.body) continue; // Image-only pages have no text to synthesize.
        let anchor = index === resolved.index ? resolved.anchor?.(doc) : null;
        if (anchor && !anchor.cloneRange && anchor.nodeType) {
            const range = doc.createRange(); range.selectNodeContents(anchor); anchor = range;
        }
        const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
        let node, first, last, lastEnd, block, remaining = limit;
        const parts = [];
        while ((node = walker.nextNode())) {
            if (!readable(node)) continue;
            let start = 0;
            if (anchor) {
                const point = doc.createRange(); point.setStart(node, node.length); point.collapse(true);
                if (point.compareBoundaryPoints(Range.START_TO_START, anchor) <= 0) continue;
                if (node === anchor.startContainer) start = anchor.startOffset;
                else {
                    point.setStart(node, 0);
                    if (point.compareBoundaryPoints(Range.START_TO_START, anchor) < 0) continue;
                }
            }
            const parent = node.parentElement.closest('p,div,li,h1,h2,h3,h4,h5,h6,blockquote,td,pre') ?? doc.body;
            if (first && parent !== block) break;
            let end = Math.min(passageEnd(node.data, start), start + remaining);
            if (end < node.length && /[\uD800-\uDBFF]/.test(node.data[end - 1])) --end;
            const text = node.data.slice(start, end);
            if (!text.trim() && !first) continue;
            first ??= { node, start }; block = parent; last = node; lastEnd = end;
            parts.push(text); remaining -= text.length;
            if (end < node.length || remaining <= 0) break;
        }
        if (first) {
            const range = doc.createRange(); range.setStart(first.node, first.start); range.setEnd(last, lastEnd);
            const next = range.cloneRange(); next.collapse(false);
            const label = view.getProgressOf(index, range).tocItem?.label;
            return { text: parts.join('').trim(), locator: view.getCFI(index, range), nextLocator: view.getCFI(index, next),
                language: first.node.parentElement.closest('[lang], [xml\\:lang]')?.getAttribute('lang')
                    || doc.documentElement.lang || (typeof book.metadata?.language === 'string' ? book.metadata.language : ''),
                label: typeof label === 'string' ? label : '', index };
        }
        // Yield between empty/non-text chapters so closing cancels a long scan.
        await new Promise(resolve => setTimeout(resolve, 0));
    }
    return null;
}

export async function revealReadAloud(view, locator) {
    const target = view.resolveNavigation(locator);
    if (!target) return;
    // Do not add every spoken passage to the reader's navigation history.
    const visible = view.lastLocation?.range;
    const content = view.renderer.getContents?.().find(item => item.index === target.index);
    const range = content && target.anchor?.(content.doc);
    if (visible && range && visible.startContainer.ownerDocument === range.startContainer.ownerDocument
        && visible.comparePoint(range.startContainer, range.startOffset) === 0) return;
    await view.renderer.goTo(target);
}
