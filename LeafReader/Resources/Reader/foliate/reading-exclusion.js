// Layout-only floats. Their empty nodes are excluded from EPUB CFI indexing, so
// splitting a text node at a column boundary never changes a saved locator.
export const exclusionAttribute = 'data-leaf-reading-exclusion';
export function clearReadingExclusion(doc) {
    const markers = doc.querySelectorAll(`[${exclusionAttribute}]`);
    if (!markers.length) return;
    for (const marker of markers) marker.remove();
    doc.body.normalize();
}

export function applyReadingExclusion(doc, { exclusion, width, height, gap, columnWidth }, rtl, vertical) {
    if (!exclusion || rtl || vertical) return;
    const radius = exclusion.width / 2 + 6;
    const centerY = exclusion.y + exclusion.height / 2;
    if (centerY + radius > height || centerY - radius < 0) return;
    const stride = columnWidth + gap;
    const columns = Math.max(1, Math.round(width / stride));
    const targetColumn = Math.min(columns - 1, Math.max(0, Math.floor(exclusion.x / stride)));
    const rightInset = targetColumn * stride + gap / 2 + columnWidth - exclusion.x - exclusion.width / 2;
    const floatWidth = radius + rightInset;
    if (floatWidth <= 0) return; // The icon is already outside the text column.
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode: node => node.textContent.trim() && !node.parentElement.closest('script,style,svg,math')
            ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
    });
    const nodes = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node);
    const range = doc.createRange();
    let cursor = 0;
    // Only the loaded chapter is touched. Walk its text in order rather than
    // rescanning the whole document for every page.
    for (let column = targetColumn; cursor < nodes.length; column += columns) {
        const left = column * stride + gap / 2;
        const right = left + columnWidth;
        let node, offset = 0, rect;
        while (cursor < nodes.length) {
            node = nodes[cursor];
            range.selectNodeContents(node);
            const rects = [...range.getClientRects()];
            if (!rects.some(r => r.right > left + 0.5 && r.left < right - 0.5)) {
                if (rects.some(r => r.left >= right)) break;
                cursor++; continue;
            }
            let lo = 0, hi = node.length;
            while (lo < hi) {
                const mid = Math.floor((lo + hi) / 2);
                range.setStart(node, mid); range.setEnd(node, mid + 1);
                if (range.getBoundingClientRect().right <= left + 0.5) lo = mid + 1;
                else hi = mid;
            }
            offset = lo;
            if (offset >= node.length) { cursor++; continue; }
            range.setStart(node, offset); range.setEnd(node, offset + 1);
            rect = range.getBoundingClientRect();
            break;
        }
        if (!rect) {
            if (cursor >= nodes.length) break;
            continue;
        }
        if (rect.top > centerY + radius) continue;
        const marker = doc.createElement('span');
        marker.setAttribute(exclusionAttribute, '');
        marker.setAttribute('aria-hidden', 'true');
        const floatHeight = centerY + radius - Math.max(0, rect.top);
        marker.style.cssText = `float:right !important;display:block !important;width:${floatWidth}px !important;
            height:${floatHeight}px !important;shape-outside:circle(${radius}px at ${radius}px ${floatHeight - radius}px) !important;
            margin:0 !important;padding:0 !important;border:0 !important;pointer-events:none !important;`;
        range.collapse(true);
        range.insertNode(marker);
        // A glyph's top differs from its line box (especially at large sizes).
        // Align the circle to the actual float box, not the font's glyph bounds.
        const placed = marker.getBoundingClientRect();
        const cx = column * stride + gap / 2 + columnWidth - rightInset - placed.left;
        const cy = centerY - placed.top;
        marker.style.setProperty('height', `${cy + radius}px`, 'important');
        marker.style.setProperty('shape-outside', `circle(${radius}px at ${cx}px ${cy}px)`, 'important');
        // Range insertion leaves a new tail. Keep it in the ordered walk.
        if (marker.nextSibling?.nodeType === Node.TEXT_NODE) nodes.splice(cursor + 1, 0, marker.nextSibling);
        cursor++;
    }
}

// A single viewport-following circle in continuous flow. The rest of the
// chapter keeps its normal width; there is no full-height side rail.
export function applyScrollExclusion(doc, circle) {
    let marker = doc.querySelector(`[${exclusionAttribute}]`);
    const body = doc.body.getBoundingClientRect();
    const radius = circle.radius;
    const width = body.right - circle.x + radius;
    if (width <= 0 || circle.y + radius <= body.top) {
        marker?.remove(); return false;
    }
    if (!marker) {
        marker = doc.createElement('span');
        marker.setAttribute(exclusionAttribute, '');
        marker.setAttribute('aria-hidden', 'true');
        doc.body.prepend(marker);
    }
    const height = circle.y + radius - body.top;
    const style = `float:right !important;display:block !important;width:${width}px !important;
        height:${height}px !important;shape-outside:circle(${radius}px at ${radius}px ${height - radius}px) !important;
        margin:0 !important;padding:0 !important;border:0 !important;pointer-events:none !important;`;
    if (marker.getAttribute('style') === style) return false;
    marker.setAttribute('style', style);
    return true;
}
