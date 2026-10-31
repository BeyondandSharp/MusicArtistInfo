/*
 * MusicArtistInfo - Material Skin queue-panel lyrics chooser.
 *
 * The plugin's loader (Lyrics/MaterialSkin.pm) adds this script to Material
 * Skin's custom.js.  Instead of a separate dialog, the chooser lives in the
 * queue panel:
 *   - a "Choose lyrics" entry is added to the now-playing settings menu;
 *   - a lyrics icon is added to the queue toolbar next to Actions;
 *   - the queue list is replaced by a lyrics search / candidate list.
 */
(function () {
	'use strict';

	if (window.__MAI_MATERIAL_QUEUE_LOADED) {
		return;
	}
	window.__MAI_MATERIAL_QUEUE_LOADED = true;

	var LANG = '';
	try { LANG = (window.lmsOptions && lmsOptions.lang) || ''; } catch (e) {}
	var IS_ZH = /^zh/i.test(LANG);
	var TEXT = {
		menu: IS_ZH ? '选择歌词' : 'Choose lyrics',
		back: IS_ZH ? '返回队列' : 'Back to queue',
		search: IS_ZH ? '搜索' : 'Search',
		title: IS_ZH ? '标题' : 'Title',
		artist: IS_ZH ? '艺术家' : 'Artist',
		searching: IS_ZH ? '正在搜索歌词...' : 'Searching for lyrics...',
		none: IS_ZH ? '未找到歌词' : 'No lyrics found',
		error: IS_ZH ? '歌词搜索失败' : 'Could not search for lyrics',
		choose: IS_ZH ? '选择歌词' : 'Choose lyrics',
		applying: IS_ZH ? '正在应用...' : 'Applying...',
		applied: IS_ZH ? '已选择' : 'Selected',
		missing: IS_ZH ? '请填写标题和艺术家' : 'Please enter a title and artist',
		synced: IS_ZH ? '同步' : 'Synced',
		plain: IS_ZH ? '文本' : 'Plain',
		source: IS_ZH ? '来源' : 'Source',
		queue: IS_ZH ? '歌词' : 'Lyrics',
		timeout: IS_ZH ? '搜索超时，请重试' : 'Search timed out. Please try again.',
		cancel: IS_ZH ? '取消搜索' : 'Cancel search',
		cancelled: IS_ZH ? '搜索已取消' : 'Search cancelled',
		found: IS_ZH ? '已找到 %1 条' : '%1 found'
	};

	var state = {
		open: false,
		active: false,
		panel: null,
		queueView: null,
		queueList: null,
		searchButton: null,
		titleInput: null,
		artistInput: null,
		list: null,
		status: null,
		session: '',
		searchId: '',
		searchTimer: null,
		searchDeadline: 0,
		searchDone: true,
		cancelled: false,
		searchSeq: 0,
		candidates: [],
		selectedHash: '',
		busy: false,
		requestId: 0,
		startController: null,
		pollController: null,
		progressBar: null,
		progressFill: null,
		cancelButton: null,
		total: 0,
		progress: 0,
		playerId: '',
		trackId: '',
		url: '',
		album: '',
		duration: '',
		wrapped: false,
		preview: null,
		resizer: null,
		lines: [],
		currentLine: -1,
		currentTime: 0,
		syncTimer: null
	};

	function addStyle() {
		if (document.getElementById('maiMaterialQueueStyle')) return;

		var style = document.createElement('style');
		style.id = 'maiMaterialQueueStyle';
		style.textContent =
			'#queue-view.mai-lq-active{display:flex!important;flex-direction:column!important;min-height:0!important;overflow:hidden!important}' +
			'#queue-view.mai-lq-active > .lms-list{display:none!important}' +
			'.mai-lq-panel{display:none;flex:1 1 0;min-height:0;max-height:100%;flex-direction:column;background:var(--background-color);color:var(--text-color);overflow:hidden;font:inherit}' +
			'#queue-view.mai-lq-active > .mai-lq-panel{display:flex}' +
			'.mai-lq-searchbar{display:flex;align-items:center;gap:2px;min-height:var(--sub-toolbar-height,48px);padding:0 7px;border-bottom:1px solid var(--sub-toolbar-border-color);background:var(--sub-toolbar-color);color:var(--sub-toolbar-text-color);flex:0 0 auto}' +
			'.mai-lq-searchbar .mai-lq-inputs{display:flex;gap:12px;flex:1 1 auto;min-width:0;padding:0 2px}' +
			'.mai-lq-searchbar input{flex:1 1 0;min-width:0;border:0;border-bottom:1px solid var(--border-color);background:transparent;color:var(--text-color);font:inherit;padding:7px 2px 5px;outline:none}' +
			'.mai-lq-searchbar input:focus{border-bottom-color:var(--highlight-color,#1976d2)}' +
			'.mai-lq-searchbar input::placeholder{color:var(--text-color);opacity:.55}' +
			'.mai-lq-status{flex:0 0 auto;min-height:24px;padding:4px 14px;font-size:var(--small-font-size,90%);opacity:var(--sub-opacity,.7);white-space:normal}' +
			'.mai-lq-list{flex:1 1 auto;min-height:0;overflow:auto;overscroll-behavior:contain}' +
			'.mai-lq-resizer{flex:0 0 7px;min-height:7px;cursor:row-resize;background:var(--border-color);position:relative;touch-action:none}' +
			'.mai-lq-resizer:after{content:"";position:absolute;left:50%;top:2px;width:34px;height:3px;margin-left:-17px;border-radius:2px;background:var(--sub-toolbar-text-color);opacity:.45}' +
			'.mai-lq-item{display:block;width:100%;box-sizing:border-box;text-align:left;border:0;border-bottom:1px solid var(--list-item-border-color);background:transparent;color:inherit;font:inherit;padding:9px 14px 8px;cursor:pointer;outline:none}' +
			'.mai-lq-item:hover{background:var(--list-hover-color)}' +
			'.mai-lq-item.selected{background:var(--pq-current-color)}' +
			'.mai-lq-item:focus{background:var(--list-active-color)}' +
			'.mai-lq-head{display:flex;align-items:baseline;gap:8px;min-width:0}' +
			'.mai-lq-badge{flex:0 0 auto;font-size:var(--small-font-size,90%);opacity:var(--sub-opacity,.7);border:1px solid var(--border-color);border-radius:3px;padding:0 4px;line-height:1.5}' +
			'.mai-lq-badge.mai-lq-badge-synced{color:var(--highlight-color,#1976d2)!important;border-color:var(--highlight-color,#1976d2);opacity:1!important;font-weight:var(--bold-weight,600)}' +
			'.mai-lq-title{flex:1 1 auto;min-width:0;font-weight:var(--bold-weight,600);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}' +
			'.mai-lq-meta{display:block;font-size:var(--small-font-size,90%);opacity:var(--sub-opacity,.7);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:2px}' +
			'.mai-lq-preview{display:block;font-size:var(--small-font-size,90%);opacity:.62;white-space:pre-line;overflow:hidden;max-height:2.9em;margin-top:3px}' +
			'.mai-lq-item.selected .mai-lq-title{color:var(--highlight-color,#1976d2)}' +
			'.mai-lq-toggle.mai-lq-toggle-active{background:var(--pq-current-color)!important;border-radius:50%}' +
			'.mai-lq-toolbar-btn{color:var(--sub-toolbar-text-color)!important;display:inline-flex!important;align-items:center!important;justify-content:center!important}' +
			'.mai-lq-progress{flex:0 0 auto;height:3px;background:var(--border-color);overflow:hidden;opacity:.9}' +
			'.mai-lq-progress-fill{height:100%;width:0;background:var(--highlight-color,#1976d2);transition:width .2s ease}' +
			'.mai-lq-progress.indeterminate .mai-lq-progress-fill{width:35%!important;animation:mai-lq-progress 1.1s ease-in-out infinite}' +
			'.mai-lq-lyrics{flex:0 0 33.333%;min-height:72px;overflow:auto;padding:6px 14px 12px;border-top:1px solid var(--sub-toolbar-border-color);text-align:center;line-height:1.55;white-space:pre-wrap}' +
			'.mai-lq-line{padding:2px 8px;border-radius:4px;white-space:pre-wrap}' +
			'.mai-lq-line.lyrics-current-line{background:var(--pq-current-color)!important;font-weight:var(--bold-weight)!important}' +
			'.mai-lq-progress.done .mai-lq-progress-fill{width:100%!important;opacity:.55}' +
			'@keyframes mai-lq-progress{0%{transform:translateX(-120%)}100%{transform:translateX(320%)}}';
		document.head.appendChild(style);
	}

	function getPlayerId() {
		try {
			if (window.bus && bus.$store && bus.$store.state && bus.$store.state.player) {
				return bus.$store.state.player.id;
			}
		} catch (e) {}
		try {
			if (window.app && app.$store && app.$store.state && app.$store.state.player) {
				return app.$store.state.player.id;
			}
		} catch (e) {}
		var match = location.search.match(/[?&]player=([^&]+)/);
		return match ? decodeURIComponent(match[1]) : '';
	}

	function findNowPlaying(vm, depth) {
		if (!vm || (depth || 0) > 8) return null;
		if (typeof vm.fetchTrackInfo === 'function' && vm.info && vm.info.tabs && vm.playerStatus) {
			return vm;
		}
		var children = vm.$children || [];
		for (var i = 0; i < children.length; i++) {
			var found = findNowPlaying(children[i], (depth || 0) + 1);
			if (found) return found;
		}
		return null;
	}

	function currentInfoFromVm(vm) {
		var info = { player: getPlayerId(), title: '', artist: '', album: '', duration: '', trackId: '', url: '' };
		if (!vm) return info;

		var cur = vm.playerStatus && vm.playerStatus.current ? vm.playerStatus.current : {};
		var it = vm.infoTrack || {};

		info.title = cur.title || it.title || '';
		info.artist = cur.artist || it.artist || '';
		info.album = cur.album || it.album || '';
		info.duration = cur.duration || it.duration || '';
		info.trackId = cur.id || cur.track_id || it.track_id || it.id || '';
		info.url = cur.url || it.url || '';
		return info;
	}

	function statusCurrentItem(result) {
		result = result || {};
		var list = result.playlist_loop || [];
		var index = parseInt(result.playlist_cur_index, 10);
		if (isNaN(index)) index = 0;
		for (var i = 0; i < list.length; i++) {
			if (parseInt(list[i]['playlist index'], 10) === index) return list[i];
		}
		return list[0] || {};
	}

	function requestCurrentInfo(cb) {
		var vm = findNowPlaying(window.app, 0);
		var info = currentInfoFromVm(vm);
		var playerId = getPlayerId();

		if (info.title && info.artist) {
			cb(info);
			return;
		}

		if (!playerId || typeof window.lmsCommand !== 'function') {
			cb(info);
			return;
		}

		window.lmsCommand(playerId, ['status', 0, 10, 'tags:title,artist,album,url']).then(function (response) {
			var item = statusCurrentItem(response && response.data ? response.data.result : null);
			info.title = item.title || info.title;
			info.artist = item.artist || info.artist;
			info.album = item.album || info.album;
			info.duration = item.duration || info.duration;
			info.trackId = item.id || info.trackId;
			info.url = item.url || info.url;
			info.player = playerId;
			cb(info);
		}).catch(function () {
			cb(info);
		});
	}

	function requestJson(url, options) {
		options = options || {};
		if (window.fetch) {
			return fetch(url, options).then(function (response) {
				return response.text().then(function (body) {
					try { return JSON.parse(body); } catch (e) { return { error: body || response.statusText }; }
				});
			});
		}
		return Promise.reject(new Error('fetch is not available'));
	}

	function encodeQuery(params) {
		return Object.keys(params).filter(function (k) {
			return params[k] !== undefined && params[k] !== null;
		}).map(function (k) {
			return encodeURIComponent(k) + '=' + encodeURIComponent(params[k]);
		}).join('&');
	}

	function setStatus(message) {
		if (state.status) state.status.textContent = message || '';
	}

	function queueVisible() {
		var view = document.querySelector('#queue-view');
		if (!view) return false;
		var style = window.getComputedStyle(view);
		if (style.display === 'none' || style.visibility === 'hidden') return false;
		var rect = view.getBoundingClientRect();
		return rect.width > 0 && rect.height > 0;
	}

	function ensureQueue(cb) {
		if (queueVisible()) {
			cb();
			return;
		}

		try {
			if (window.bus) bus.$emit('toggleQueue');
		} catch (e) {}

		setTimeout(function () {
			if (!queueVisible()) {
				try {
					if (window.bus && bus.$store) {
						var expanded = false;
						try { expanded = !!(window.app && app.nowPlayingExpanded); } catch (e) {}
						bus.$store.commit(expanded ? 'setShowQueueNp' : 'setShowQueue', true);
					}
				} catch (e) {}
			}
			setTimeout(cb, 350);
		}, 250);
	}

	function initPreviewResizer(panel) {
		var dragging = false;
		var startY = 0;
		var startHeight = 0;
		function move(event) {
			if (!dragging || !state.preview) return;
			var point = event.touches ? event.touches[0] : event;
			if (!point) return;
			var panelHeight = panel.getBoundingClientRect().height;
			var next = startHeight - (point.clientY - startY);
			next = Math.max(72, Math.min(next, panelHeight - 140));
			state.preview.style.flex = '0 0 ' + next + 'px';
			event.preventDefault();
		}
		function end() {
			dragging = false;
			document.removeEventListener('pointermove', move);
			document.removeEventListener('pointerup', end);
			document.removeEventListener('pointercancel', end);
		}
		state.resizer.addEventListener('pointerdown', function (event) {
			if (!state.preview) return;
			dragging = true;
			startY = event.clientY;
			startHeight = state.preview.getBoundingClientRect().height;
			document.addEventListener('pointermove', move);
			document.addEventListener('pointerup', end);
			document.addEventListener('pointercancel', end);
			event.preventDefault();
		});
	}

	function createPanel() {
		var panel = document.createElement('div');
		panel.id = 'mai-lq-panel';
		panel.className = 'mai-lq-panel';

		var bar = document.createElement('div');
		bar.className = 'mai-lq-searchbar';

		var inputs = document.createElement('div');
		inputs.className = 'mai-lq-inputs';

		state.titleInput = document.createElement('input');
		state.titleInput.type = 'text';
		state.titleInput.id = 'mai-lq-title';
		state.titleInput.placeholder = TEXT.title;
		state.titleInput.setAttribute('aria-label', TEXT.title);
		state.titleInput.addEventListener('keydown', onSearchKey);
		inputs.appendChild(state.titleInput);

		state.artistInput = document.createElement('input');
		state.artistInput.type = 'text';
		state.artistInput.id = 'mai-lq-artist';
		state.artistInput.placeholder = TEXT.artist;
		state.artistInput.setAttribute('aria-label', TEXT.artist);
		state.artistInput.addEventListener('keydown', onSearchKey);
		inputs.appendChild(state.artistInput);

		bar.appendChild(inputs);

		state.searchButton = document.createElement('button');
		state.searchButton.type = 'button';
		state.searchButton.className = 'v-btn v-btn--flat v-btn--icon v-btn--small toolbar-button mai-lq-toolbar-btn';
		state.searchButton.title = TEXT.search;
		state.searchButton.setAttribute('aria-label', TEXT.search);
		state.searchButton.innerHTML = '<i class="v-icon material-icons" aria-hidden="true">search</i>';
		state.searchButton.addEventListener('click', function (event) {
			event.preventDefault();
			event.stopPropagation();
			search();
		});
		bar.appendChild(state.searchButton);

		state.cancelButton = document.createElement('button');
		state.cancelButton.type = 'button';
		state.cancelButton.className = 'v-btn v-btn--flat v-btn--icon v-btn--small toolbar-button mai-lq-toolbar-btn mai-lq-cancel';
		state.cancelButton.title = TEXT.cancel;
		state.cancelButton.setAttribute('aria-label', TEXT.cancel);
		state.cancelButton.style.display = 'none';
		state.cancelButton.innerHTML = '<i class="v-icon material-icons" aria-hidden="true">close</i>';
		state.cancelButton.addEventListener('click', function (event) {
			event.preventDefault();
			event.stopPropagation();
			cancelSearch(true);
		});
		bar.appendChild(state.cancelButton);
		panel.appendChild(bar);

		state.progressBar = document.createElement('div');
		state.progressBar.className = 'mai-lq-progress';
		state.progressBar.setAttribute('role', 'progressbar');
		state.progressBar.setAttribute('aria-valuemin', '0');
		state.progressBar.setAttribute('aria-valuemax', '100');
		state.progressFill = document.createElement('div');
		state.progressFill.className = 'mai-lq-progress-fill';
		state.progressBar.appendChild(state.progressFill);
		panel.appendChild(state.progressBar);

		state.status = document.createElement('div');
		state.status.className = 'mai-lq-status';
		panel.appendChild(state.status);

		state.list = document.createElement('div');
		state.list.className = 'lms-list mai-lq-list';
		state.list.id = 'mai-lq-list';
		panel.appendChild(state.list);

		state.resizer = document.createElement('div');
		state.resizer.className = 'mai-lq-resizer';
		state.resizer.setAttribute('role', 'separator');
		state.resizer.setAttribute('aria-orientation', 'horizontal');
		state.resizer.title = IS_ZH ? '拖动调整歌词高度' : 'Drag to resize lyrics';
		panel.appendChild(state.resizer);

		state.preview = document.createElement('div');
		state.preview.className = 'mai-lq-lyrics np-info-lyrics';
		state.preview.id = 'mai-lq-lyrics';
		state.preview.style.flex = '0 0 33.333%';
		panel.appendChild(state.preview);

		initPreviewResizer(panel);
		return panel;
	}

	function onSearchKey(event) {
		if (event.key === 'Enter' || event.keyCode === 13) {
			event.preventDefault();
			search();
		}
	}

	function ensurePanel() {
		var view = document.querySelector('#queue-view');
		if (!view) return false;

		state.queueView = view;
		var toolbar = null;
		for (var i = 0; i < view.children.length; i++) {
			if (view.children[i].classList && view.children[i].classList.contains('subtoolbar')) {
				toolbar = view.children[i];
				break;
			}
		}
		if (!toolbar) return false;

		if (!state.panel) {
			state.panel = createPanel();
		}

		if (state.panel.parentNode !== view || state.panel.previousElementSibling !== toolbar) {
			view.insertBefore(state.panel, toolbar.nextSibling);
		}

		state.panel.style.display = '';

		for (var c = 0; c < view.children.length; c++) {
			var child = view.children[c];
			if (child !== state.panel && child.classList && child.classList.contains('lms-list')) {
				state.queueList = child;
				break;
			}
		}

		view.classList.add('mai-lq-active');
		state.active = true;
		return true;
	}

	function deactivate() {
		cancelSearch(false, '');
		stopSync();
		state.open = false;
		state.active = false;
		if (state.queueView) state.queueView.classList.remove('mai-lq-active');
		if (state.panel) state.panel.style.display = 'none';
		updateToolbarButton();
	}

	function createQueueButton() {
		var btn = document.createElement('button');
		btn.type = 'button';
		btn.className = 'v-btn v-btn--flat v-btn--icon v-btn--small toolbar-button mai-lq-toolbar-btn mai-lq-toggle';
		btn.title = TEXT.menu;
		btn.setAttribute('aria-label', TEXT.menu);
		btn.innerHTML = '<i class="v-icon material-icons" aria-hidden="true">lyrics</i>';
		btn.addEventListener('click', function (event) {
			event.preventDefault();
			event.stopPropagation();
			if (state.open) {
				deactivate();
			} else {
				activate();
			}
		});
		return btn;
	}

	function ensureToolbarButton() {
		var view = document.querySelector('#queue-view');
		if (!view) return;

		var toolbar = null;
		for (var i = 0; i < view.children.length; i++) {
			if (view.children[i].classList && view.children[i].classList.contains('subtoolbar')) {
				toolbar = view.children[i];
				break;
			}
		}
		if (!toolbar) return;

		var existing = toolbar.querySelector('.mai-lq-toggle');
		if (existing) {
			existing.classList.toggle('mai-lq-toggle-active', state.open);
			return;
		}

		var actions = null;
		var buttons = toolbar.querySelectorAll('.v-btn');
		for (var b = 0; b < buttons.length; b++) {
			var icon = buttons[b].querySelector('.v-icon');
			if (icon && (icon.textContent || '').trim() === 'more_vert') {
				actions = buttons[b];
				break;
			}
		}

		var button = createQueueButton();
		if (actions && actions.parentNode) {
			actions.parentNode.insertBefore(button, actions.nextSibling);
		} else {
			toolbar.appendChild(button);
		}
		button.classList.toggle('mai-lq-toggle-active', state.open);
	}

	function updateToolbarButton() {
		var btn = document.querySelector('#queue-view .mai-lq-toggle');
		if (btn) btn.classList.toggle('mai-lq-toggle-active', state.open);
	}

	function addMenuEntry() {
		if (document.querySelector('.mai-lq-menu-entry')) return;

		var menus = document.querySelectorAll('.v-menu__content');
		var target = null;
		for (var i = 0; i < menus.length; i++) {
			var style = window.getComputedStyle(menus[i]);
			if (style.display === 'none' || style.visibility === 'hidden') continue;
			var text = menus[i].innerText || '';
			// The config menu contains the zoom percentages; the same menu is
			// used for every UI language.
			if ((text.indexOf('Zoom') >= 0 || text.indexOf('缩放') >= 0)
				|| (text.indexOf('100%') >= 0 && text.indexOf('200%') >= 0)) {
				target = menus[i];
				break;
			}
		}
		if (!target) return;

		var list = target.querySelector('.v-list') || target;

		var item = document.createElement('div');
		item.className = 'v-list__tile v-list__tile--link mai-lq-menu-entry';
		item.setAttribute('role', 'menuitem');
		item.setAttribute('tabindex', '0');
		item.innerHTML = '<div class="v-list__tile__content"><div class="v-list__tile__title"></div></div>';
		item.querySelector('.v-list__tile__title').textContent = TEXT.menu;
		item.addEventListener('click', function (event) {
			event.preventDefault();
			event.stopPropagation();
			try {
				var vm = findNowPlaying(window.app, 0);
				if (vm && vm.menu) vm.menu.show = false;
			} catch (e) {}
			openQueueLyrics();
		});
		// Put "Choose lyrics" in the section above the zoom controls.  The
		// existing divider between the display options and the zoom header
		// is kept, so the menu reads: options / Choose lyrics / divider /
		// zoom.
		var anchor = null;
		for (var c = 0; c < list.children.length; c++) {
			var child = list.children[c];
			if ((child.innerText || '').indexOf('Zoom') >= 0
				|| (child.innerText || '').indexOf('缩放') >= 0) {
				anchor = child;
				break;
			}
		}
		if (anchor && anchor.previousElementSibling
			&& anchor.previousElementSibling.classList
			&& anchor.previousElementSibling.classList.contains('v-divider')) {
			anchor = anchor.previousElementSibling;
		}
		if (anchor) {
			list.insertBefore(item, anchor);
		} else {
			list.insertBefore(item, list.firstChild);
		}
	}

	function fillInfo(info) {
		state.playerId = info.player || '';
		state.trackId = info.trackId || '';
		state.url = info.url || '';
		state.album = info.album || '';
		state.duration = info.duration || '';
		if (state.titleInput && !state.titleInput.value) state.titleInput.value = info.title || '';
		if (state.artistInput && !state.artistInput.value) state.artistInput.value = info.artist || '';
	}

	function clearSearchTimer() {
		if (state.searchTimer) {
			clearTimeout(state.searchTimer);
			state.searchTimer = null;
		}
	}

	function abortSearchRequests() {
		if (state.startController) {
			try { state.startController.abort(); } catch (e) {}
			state.startController = null;
		}
		if (state.pollController) {
			try { state.pollController.abort(); } catch (e) {}
			state.pollController = null;
		}
	}

	function formatFound(count) {
		return TEXT.found.replace('%1', String(count));
	}

	function updateProgress() {
		if (!state.progressBar || !state.progressFill) return;

		var total = Number(state.total) || 0;
		var progress = Number(state.progress) || 0;
		var searching = !state.searchDone && !state.cancelled;
		var percent = total > 0 ? Math.max(0, Math.min(100, Math.round(progress / total * 100))) : 0;

		state.progressBar.classList.toggle('indeterminate', searching && total <= 0);
		state.progressBar.classList.toggle('done', state.searchDone && !state.cancelled);
		state.progressBar.classList.toggle('cancelled', state.cancelled);
		state.progressBar.setAttribute('aria-valuenow', String(percent));

		if (searching && total <= 0) {
			state.progressFill.style.width = '';
		} else {
			state.progressFill.style.width = percent + '%';
		}
	}

	function showSearchUi(searching) {
		if (state.searchButton) state.searchButton.disabled = !!searching;
		if (state.cancelButton) state.cancelButton.style.display = searching ? '' : 'none';
	}

	function setSearchRunning(running) {
		state.searchDone = !running;
		showSearchUi(running);
		updateProgress();
	}

	function cancelSearch(userInitiated, message) {
		var id = state.searchId;

		state.searchSeq++;
		clearSearchTimer();
		abortSearchRequests();

		state.searchDone = true;
		state.cancelled = true;
		state.busy = false;

		showSearchUi(false);
		updateProgress();
		setStatus(message || TEXT.cancelled);

		if (id) {
			requestJson('/plugins/MusicArtistInfo/lyrics/cancel?' + encodeQuery({
				search_id: id,
				_: Date.now()
			}), {
				method: 'POST',
				headers: { 'X-Requested-With': 'XMLHttpRequest' },
				credentials: 'same-origin'
			}).catch(function () {});
		}
	}

	function schedulePoll() {
		clearSearchTimer();
		if (!state.open || state.searchDone || !state.searchId) return;

		var seq = state.searchSeq;
		state.searchTimer = setTimeout(function () {
			pollSearch(seq);
		}, 450);
	}

	function applySnapshot(snapshot) {
		if (!snapshot) return;

		state.total = Number(snapshot.total) || 0;
		state.progress = Number(snapshot.progress) || 0;
		state.candidates = snapshot.candidates || [];
		state.searchDone = !!snapshot.done;
		state.cancelled = !!snapshot.cancelled;

		renderCandidates();
		if (state.candidates.length) renderPreview(state.candidates[0]);
		updateProgress();

		if (state.searchDone || state.cancelled) {
			clearSearchTimer();
			showSearchUi(false);
			updateProgress();

			if (state.cancelled) {
				setStatus(TEXT.cancelled);
			} else if (!state.candidates.length) {
				setStatus(TEXT.none);
			} else {
				setStatus('');
			}
		} else {
			showSearchUi(true);
			setStatus(TEXT.searching + (state.candidates.length ? ' · ' + formatFound(state.candidates.length) : ''));
		}
	}

	function pollSearch(seq) {
		if (seq !== state.searchSeq || !state.open || state.searchDone || !state.searchId) return;

		if (Date.now() > state.searchDeadline) {
			cancelSearch(true, TEXT.timeout);
			return;
		}

		var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
		state.pollController = controller;

		var options = {
			method: 'GET',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		};
		if (controller) options.signal = controller.signal;

		var url = '/plugins/MusicArtistInfo/lyrics/search?' + encodeQuery({
			search_id: state.searchId,
			_: Date.now()
		});

		requestJson(url, options).then(function (result) {
			if (state.pollController === controller) state.pollController = null;
			if (seq !== state.searchSeq || !state.open) return;

			if (result && result.error) {
				setSearchRunning(false);
				setStatus(result.error);
				return;
			}

			applySnapshot(result);

			if (!state.searchDone && !state.cancelled) schedulePoll();
		}).catch(function (error) {
			if (state.pollController === controller) state.pollController = null;
			if (seq !== state.searchSeq || !state.open) return;
			if (error && error.name === 'AbortError') return;

			setSearchRunning(false);
			setStatus(TEXT.error);
		});
	}

	function search() {
		if (!state.titleInput || !state.artistInput) return;

		var title = state.titleInput.value.trim();
		var artist = state.artistInput.value.trim();

		cancelSearch(false, '');

		state.searchSeq++;
		state.searchId = '';
		state.session = '';
		state.candidates = [];
		state.selectedHash = '';
		stopSync();
		if (state.preview) state.preview.innerHTML = '';
		state.searchDone = false;
		state.cancelled = false;
		state.busy = false;
		state.progress = 0;
		state.total = 0;

		if (state.list) state.list.innerHTML = '';

		if (!title && !artist) {
			setSearchRunning(false);
			setStatus(TEXT.missing);
			return;
		}

		setSearchRunning(true);
		updateProgress();
	setStatus(TEXT.searching);

		var seq = state.searchSeq;
		var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
		var startTimedOut = false;
		var startTimer = setTimeout(function () {
			startTimedOut = true;
			if (controller) {
				try { controller.abort(); } catch (e) {}
			}
		}, 15000);

		state.startController = controller;

		var options = {
			method: 'GET',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		};
		if (controller) options.signal = controller.signal;

		var url = '/plugins/MusicArtistInfo/lyrics/candidates?' + encodeQuery({
			track_id: state.trackId,
			url: state.url,
			title: title,
			artist: artist,
			album: state.album,
			duration: state.duration,
			player: state.playerId,
			async: 1,
			_: Date.now()
		});

		requestJson(url, options).then(function (result) {
			clearTimeout(startTimer);
			if (state.startController === controller) state.startController = null;
			if (seq !== state.searchSeq || !state.open) return;

			if (result && result.error) {
				setSearchRunning(false);
				setStatus(result.error);
				return;
			}

			state.searchId = result.search_id || result.session || '';
			state.session = state.searchId;
			state.searchDeadline = Date.now() + 32000;

			applySnapshot(result);

			if (!state.searchDone && !state.cancelled) schedulePoll();
		}).catch(function (error) {
			clearTimeout(startTimer);
			if (state.startController === controller) state.startController = null;
			if (seq !== state.searchSeq || !state.open) return;
			if (error && error.name === 'AbortError' && !startTimedOut) return;

			setSearchRunning(false);
			setStatus(startTimedOut ? TEXT.timeout : TEXT.error);
		});
	}

	function renderCandidates() {
		if (!state.list) return;

		var scrollTop = state.list.scrollTop;
		state.list.innerHTML = '';

		state.candidates.forEach(function (candidate, index) {
			var selected = candidate.hash
				? candidate.hash === state.selectedHash
				: index === 0 && !state.selectedHash;

			var row = document.createElement('button');
			row.type = 'button';
			row.className = 'mai-lq-item' + (selected ? ' selected' : '');
			row.setAttribute('data-index', String(index));
			if (candidate.hash) row.setAttribute('data-hash', candidate.hash);

			var head = document.createElement('div');
			head.className = 'mai-lq-head';

			var badge = document.createElement('span');
			badge.className = 'mai-lq-badge' + (candidate.synced ? ' mai-lq-badge-synced' : '');
			badge.textContent = candidate.synced ? TEXT.synced : TEXT.plain;
			head.appendChild(badge);

			var title = document.createElement('span');
			title.className = 'mai-lq-title';
			title.textContent = candidate.title || candidate.artist || TEXT.choose;
			head.appendChild(title);

			row.appendChild(head);

			var meta = document.createElement('span');
			meta.className = 'mai-lq-meta';
			meta.textContent = [candidate.artist, candidate.album, candidate.source ? TEXT.source + ': ' + candidate.source : '']
				.filter(Boolean).join(' — ');
			row.appendChild(meta);

			if (candidate.preview) {
				var preview = document.createElement('span');
				preview.className = 'mai-lq-preview';
				preview.textContent = candidate.preview;
				row.appendChild(preview);
			}

			row.addEventListener('click', function (event) {
				event.preventDefault();
				event.stopPropagation();
				applyCandidate(candidate.hash || '', index);
			});

			state.list.appendChild(row);
		});

		state.list.scrollTop = scrollTop;
	}

	function parseLrc(text) {
		var lines = [];
		var re = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/g;
		String(text || '').split(/\r?\n/).forEach(function (raw) {
			var times = [];
			var m;
			while ((m = re.exec(raw)) !== null) {
				var fraction = m[3] ? parseInt(m[3], 10) : 0;
				if (m[3] && m[3].length === 2) fraction *= 10;
				times.push(parseInt(m[1], 10) * 60 + parseInt(m[2], 10) + fraction / 1000);
			}
			var lineText = raw.replace(re, '').trim();
			if (!times.length || /^\[[a-z]+:/i.test(raw)) return;
			times.forEach(function (time) { lines.push({ time: time, text: lineText }); });
		});
		lines.sort(function (a, b) { return a.time - b.time; });
		return lines;
	}
	function stopSync() {
		if (state.syncTimer) { clearInterval(state.syncTimer); state.syncTimer = null; }
	}
	function renderPreview(candidate) {
		if (!state.preview) return;
		state.preview.innerHTML = '';
		state.lines = [];
		state.currentLine = -1;
		if (!candidate) return;
		if (candidate.synced) {
			var lines = parseLrc(candidate.lyrics);
			if (lines.length) {
				state.lines = lines;
				lines.forEach(function (line, index) {
					var row = document.createElement('div');
					row.className = 'mai-lq-line';
					row.setAttribute('data-index', index);
					row.textContent = line.text || ' ';
					state.preview.appendChild(row);
				});
				startSync();
				updateCurrentLine(true);
				return;
			}
		}
		state.preview.textContent = candidate.lyrics || '';
		stopSync();
	}
	function updateCurrentLine(scroll) {
		if (!state.lines.length || !state.preview) return;
		var index = -1;
		for (var i = 0; i < state.lines.length; i++) {
			if (state.lines[i].time <= state.currentTime) index = i;
			else break;
		}
		if (index < 0) index = 0;
		if (index === state.currentLine && !scroll) return;
		state.currentLine = index;
		var nodes = state.preview.querySelectorAll('.mai-lq-line');
		Array.prototype.forEach.call(nodes, function (node, i) {
			node.classList.toggle('lyrics-current-line', i === index);
		});
		if (nodes[index] && scroll) {
			try { nodes[index].scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) {}
		}
	}
	function fetchPlaybackTime() {
		if (!state.playerId || !state.open) return;
		if (typeof window.lmsCommand === 'function') {
			window.lmsCommand(state.playerId, ['status', 0, 1, 'tags:']).then(function (response) {
				var result = response && response.data ? response.data.result : (response && response.result);
				if (!result || result.time === undefined) return;
				state.currentTime = Number(result.time) || 0;
				updateCurrentLine(false);
			}).catch(function () {});
			return;
		}
		fetch('/jsonrpc.js', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			credentials: 'same-origin',
			body: JSON.stringify({ id: 1, method: 'slim.request', params: [ state.playerId, ['status', '-', 1, 'tags:'] ] })
		}).then(function (r) { return r.json(); }).then(function (data) {
			var result = data && data.result;
			if (!result || result.time === undefined) return;
			state.currentTime = Number(result.time) || 0;
			updateCurrentLine(false);
		}).catch(function () {});
	}
	function startSync() {
		stopSync();
		if (!state.lines.length || !state.playerId) return;
		state.syncTimer = setInterval(fetchPlaybackTime, 500);
		fetchPlaybackTime();
	}

	function applyCandidate(hash, index) {
		if (state.busy || !state.searchId) return;

		var candidate = null;
		if (hash) {
			for (var i = 0; i < state.candidates.length; i++) {
				if (state.candidates[i].hash === hash) {
					candidate = state.candidates[i];
					break;
				}
			}
		} else {
			candidate = state.candidates[index];
		}

		if (!candidate) return;

		state.selectedHash = candidate.hash || '';
		renderCandidates();
		renderPreview(candidate);
		state.busy = true;
		setStatus(TEXT.applying);

		var params = {
			session: state.searchId,
			_: Date.now()
		};
		if (candidate.hash) {
			params.hash = candidate.hash;
		} else {
			params.index = index;
		}

		var url = '/plugins/MusicArtistInfo/lyrics/select?' + encodeQuery(params);

		requestJson(url, {
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		}).then(function (result) {
			state.busy = false;
			if (result && result.error) {
				setStatus(result.error);
				return;
			}

			setStatus((candidate.source ? TEXT.source + ': ' + candidate.source + ' · ' : '') + TEXT.applied);
			refreshNowPlaying();
		}).catch(function () {
			state.busy = false;
			setStatus(TEXT.error);
		});
	}

	function refreshNowPlaying() {
		var vm = findNowPlaying(window.app, 0);
		if (!vm) return;

		var tab = vm.info && vm.info.tabs ? vm.info.tabs[2] : null;
		if (tab) {
			tab.tracktitle = null;
			tab.artist = null;
			tab.url = null;
			tab.track_id = null;
		}

		try { vm.fetchTrackInfo(); } catch (e) {}
	}

	function activate() {
		state.open = true;
		ensureQueue(function () {
			if (!ensurePanel()) return;
			ensureToolbarButton();
			updateToolbarButton();

			requestCurrentInfo(function (info) {
				if (!state.open) return;
				fillInfo(info);
				search();
			});
		});
	}

	function openQueueLyrics() {
		activate();
	}

	function scan() {
		addStyle();

		ensureToolbarButton();

		if (state.open) {
			if (!ensurePanel()) return;
			updateToolbarButton();
		}
	}

	document.addEventListener('click', function (event) {
		var target = event.target;
		if (!target || !target.closest) return;
		if (target.closest('.np-menu-fab')) {
			setTimeout(addMenuEntry, 80);
		}
	}, true);

	setInterval(scan, 500);
	document.addEventListener('DOMContentLoaded', scan);
	if (document.readyState !== 'loading') scan();
})();
