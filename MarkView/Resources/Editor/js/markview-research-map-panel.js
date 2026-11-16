// Research map, part 5 of 6: selection, the properties panel, the node menu, AI actions, export and the dialogs.
(function (A) {
    'use strict';
    if (!A.ready) return;   // the page has no editor area, or no layout engine (the first part returned early): nothing to set up
    const {
        AI_ACTIONS, LIMITS, Layout, MAX_TITLE, NODE_ICONS, NODE_ICON_IDS, PANEL_BOX, SHAPE_IDS, SHAPE_NAMES,
        SIZE_PRESETS, VISUAL_KINDS, boxOf, branchHex, clamp, clearLink, closeQueries, diagramSourceOf, el,
        ensureVisible, fillVisual, fitTitle, flushAll, focusNode, h, icon, imageOf, imageURL, nodeById, queueUpdate,
        reveal, rm, saveSoon, send, setGlyph, toast, visualOf
    } = A;
    Object.assign(A, {
        closeDialog, closeExport, closeMenu, currentDescription, exportDialog, fillPanel, iconDialog, openMenu,
        pictureDialog, renderAI, runAI, select, syncSelection, toggleDrawList, toggleExport, translateDialog
    });

    // ---- selection and panel ---------------------------------------------------------------------------------------------------
    function select(id) {
        if (id) clearLink();
        if (rm.selected === id) return;
        flushAll();
        closeMenu();
        rm.selected = id;
        syncSelection();
        fillPanel();
        saveSoon();
    }
    function syncSelection() {
        rm.els.forEach(function (entry, id) {
            const chosen = id === rm.selected;
            entry.btn.setAttribute('aria-pressed', chosen ? 'true' : 'false');
            entry.wrap.classList.toggle('selected', chosen);
            entry.handles.forEach(function (handle) { handle.hidden = !chosen; });
        });
    }

    /** The description as the page now holds it: an edit not sent yet wins over the snapshot. */
    function currentDescription(id) {
        const pending = rm.pending[id];
        if (pending && Object.prototype.hasOwnProperty.call(pending.fields, 'description')) return pending.fields.description;
        const node = nodeById(id);
        return node ? node.description : '';
    }
    function syncVisualPanel(node) {
        const kind = node.visual || 'text';
        VISUAL_KINDS.forEach(function (k) { el.visualBtns[k[0]].setAttribute('aria-pressed', k[0] === kind ? 'true' : 'false'); });
        el.visualPane.hidden = !node.visual;
        const v = visualOf(node);
        el.shapeRow.hidden = !!v;
        if (!node.visual) { el.visualPreview._vk = ''; return; }
        const diagram = node.visual === 'diagram';
        el.visualSource.hidden = !diagram;
        el.imageInput.hidden = diagram;
        if (diagram) setField(el.visualSource, diagramSourceOf(node.description) || '', node.id, 'description');
        else setField(el.imageInput, (imageOf(node.description) || {}).src || '', node.id, 'description');
        el.visualPreview.hidden = !v;
        el.visualExpand.hidden = !v;
        if (v) fillVisual(el.visualPreview, v, PANEL_BOX, node.title, null);
        else el.visualPreview._vk = '';
    }

    function setField(field, value, id, key) {
        if (field.value === value) return;
        // Never overwrite what the person is typing, or an edit that has not been sent yet.
        if (document.activeElement === field) return;
        if (rm.pending[id] && Object.prototype.hasOwnProperty.call(rm.pending[id].fields, key)) return;
        field.value = value;
    }
    function fillPanel(forceNumber) {
        const node = nodeById(rm.selected);
        el.empty.hidden = !!node;
        el.body.hidden = !node;
        if (!node) { rm.panelFor = null; return; }
        const fresh = rm.panelFor !== node.id;
        rm.panelFor = node.id;
        if (fresh) {
            el.titleInput.value = node.title;
            el.titleError.textContent = '';
            el.desc.value = node.description;
            el.tagInput.value = '';
        } else {
            if (!el.titleError.textContent) setField(el.titleInput, node.title, node.id, 'title');
            setField(el.desc, node.description, node.id, 'description');
        }
        syncVisualPanel(node);
        const shownColor = node.color || branchHex(node.id);
        if (document.activeElement !== el.color) el.color.value = shownColor;
        el.colorClear.hidden = !node.color;
        setGlyph(el.iconGlyph, node.icon);
        el.iconText.textContent = node.icon ? (NODE_ICONS[node.icon] ? node.icon.charAt(0).toUpperCase() + node.icon.slice(1) : 'Emoji') : 'None';
        el.iconClear.hidden = !node.icon;
        const pictureURL = node.image ? imageURL(node.image) : null;
        el.imageThumb.hidden = !pictureURL;
        if (pictureURL && el.imageThumb._key !== pictureURL) { el.imageThumb._key = pictureURL; el.imageThumb.src = pictureURL; }
        el.imageText.textContent = node.image ? node.image.split('/').pop().slice(0, 28) : 'None';
        el.imageClear.hidden = !node.image;
        if (forceNumber === true || document.activeElement !== el.numberInput) el.numberInput.value = node.number == null ? '' : String(node.number);
        // Shape and size: the buttons say what is set; the fields show the stored values (empty is automatic).
        const look = boxOf(node), shown = node.shape || 'rounded';
        SHAPE_IDS.forEach(function (id) {
            const name = (rm.snap.shapeNames && rm.snap.shapeNames[id]) || SHAPE_NAMES[id];
            const button = el.shapeBtns[id];
            button.setAttribute('aria-pressed', id === shown ? 'true' : 'false');
            button.title = name;
            button.setAttribute('aria-label', name + ' shape');
        });
        el.sizeBtns.auto.setAttribute('aria-pressed', look.width == null && look.height == null ? 'true' : 'false');
        SIZE_PRESETS.forEach(function (p) { el.sizeBtns[p.id].setAttribute('aria-pressed', look.width === p.w && look.height === p.h ? 'true' : 'false'); });
        [['width', el.widthInput], ['height', el.heightInput]].forEach(function (pair) {
            const key = pair[0], input = pair[1];
            input.min = String(LIMITS[key][0]);
            input.max = String(LIMITS[key][1]);
            if (forceNumber === true || document.activeElement !== input) input.value = look[key] == null ? '' : String(look[key]);
        });
        // Tags: chips before the input, which keeps its focus and caret.
        Array.prototype.slice.call(el.tags.querySelectorAll('.rm-tag')).forEach(function (chip) { chip.remove(); });
        node.tags.forEach(function (tag) {
            const chip = h('span', { class: 'rm-tag', 'data-tag': tag }, tag, h('button', { type: 'button', 'aria-label': 'Remove tag “' + tag + '”', onClick: function () {
                queueUpdate(node.id, { tags: node.tags.filter(function (t) { return t !== tag; }) }, true);
            } }, '×'));
            el.tags.insertBefore(chip, el.tagInput);
        });
        // Evidence.
        el.evList.textContent = '';
        node.evidence.forEach(function (ev) {
            const row = h('li', { class: 'rm-ev-row' },
                h('span', { class: 'rm-ev-chip', 'data-label': ev.label }, ev.label || 'Finding'),
                h('span', { class: 'rm-ev-text' }, ev.text));
            if (ev.source) {
                row.appendChild(h('button', { class: 'rm-ev-source', type: 'button', title: 'Open ' + ev.source, 'data-source': ev.source, onClick: function (event) {
                    event.preventDefault();
                    event.stopPropagation();
                    send('open', { source: ev.source });
                } }, ev.source));
            }
            el.evList.appendChild(row);
        });
        renderAI();
        el.evHeading.textContent = 'Evidence (' + node.evidence.length + ')';
        el.evSection.hidden = node.evidence.length === 0;
        // Logical connections of this node, each removable.
        el.connList.textContent = '';
        const mine = rm.snap.links.filter(function (l) { return l.from === node.id || l.to === node.id; });
        mine.forEach(function (l) {
            const otherId = l.from === node.id ? l.to : l.from, other = nodeById(otherId);
            const name = other ? other.title : otherId;
            el.connList.appendChild(h('li', { class: 'rm-conn-row', 'data-from': l.from, 'data-to': l.to },
                h('button', { class: 'rm-conn-name', type: 'button', title: 'Select this node', onClick: function () { reveal(otherId); select(otherId); ensureVisible(otherId); } }, '↔ ' + name),
                h('button', { class: 'rm-x', type: 'button', title: 'Remove this connection', 'aria-label': 'Remove the connection to “' + name + '”', onClick: function () { send('unlink', { from: l.from, to: l.to }); } }, icon('close'))));
        });
        el.connHeading.textContent = 'Connections (' + mine.length + ')';
        el.connSection.hidden = mine.length === 0;
        // Last, when the panel has its final content: a scrollbar that appears now narrows the title field. The second pass
        // measures at the final width (a taller title can itself bring the scrollbar).
        fitTitle();
        fitTitle();
    }

    // ---- node menu -----------------------------------------------------------------------------------------------------------------
    function descendantIds(id) {
        const ids = [id];
        for (let i = 0; i < ids.length; i++) rm.snap.nodes.forEach(function (n) { if (n.parent === ids[i] && ids.indexOf(n.id) < 0) ids.push(n.id); });
        return ids;
    }
    function closeMenu() {
        if (rm.menu == null && !rm.menuEl) return;
        const entry = rm.els.get(rm.menu);
        if (entry) {
            entry.wrap.classList.remove('menu-open');
            entry.tri.setAttribute('aria-expanded', 'false');
        }
        if (rm.menuEl) { rm.menuEl.remove(); rm.menuEl = null; }
        rm.menu = null;
    }
    /** Under the node's menu button, at screen size (the menu is not part of the zoomed map), kept inside the map area. */
    function placeMenu(bar, entry) {
        const host = el.left.getBoundingClientRect(), anchor = entry.tri.getBoundingClientRect();
        const width = bar.offsetWidth, height = bar.offsetHeight;
        let left = anchor.right - host.left - width, top = anchor.bottom - host.top + 4;
        left = clamp(left, 4, Math.max(4, host.width - width - 4));
        if (top + height > host.height - 4) top = Math.max(4, host.height - height - 4);
        bar.style.left = left + 'px';
        bar.style.top = top + 'px';
    }
    function aiBusy() { return !!(rm.snap && (rm.snap.job || rm.snap.status === 'researching')); }
    const BUSY_HINT = 'An AI job is already working on this map; stop it or wait for it first.';
    function openMenu(id) {
        closeMenu();
        closeExport();
        const entry = rm.els.get(id), node = nodeById(id);
        if (!entry || !node) return;
        const snap = rm.snap, isRoot = id === snap.nodes[0].id, busy = aiBusy();
        const dialogs = { develop: true, correct: true };
        const bar = h('div', { class: 'rm-actions', role: 'menu', 'aria-label': 'Actions for node “' + node.title + '”' });
        const addItem = function (item) {
            const button = h('button', { class: 'rm-item' + (item.ai ? ' ai' : '') + (item.danger ? ' danger' : ''), type: 'button', role: 'menuitem', 'data-act': item.act,
                title: item.off && item.offHint ? item.offHint : (item.hint || item.label), 'aria-label': item.label, disabled: !!item.off }, icon(item.icon), h('span', null, item.label));
            if (item.more) button.appendChild(h('span', { class: 'rm-more', 'aria-hidden': 'true' }, '▾'));
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                if (item.act === 'arrange') { toggleLayouts(bar, node, button, entry); return; }
                if (item.act === 'draw') { toggleDrawMenu(bar, node, button, entry); return; }
                closeMenu();
                item.run();
            });
            bar.appendChild(button);
        };
        AI_ACTIONS.forEach(function (action) {
            addItem({ act: action.act, label: action.label + (dialogs[action.act] ? '…' : ''), icon: action.icon, ai: true, hint: action.hint, off: busy, offHint: BUSY_HINT,
                run: function () { runAI(action.act, node); } });
        });
        addItem({ act: 'draw', label: 'Draw', icon: 'diagram', ai: true, more: true, hint: 'The AI draws a diagram of this node as a child node: sequence, flowchart, data flow and more',
            off: busy, offHint: BUSY_HINT, run: null });
        bar.appendChild(h('div', { class: 'rm-sep', role: 'separator' }));
        addItem({ act: 'add', label: 'Add child node…', icon: 'plus', run: function () { addChildDialog(node); } });
        addItem({ act: 'link', label: 'Add logical connection…', icon: 'link', off: snap.nodes.length < 2, run: function () { linkDialog(node); } });
        addItem({ act: 'edit', label: 'Edit title…', icon: 'edit', run: function () { editDialog(node); } });
        addItem({ act: 'icon', label: 'Icon…', icon: 'tag', hint: 'Choose an icon or an emoji for this node', run: function () { select(id); iconDialog(node); } });
        addItem({ act: 'image', label: 'Image…', icon: 'photo', hint: 'Add a picture to this node, shown beside its icon', run: function () { select(id); pictureDialog(node); } });
        const kids = snap.nodes.filter(function (n) { return n.parent === id; });
        const numbered = kids.length > 0 && kids.every(function (n, i) { return n.number === i + 1; });
        addItem({ act: 'number-children', label: numbered ? 'Remove numbers from children' : 'Number children 1, 2, 3…', icon: 'text',
            hint: numbered ? 'Take the number badges off the child nodes' : 'Give the child nodes the number badges 1, 2, 3 in map order',
            off: kids.length === 0, offHint: 'This node has no children', run: function () { send('numberChildren', { id: id, clear: numbered }); } });
        addItem({ act: 'focus', label: 'Focus on this node', icon: 'centre', hint: 'Fold everything except the path from the root to this node and its children',
            run: function () { focusNode(id); } });
        addItem({ act: 'arrange', label: 'Arrange branch', icon: 'grid', more: true, hint: 'Choose how this branch lays out its nodes', run: null });
        bar.appendChild(h('div', { class: 'rm-sep', role: 'separator' }));
        addItem({ act: 'delete', label: 'Delete node…', icon: 'trash', danger: true, off: isRoot, offHint: 'The root node cannot be deleted', run: function () { deleteDialog(node); } });
        el.left.appendChild(bar);
        placeMenu(bar, entry);
        entry.wrap.classList.add('menu-open');
        entry.tri.setAttribute('aria-expanded', 'true');
        rm.menu = id;
        rm.menuEl = bar;
    }
    function toggleLayouts(bar, node, anchorButton, entry) {
        const existing = bar.querySelector('.rm-layouts');
        if (existing) { existing.remove(); placeMenu(bar, entry); return; }
        const layouts = rm.snap.layouts.length ? rm.snap.layouts : Layout.PRESETS.map(function (id) { return { id: id, name: id.charAt(0).toUpperCase() + id.slice(1) }; });
        const current = Layout.effectiveLayout(rm.snap.nodes, node.id, rm.snap.layouts);
        const list = h('div', { class: 'rm-layouts', role: 'menu', 'aria-label': 'Arrange branch' });
        layouts.forEach(function (layout) {
            const on = layout.id === current;
            const button = h('button', { type: 'button', role: 'menuitemradio', 'aria-checked': on ? 'true' : 'false', 'data-layout': layout.id }, h('span', { class: 'rm-check' }, on ? '✓' : ''), layout.name);
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                closeMenu();
                send('layout', { id: node.id, layout: layout.id });
            });
            list.appendChild(button);
        });
        anchorButton.insertAdjacentElement('afterend', list);
        placeMenu(bar, entry);
    }

    // ---- Draw: a diagram of a node as a child node (REQ-012, DEC-013) -------------------------------------------------------------
    function drawKinds() { return (rm.snap && rm.snap.drawKinds) || []; }
    function drawButtons(node, after) {
        return drawKinds().map(function (kind) {
            const button = h('button', { type: 'button', role: 'menuitem', 'data-kind': kind.id, title: kind.hint || kind.name }, kind.name + (kind.id === 'custom' ? '…' : ''));
            button.addEventListener('click', function (event) {
                event.stopPropagation();
                after();
                runDraw(node, kind);
            });
            return button;
        });
    }
    function toggleDrawMenu(bar, node, anchorButton, entry) {
        const existing = bar.querySelector('.rm-draw-menu');
        if (existing) { existing.remove(); placeMenu(bar, entry); return; }
        const list = h('div', { class: 'rm-layouts rm-draw-menu', role: 'menu', 'aria-label': 'Diagram types' }, drawButtons(node, closeMenu));
        anchorButton.insertAdjacentElement('afterend', list);
        placeMenu(bar, entry);
    }
    function toggleDrawList() {
        const node = nodeById(rm.selected);
        if (!node) return;
        const open = el.drawList.hidden;
        el.drawList.textContent = '';
        if (open) drawButtons(node, function () { toggleDrawList(); }).forEach(function (b) { el.drawList.appendChild(b); });
        el.drawList.hidden = !open;
        el.drawBtn.setAttribute('aria-expanded', open ? 'true' : 'false');
    }
    function runDraw(node, kind) {
        if (aiBusy()) { toast(BUSY_HINT); return; }
        if (kind.id === 'custom') {
            textDialog('Draw a diagram', 'The AI draws a diagram of “' + node.title + '” as a child node.', 'What should it show?', '', 500, 'Draw',
                function (text) { send('draw', { id: node.id, kind: 'custom', instruction: text }); }, 'Say what the diagram should show.',
                { multiline: true, placeholder: 'e.g. the retry rules as a decision flow' });
            return;
        }
        send('draw', { id: node.id, kind: kind.id });
    }

    // ---- AI actions on a node (REQ-006) ----------------------------------------------------------------------------------------------
    function runAI(act, node) {
        if (!node) return;
        if (aiBusy()) { toast(BUSY_HINT); return; }
        if (act === 'describe') send('describe', { id: node.id });
        else if (act === 'investigate') send('investigate', { id: node.id });
        else if (act === 'develop') developDialog(node);
        else if (act === 'correct') correctDialog(node);
    }
    function renderAI() {
        const busy = aiBusy();
        el.aiButtons.forEach(function (button) { button.disabled = busy; });
        if (busy && !el.drawList.hidden) toggleDrawList();
        el.aiNote.textContent = busy ? BUSY_HINT : '';
    }

    // ---- export menu -----------------------------------------------------------------------------------------------------------------
    function toggleExport() {
        if (rm.exportOpen) { closeExport(); return; }
        closeMenu();
        closeQueries();
        rm.exportOpen = true;
        el.exportMenu.hidden = false;
        el.exportBtn.setAttribute('aria-expanded', 'true');
    }
    function closeExport() {
        rm.exportOpen = false;
        el.exportMenu.hidden = true;
        el.exportBtn.setAttribute('aria-expanded', 'false');
    }

    // ---- dialogs (the web view blocks alert, confirm and prompt, so these are in the page) ------------------------------------------
    function closeDialog() {
        if (!rm.dialog) return;
        rm.dialog.remove();
        rm.dialog = null;
    }
    function dialog(title, body, actions, label) {
        closeDialog();
        closeMenu();
        const buttons = actions.map(function (action) {
            return h('button', { class: 'rm-btn' + (action.kind ? ' ' + action.kind : ''), type: 'button', 'data-kind': action.kind || 'ghost', onClick: function () {
                if (action.run && action.run() === false) return;
                closeDialog();
            } }, action.label);
        });
        const card = h('div', { class: 'rm-dialog', role: 'dialog', 'aria-modal': 'true', 'aria-label': label || title }, h('h2', null, title), h('div', { class: 'rm-dialog-body' }, body), h('div', { class: 'rm-dialog-actions' }, buttons));
        const overlay = h('div', { class: 'rm-modal', onPointerdown: function (event) { if (event.target === overlay) closeDialog(); } }, card);
        el.root.appendChild(overlay);
        rm.dialog = overlay;
        const primary = buttons.filter(function (b) { return b.classList.contains('primary') || b.classList.contains('danger'); })[0];
        card.addEventListener('keydown', function (event) {
            if (event.key === 'Enter' && primary && (event.target.tagName === 'INPUT' || ((event.metaKey || event.ctrlKey) && event.target.tagName === 'TEXTAREA'))) { event.preventDefault(); primary.click(); }
        });
        const first = card.querySelector('input, textarea, select') || primary || buttons[0];
        if (first) first.focus();
        return overlay;
    }
    function textDialog(title, intro, labelText, initial, maxLength, okLabel, onOk, emptyMessage, options) {
        options = options || {};
        const input = options.multiline
            ? h('textarea', { maxlength: String(maxLength), 'aria-label': labelText, spellcheck: 'false', placeholder: options.placeholder || '' })
            : h('input', { type: 'text', maxlength: String(maxLength), 'aria-label': labelText, value: initial || '', spellcheck: 'false', placeholder: options.placeholder || '' });
        if (options.multiline) input.value = initial || '';
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog(title, [intro ? h('p', null, intro) : null, h('label', null, labelText, input), error], [
            { label: 'Cancel', kind: 'ghost' },
            { label: okLabel, kind: 'primary', run: function () {
                const value = input.value.trim();
                if (!value && emptyMessage) { error.textContent = emptyMessage; input.focus(); return false; }
                onOk(value);
            } }
        ]);
        input.select();
    }
    /** One emoji: a single grapheme that is a pictograph. Swift decides in the end; this only saves a round trip. */
    function isEmojiText(value) {
        if (!value) return false;
        const parts = typeof Intl !== 'undefined' && Intl.Segmenter ? Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(value)) : [value];
        return parts.length === 1 && /\p{Extended_Pictographic}|\p{Regional_Indicator}|\uFE0F/u.test(value);
    }
    function iconDialog(node) {
        if (!node) return;
        const grid = h('div', { class: 'rm-icongrid', role: 'group', 'aria-label': 'Built-in icons' });
        NODE_ICON_IDS.forEach(function (id) {
            const name = id.charAt(0).toUpperCase() + id.slice(1);
            grid.appendChild(h('button', { type: 'button', 'data-icon': id, title: name, 'aria-label': name, 'aria-pressed': node.icon === id ? 'true' : 'false', onClick: function () {
                queueUpdate(node.id, { icon: id }, true);
                closeDialog();
            } }, icon(id, NODE_ICONS)));
        });
        const input = h('input', { type: 'text', 'aria-label': 'Emoji', maxlength: '16', spellcheck: 'false', placeholder: 'Paste or type one emoji', value: node.icon && !NODE_ICONS[node.icon] ? node.icon : '' });
        const error = h('p', { class: 'rm-error', role: 'alert' });
        const actions = [{ label: 'Cancel', kind: 'ghost' }];
        if (node.icon) actions.push({ label: 'Remove icon', kind: 'ghost', run: function () { queueUpdate(node.id, { icon: '' }, true); } });
        actions.push({ label: 'Use emoji', kind: 'primary', run: function () {
            const value = input.value.trim();
            if (!isEmojiText(value)) { error.textContent = 'Paste one emoji (macOS: Control-Command-Space).'; input.focus(); return false; }
            queueUpdate(node.id, { icon: value }, true);
        } });
        dialog('Icon for “' + node.title + '”', [grid, h('label', null, 'Or any emoji', input), error], actions, 'Choose an icon');
    }
    // ---- a picture on a node, beside its icon (REQ-017, DEC-018) -----------------------------------------------------------------
    const PICTURE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
    const PICTURE_LIMIT = 6000000;   // the same limit as ResearchMapImages.sizeLimit in Swift
    function hasFiles(event) { return !!(event.dataTransfer && Array.prototype.indexOf.call(event.dataTransfer.types || [], 'Files') >= 0); }
    function firstFile(transfer) { return transfer && transfer.files && transfer.files.length ? transfer.files[0] : null; }
    /** Sends a picture that was chosen, dropped or pasted to Swift, which saves it in images/ beside the map and sets it on the node. Returns a one-line reason when it cannot. */
    function attachPicture(id, file) {
        if (!file || !nodeById(id)) return 'That node no longer exists.';
        if (PICTURE_TYPES.indexOf(file.type) < 0) return 'Use a PNG, JPEG, GIF or WebP picture.';
        if (file.size > PICTURE_LIMIT) return 'The picture is larger than 6 MB.';
        const reader = new FileReader();
        reader.onload = function () {
            const result = String(reader.result || ''), comma = result.indexOf(',');
            if (comma < 0) { toast('The picture could not be read.'); return; }
            send('attachImage', { id: id, name: file.name || 'image', data: result.slice(comma + 1) });
        };
        reader.onerror = function () { toast('The picture could not be read.'); };
        reader.readAsDataURL(file);
        return '';
    }
    function pictureDialog(node) {
        if (!node) return;
        const id = node.id;
        const input = h('input', { type: 'file', accept: PICTURE_TYPES.join(','), hidden: true, 'aria-label': 'Choose a picture file' });
        const preview = h('img', { class: 'rm-picture-preview', alt: '', hidden: true });
        const current = node.image ? imageURL(node.image) : null;
        if (current) { preview.src = current; preview.hidden = false; }
        const choose = h('button', { class: 'rm-btn', type: 'button', 'data-act': 'choose-picture', onClick: function () { input.click(); } }, 'Choose file…');
        const zone = h('div', { class: 'rm-dropzone', role: 'group', 'aria-label': 'Picture for this node' }, preview,
            h('span', null, 'Drop a picture here, paste it (⌘V), or choose a file. PNG, JPEG, GIF or WebP, up to 6 MB.'), choose, input);
        const error = h('p', { class: 'rm-error', role: 'alert' });
        const take = function (file) {
            const problem = attachPicture(id, file);
            if (problem) { error.textContent = problem; return; }
            closeDialog();
        };
        input.addEventListener('change', function () { take(firstFile(input)); });
        zone.addEventListener('dragover', function (event) { if (hasFiles(event)) { event.preventDefault(); zone.classList.add('over'); } });
        zone.addEventListener('dragleave', function () { zone.classList.remove('over'); });
        zone.addEventListener('drop', function (event) {
            zone.classList.remove('over');
            if (!hasFiles(event)) return;
            event.preventDefault();
            take(firstFile(event.dataTransfer));
        });
        const actions = [{ label: 'Cancel', kind: 'ghost' }];
        if (node.image) actions.push({ label: 'Remove picture', kind: 'ghost', run: function () { queueUpdate(id, { image: '' }, true); } });
        const overlay = dialog('Picture for “' + node.title + '”', [zone, error], actions, 'Choose a picture');
        overlay.addEventListener('paste', function (event) {
            const file = firstFile(event.clipboardData);
            if (!file) return;
            event.preventDefault();
            take(file);
        });
    }
    /** A picture dropped on a node of the canvas goes onto that node. */
    (function () {
        let over = '';
        const mark = function (id) {
            if (id === over) return;
            const old = over && rm.els.get(over);
            if (old) old.wrap.classList.remove('picture-drop');
            over = id;
            const entry = id && rm.els.get(id);
            if (entry) entry.wrap.classList.add('picture-drop');
        };
        const nodeAt = function (event) {
            const wrap = event.target && event.target.closest ? event.target.closest('.rm-node-wrap') : null;
            return wrap ? wrap.getAttribute('data-id') : '';
        };
        el.viewport.addEventListener('dragover', function (event) {
            const id = hasFiles(event) ? nodeAt(event) : '';
            mark(id);
            if (!id) return;
            event.preventDefault();
            event.dataTransfer.dropEffect = 'copy';
        });
        el.viewport.addEventListener('dragleave', function (event) { if (!event.relatedTarget || !el.viewport.contains(event.relatedTarget)) mark(''); });
        el.viewport.addEventListener('drop', function (event) {
            mark('');
            const id = hasFiles(event) ? nodeAt(event) : '';
            if (!id) return;
            event.preventDefault();
            event.stopPropagation();
            const problem = attachPicture(id, firstFile(event.dataTransfer));
            if (problem) toast(problem); else select(id);
        });
    })();

    function addChildDialog(parent) {
        textDialog('Add child node', 'Parent node: ' + parent.title, 'Child node name', '', MAX_TITLE, 'Add', function (title) { send('addChild', { parent: parent.id, title: title }); }, 'Enter a node name.');
    }
    function editDialog(node) {
        textDialog('Edit node', '', 'Node name', node.title, MAX_TITLE, 'Save', function (title) { send('update', { id: node.id, title: title }); }, 'Enter a node name.');
    }
    function developDialog(node) {
        textDialog('Expand topic', 'The AI adds child nodes under “' + node.title + '”.', 'Direction (optional)', '', 500, 'Expand', function (direction) { send('develop', { id: node.id, direction: direction }); }, '',
            { placeholder: 'e.g. compare the options, or focus on the costs' });
    }
    function correctDialog(node) {
        textDialog('Correct node', 'The AI checks “' + node.title + '” against the project and the web and fixes only this node.', 'What is wrong with it?', '', 2000, 'Correct', function (note) { send('correct', { id: node.id, note: note }); }, 'Say what is wrong with this node.',
            { multiline: true, placeholder: 'e.g. the cache is not LRU, it evicts by size' });
    }
    // ---- language of an export and of a translation (REQ-013, REQ-014) -------------------------------------------------------------
    function savedLanguage(key) { try { return localStorage.getItem(key) || ''; } catch (e) { return ''; } }
    function saveLanguage(key, value) { try { localStorage.setItem(key, value); } catch (e) { /* the choice is only a convenience */ } }
    /** A language picker: the languages of the snapshot, optionally "the map's own language" first, and Other… with a field to type one. */
    function languagePicker(storageKey, withOwn) {
        const languages = (rm.snap && rm.snap.languages && rm.snap.languages.length) ? rm.snap.languages : [{ code: 'en', name: 'English' }];
        const select = h('select', { 'aria-label': 'Language' });
        if (withOwn) select.appendChild(h('option', { value: '' }, 'The language of the map'));
        languages.forEach(function (l) { select.appendChild(h('option', { value: l.name }, l.name)); });
        select.appendChild(h('option', { value: '__other' }, 'Other…'));
        const other = h('input', { type: 'text', maxlength: '40', 'aria-label': 'Language name', placeholder: 'e.g. Japanese', spellcheck: 'false', hidden: true });
        const saved = savedLanguage(storageKey);
        const known = Array.prototype.some.call(select.options, function (o) { return o.value === saved; });
        if (saved && known) select.value = saved;
        else if (saved) { select.value = '__other'; other.value = saved; other.hidden = false; }
        else select.value = withOwn ? '' : languages[0].name;
        select.addEventListener('change', function () { other.hidden = select.value !== '__other'; if (!other.hidden) other.focus(); });
        return {
            nodes: [h('label', null, 'Language', select), other],
            /** The chosen language name, '' for the map's own, or null with a message when Other… is empty. */
            value: function () { return select.value === '__other' ? other.value.trim().replace(/\s+/g, ' ') : select.value; },
            needsName: function () { return select.value === '__other' && !other.value.trim(); },
            remember: function () { saveLanguage(storageKey, select.value === '__other' ? other.value.trim() : select.value); },
            focusOther: function () { other.focus(); }
        };
    }
    function exportDialog(kind) {
        if (aiBusy()) { toast(BUSY_HINT); return; }
        const picker = languagePicker('mvMapLang:export', true);
        const error = h('p', { class: 'rm-error', role: 'alert' });
        const pdf = kind === 'pdf';
        dialog(pdf ? 'Export as PDF' : 'Export as Markdown report',
            [h('p', null, 'The AI writes a report of the whole map as a document to share: an introduction, the story of each branch, conclusions and open questions, with the map’s diagrams and pictures where they belong. It takes a few minutes.'), picker.nodes, error],
            [{ label: 'Cancel', kind: 'ghost' },
             { label: pdf ? 'Export…' : 'Export', kind: 'primary', run: function () {
                 if (picker.needsName()) { error.textContent = 'Type the name of the language.'; picker.focusOther(); return false; }
                 picker.remember();
                 send('export', { kind: kind, language: picker.value() });
             } }], pdf ? 'Export as PDF' : 'Export as Markdown report');
    }
    function translateDialog() {
        if (aiBusy()) { toast(BUSY_HINT); return; }
        const picker = languagePicker('mvMapLang:translate', false);
        const mode = h('select', { 'aria-label': 'Result' },
            h('option', { value: 'copy' }, 'A new map next to this one'),
            h('option', { value: 'replace' }, 'Replace this map (a copy is saved first)'));
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog('Translate map',
            [h('p', null, 'The AI translates the question and the text of every node. The structure, the sources and the links stay exactly as they are.'), picker.nodes, h('label', null, 'Result', mode), error],
            [{ label: 'Cancel', kind: 'ghost' },
             { label: 'Translate', kind: 'primary', run: function () {
                 if (picker.needsName() || !picker.value()) { error.textContent = 'Choose or type a language.'; picker.focusOther(); return false; }
                 picker.remember();
                 send('translate', { language: picker.value(), mode: mode.value });
             } }], 'Translate map');
    }
    function nodeOptions(nodes) {
        const depth = function (n) { let d = 0, cur = n, guard = 0; while (cur && cur.parent && guard++ < 100) { d++; cur = rm.snap.byId.get(cur.parent); } return d; };
        return nodes.map(function (n) { return h('option', { value: n.id }, ' '.repeat(Math.min(depth(n), 6)) + n.title); });
    }
    function linkDialog(node) {
        const nodes = rm.snap.nodes;
        const from = h('select', { 'aria-label': 'First node' }, nodeOptions(nodes));
        const to = h('select', { 'aria-label': 'Second node' }, nodeOptions(nodes));
        from.value = node.id;
        const other = nodes.filter(function (n) { return n.id !== node.id; })[0];
        if (other) to.value = other.id;
        const error = h('p', { class: 'rm-error', role: 'alert' });
        dialog('Add logical connection', [h('label', null, 'First node', from), h('label', null, 'Second node', to), error], [
            { label: 'Cancel', kind: 'ghost' },
            { label: 'Add', kind: 'primary', run: function () {
                if (from.value === to.value) { error.textContent = 'Select two different nodes.'; return false; }
                if (rm.snap.links.some(function (l) { return (l.from === from.value && l.to === to.value) || (l.from === to.value && l.to === from.value); })) { error.textContent = 'This connection already exists.'; return false; }
                send('link', { from: from.value, to: to.value });
            } }
        ]);
    }
    function deleteDialog(node) {
        const below = descendantIds(node.id).length - 1;
        const message = 'Delete node “' + node.title + '”' + (below > 0 ? ' and its child nodes (' + below + ')' : '') + '? Its logical connections will also be deleted.';
        dialog('Delete node', h('p', null, message), [
            { label: 'Cancel', kind: 'ghost' },
            { label: 'Delete', kind: 'danger', run: function () { rm.fallbackSelect = node.parent; send('delete', { id: node.id }); } }
        ]);
    }
})(window.MVResearchMapView);
