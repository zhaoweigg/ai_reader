import { makeBook } from './foliate/view.js';
import { openBookSource } from './book-source.js';
import { createAnnotations } from './annotations.js';
import { readAloudChunk, revealReadAloud, clearReadAloud, setSpokenRange, clearSpokenRange } from './read-aloud.js';
import { languageText, contributor } from './metadata-text.js';
import { nearbyChatText } from './chat-context.js';
import { retrieveEarlierPassages } from './book-recall.js';

const post = (type, detail = {}) => window.webkit?.messageHandlers?.leaf?.postMessage({ type, ...detail });
const escapeHTML = text => text.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let view;
let annotationLayer;
let searchGeneration;
let preferences;
let fixedIndex = 0;
let lastLinkActivation = 0;
const observedDocuments = new WeakSet();
// Remember the current selection owner without retaining an evicted chapter.
// An empty current selection must never resurrect an older iframe range.
let selectedDocument;
let chatRecallID;
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
reducedMotion.addEventListener('change', () => { if (preferences) applyPreferences(preferences); });

function textBoundedSelection(range) {
    if (range.startContainer.nodeType === Node.TEXT_NODE && range.endContainer.nodeType === Node.TEXT_NODE)
        return range;
    // EPUB CFI character offsets belong to text nodes. Whole-element selections
    // need equivalent text endpoints rather than element child offsets.
    const doc = range.startContainer.ownerDocument;
    const walker = doc.createTreeWalker(range.commonAncestorContainer, NodeFilter.SHOW_TEXT);
    let first, last, node;
    while ((node = walker.nextNode())) {
        if (!range.intersectsNode(node)) continue;
        const start = node === range.startContainer ? range.startOffset : 0;
        const end = node === range.endContainer ? range.endOffset : node.length;
        if (end <= start) continue;
        first ??= { node, offset:start };
        last = { node, offset:end };
    }
    if (!first) return range;
    const textRange = doc.createRange();
    textRange.setStart(first.node, first.offset);
    textRange.setEnd(last.node, last.offset);
    return textRange;
}

function observeReadingTouches(doc, index) {
    if (observedDocuments.has(doc)) return;
    observedDocuments.add(doc);
    doc.addEventListener('selectionchange', () => {
        if (!view?.renderer?.getContents?.().some(content => content.doc === doc)) return;
        const selection = doc.getSelection();
        const text = selection && !selection.isCollapsed ? selection.toString().slice(0,12000) : '';
        if (!text && selectedDocument && selectedDocument.deref() !== doc) return;
        const detail = { text, tooLong: (selection?.toString().length ?? 0) > 12000 };
        if (text || selectedDocument?.deref() === doc) selectedDocument = new WeakRef(doc);
        if (text && selection.rangeCount && view) {
            const range = textBoundedSelection(selection.getRangeAt(0));
            // A selected range can belong to a neighboring visible chapter.
            // Snapshot its own CFI/label without navigating the reading viewport.
            detail.locator = view.getCFI(index, range);
            detail.label = languageText(view.getProgressOf(index, range).tocItem?.label);
            Object.assign(detail, nearbyChatText(range, view.lastLocation?.range));
        }
        post('selection', detail);
    });
    let start;
    doc.addEventListener('touchstart', event => {
        const point = event.touches.length === 1 ? event.touches[0] : null;
        start = point && { x:point.clientX, y:point.clientY };
    }, { passive:true });
    doc.addEventListener('touchmove', event => {
        const point = event.touches[0];
        if (!start || !point || Math.hypot(point.clientX - start.x, point.clientY - start.y) < 12) return;
        start = null;
        post('readingActivity');
    }, { passive:true });
}

function tap({ x, y }) {
    if (!view?.renderer || Date.now() - lastLinkActivation < 500) return;
    const point = { x:x * innerWidth, y:y * innerHeight };
    for (const content of view.renderer.getContents?.() ?? []) {
        const { doc } = content;
        if (doc.getSelection()?.isCollapsed === false) return;
        const frame = doc.defaultView.frameElement?.getBoundingClientRect();
        if (!frame?.width || !frame.height) continue;
        const localX = (point.x - frame.left) * doc.defaultView.innerWidth / frame.width;
        const localY = (point.y - frame.top) * doc.defaultView.innerHeight / frame.height;
        if (annotationLayer?.hit(content, { x: localX, y: localY })) return;
        if (doc.elementFromPoint(localX, localY)?.closest('a,button,input,select,textarea,audio,video,[role="button"]')) return;
    }
    if (!preferences.scrolling && (x < 0.3 || x > 0.7)) {
        post('readingActivity');
        command({ action:x < 0.3 ? 'previous' : 'next' });
    } else post('toggleControls');
}

function sanitize(doc) {
    doc.querySelectorAll('script,iframe,object,embed,form,base,meta[http-equiv],link[rel="import"]').forEach(el => el.remove());
    for (const el of doc.querySelectorAll('*')) {
        for (const attribute of [...el.attributes]) {
            if (attribute.name === 'data-leaf-reading-exclusion' || /^on/i.test(attribute.name) || /^(?:javascript|vbscript):/i.test(attribute.value.trim())) el.removeAttribute(attribute.name);
        }
    }
    return doc;
}

function markdown(source) {
    // A deliberately small, safe Markdown subset; HTML is always treated as text.
    const lines = source.replace(/\r\n?/g, '\n').split('\n');
    let code = false;
    return lines.map(line => {
        if (/^```/.test(line)) { code = !code; return code ? '<pre><code>' : '</code></pre>'; }
        if (code) return escapeHTML(line) + '\n';
        const safe = escapeHTML(line).replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>').replace(/`([^`]+)`/g, '<code>$1</code>');
        const heading = safe.match(/^(#{1,6})\s+(.+)/);
        if (heading) return `<h${heading[1].length}>${heading[2]}</h${heading[1].length}>`;
        if (/^&gt;\s?/.test(safe)) return `<blockquote>${safe.replace(/^&gt;\s?/, '')}</blockquote>`;
        if (/^[-*]\s/.test(safe)) return `<p>• ${safe.slice(2)}</p>`;
        return safe.trim() ? `<p>${safe}</p>` : '';
    }).join('\n') + (code ? '</code></pre>' : '');
}

async function simpleBook(file, format) {
    const text = await file.text();
    const title = file.name.replace(/\.[^.]+$/, '');
    const content = format === 'html' ? text : format === 'md' ? markdown(text)
        : text.replace(/\r\n?/g, '\n').split(/\n\s*\n/).map(p => `<p>${escapeHTML(p).replace(/\n/g, '<br>')}</p>`).join('\n');
    const doc = sanitize(new DOMParser().parseFromString(content, 'text/html'));
    const toc = [...doc.querySelectorAll('h1,h2,h3')].map((heading, index) => {
        heading.id ||= `heading-${index}`;
        return { label: heading.textContent.trim(), href: `text#${heading.id}` };
    });
    const html = '<!doctype html>' + doc.documentElement.outerHTML;
    let url;
    return {
        metadata: { title, language: 'en' },
        sections: [{ id: 'text', size: html.length, load: () => url ||= URL.createObjectURL(new Blob([html], {type:'text/html'})),
            unload: () => { if(url) URL.revokeObjectURL(url); url = null; },
            createDocument: async () => new DOMParser().parseFromString(html, 'text/html'), resolveHref: href => href }],
        toc: toc.length ? toc : [{ label: title, href: 'text' }],
        resolveHref: href => ({ index:0, anchor: document => document.getElementById(href.split('#')[1]) || document.body }),
        splitTOCHref: href => href.split('#'),
        getTOCFragment: (document, id) => document.getElementById(id) || document.body,
        destroy: () => { if(url) URL.revokeObjectURL(url); }
    };
}

function applyPreferences(value) {
    preferences = value;
    document.documentElement.style.background = value.background;
    document.body.style.background = value.background;
    if (!view?.renderer) return;
    // Pin reflow to text rather than a section percentage, which can move to a
    // different passage when font metrics or reading flow change.
    const anchor = view.lastLocation?.range?.cloneRange();
    if (anchor && !view.isFixedLayout) {
        anchor.collapse(true);
        view.renderer.scrollToAnchor(anchor);
    }
    view.renderer.toggleAttribute('animated', !value.scrolling && !reducedMotion.matches);
    if (view.isFixedLayout) { view.renderer.setAttribute('zoom', 'fit-page'); return; }
    const font = value.font === 'System' ? '-apple-system, sans-serif' : `"${value.font}", serif`;
    const bounded = (value, fallback, min, max) => Number.isFinite(Number(value))
        ? Math.min(max, Math.max(min, Number(value))) : fallback;
    const size = bounded(value.fontSize, 19, 12, 32);
    const line = bounded(value.lineHeight, 1.65, 1.1, 2.2);
    const horizontal = bounded(value.horizontalMargin ?? 20, 20, 8, 48);
    const vertical = bounded(value.verticalMargin ?? 12, 12, 0, 48);
    view.renderer.style.setProperty('--leaf-chapter-divider-color', value.accent ?? value.foreground);
    view.renderer.style.setProperty('--leaf-chapter-divider-inset', `${horizontal}px`);
    const paragraph = bounded(value.paragraphSpacing ?? 0.65, 0.65, 0, 1.5);
    const doc = view.renderer.getContents?.()[0]?.doc;
    const verticalText = doc && /^(vertical|sideways)/.test(doc.defaultView.getComputedStyle(doc.body).writingMode);
    const inlineSize = (verticalText ? view.clientHeight : view.clientWidth) || 390;
    // Foliate's gap is a percentage of the inline viewport; its margin and size
    // attributes are CSS lengths and must include units.
    const inlineMargin = verticalText ? vertical : horizontal;
    const gap = 100 * inlineMargin / (inlineSize + (value.scrolling ? inlineMargin : 0));
    const attribute = (name, value) => {
        if (view.renderer.getAttribute(name) !== value) view.renderer.setAttribute(name, value);
    };
    attribute('flow', value.scrolling ? 'scrolled' : 'paginated');
    attribute('margin', `${verticalText ? horizontal : vertical}px`);
    attribute('gap', `${gap}%`);
    attribute('max-inline-size', '680px');
    view.renderer.setStyles?.(`
        html { color-scheme: ${value.colorScheme ?? (value.background === '#17232E' ? 'dark' : 'light')}; font-size:${size}px !important;
            -webkit-text-size-adjust:none !important; text-size-adjust:none !important; }
        html, body { background:${value.background} !important; color:${value.foreground} !important; }
        body { font-family:${font} !important; font-size:1rem !important; padding:0 !important; }
        p, li, blockquote, dd { font-family:${font} !important; font-size:1rem !important; line-height:${line} !important;
            color:${value.foreground} !important; text-align:start; hyphens:auto; overflow-wrap:break-word; }
        p { margin-block:0 ${paragraph}em !important; }
        h1,h2,h3 { font-family:${font} !important; line-height:1.2; color:${value.foreground} !important; }
        pre { white-space:pre-wrap; font-size:0.85em; }
        a { color:${value.accent ?? (value.background === '#17232E' ? '#93CABB' : '#24776A')} !important; }
        img,svg { max-width:100%; }`);
}

function flattenTOC(items = [], depth = 0) {
    return items.flatMap(item => [
        ...(item.href != null ? [{ label: languageText(item.label) || 'Untitled section', href:String(item.href), depth }] : []),
        ...flattenTOC(item.subitems ?? item.children ?? [], depth + 1)
    ]);
}

async function rejectEncryptedMOBI(file) {
    const header = new DataView(await file.slice(0, 90).arrayBuffer());
    if (header.byteLength < 86) return;
    const record = header.getUint32(78);
    const palmdoc = new DataView(await file.slice(record, record + 16).arrayBuffer());
    if (palmdoc.byteLength >= 14 && palmdoc.getUint16(12) !== 0) throw new Error('This Kindle book is DRM-protected. Import a DRM-free copy.');
}

async function open(config) {
    try {
        close();
        const file = await openBookSource(config.name, config.format);
        if (['mobi','azw','azw3','prc'].includes(config.format)) await rejectEncryptedMOBI(file);
        const book = ['txt','md','html','rtf'].includes(config.format) ? await simpleBook(file, config.format) : await makeBook(file);
        if (!book.sections?.length) throw new Error('This book has no readable sections. Try another copy.');
        book.transformTarget?.addEventListener('data', ({ detail }) => {
            if (/html|xml|svg/.test(detail.type || '')) {
                const original = detail.data;
                detail.data = Promise.resolve(original).then(data => {
                    if (typeof data !== 'string') return data;
                    const type = /xhtml/.test(detail.type) ? 'application/xhtml+xml' : /svg/.test(detail.type) ? 'image/svg+xml' : 'text/html';
                    return new XMLSerializer().serializeToString(sanitize(new DOMParser().parseFromString(data, type)));
                });
            }
        });
        view = document.createElement('foliate-view');
        document.body.append(view);
        annotationLayer = createAnnotations(view, config.annotations, post);
        view.addEventListener('load', ({ detail }) => {
            if (!detail.preload) post('selection', {text:''});
            observeReadingTouches(detail.doc, detail.index);
            if (!detail.preload) requestAnimationFrame(() => { if (preferences) applyPreferences(preferences); });
        });
        view.addEventListener('link', () => { lastLinkActivation = Date.now(); });
        view.addEventListener('external-link', event => { lastLinkActivation = Date.now(); event.preventDefault(); });
        view.addEventListener('relocate', ({detail}) => {
            fixedIndex = detail.index ?? fixedIndex;
            const count = view.book.sections.length;
            const fraction = Number.isFinite(detail.fraction) ? detail.fraction : count > 1 ? fixedIndex / (count - 1) : 0;
            post('relocate', { locator:detail.cfi || `section:${fixedIndex}`, fraction,
                label:languageText(detail.tocItem?.label) || (view.isFixedLayout ? `Page ${fixedIndex + 1} of ${count}` : '') });
        });
        await view.open(book);
        view.renderer.setChapterDivider?.(doc => {
            const language = languageText(book.metadata?.language) || doc.documentElement.lang;
            return /^(?:zh|zho|chi|chinese)(?:[-_ ]|$)/i.test(language.trim()) ? '下一章' : 'Next Chapter';
        });
        let viewportStart;
        view.renderer.addEventListener('relocate', ({ detail }) => {
            const next = { index:detail.index, node:detail.range?.startContainer, offset:detail.range?.startOffset };
            const changed = viewportStart && (next.index !== viewportStart.index || next.node !== viewportStart.node || next.offset !== viewportStart.offset);
            viewportStart = next;
            if (changed && ['snap', 'page', 'scroll'].includes(detail.reason)) post('readingActivity');
        });
        applyPreferences(config.preferences);
        post('toc', { items:flattenTOC(book.toc) });
        post('metadata', { title:languageText(book.metadata?.title), author:contributor(book.metadata?.author) });
        const location = config.locator;
        if (location?.startsWith('section:')) await view.goTo(Number(location.slice(8)));
        else await view.init({ lastLocation: location || undefined, showTextStart:true });
        post('ready');
        // Cover extraction can fail independently of the text (for example an SVG cover).
        Promise.resolve(book.getCover?.()).then(blob => {
            if (!blob || blob.size > 8 * 1024 * 1024) return;
            const reader = new FileReader();
            reader.onload = () => post('metadata', { cover:reader.result.split(',')[1] });
            reader.readAsDataURL(blob);
        }).catch(() => {});
    } catch(error) { post('error', { message:readableError(error) }); }
}

function close() {
    selectedDocument = undefined;
    if (view) clearReadAloud(view);
    post('selection', {text:''});
    searchGeneration = null;
    annotationLayer = null;
    const previous = view;
    view = null;
    previous?.close();
    previous?.book?.destroy?.();
    previous?.remove();
}

function readableError(error) {
    const message = error?.message || String(error);
    return /encrypt|drm|password/i.test(message) ? 'This book is protected. Import a DRM-free copy, or unlock a password-protected PDF in the PDF reader.'
        : `${message} If this file is incomplete or unsupported, download a fresh DRM-free copy and import it again.`;
}

async function command({action, value}) {
    try {
        if (!view) return;
        if (action === 'next') await view.goRight();
        if (action === 'previous') await view.goLeft();
        if (action === 'navigate') {
            if (value.startsWith('section:')) await view.goTo(Number(value.slice(8)));
            else await view.goTo(value);
        }
        if (action === 'seek') {
            if (view.isFixedLayout) await view.goTo(Math.round(value * (view.book.sections.length - 1)));
            else await view.goToFraction(Math.min(0.99999, Math.max(0, value)));
        }
        if (action === 'clearSearch') { searchGeneration = null; view.clearSearch(); }
    } catch(error) { post('error', {message:readableError(error)}); }
}

async function search({query, generation}) {
    searchGeneration = generation;
    const items = [];
    try {
        if (view.isFixedLayout && !view.book.sections.some(section => section.createDocument)) {
            post('searchResults', {generation, items}); return;
        }
        for await (const result of view.search({query, matchCase:false})) {
            if (generation !== searchGeneration) return;
            for (const item of result.subitems ?? (result.cfi ? [result] : [])) {
                const excerpt = item.excerpt;
                items.push({locator:item.cfi, label:languageText(result.label) || 'Matching passage',
                    excerpt: typeof excerpt === 'string' ? excerpt : `${excerpt?.pre || ''}${excerpt?.match || ''}${excerpt?.post || ''}`});
                if (items.length >= 200) break;
            }
            if (items.length >= 200) break;
        }
        if (generation === searchGeneration) post('searchResults', {generation, items});
    } catch(error) { post('searchResults', {generation, items}); }
}

window.Leaf = { open, close, command, applyPreferences, search, tap,
    recallBook: async ({term, locator, id, selection}) => {
        const source=view; chatRecallID=id;
        return retrieveEarlierPassages(source,term,locator,{selection,prepare:sanitize,cancelled:()=>view!==source || chatRecallID!==id});
    },
    cancelRecall: ({id}) => { if (chatRecallID===id) chatRecallID=null; },
    setSpokenRange: config => setSpokenRange(view, config),
    clearSpokenRange: () => { if (view) clearSpokenRange(view); },
    readAloudChunk: ({ locator }) => readAloudChunk(view, locator, sanitize),
    revealReadAloud: ({ locator }) => revealReadAloud(view, locator),
    clearReadAloud: () => { if (view) clearReadAloud(view); },
    setAnnotations: ({ items }) => annotationLayer?.set(items),
    clearSelection: () => {
        for (const {doc} of view?.renderer?.getContents?.() ?? []) doc?.getSelection()?.removeAllRanges();
        post('selection', {text:''});
    },
    chatContext: () => {
        const contents = view?.renderer?.getContents?.() ?? [];
        const owner = selectedDocument?.deref();
        const current = selectedDocument
            ? contents.find(({doc}) => doc === owner)
            : contents.find(({doc}) => doc?.hasFocus() && !doc.getSelection()?.isCollapsed)
                ?? contents.find(({doc}) => doc?.getSelection()?.isCollapsed === false);
        for (const {doc, index} of current ? [current] : []) {
            const selection = doc?.getSelection();
            if (selection && !selection.isCollapsed && selection.toString().trim()) {
                const range = textBoundedSelection(selection.getRangeAt(0));
                return {text: selection.toString().slice(0, 24000), source: 'selection',
                    locator:view.getCFI(index, range), label:languageText(view.getProgressOf(index, range).tocItem?.label),
                    ...nearbyChatText(range, view.lastLocation?.range)};
            }
        }
        // visibleText() below is a diagnostic for the whole loaded document.
        // Chat must use only the visible range, never the entire chapter.
        const range = view?.lastLocation?.range;
        return {text: range?.toString().slice(0, 24000) ?? '', source: 'page', ...nearbyChatText(range)};
    },
    // Useful to test the actual rendered document, rather than only parser metadata.
    visibleText: () => view?.renderer?.getContents?.().map(({doc}) => doc?.body?.innerText || '').join('\n') || '',
    currentLocation: () => view?.lastLocation?.cfi,
    isLocationVisible: locator => {
        try {
            const target = view.resolveCFI(locator);
            const doc = view.renderer.getContents().find(item => item.index === target.index)?.doc;
            const saved = doc && target.anchor(doc);
            const visible = view.lastLocation?.range;
            return Boolean(saved && visible && visible.comparePoint(saved.startContainer, saved.startOffset) === 0);
        } catch { return false; }
    },
    bookSectionCount: () => view?.book?.sections.length || 0 };
window.addEventListener('resize', () => { if (preferences) applyPreferences(preferences); });
post('bridgeReady');
