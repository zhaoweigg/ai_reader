import { Overlayer } from './foliate/overlayer.js';

// Each request returns one bounded passage and a CFI cursor. Detached chapter
// documents are temporary; speech never renders or retains the whole book.
const excluded = 'script,style,noscript,template,rt, [hidden], [aria-hidden="true"]';
const limit = 800;
const sources = new WeakMap();
export function clearReadAloud(view) {
    clearSpokenRange(view);
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

export async function readAloudChunk(view, locator, sanitize = doc => doc) {
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
        const cached = source.index === index ? source.doc : null;
        const doc = mounted ?? cached ?? await section.createDocument?.();
        if (view.book !== book || source.epoch !== epoch) throw new Error('Listening was stopped.');
        if (doc && !mounted && !cached) sanitize(doc);
        // Keep at most one detached text document. Never retain mounted iframe
        // documents: their lifetime belongs to the reader's bounded window.
        source.doc = mounted ? null : doc; source.index = index;
        if (!doc?.body) continue; // Image-only pages have no text to synthesize.
        let anchor = index === resolved.index ? resolved.anchor?.(doc) : null;
        if (anchor && !anchor.cloneRange && anchor.nodeType) {
            const range = doc.createRange(); range.selectNodeContents(anchor); anchor = range;
        }
        const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
        let node, first, last, lastEnd, block, breaks, remaining = limit;
        const parts = [], pieces = [];
        let spokenOffset = 0;
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
            const parent = node.parentElement.closest('p,div,li,h1,h2,h3,h4,h5,h6,blockquote,td,tr,pre,figcaption,dt,dd,section,article') ?? doc.body;
            if (first && parent !== block) break;
            if (first && breaks.length) {
                const gap = doc.createRange(); gap.setStart(last, lastEnd); gap.setEnd(node, start);
                if (breaks.some(br => gap.intersectsNode(br))) {
                    // A separator belongs only to the spoken string. Keep the
                    // original text nodes and CFI offsets completely unchanged.
                    parts.push('\n');
                    spokenOffset++;
                    if (--remaining <= 0) break;
                }
            }
            let end = Math.min(passageEnd(node.data, start), start + remaining);
            if (end < node.length && /[\uD800-\uDBFF]/.test(node.data[end - 1])) --end;
            const text = node.data.slice(start, end);
            if (!text.trim() && !first) continue;
            if (!first) breaks = [...parent.querySelectorAll('br')].filter(br => !br.closest(excluded));
            first ??= { node, start }; block = parent; last = node; lastEnd = end;
            pieces.push({ node, start, end, offset: spokenOffset });
            parts.push(text); remaining -= text.length;
            spokenOffset += text.length;
            if (end < node.length || remaining <= 0) break;
        }
        if (first) {
            const range = doc.createRange(); range.setStart(first.node, first.start); range.setEnd(last, lastEnd);
            const next = range.cloneRange(); next.collapse(false);
            const label = view.getProgressOf(index, range).tocItem?.label;
            const raw = parts.join(''), text = raw.trim(), leading = raw.length - raw.trimStart().length;
            // Spoken offsets include synthetic line breaks and omit trimmed
            // whitespace/rt text. Map bounded text pieces back to original CFIs
            // rather than inserting spans or assuming DOM and speech offsets match.
            const segments = pieces.flatMap(piece => {
                const start = Math.max(leading, piece.offset), end = Math.min(leading + text.length, piece.offset + piece.end - piece.start);
                if (end <= start) return [];
                const anchor = doc.createRange();
                anchor.setStart(piece.node, piece.start + start - piece.offset);
                anchor.setEnd(piece.node, piece.start + end - piece.offset);
                return [{ offset: start - leading, length: end - start, locator: view.getCFI(index, anchor) }];
            });
            return { text, segments, locator: view.getCFI(index, range), nextLocator: view.getCFI(index, next),
                language: first.node.parentElement.closest('[lang], [xml\\:lang]')?.getAttribute('lang')
                    || doc.documentElement.lang || (typeof book.metadata?.language === 'string' ? book.metadata.language : ''),
                label: typeof label === 'string' ? label : '', index };
        }
        // Yield between empty/non-text chapters so closing cancels a long scan.
        await new Promise(resolve => setTimeout(resolve, 0));
    }
    return null;
}

const spokenViews = new WeakMap();
const spokenKey = 'leaf-spoken-word';
function clearPaint(view) {
    for (const content of view.renderer?.getContents?.() ?? []) content.overlayer?.remove(spokenKey);
}
function paintSpokenRange(view, state) {
    clearPaint(view);
    const { passage, location, length } = state;
    if (!passage || length <= 0) return;
    const contents = view.renderer?.getContents?.() ?? [];
    const ranges = [];
    for (const segment of passage.segments ?? []) {
        const start = Math.max(location, segment.offset), end = Math.min(location + length, segment.offset + segment.length);
        if (end <= start) continue;
        try {
            const target = view.resolveCFI(segment.locator), content = contents.find(item => item.index === target.index);
            if (!content?.overlayer) continue; // Never load a chapter to paint it.
            const anchor = target.anchor(content.doc), range = anchor.cloneRange();
            if (anchor.startContainer.nodeType !== Node.TEXT_NODE) continue;
            range.setStart(anchor.startContainer, anchor.startOffset + start - segment.offset);
            range.setEnd(anchor.startContainer, anchor.startOffset + end - segment.offset);
            ranges.push({ content, range });
        } catch { /* A stale/reloading document must not interrupt speech. */ }
    }
    // A word can cross inline elements. One draw group owns all of its rects,
    // keeping hit testing and persistent annotations completely independent.
    for (const content of new Set(ranges.map(item => item.content))) {
        const matching = ranges.filter(item => item.content === content).map(item => item.range);
        const range = { getClientRects: () => matching.flatMap(item => [...item.getClientRects()]) };
        content.overlayer.add(spokenKey, range, rects => {
            const group = Overlayer.highlight(rects, { color: '#F2B84B' });
            group.setAttribute('data-leaf-spoken-word', 'true');
            group.setAttribute('data-leaf-spoken-text', passage.text.slice(location, location + length));
            group.style.opacity = '.42';
            group.style.pointerEvents = 'none';
            return group;
        }, { interactive: false });
    }
}
export function clearSpokenRange(view) {
    const state = spokenViews.get(view);
    if (state) { state.revision++; state.passage = null; }
    clearPaint(view);
}
export async function setSpokenRange(view, { passage, locator, location, length, follow }) {
    if (!view?.book) return;
    let state = spokenViews.get(view);
    if (!state) {
        state = { revision: 0 };
        spokenViews.set(view, state);
        const redraw = () => queueMicrotask(() => paintSpokenRange(view, state));
        view.addEventListener('create-overlay', redraw);
        view.addEventListener('relocate', redraw);
    }
    if (passage) state.passage = passage;
    if (state.passage?.locator !== locator) return;
    const revision = ++state.revision;
    state.location = Math.max(0, location); state.length = Math.max(0, length);
    if (follow) {
        const segment = state.passage.segments?.find(item => location >= item.offset && location < item.offset + item.length);
        if (segment) {
            await revealReadAloud(view, segment.locator, Math.max(0, location - segment.offset));
        }
    }
    if (revision === state.revision) paintSpokenRange(view, state);
}

export async function revealReadAloud(view, locator, offset = 0) {
    const source = sources.get(view);
    if (!source) return;
    const epoch = source.epoch;
    const request = `${locator}@${offset}`;
    source.latestReveal = request;
    // Rapid Next/Previous actions must finish at the newest passage, even if an
    // earlier reveal is still waiting for a cold chapter document to load.
    source.navigation = (source.navigation ?? Promise.resolve()).catch(() => {}).then(async () => {
        if (source.epoch !== epoch || source.latestReveal !== request || !view.book) return;
        const target = view.resolveNavigation(locator);
        if (!target) return;
        if (offset > 0) {
            const anchor = target.anchor;
            target.anchor = doc => {
                const range = anchor(doc); range.collapse(true);
                if (range.startContainer.nodeType === Node.TEXT_NODE)
                    range.setStart(range.startContainer, Math.min(range.startContainer.length, range.startOffset + offset));
                return range;
            };
        }
        // Do not add every spoken passage to the reader's navigation history.
        const visible = view.lastLocation?.range;
        const content = view.renderer.getContents?.().find(item => item.index === target.index);
        const range = content && target.anchor?.(content.doc);
        if (visible && range && visible.startContainer.ownerDocument === range.startContainer.ownerDocument
            && visible.comparePoint(range.startContainer, range.startOffset) === 0) return;
        await view.renderer.goTo(target);
    });
    await source.navigation;
}
