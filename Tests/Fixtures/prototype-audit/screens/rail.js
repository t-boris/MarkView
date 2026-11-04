// A widget whose root is an <aside> (BUG-064): inside <main> it is the screen's content, not the shell's chrome.
App.register({ id: 'rail', route: '/rail', render: function () {
  return '<aside aria-label="Notes"><h2>Notes</h2><p>No notes yet.</p></aside>';
} });
