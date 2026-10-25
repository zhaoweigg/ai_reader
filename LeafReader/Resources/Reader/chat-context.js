// Read bounded neighbors from the already loaded document. Never load chapters,
// serialize the whole body, change selection, or move the reading viewport.
export function nearbyChatText(range, visibleRange) {
    if (!range) return {};
    const doc = range.startContainer.ownerDocument;
    const allowed = node => !node.parentElement?.closest('script,style,nav,[hidden],[aria-hidden="true"]');
    const walk = (node, offset, backwards, limit, boundary) => {
        if (node.nodeType !== 3 || !doc.body?.contains(node)) return '';
        const walker = doc.createTreeWalker(doc.body, 4);
        walker.currentNode = node;
        let result = '', count = 0;
        while (node && result.length < limit && count++ < 2048) {
            let start = backwards ? 0 : offset, end = backwards ? offset : node.length;
            if (boundary) {
                if (boundary.endContainer === node) end = Math.min(end, boundary.endOffset);
                else if (boundary.comparePoint(node, 0) > 0) break;
            }
            if (allowed(node) && end > start) {
                const text = backwards ? node.data.slice(Math.max(start, end - (limit - result.length)), end)
                    : node.data.slice(start, Math.min(end, start + limit - result.length));
                result = backwards ? text + result : result + text;
            }
            if (boundary?.endContainer === node) break;
            node = backwards ? walker.previousNode() : walker.nextNode();
            offset = backwards ? node?.length ?? 0 : 0;
        }
        return result;
    };
    // Capture up to the largest limits in AI settings; each request trims to the reader's choice.
    const precedingText = walk(range.startContainer, range.startOffset, true, 8000);
    // Only text after a selection which is already inside the visible range may
    // follow it. Ordinary page context never reads ahead of the visible endpoint.
    let followingText = '';
    if (visibleRange?.startContainer.ownerDocument === doc &&
        visibleRange.isPointInRange(range.endContainer, range.endOffset)) {
        followingText = walk(range.endContainer, range.endOffset, false, 4000, visibleRange);
    }
    return {precedingText, followingText};
}
