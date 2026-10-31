(function () {
	'use strict';

	if (window.MAILyrics) {
		return;
	}

	var DEFAULT_STRINGS = {
		choose: 'Choose lyrics',
		title: 'Title',
		artist: 'Artist',
		search: 'Search',
		use: 'Use this lyrics',
		close: 'Close',
		loading: 'Searching for lyrics...',
		none: 'No lyrics found',
		error: 'Could not load lyrics',
		saved: 'Saved',
		cached: 'Cached',
		source: 'Source',
		synced: 'Synced',
		plain: 'Plain text',
		timeout: 'Search timed out. Please try again.'
	};

	var state = {
		overlay: null,
		dialog: null,
		button: null,
		strings: DEFAULT_STRINGS,
		endpoint: '/plugins/MusicArtistInfo/lyrics',
		trackId: '',
		url: '',
		title: '',
		artist: '',
		album: '',
		duration: '',
		player: '',
		onApply: null,
		session: '',
		requestId: 0,
		controller: null,
		candidates: [],
		selected: -1,
		busy: false,
		lines: [],
		currentLine: -1,
		syncTimer: null
	};

	function text(value) {
		return value === null || value === undefined ? '' : String(value);
	}

	function el(tag, className, content) {
		var node = document.createElement(tag);
		if (className) node.className = className;
		if (content !== undefined && content !== null) node.textContent = content;
		return node;
	}

	function mergeStrings(parsed) {
		var merged = {};
		Object.keys(DEFAULT_STRINGS).forEach(function (key) {
			merged[key] = text(parsed && parsed[key]) || DEFAULT_STRINGS[key];
		});
		return merged;
	}

	function parseStrings(button) {
		var raw = button.getAttribute('data-strings');
		if (!raw) return DEFAULT_STRINGS;

		try {
			return mergeStrings(JSON.parse(raw));
		} catch (e) {
			return DEFAULT_STRINGS;
		}
	}

	function addStyle() {
		if (document.getElementById('maiLyricsChooserStyle')) return;

		var style = document.createElement('style');
		style.id = 'maiLyricsChooserStyle';
		style.textContent =
			'.mai-lyrics-overlay{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box}' +
			'.mai-lyrics-dialog{background:#fff;color:#222;width:min(1000px,100%);height:90vh;max-height:calc(100vh - 32px);border-radius:8px;box-shadow:0 20px 60px rgba(0,0,0,.35);display:flex;flex-direction:column;overflow:hidden;font-size:14px}' +
			'.mai-lyrics-header{display:flex;align-items:center;justify-content:space-between;padding:12px 16px;border-bottom:1px solid #ddd;font-weight:bold;font-size:16px}' +
			'.mai-lyrics-close{border:0;background:transparent;font-size:22px;line-height:1;cursor:pointer;color:#555;padding:0 4px}' +
			'.mai-lyrics-search{display:flex;flex-wrap:wrap;gap:8px;align-items:flex-end;padding:12px 16px;border-bottom:1px solid #eee;background:#fafafa}' +
			'.mai-lyrics-search label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#555;min-width:160px;flex:1}' +
			'.mai-lyrics-search input{padding:6px 8px;border:1px solid #bbb;border-radius:4px;font-size:14px}' +
			'.mai-lyrics-body{display:flex;flex-direction:column;gap:0;min-height:0;flex:1 1 0;overflow:hidden}' +
			'.mai-lyrics-list{width:100%;min-width:0;overflow:auto;border-bottom:1px solid #e5e5e5;flex:1 1 0;min-height:0}' +
			'.mai-lyrics-item{display:block;width:100%;text-align:left;border:0;border-bottom:1px solid #eee;background:#fff;padding:10px 12px;cursor:pointer;font:inherit;color:inherit}' +
			'.mai-lyrics-item:hover{background:#f2f7fb}' +
			'.mai-lyrics-item.selected{background:#e3f0fa}' +
			'.mai-lyrics-item-title{font-weight:bold;display:block;margin-bottom:2px}' +
			'.mai-lyrics-item-meta{color:#666;font-size:12px;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
			'.mai-lyrics-badge{display:inline-block;margin-left:6px;padding:0 5px;border-radius:3px;background:#eee;color:#666;font-size:11px;vertical-align:middle}' +
			'.mai-lyrics-badge.mai-lyrics-badge-synced{background:#e3f0fa;color:#145a8a;font-weight:bold}' +
			'.mai-lyrics-preview{flex:0 0 33.333%;overflow:auto;padding:12px 16px;white-space:pre-wrap;line-height:1.5;min-height:72px;max-height:70%;}' +
			'.mai-lyrics-resizer{flex:0 0 0;height:0;min-height:0;cursor:row-resize;background:transparent;position:relative;overflow:visible;touch-action:none}' +
			'.mai-lyrics-resizer:before{content:"";position:absolute;left:0;right:0;top:-5px;height:10px;cursor:row-resize}' +
			'.mai-lyrics-resizer:after{content:"";position:absolute;left:50%;top:2px;width:34px;height:3px;margin-left:-17px;border-radius:2px;background:#999;opacity:.55}' +
			'.mai-lyrics-footer{display:flex;gap:8px;align-items:center;padding:10px 16px;border-top:1px solid #ddd;background:#fafafa}' +
			'.mai-lyrics-status{flex:1;color:#555;font-size:13px;min-height:18px}' +
			'.mai-lyrics-status.error{color:#b00020}' +
			'.mai-lyrics-footer button{padding:7px 14px;border:1px solid #999;border-radius:4px;background:#fff;cursor:pointer;font:inherit}' +
			'.mai-lyrics-footer button.primary{background:#2b7bb9;border-color:#2b7bb9;color:#fff}' +
			'.mai-lyrics-footer button:disabled{opacity:.5;cursor:default}' +
			'.mai-lyrics-empty{padding:16px;color:#666}' +
			'.mai-lyrics-sync-line{padding:2px 8px;border-radius:4px;transition:background .15s,color .15s;white-space:pre-wrap}' +
			'.mai-lyrics-sync-line.mai-lyrics-sync-current{background:#e3f0fa;color:#145a8a;font-weight:bold}';
		document.head.appendChild(style);
	}

	function setStatus(message, isError) {
		var node = document.getElementById('maiLyricsStatus');
		if (!node) return;
		node.textContent = message || '';
		node.className = 'mai-lyrics-status' + (isError ? ' error' : '');
	}

	function setBusy(busy) {
		state.busy = busy;
		var search = document.getElementById('maiLyricsSearchButton');
		var use = document.getElementById('maiLyricsUseButton');
		if (search) search.disabled = busy;
		if (use) use.disabled = busy || state.selected < 0;
	}

	function requestJson(url, options) {
		options = options || {};

		if (window.fetch) {
			return fetch(url, options).then(function (response) {
				return response.text().then(function (body) {
					try {
						return JSON.parse(body);
					} catch (e) {
						throw new Error('Invalid response from server');
					}
				});
			});
		}

		return new Promise(function (resolve, reject) {
			var xhr = new XMLHttpRequest();
			xhr.open(options.method || 'GET', url, true);
			xhr.withCredentials = true;
			xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');

			try {
				Object.keys(options.headers || {}).forEach(function (key) {
					xhr.setRequestHeader(key, options.headers[key]);
				});
			} catch (e) {
				// ignore
			}

			xhr.onreadystatechange = function () {
				if (xhr.readyState !== 4) return;
				try {
					resolve(JSON.parse(xhr.responseText));
				} catch (e) {
					reject(new Error('Invalid response from server'));
				}
			};
			xhr.onerror = function () {
				reject(new Error('Network error'));
			};
			xhr.send(null);
		});
	}

	function queryString(params) {
		return Object.keys(params).map(function (key) {
			return encodeURIComponent(key) + '=' + encodeURIComponent(text(params[key]));
		}).join('&');
	}

	function renderCandidates() {
		var list = document.getElementById('maiLyricsCandidateList');
		if (!list) return;
		list.innerHTML = '';

		if (!state.candidates.length) {
			list.appendChild(el('div', 'mai-lyrics-empty', state.strings.none));
			return;
		}

		state.candidates.forEach(function (candidate, index) {
			var button = el('button', 'mai-lyrics-item' + (index === state.selected ? ' selected' : ''));
			button.type = 'button';

			var title = el('span', 'mai-lyrics-item-title', text(candidate.title) || text(state.title));
			var badge = el('span', 'mai-lyrics-badge' + (candidate.synced ? ' mai-lyrics-badge-synced' : ''),
				candidate.synced ? state.strings.synced : state.strings.plain);
			title.appendChild(badge);

			var metaParts = [];
			if (candidate.artist) metaParts.push(candidate.artist);
			if (candidate.album) metaParts.push(candidate.album);
			if (candidate.source) metaParts.push(state.strings.source + ': ' + candidate.source);

			button.appendChild(title);
			button.appendChild(el('span', 'mai-lyrics-item-meta', metaParts.join(' — ')));

			button.addEventListener('click', function () {
				selectCandidate(index);
			});

			list.appendChild(button);
		});
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
				else if (m[3] && m[3].length === 3) { /* already ms */ }
				times.push(parseInt(m[1], 10) * 60 + parseInt(m[2], 10) + fraction / 1000);
			}
			var lineText = raw.replace(re, '').trim();
			if (!times.length || /^\[[a-z]+:/i.test(raw)) return;
			times.forEach(function (time) { lines.push({ time: time, text: lineText }); });
		});
		lines.sort(function (a, b) { return a.time - b.time; });
		return lines;
	}
	function renderPreview(candidate) {
		var preview = document.getElementById('maiLyricsPreview');
		if (!preview) return;
		preview.innerHTML = '';
		state.lines = [];
		state.currentLine = -1;
		if (!candidate) return;
		if (candidate.synced) {
			var lines = parseLrc(candidate.lyrics);
			if (lines.length) {
				state.lines = lines;
				lines.forEach(function (line, index) {
					var row = document.createElement('div');
					row.className = 'mai-lyrics-sync-line';
					row.setAttribute('data-index', index);
					row.textContent = line.text || ' ';
					preview.appendChild(row);
				});
				updateCurrentLine(true);
				startSync();
				return;
			}
		}
		preview.textContent = candidate.lyrics || '';
		stopSync();
	}
	function updateCurrentLine(scroll) {
		if (!state.lines.length || !state.player) return;
		var time = state.currentTime || 0;
		var index = -1;
		for (var i = 0; i < state.lines.length; i++) {
			if (state.lines[i].time <= time) index = i;
			else break;
		}
		if (index < 0) index = 0;
		if (index === state.currentLine && !scroll) return;
		state.currentLine = index;
		var nodes = document.querySelectorAll('#maiLyricsPreview .mai-lyrics-sync-line');
		Array.prototype.forEach.call(nodes, function (node, i) {
			node.classList.toggle('mai-lyrics-sync-current', i === index);
		});
		if (nodes[index] && scroll) {
			try { nodes[index].scrollIntoView({ block: 'center', behavior: 'smooth' }); } catch (e) {}
		}
	}
	function stopSync() {
		if (state.syncTimer) { clearInterval(state.syncTimer); state.syncTimer = null; }
	}
	function startSync() {
		stopSync();
		if (!state.lines.length || !state.player) return;
		state.syncTimer = setInterval(fetchPlaybackTime, 500);
		fetchPlaybackTime();
	}
	function fetchPlaybackTime() {
		if (!state.player || !state.overlay) return;
		fetch('/jsonrpc.js', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			credentials: 'same-origin',
			body: JSON.stringify({ id: 1, method: 'slim.request', params: [ state.player, ['status', '-', 1, 'tags:'] ] })
		}).then(function (r) { return r.json(); }).then(function (data) {
			var result = data && data.result;
			if (!result || result.time === undefined) return;
			state.currentTime = Number(result.time) || 0;
			updateCurrentLine(false);
		}).catch(function () {});
	}

	function selectCandidate(index) {
		state.selected = index;
		var candidate = state.candidates[index];

		renderCandidates();
		renderPreview(candidate);

		var use = document.getElementById('maiLyricsUseButton');
		if (use) use.disabled = state.busy || !candidate;
	}

	function search() {
		var titleInput = document.getElementById('maiLyricsTitle');
		var artistInput = document.getElementById('maiLyricsArtist');

		state.title = titleInput.value;
		state.artist = artistInput.value;
		state.session = '';
		state.candidates = [];
		state.selected = -1;

		document.getElementById('maiLyricsCandidateList').innerHTML = '';
		document.getElementById('maiLyricsPreview').textContent = '';

		setStatus(state.strings.loading, false);
		setBusy(true);

		if (state.controller) {
			try { state.controller.abort(); } catch (e) {}
			state.controller = null;
		}

		var requestId = ++state.requestId;
		var controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
		var timedOut = false;
		var timer = setTimeout(function () {
			timedOut = true;
			if (controller) {
				controller.abort();
			} else {
				state.requestId++;
				setBusy(false);
				setStatus(state.strings.timeout, true);
			}
		}, 30000);

		state.controller = controller;

		var url = state.endpoint + '/candidates?' + queryString({
			track_id: state.trackId,
			url: state.url,
			title: state.title,
			artist: state.artist,
			album: state.album,
			duration: state.duration,
			player: state.player,
			_: Date.now()
		});

		var options = {
			method: 'GET',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		};

		if (controller) {
			options.signal = controller.signal;
		}

		requestJson(url, options).then(function (result) {
			clearTimeout(timer);
			if (requestId !== state.requestId || !state.overlay) return;
			state.controller = null;
			setBusy(false);

			if (result && result.error) {
				setStatus(result.error, true);
				return;
			}

			state.session = result.session || '';
			state.candidates = result.candidates || [];

			if (!state.candidates.length) {
				setStatus(state.strings.none, false);
				renderCandidates();
				return;
			}

			setStatus('', false);
			selectCandidate(0);
		}).catch(function (error) {
			clearTimeout(timer);
			if (requestId !== state.requestId || !state.overlay) return;
			state.controller = null;
			setBusy(false);

			if (timedOut || (error && error.name === 'AbortError')) {
				setStatus(state.strings.timeout, true);
				return;
			}

			setStatus((error && error.message) || state.strings.error, true);
		});
	}

	function useSelected() {
		if (state.busy || !state.session || state.selected < 0) return;

		var candidate = state.candidates[state.selected];
		if (!candidate) return;

		setBusy(true);
		setStatus(state.strings.loading, false);

		var url = state.endpoint + '/select?' + queryString({
			session: state.session,
			index: state.selected,
			_: Date.now()
		});

		requestJson(url, {
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		}).then(function (result) {
			if (!state.overlay) return;
			setBusy(false);

			if (result && result.error) {
				setStatus(result.error, true);
				return;
			}

			var lyrics = text(result.lyrics);
			if (!lyrics) lyrics = candidate.lyrics;

			var display = document.getElementById('maiLyricsText');
			if (display) {
				display.textContent = lyrics;
				display.style.whiteSpace = 'pre-wrap';
			}

			var preview = document.getElementById('maiLyricsPreview');
			if (preview) preview.textContent = lyrics;

			var suffix = result.sidecar
				? ' (' + state.strings.saved + ')'
				: (result.cached ? ' (' + state.strings.cached + ')' : '');

			setStatus((candidate.source ? (state.strings.source + ': ' + candidate.source) : '') + suffix, false);

			if (typeof state.onApply === 'function') {
				try {
					state.onApply(result, candidate);
				} catch (e) {
					// ignore integration callback errors
				}
			}
		}).catch(function (error) {
			if (!state.overlay) return;
			setBusy(false);
			setStatus((error && error.message) || state.strings.error, true);
		});
	}

	function close() {
		state.requestId++;
		if (state.controller) {
			try { state.controller.abort(); } catch (e) {}
			state.controller = null;
		}

		stopSync();
		state.lines = [];
		if (state.overlay && state.overlay.parentNode) {
			state.overlay.parentNode.removeChild(state.overlay);
		}
		state.overlay = null;
		state.dialog = null;

		document.removeEventListener('keydown', onKeyDown);
	}

	function onKeyDown(event) {
		if (event.key === 'Escape' || event.keyCode === 27) {
			close();
		}
	}

	function initPreviewResizer(body, preview, resizer) {
		var dragging = false;
		var startY = 0;
		var startHeight = 0;
		function move(event) {
			if (!dragging || !preview) return;
			var point = event.touches ? event.touches[0] : event;
			if (!point) return;
			var bodyHeight = body.getBoundingClientRect().height;
			var next = startHeight - (point.clientY - startY);
			next = Math.max(72, Math.min(next, bodyHeight - 120));
			preview.style.flex = '0 0 ' + next + 'px';
			event.preventDefault();
		}
		function end() {
			dragging = false;
			document.removeEventListener('pointermove', move);
			document.removeEventListener('pointerup', end);
			document.removeEventListener('pointercancel', end);
		}
		resizer.addEventListener('pointerdown', function (event) {
			dragging = true;
			startY = event.clientY;
			startHeight = preview.getBoundingClientRect().height;
			document.addEventListener('pointermove', move);
			document.addEventListener('pointerup', end);
			document.addEventListener('pointercancel', end);
			event.preventDefault();
		});
	}

	function buildDialog() {
		var overlay = el('div', 'mai-lyrics-overlay');
		var dialog = el('div', 'mai-lyrics-dialog');
		dialog.setAttribute('role', 'dialog');
		dialog.setAttribute('aria-modal', 'true');

		var header = el('div', 'mai-lyrics-header');
		header.appendChild(el('span', '', state.strings.choose));
		var closeButton = el('button', 'mai-lyrics-close', '\u00d7');
		closeButton.type = 'button';
		closeButton.addEventListener('click', close);
		header.appendChild(closeButton);

		var searchBox = el('div', 'mai-lyrics-search');

		var titleLabel = el('label', '', state.strings.title);
		var titleInput = document.createElement('input');
		titleInput.id = 'maiLyricsTitle';
		titleInput.type = 'text';
		titleInput.value = state.title;
		titleInput.addEventListener('keydown', function (event) {
			if (event.key === 'Enter') search();
		});
		titleLabel.appendChild(titleInput);

		var artistLabel = el('label', '', state.strings.artist);
		var artistInput = document.createElement('input');
		artistInput.id = 'maiLyricsArtist';
		artistInput.type = 'text';
		artistInput.value = state.artist;
		artistInput.addEventListener('keydown', function (event) {
			if (event.key === 'Enter') search();
		});
		artistLabel.appendChild(artistInput);

		var searchButton = el('button', 'primary', state.strings.search);
		searchButton.type = 'button';
		searchButton.id = 'maiLyricsSearchButton';
		searchButton.addEventListener('click', search);

		searchBox.appendChild(titleLabel);
		searchBox.appendChild(artistLabel);
		searchBox.appendChild(searchButton);

		var body = el('div', 'mai-lyrics-body');
		var list = el('div', 'mai-lyrics-list');
		list.id = 'maiLyricsCandidateList';
		var preview = el('div', 'mai-lyrics-preview');
		preview.id = 'maiLyricsPreview';

		body.appendChild(list);
		var resizer = el('div', 'mai-lyrics-resizer');
		resizer.setAttribute('role', 'separator');
		resizer.setAttribute('aria-orientation', 'horizontal');
		body.appendChild(resizer);
		body.appendChild(preview);
		initPreviewResizer(body, preview, resizer);

		var footer = el('div', 'mai-lyrics-footer');
		var status = el('span', 'mai-lyrics-status');
		status.id = 'maiLyricsStatus';
		footer.appendChild(status);

		var useButton = el('button', 'primary', state.strings.use);
		useButton.type = 'button';
		useButton.id = 'maiLyricsUseButton';
		useButton.disabled = true;
		useButton.addEventListener('click', useSelected);

		var cancelButton = el('button', '', state.strings.close);
		cancelButton.type = 'button';
		cancelButton.addEventListener('click', close);

		footer.appendChild(useButton);
		footer.appendChild(cancelButton);

		dialog.appendChild(header);
		dialog.appendChild(searchBox);
		dialog.appendChild(body);
		dialog.appendChild(footer);

		overlay.appendChild(dialog);
		overlay.addEventListener('click', function (event) {
			if (event.target === overlay) close();
		});

		return { overlay: overlay, dialog: dialog };
	}

	function open(input) {
		addStyle();

		state.onApply = null;
		state.player = '';

		if (input && typeof input === 'object' && input.nodeType !== 1) {
			state.button = null;
			state.strings = mergeStrings(input.strings);
			state.endpoint = input.endpoint || state.endpoint;
			state.trackId = text(input.trackId || input.track_id);
			state.url = text(input.url);
			state.title = text(input.title);
			state.artist = text(input.artist);
			state.album = text(input.album);
			state.duration = text(input.duration);
			state.player = text(input.player);
			state.onApply = typeof input.onApply === 'function' ? input.onApply : null;
		} else {
			var button = input;
			state.button = button;
			state.strings = parseStrings(button);
			state.endpoint = button.getAttribute('data-endpoint') || state.endpoint;
			state.trackId = button.getAttribute('data-track-id') || '';
			state.url = button.getAttribute('data-url') || '';
			state.title = button.getAttribute('data-title') || '';
			state.artist = button.getAttribute('data-artist') || '';
			state.album = button.getAttribute('data-album') || '';
			state.duration = button.getAttribute('data-duration') || '';
			state.player = button.getAttribute('data-player') || '';
		}

		if (state.overlay) {
			return;
		}

		var built = buildDialog();
		state.overlay = built.overlay;
		state.dialog = built.dialog;

		document.body.appendChild(state.overlay);
		document.addEventListener('keydown', onKeyDown);

		search();
	}

	window.MAILyrics = {
		open: open,
		close: close
	};
})();
