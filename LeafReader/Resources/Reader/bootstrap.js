const report = event => {
    const message = event.reason?.message || event.message || 'The reader could not load this book.';
    // WebKit defers these layout notifications to the next frame. They do not
    // mean that parsing or opening the book failed.
    if (!event.error && /^ResizeObserver loop (completed with undelivered notifications|limit exceeded)\.?$/.test(message)) return;
    window.webkit?.messageHandlers.leaf.postMessage({type: 'error', message});
};
window.addEventListener('error', report);
window.addEventListener('unhandledrejection', report);
