import {languageText} from './metadata-text.js';
const recallCache = new WeakMap();

// On-demand, read-only lookup. Each detached chapter is discarded before the
// next one; only six short excerpts survive. Reader search/annotations are untouched.
export async function retrieveEarlierPassages(view, term, locator, options = {}) {
    const maxSections = Math.min(512, options.maxSections ?? 512);
    const deadline = performance.now() + Math.min(8000, options.timeout ?? 8000);
    const result = {term, excerpts: [], scannedSections: 0, totalSections: 0, complete: false};
    if (!view || term.length < 2 || term.length > 40) return result;
    if (options.cancelled?.()) return result;
    const key=JSON.stringify([term,locator,!!options.selection]);
    const cacheable=options.maxSections==null && options.timeout==null;
    if (cacheable && recallCache.get(view)?.has(key)) return recallCache.get(view).get(key);
    let boundary;
    try { boundary = view.resolveCFI(locator); } catch { return result; }
    if (!Number.isInteger(boundary?.index) || boundary.index < 0 || boundary.index >= view.book.sections.length) return result;
    const eligible = view.book.sections.map((section, index) => ({section,index}))
        .filter(({section,index}) => index <= boundary.index && section.linear !== 'no' && section.createDocument);
    result.totalSections = eligible.length;
    // Find introductions and recent appearances first, then fill the middle.
    const order = [...eligible.slice(0,32), ...eligible.slice(-96).reverse(), ...eligible];
    const visited = new Set(), hits = [];
    let partial = false, bytes = 0;
    for (const {section,index} of order) {
        if (visited.has(index)) continue;
        if (options.cancelled?.() || performance.now() >= deadline || visited.size >= maxSections) break;
        visited.add(index);
        if (section.size > 1048576 || bytes + (section.size || 500000) > 8388608) { partial=true; continue; }
        bytes += section.size || 500000;
        let timer;
        try {
            let doc = await Promise.race([section.createDocument(), new Promise((_,reject) => {
                timer = setTimeout(() => reject(new Error('Lookup deadline')), Math.max(1,deadline-performance.now()));
            })]);
            clearTimeout(timer);
            if (options.cancelled?.()) break;
            if (options.prepare) doc=options.prepare(doc);
            const end = index === boundary.index ? boundary.anchor?.(doc) : null;
            if (end?.collapse && options.selection) end.collapse(true);
            if (index === boundary.index && (!end?.endContainer || end.endContainer.ownerDocument !== doc)) { partial = true; continue; }
            const walker = doc.createTreeWalker(doc.body ?? doc.documentElement, 4), chunks = [];
            let node, length = 0, nodes = 0;
            while ((node=walker.nextNode())) {
                if (++nodes > 20000 || length >= 250000) { partial=true; break; }
                if (node.parentElement?.closest('script,style,nav,[hidden],[aria-hidden="true"]')) continue;
                if (end && end.comparePoint(node,0)>0) break;
                const stop = end?.endContainer === node ? end.endOffset : node.length;
                if (stop > 250000-length) partial=true;
                const value = node.data.slice(0,Math.min(stop,250000-length));
                chunks.push(value); length += value.length;
                if (end?.endContainer === node) break;
            }
            const text=chunks.join(''), folded=text.toLocaleLowerCase(), needle=term.toLocaleLowerCase();
            let offset=-1, matches=0;
            while ((offset=folded.indexOf(needle,offset+1))>=0 && matches++<200) {
                const first=Math.max(0,offset-170), last=Math.min(text.length,first+500);
                const excerpt={index,offset,chapter:languageText(view.getProgressOf(index)?.tocItem?.label) || `Section ${index+1}`,text:text.slice(first,last)};
                if (hits.some(hit => hit.index===index && Math.abs(hit.offset-offset)<180)) continue;
                hits.push(excerpt); hits.sort((a,b)=>a.index-b.index || a.offset-b.offset);
                if (hits.length>6) hits.splice(1,hits.length-6);
            }
            if (matches >= 200) partial=true;
            doc=null;
            result.scannedSections++;
        } catch { partial=true; }
        finally { clearTimeout(timer); }
        // Let typing, page gestures and cancellation run between detached chapters.
        await new Promise(resolve=>setTimeout(resolve,0));
    }
    result.excerpts=hits.map(({chapter,text})=>({chapter,text}));
    result.complete=!partial && result.scannedSections===eligible.length;
    if (result.complete && cacheable) {
        const cache=recallCache.get(view) ?? new Map();cache.set(key,result);
        if (cache.size>4) cache.delete(cache.keys().next().value);
        recallCache.set(view,cache);
    }
    return result;
}
