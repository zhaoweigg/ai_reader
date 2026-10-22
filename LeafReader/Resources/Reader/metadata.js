import { makeBook } from './foliate/view.js';
import { openBookSource } from './book-source.js';

const post = value => window.webkit.messageHandlers.leafMetadata.postMessage(value);
const languageText = value => typeof value === 'string' ? value : value ? languageText(Object.values(value)[0]) : '';
const contributor = value => Array.isArray(value) ? value.map(contributor).filter(Boolean).join(', ')
    : typeof value === 'string' ? value : languageText(value?.name);

async function coverPNG(blob) {
    if (!blob || blob.size > 8 * 1024 * 1024) return null;
    const url = URL.createObjectURL(blob);
    try {
        const image = new Image();
        image.src = url;
        await image.decode();
        const scale = Math.min(1, 600 / Math.max(image.naturalWidth, image.naturalHeight));
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(image.naturalWidth * scale));
        canvas.height = Math.max(1, Math.round(image.naturalHeight * scale));
        canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height);
        return canvas.toDataURL('image/png').split(',')[1];
    } finally { URL.revokeObjectURL(url); }
}

async function embeddedCover(book) {
    try {
        const cover = await coverPNG(await book.getCover?.());
        if (cover) return cover;
    } catch { }
    // Older EPUBs may identify an XHTML cover page instead of the image itself.
    const resources = book.resources;
    const candidates = [resources?.cover, ...(resources?.manifest ?? [])
        .filter(item => item.mediaType?.startsWith('image/') && /cover/i.test(item.id + item.href))].filter(Boolean);
    for (const item of candidates) {
        try {
            if (item.mediaType?.startsWith('image/')) {
                const cover = await coverPNG(new Blob([await book.loadBlob(item.href)], {type: item.mediaType}));
                if (cover) return cover;
            } else if (/html|xml/.test(item.mediaType)) {
                const doc = await book.loadDocument(item);
                for (const image of doc.querySelectorAll('img[src], image')) {
                    const src = image.getAttribute('src') || image.getAttribute('href')
                        || image.getAttributeNS('http://www.w3.org/1999/xlink', 'href');
                    if (!src) continue;
                    let blob;
                    if (/^(data|blob):/.test(src)) blob = await (await fetch(src)).blob();
                    else {
                        const url = new URL(src, 'https://book.invalid/' + item.href);
                        if (url.origin !== 'https://book.invalid') continue;
                        const path = decodeURI(url.pathname.slice(1));
                        const imageItem = resources.getItemByHref(path);
                        blob = new Blob([await book.loadBlob(path)], {type: imageItem?.mediaType || ''});
                    }
                    const cover = await coverPNG(blob);
                    if (cover) return cover;
                }
            }
        } catch { }
    }
    return null;
}

let book;
try {
    const config = new URLSearchParams(location.search);
    book = await makeBook(await openBookSource(config.get('name'), config.get('format')));
    // A missing or unsupported cover must not prevent metadata or import.
    let cover = null;
    try { cover = await embeddedCover(book); } catch { }
    post({type: 'metadata', title: config.get('format') === 'cbz' ? null : languageText(book.metadata?.title),
        author: contributor(book.metadata?.author), cover});
} catch { post({type: 'error'}); }
finally { book?.destroy?.(); }
