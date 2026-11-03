/*
 * Pictures a document refers to by a relative path (BUG-061).
 *
 * The editor page cannot read files, so the app serves them at `markview-doc:///<absolute path>`
 * (DocumentFileSchemeHandler). The page rewrites the address of a picture only after the document is
 * rendered; the text of the document is never changed. The path the author wrote is kept in a data
 * attribute and put back when the rendered page is turned into Markdown again (WYSIWYG edit).
 *
 * The functions that take no page are pure, so tools/tests/document-files-tests.sh runs them under node.
 */
(function (root) {
    'use strict';

    const SCHEME = 'markview-doc';
    // An anchor, or an address with a scheme of its own (http, data, blob, mailto): the page can load it as written.
    const SELF_CONTAINED = /^(?:#|[a-z][a-z0-9+.-]*:)/i;

    /**
     * The `markview-doc:` address of the picture a document refers to as `src`, or null when the
     * address is not a local file (http, data, an anchor, a protocol-relative URL) and stays as written.
     * `baseURL` is the `file://` address of the document's folder.
     */
    function pictureURL(src, baseURL) {
        if (!src || !baseURL) return null;
        const written = String(src).trim();
        if (!written || (SELF_CONTAINED.test(written) && !/^file:/i.test(written))) return null;
        let file;
        try { file = new URL(written, baseURL); } catch (e) { return null; }
        if (file.protocol !== 'file:' || file.host) return null;
        return SCHEME + '://' + file.pathname;
    }

    /** The same for a `srcset` value: every candidate keeps its descriptor ("2x", "480w"). Null when nothing changes. */
    function pictureSrcset(value, baseURL) {
        if (!value || /data:/i.test(value)) return null;
        let changed = false;
        const candidates = String(value).split(',').map(function (candidate) {
            const parts = candidate.trim().split(/\s+/);
            const resolved = pictureURL(parts[0], baseURL);
            if (!resolved) return candidate.trim();
            changed = true;
            return [resolved].concat(parts.slice(1)).join(' ');
        });
        return changed ? candidates.join(', ') : null;
    }

    /** `html` with the author's own paths back in place of the addresses the page rewrote. */
    function withOriginalPaths(html) {
        const holder = document.createElement('div');
        holder.innerHTML = html;
        [['src', 'data-mv-src'], ['srcset', 'data-mv-srcset'], ['href', 'data-mv-href']].forEach(function (pair) {
            holder.querySelectorAll('[' + pair[1] + ']').forEach(function (element) {
                element.setAttribute(pair[0], element.getAttribute(pair[1]));
                element.removeAttribute(pair[1]);
            });
        });
        return holder.innerHTML;
    }

    /** Rewrites the pictures of a rendered document to their `markview-doc:` addresses, remembering what the author wrote. */
    function resolvePictures(container, baseURL) {
        if (!baseURL) return;
        container.querySelectorAll('img[src]').forEach(function (img) {
            const written = img.getAttribute('src');
            const resolved = pictureURL(written, baseURL);
            if (!resolved) return;
            img.setAttribute('data-mv-src', written);
            img.setAttribute('src', resolved);
        });
        container.querySelectorAll('img[srcset], source[srcset]').forEach(function (element) {
            const written = element.getAttribute('srcset');
            const resolved = pictureSrcset(written, baseURL);
            if (!resolved) return;
            element.setAttribute('data-mv-srcset', written);
            element.setAttribute('srcset', resolved);
        });
    }

    const api = { pictureURL: pictureURL, pictureSrcset: pictureSrcset, withOriginalPaths: withOriginalPaths, resolvePictures: resolvePictures };
    if (typeof module !== 'undefined' && module.exports) module.exports = api;
    root.MarkViewDocumentFiles = api;
})(typeof window !== 'undefined' ? window : globalThis);
