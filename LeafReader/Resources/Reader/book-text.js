import {languageText} from './metadata-text.js';

// Plain text for the on-device chat index. Reads a detached copy of one section;
// the rendered chapter, selection and viewport are untouched. Section text and
// reading boundaries use the same walk, so offsets agree.
const BLOCKS = new Set(['P', 'DIV', 'LI', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'BLOCKQUOTE', 'TR', 'SECTION',
    'ARTICLE', 'PRE', 'DT', 'DD', 'FIGCAPTION', 'TD', 'TH', 'BR', 'HR', 'TABLE', 'UL', 'OL']);
const LIMIT = 400000;

function walk(doc, end) {
    const root = doc?.body ?? doc?.documentElement;
    if (!root) return {text: '', offset: 0};
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
        acceptNode: node => node.nodeType === 1 && node.matches('script,style,nav,[hidden],[aria-hidden="true"]')
            ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
    });
    let text = '', offset = null, node;
    while ((node = walker.nextNode()) && text.length < LIMIT) {
        if (node.nodeType === 1) {
            if (BLOCKS.has(node.tagName.toUpperCase()) && text && !text.endsWith('\n')) text += '\n';
            continue;
        }
        if (end && offset === null) {
            if (end.comparePoint(node, 0) > 0) offset = text.length;
            else if (end.endContainer === node) offset = text.length + end.endOffset;
        }
        text += node.data;
    }
    return {text: text.slice(0, LIMIT), offset: Math.min(offset ?? text.length, LIMIT)};
}

async function detached(section, prepare) {
    let doc = null;
    if (section?.createDocument) doc = await section.createDocument();
    else if (section?.load) {
        const url = await section.load();
        doc = new DOMParser().parseFromString(await (await fetch(url)).text(), 'text/html');
    }
    return doc && prepare ? prepare(doc) : doc;
}

export async function sectionText(view, index, prepare) {
    const section = view?.book?.sections?.[index];
    if (!section) throw new Error('No such section');
    const label = languageText(view.getProgressOf?.(index)?.tocItem?.label) || '';
    if (section.linear === 'no') return {label, text: ''};
    return {label, text: walk(await detached(section, prepare)).text};
}

// The reader's position: everything up to the end of the visible page or selection.
export async function textBoundary(view, locator, prepare) {
    const target = view.resolveCFI(locator);
    const index = target?.index;
    if (!Number.isInteger(index)) return null;
    const doc = await detached(view.book.sections[index], prepare);
    let range = null;
    try { range = target.anchor?.(doc); } catch {}
    // An unresolvable anchor excludes the whole current section, never reveals it.
    if (!range?.endContainer || range.endContainer.ownerDocument !== doc) return {section: index, offset: 0};
    return {section: index, offset: walk(doc, range).offset};
}
