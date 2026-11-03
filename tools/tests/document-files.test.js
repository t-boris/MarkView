// Standalone check of the page side of BUG-061: how a document's relative picture paths become markview-doc: addresses.
// Run with tools/tests/document-files-tests.sh (node, no packages).
'use strict';
const assert = require('node:assert');
const { pictureURL, pictureSrcset } = require('../../MarkView/Resources/Editor/vendor/js/markview-document-files.js');

const base = 'file:///Users/boris/my%20project/docs/';
let failures = 0;
function check(name, actual, expected) {
    try { assert.strictEqual(actual, expected); console.log('ok   ' + name); }
    catch (e) { failures++; console.log('FAIL ' + name + ' got ' + JSON.stringify(actual) + ' want ' + JSON.stringify(expected)); }
}

check('a relative path', pictureURL('images/a.png', base), 'markview-doc:///Users/boris/my%20project/docs/images/a.png');
check('dot-slash', pictureURL('./images/a.png', base), 'markview-doc:///Users/boris/my%20project/docs/images/a.png');
check('parent folder', pictureURL('../shots/a.png', base), 'markview-doc:///Users/boris/my%20project/shots/a.png');
check('a space written as %20', pictureURL('images/file%20tree.png', base), 'markview-doc:///Users/boris/my%20project/docs/images/file%20tree.png');
check('a space written as itself', pictureURL('images/file tree.png', base), 'markview-doc:///Users/boris/my%20project/docs/images/file%20tree.png');
check('a non-ASCII name', pictureURL('картинка.png', base), 'markview-doc:///Users/boris/my%20project/docs/%D0%BA%D0%B0%D1%80%D1%82%D0%B8%D0%BD%D0%BA%D0%B0.png');
check('a query is dropped', pictureURL('a.png?raw=true', base), 'markview-doc:///Users/boris/my%20project/docs/a.png');
check('an absolute file URL', pictureURL('file:///Users/boris/my%20project/x.png', base), 'markview-doc:///Users/boris/my%20project/x.png');
check('surrounding spaces', pictureURL('  a.png ', base), 'markview-doc:///Users/boris/my%20project/docs/a.png');

check('https stays', pictureURL('https://img.shields.io/a.svg', base), null);
check('http stays', pictureURL('http://example.com/a.png', base), null);
check('a data URI stays', pictureURL('data:image/png;base64,AAAA', base), null);
check('a blob stays', pictureURL('blob:abc', base), null);
check('an anchor stays', pictureURL('#top', base), null);
check('a protocol-relative URL stays', pictureURL('//cdn.example.com/a.png', base), null);
check('a markview-doc address stays', pictureURL('markview-doc:///a.png', base), null);
check('empty stays', pictureURL('', base), null);
check('no base, no address', pictureURL('a.png', null), null);

check('a srcset keeps its descriptors',
      pictureSrcset('a.png 1x, b.png 2x', base),
      'markview-doc:///Users/boris/my%20project/docs/a.png 1x, markview-doc:///Users/boris/my%20project/docs/b.png 2x');
check('a srcset of widths', pictureSrcset('small.png 480w, big.png 800w', base),
      'markview-doc:///Users/boris/my%20project/docs/small.png 480w, markview-doc:///Users/boris/my%20project/docs/big.png 800w');
check('a srcset with a web address is left alone', pictureSrcset('https://x.test/a.png 1x', base), null);
check('a srcset with inline data is left alone', pictureSrcset('data:image/png;base64,AAAA 1x', base), null);
check('a mixed srcset changes only the local candidate', pictureSrcset('a.png 1x, https://x.test/b.png 2x', base),
      'markview-doc:///Users/boris/my%20project/docs/a.png 1x, https://x.test/b.png 2x');

console.log(failures === 0 ? 'ALL OK' : failures + ' FAILED');
process.exit(failures === 0 ? 0 : 1);
