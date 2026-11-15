/* Markdown parser setup for book export; externalized so book.html keeps script-src 'self'. */
var md = markdownit({ html: true, linkify: true, typographer: false });
md.use(markdownitFootnote);
md.use(markdownitTaskLists);
