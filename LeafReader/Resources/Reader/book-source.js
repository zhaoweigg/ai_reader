// A ZIP-backed book only needs its directory and the current entries. Keep the
// archive on disk instead of copying it into a permanent WebKit Blob.
const bookURL = 'leaf-reader://reader/book';
const chunkSize = 256 * 1024;
class DiskSlice {
    constructor(name, total, start = 0, end = total) {
        Object.assign(this, {name, total, start, end, size:end - start, type:''});
    }
    slice(start = 0, end = this.size) {
        const clamp = value => Math.min(this.size, Math.max(0, value < 0 ? this.size + value : value));
        const first = clamp(start), last = Math.max(first, clamp(end));
        return new DiskSlice(this.name, this.total, this.start + first, this.start + last);
    }
    async arrayBuffer() {
        const output = new Uint8Array(this.size);
        for (let offset = 0; offset < this.size; offset += chunkSize) {
            const length = Math.min(chunkSize, this.size - offset);
            const first = this.start + offset, last = first + length - 1;
            const response = await fetch(bookURL, {headers:{Range:`bytes=${first}-${last}`}});
            if (response.status !== 206 || response.headers.get('Content-Range') !== `bytes ${first}-${last}/${this.total}`)
                throw new Error('The book could not be read from disk.');
            const data = await response.arrayBuffer();
            if (data.byteLength !== length) throw new Error('The book file is incomplete.');
            output.set(new Uint8Array(data), offset);
        }
        return output.buffer;
    }
}
export async function openBookSource(name, format) {
    if (['epub', 'cbz', 'fbz'].includes(format)) {
        const response = await fetch(bookURL, {method:'HEAD'});
        const size = Number(response.headers.get('Content-Length'));
        if (!response.ok || !Number.isSafeInteger(size) || size <= 0)
            throw new Error('The book file could not be read.');
        return new DiskSlice(name, size);
    }
    const response = await fetch(bookURL);
    if (!response.ok) throw new Error('The book file could not be read.');
    return new File([await response.blob()], name);
}
