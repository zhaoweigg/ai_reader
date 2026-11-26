// The theme owns the page background, but a nested span can still use an EPUB's
// print ink. Repair unreadable text in mounted chapters without rewriting markup.
const chapterColors = new WeakMap();
const textFill = '-webkit-text-fill-color';
const minimumContrast = 4.5;

const composite = ([red, green, blue, alpha], background) =>
    [red, green, blue].map((component, index) => component * alpha + background[index] * (1 - alpha));

function luminance(color) {
    const [red, green, blue] = color.map(component =>
        component <= 0.04045 ? component / 12.92 : ((component + 0.055) / 1.055) ** 2.4);
    return red * 0.2126 + green * 0.7152 + blue * 0.0722;
}

function contrast(ink, backdrop) {
    const foreground = luminance(composite(ink, backdrop));
    const background = luminance(backdrop);
    return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
}

function colorReader(doc) {
    const canvas = doc.createElementNS('http://www.w3.org/1999/xhtml', 'canvas');
    canvas.width = canvas.height = 1;
    const context = canvas.getContext('2d', { willReadFrequently:true });
    if (!context) return null;
    const colors = new Map();
    return value => {
        if (!colors.has(value)) {
            context.clearRect(0, 0, 1, 1);
            context.fillStyle = value;
            context.fillRect(0, 0, 1, 1);
            colors.set(value, Array.from(context.getImageData(0, 0, 1, 1).data, channel => channel / 255));
        }
        return colors.get(value);
    };
}

export function applyChapterContrast(doc, { colorScheme, background, foreground, accent }) {
    if (!doc?.body) return;
    const key = colorScheme === 'dark' ? `${background} ${foreground} ${accent}` : null;
    const previous = chapterColors.get(doc);
    if (previous?.key === key || (!key && !previous)) return;
    previous?.restore();
    chapterColors.delete(doc);
    if (!key) return;

    const color = colorReader(doc);
    if (!color) return;
    const page = color(background).slice(0, 3);
    const backgrounds = new WeakMap([[doc.documentElement, page]]);
    const styles = new WeakMap();
    const styleOf = element => {
        if (!styles.has(element)) styles.set(element, doc.defaultView.getComputedStyle(element));
        return styles.get(element);
    };
    const backdropFor = element => {
        if (!backgrounds.has(element)) {
            const style = styleOf(element);
            const parent = backdropFor(element.parentElement);
            // A background image or gradient has no single measurable color.
            const backdrop = parent && style.display !== 'none' && style.backgroundImage === 'none'
                ? composite(color(style.backgroundColor), parent) : null;
            backgrounds.set(element, backdrop);
        }
        return backgrounds.get(element);
    };

    const checked = new Set();
    const inkByElement = new Map();
    const repairs = new Map();
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        const element = node.parentElement;
        if (!element || checked.has(element) || !node.data.trim()) continue;
        checked.add(element);
        if (element.closest('svg, math, script, style, select, textarea, audio, video')) continue;
        const style = styleOf(element);
        const authored = style.getPropertyValue(textFill);
        const ink = !authored || authored === 'currentcolor' ? style.color : authored;
        inkByElement.set(element, ink);
        const backdrop = backdropFor(element);
        if (!backdrop || color(ink)[3] === 0 ||
            contrast(color(ink), backdrop) >= minimumContrast) continue;
        const preferred = accent && element.closest('a') ? accent : foreground;
        const fallback = contrast(color('#fff'), backdrop) >= contrast(color('#000'), backdrop) ? '#fff' : '#000';
        repairs.set(element, contrast(color(preferred), backdrop) >= minimumContrast ? preferred : fallback);
    }

    const restored = [];
    for (const [element, ink] of inkByElement) {
        let parent = element.parentElement;
        while (parent && !repairs.has(parent)) parent = parent.parentElement;
        // Explicitly preserve the ink of nested text that would inherit our repair.
        if (!repairs.has(element) && !parent) continue;
        const value = element.style.getPropertyValue(textFill);
        const priority = element.style.getPropertyPriority(textFill);
        const hadStyle = element.hasAttribute('style');
        restored.push(() => {
            if (value) element.style.setProperty(textFill, value, priority);
            else element.style.removeProperty(textFill);
            if (!hadStyle && !element.style.length) element.removeAttribute('style');
        });
        element.style.setProperty(textFill, repairs.get(element) ?? ink, 'important');
    }
    chapterColors.set(doc, { key, restore: () => restored.forEach(restore => restore()) });
}
