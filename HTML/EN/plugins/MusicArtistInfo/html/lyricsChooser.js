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
		timeout: 'Search timed out. Please try again.',
		translate: 'Translate lyrics',
		translating: 'Translating lyrics...',
		translated: 'Lyrics translated',
		translate_queued: 'Translation queued',
		translate_failed: 'Translation failed',
		translate_no_file: 'No LRC file next to the song. Enable saving lyrics or choose lyrics first.',
		translate_already: 'Lyrics are already translated.',
		translate_already_target: 'Lyrics already look like the target language. Translate anyway?',
		translate_disabled: 'Lyrics translation is disabled in the plugin settings.',
		translate_skipped: 'Translation skipped: %s'
	};

	var state = {
		overlay: null,
		dialog: null,
		button: null,
		strings: DEFAULT_STRINGS,
		endpoint: '/plugins/MusicArtistInfo/lyrics',
		translateScript: '/plugins/MusicArtistInfo/html/lyricsTranslate.js',
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
		syncTimer: null,
		centerTimer: null,
		lastManualScroll: 0,
		programmaticScroll: false,
		bodyOverflow: null,
		zoomScale: 1,
		onViewportResize: null,
		opening: false,
		followTimer: null,
		followKey: '',
		followBusy: false
	};

	function text(value) {
		return value === null || value === undefined ? '' : String(value);
	}

	// The standard LMS web UI has no viewport meta tag on many skins.  Without
	// one, mobile browsers lay the page out at ~980px and scale it down, which
	// makes this dialog tiny.  Add a device-width viewport when the chooser is
	// opened; Material Skin and other responsive skins already provide one.
	function ensureViewportMeta() {
		if (document.querySelector('meta[name="viewport"]')) return;
		var head = document.head || document.getElementsByTagName('head')[0];
		if (!head) return;
		var meta = document.createElement('meta');
		meta.name = 'viewport';
		meta.content = 'width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content';
		head.appendChild(meta);
	}

	function lockBodyScroll() {
		if (state.bodyOverflow !== null) return;
		state.bodyOverflow = document.body.style.overflow || '';
		document.body.style.overflow = 'hidden';
	}

	function unlockBodyScroll() {
		if (state.bodyOverflow === null) return;
		document.body.style.overflow = state.bodyOverflow;
		state.bodyOverflow = null;
	}

	// Some mobile browsers (notably older iOS Safari) ignore viewport meta
	// changes made after the page has loaded.  In that case the page stays at
	// its ~980px desktop width and everything is scaled down.  Detect that and
	// scale the dialog back up so its controls remain readable and tappable.
	function viewportScale() {
		var screenWidth = 0;
		try {
			screenWidth = Math.min(window.screen.width || 0, window.screen.height || 0);
		} catch (e) {}
		var layoutWidth = window.innerWidth || 0;
		if (!screenWidth || screenWidth > 700 || !layoutWidth) return 1;
		var scale = layoutWidth / screenWidth;
		return scale > 1.4 ? scale : 1;
	}

	function applyViewportFallback() {
		if (!state.dialog) return;
		var scale = viewportScale();
		if (scale <= 1.01) {
			state.zoomScale = 1;
			state.dialog.style.width = '';
			state.dialog.style.height = '';
			state.dialog.style.maxHeight = '';
			state.dialog.style.transform = '';
			state.dialog.style.transformOrigin = '';
			return;
		}
		state.zoomScale = scale;
		state.dialog.style.width = (100 / scale) + '%';
		state.dialog.style.height = (90 / scale) + '%';
		state.dialog.style.maxHeight = 'none';
		state.dialog.style.transformOrigin = 'center center';
		state.dialog.style.transform = 'scale(' + scale + ')';
	}
	function isSynced(candidate) {
		return !!(candidate && (candidate.synced || /\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]/.test(candidate.lyrics || '')));
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
			'.mai-lyrics-overlay{position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box;overscroll-behavior:contain}' +
			'.mai-lyrics-dialog{background:#fff;color:#222;color-scheme:light;width:min(1000px,100%);height:90vh;height:90dvh;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);border-radius:8px;box-shadow:0 20px 60px rgba(0,0,0,.35);display:flex;flex-direction:column;overflow:hidden;font-size:14px;box-sizing:border-box}' +
			'.mai-lyrics-header{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:12px 16px;border-bottom:1px solid #ddd;font-weight:bold;font-size:16px;flex:0 0 auto}' +
			'.mai-lyrics-close{display:flex;align-items:center;justify-content:center;min-width:40px;min-height:40px;margin:-6px -8px -6px 0;border:0;border-radius:50%;background:transparent;font-size:24px;line-height:1;cursor:pointer;color:#555!important;padding:0}' +
			'.mai-lyrics-close:hover,.mai-lyrics-close:focus{background:#f0f0f0;outline:none}' +
			'.mai-lyrics-search{display:flex;flex-wrap:wrap;gap:8px;align-items:flex-end;padding:12px 16px;border-bottom:1px solid #eee;background:#fafafa;flex:0 0 auto}' +
			'.mai-lyrics-search label{display:flex;flex-direction:column;gap:4px;font-size:12px;color:#555;min-width:160px;flex:1}' +
			'.mai-lyrics-search input{padding:7px 9px;border:1px solid #bbb;border-radius:4px;background:#fff!important;color:#222!important;font-size:16px!important;font-family:inherit;min-width:0;box-shadow:none}' +
			'.mai-lyrics-search input:focus{outline:2px solid #2b7bb9;outline-offset:-1px;border-color:#2b7bb9!important}' +
			'.mai-lyrics-search button{padding:8px 16px;border:1px solid #2b7bb9!important;border-radius:4px!important;background:#2b7bb9!important;color:#fff!important;font:inherit;font-weight:bold;cursor:pointer;white-space:nowrap}' +
			'.mai-lyrics-search button:disabled{opacity:.55;cursor:default}' +
			'.mai-lyrics-body{display:flex;flex-direction:column;gap:0;min-height:0;flex:1 1 0;overflow:hidden}' +
			'.mai-lyrics-list{width:100%;min-width:0;overflow:auto;border-bottom:1px solid #e5e5e5;flex:1 1 0;min-height:0;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}' +
			'.mai-lyrics-item{display:block;width:100%;text-align:left;border:0!important;border-bottom:1px solid #eee!important;border-radius:0!important;background:#fff!important;padding:10px 12px;cursor:pointer;font:inherit;font-weight:normal!important;color:#222!important;box-shadow:none!important}' +
			'.mai-lyrics-item:hover{background:#f2f7fb!important}' +
			'.mai-lyrics-item.selected{background:#e3f0fa!important}' +
			'.mai-lyrics-item-title{font-weight:bold;display:block;margin-bottom:2px;color:#222!important}' +
			'.mai-lyrics-item.selected .mai-lyrics-item-title{color:#145a8a!important}' +
			'.mai-lyrics-item-meta{color:#666!important;font-size:12px!important;display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' +
			'.mai-lyrics-badge{display:inline-block;margin-left:6px;padding:0 5px;border-radius:3px;background:#eee!important;color:#666!important;font-size:11px!important;font-weight:normal!important;vertical-align:middle}' +
			'.mai-lyrics-badge.mai-lyrics-badge-synced{background:#d7e9f7!important;color:#145a8a!important;font-weight:bold!important}' +
			'.mai-lyrics-preview{flex:0 0 33.333%;overflow:auto;scroll-behavior:smooth;padding:12px 16px;white-space:pre-wrap;line-height:1.5;min-height:72px;max-height:70%;overscroll-behavior:contain;-webkit-overflow-scrolling:touch}' +
			'.mai-lyrics-resizer{flex:0 0 0;height:0;min-height:0;cursor:row-resize;background:transparent;position:relative;overflow:visible;touch-action:none}' +
			'.mai-lyrics-resizer:before{content:"";position:absolute;left:0;right:0;top:-10px;height:20px;cursor:row-resize}' +
			'.mai-lyrics-resizer:after{content:"";position:absolute;left:50%;top:2px;width:40px;height:3px;margin-left:-20px;border-radius:2px;background:#999;opacity:.55}' +
			'.mai-lyrics-footer{display:flex;gap:8px;align-items:center;padding:10px 16px;border-top:1px solid #ddd;background:#fafafa;flex:0 0 auto}' +
			'.mai-lyrics-status{flex:1;color:#555;font-size:13px;min-height:18px}' +
			'.mai-lyrics-status.error{color:#b00020}' +
			'.mai-lyrics-footer button{padding:8px 14px;border:1px solid #999!important;border-radius:4px!important;background:#fff!important;color:#222!important;cursor:pointer;font:inherit;font-weight:bold;white-space:nowrap}' +
			'.mai-lyrics-footer button.primary{background:#2b7bb9!important;border-color:#2b7bb9!important;color:#fff!important}' +
			'.mai-lyrics-footer button:disabled{opacity:.5;cursor:default}' +
			'.mai-lyrics-empty{padding:16px;color:#666}' +
			'.mai-lyrics-sync-line{padding:2px 8px;border-radius:4px;transition:background .15s,color .15s;white-space:pre-wrap}' +
			'.mai-lyrics-sync-line.mai-lyrics-sync-current{background:#e3f0fa;color:#145a8a;font-weight:bold}' +
			'@media (max-width:600px){' +
				'.mai-lyrics-overlay{padding:0;align-items:stretch}' +
				'.mai-lyrics-dialog{width:100%;height:100vh;height:100dvh;max-height:none;border-radius:0;font-size:15px}' +
				'.mai-lyrics-header{padding:calc(10px + env(safe-area-inset-top,0px)) 14px 10px;font-size:17px}' +
				'.mai-lyrics-close{min-width:44px;min-height:44px;margin:-8px -10px -8px 0;font-size:26px}' +
				'.mai-lyrics-search{padding:10px 14px;gap:8px}' +
				'.mai-lyrics-search label{min-width:0;flex:1 1 calc(50% - 4px);font-size:12px}' +
				'.mai-lyrics-search input{padding:10px;font-size:16px}' +
				'.mai-lyrics-search button{flex:1 1 100%;padding:11px 14px;font-size:15px}' +
				'.mai-lyrics-list{min-height:96px}' +
				'.mai-lyrics-preview{flex:0 0 38%;padding:10px 14px;min-height:64px}' +
				'.mai-lyrics-item{padding:12px 14px}' +
				'.mai-lyrics-footer{flex-wrap:wrap;gap:8px;padding:8px 14px calc(8px + env(safe-area-inset-bottom,0px))}' +
				'.mai-lyrics-status{flex:1 1 100%;min-height:16px;font-size:12px}' +
				'.mai-lyrics-footer button{flex:1 1 0;padding:11px 10px;font-size:15px}' +
			'}' +
			'@media (max-height:520px){' +
				'.mai-lyrics-header{padding:8px 14px}' +
				'.mai-lyrics-search{padding:8px 14px}' +
				'.mai-lyrics-list{min-height:56px}' +
				'.mai-lyrics-preview{flex-basis:38%;min-height:48px;padding:8px 14px}' +
				'.mai-lyrics-footer{padding:6px 14px calc(6px + env(safe-area-inset-bottom,0px))}' +
				'.mai-lyrics-footer button{padding:8px 10px}' +
			'}';
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
			xhr.send(options.body || null);
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
			var synced = isSynced(candidate);
			var badge = el('span', 'mai-lyrics-badge' + (synced ? ' mai-lyrics-badge-synced' : ''),
				synced ? state.strings.synced : state.strings.plain);
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
				if (m[3] && m[3].length === 1) fraction *= 100;
				else if (m[3] && m[3].length === 2) fraction *= 10;
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
		if (isSynced(candidate)) {
			var lines = Array.isArray(candidate.lines) && candidate.lines.length ? candidate.lines : parseLrc(candidate.lyrics);
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
		preview.textContent = isSynced(candidate) ? String(candidate.lyrics || '').replace(/\[[^\]]*\]/g, '') : (candidate.lyrics || '');
		stopSync();
	}
	function schedulePreviewCenter() {
		if (state.centerTimer) clearTimeout(state.centerTimer);
		state.centerTimer = setTimeout(function () {
			state.centerTimer = null;
			centerPreviewLine();
		}, 3000);
	}
	function centerPreviewLine() {
		var preview = document.getElementById('maiLyricsPreview');
		if (!preview || !state.lines.length || state.currentLine < 0) return;
		var nodes = preview.querySelectorAll('.mai-lyrics-sync-line');
		var node = nodes[state.currentLine];
		if (!node) return;
		var scale = state.zoomScale || 1;
		var pRect = preview.getBoundingClientRect();
		var nRect = node.getBoundingClientRect();
		var delta = ((nRect.top - pRect.top) - (preview.clientHeight * scale - nRect.height) / 2) / scale;
		if (Math.abs(delta) > 1) {
			state.programmaticScroll = true;
			preview.scrollTop += delta;
		}
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
		if (nodes[index]) {
			if (Date.now() - state.lastManualScroll >= 3000) centerPreviewLine();
			else if (!state.centerTimer) schedulePreviewCenter();
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

	function translationInfo() {
		return {
			endpoint: state.endpoint,
			trackId: state.trackId,
			url: state.url,
			title: state.title,
			artist: state.artist,
			player: state.player,
			strings: state.strings
		};
	}

	function loadTranslateScript(cb) {
		if (window.MAILyricsTranslate) {
			cb();
			return;
		}
		var script = document.createElement('script');
		script.src = state.translateScript;
		script.onload = cb;
		script.onerror = function () { cb(); };
		document.head.appendChild(script);
	}

	function watchTranslation(result) {
		if (!result || !result.translation || !result.translation.queued || !result.translation.key) {
			return;
		}
		var key = result.translation.key;
		loadTranslateScript(function () {
			if (!window.MAILyricsTranslate) return;
			window.MAILyricsTranslate.watch(key, translationInfo(), state.strings);
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

			watchTranslation(result);
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
		stopFollow();
		if (state.centerTimer) { clearTimeout(state.centerTimer); state.centerTimer = null; }
		state.lines = [];
		if (state.overlay && state.overlay.parentNode) {
			state.overlay.parentNode.removeChild(state.overlay);
		}
		state.overlay = null;
		state.dialog = null;
		state.zoomScale = 1;
		state.opening = false;

		unlockBodyScroll();

		if (state.onViewportResize) {
			window.removeEventListener('resize', state.onViewportResize);
			state.onViewportResize = null;
		}

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
			var scale = state.zoomScale || 1;
			var bodyHeight = body.getBoundingClientRect().height / scale;
			var next = startHeight - (point.clientY - startY) / scale;
			next = Math.max(72, Math.min(next, bodyHeight - 120));
			preview.style.flex = '0 0 ' + next + 'px';
			schedulePreviewCenter();
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
			startHeight = preview.getBoundingClientRect().height / (state.zoomScale || 1);
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
		dialog.setAttribute('aria-label', state.strings.choose);
		dialog.setAttribute('data-track-id', state.trackId || '');

		var header = el('div', 'mai-lyrics-header');
		header.appendChild(el('span', '', state.strings.choose));
		var closeButton = el('button', 'mai-lyrics-close', '\u00d7');
		closeButton.type = 'button';
		closeButton.setAttribute('aria-label', state.strings.close);
		closeButton.addEventListener('click', close);
		header.appendChild(closeButton);

		var searchBox = el('div', 'mai-lyrics-search');

		var titleLabel = el('label', '', state.strings.title);
		var titleInput = document.createElement('input');
		titleInput.id = 'maiLyricsTitle';
		titleInput.type = 'text';
		titleInput.value = state.title;
		titleInput.setAttribute('autocomplete', 'off');
		titleInput.setAttribute('autocapitalize', 'off');
		titleInput.setAttribute('spellcheck', 'false');
		titleInput.setAttribute('enterkeyhint', 'search');
		titleInput.addEventListener('keydown', function (event) {
			if (event.key === 'Enter') search();
		});
		titleLabel.appendChild(titleInput);

		var artistLabel = el('label', '', state.strings.artist);
		var artistInput = document.createElement('input');
		artistInput.id = 'maiLyricsArtist';
		artistInput.type = 'text';
		artistInput.value = state.artist;
		artistInput.setAttribute('autocomplete', 'off');
		artistInput.setAttribute('autocapitalize', 'off');
		artistInput.setAttribute('spellcheck', 'false');
		artistInput.setAttribute('enterkeyhint', 'search');
		artistInput.addEventListener('keydown', function (event) {
			if (event.key === 'Enter') search();
		});
		artistLabel.appendChild(artistInput);

		var searchButton = el('button', 'primary', state.strings.search);
		searchButton.type = 'button';
		searchButton.id = 'maiLyricsSearchButton';
		searchButton.setAttribute('aria-label', state.strings.search);
		searchButton.addEventListener('click', search);

		searchBox.appendChild(titleLabel);
		searchBox.appendChild(artistLabel);
		searchBox.appendChild(searchButton);

		var body = el('div', 'mai-lyrics-body');
		var list = el('div', 'mai-lyrics-list');
		list.id = 'maiLyricsCandidateList';
		var preview = el('div', 'mai-lyrics-preview');
		preview.id = 'maiLyricsPreview';
		preview.addEventListener('scroll', function () {
			if (state.programmaticScroll) {
				state.programmaticScroll = false;
				return;
			}
			state.lastManualScroll = Date.now();
			schedulePreviewCenter();
		});

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
		status.setAttribute('role', 'status');
		status.setAttribute('aria-live', 'polite');
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
		// Keep touch drags on the dimmed background from scrolling the page
		// behind the dialog on mobile browsers.
		overlay.addEventListener('touchmove', function (event) {
			if (event.target === overlay) event.preventDefault();
		}, { passive: false });

		return { overlay: overlay, dialog: dialog };
	}

	function currentItem(result) {
		var list = result && result.playlist_loop;
		if (!list || !list.length) return null;

		var index = parseInt(result.playlist_cur_index, 10);
		for (var i = 0; i < list.length; i++) {
			if (parseInt(list[i]['playlist index'], 10) === index) return list[i];
		}

		return list[0];
	}

	function updateButtonTrack(item) {
		var buttons = document.querySelectorAll('.maiLyricsChooserButton, .maiLyricsTranslateButton');
		for (var i = 0; i < buttons.length; i++) {
			var button = buttons[i];
			button.setAttribute('data-track-id', text(item.id || item.track_id));
			button.setAttribute('data-url', text(item.url));
			button.setAttribute('data-title', text(item.title));
			button.setAttribute('data-artist', text(item.artist));
			button.setAttribute('data-album', text(item.album));
			button.setAttribute('data-player', state.player);
			if (button.classList && button.classList.contains('maiLyricsChooserButton')) {
				button.setAttribute('data-duration', text(item.duration));
			}
		}
	}

	function applyStatusItem(item) {
		if (!item) return;
		if (item.title) state.title = item.title;
		if (item.artist) state.artist = item.artist;
		state.album = text(item.album);
		state.duration = text(item.duration);
		state.trackId = text(item.id || item.track_id);
		state.url = text(item.url);
		updateButtonTrack(item);
	}

	// The standard lyrics page can be inserted via AJAX, where its watcher
	// script is not guaranteed to have run.  Refresh the track when opening
	// the chooser so a just-played track never opens with the previous values.
	function refreshFromPlayer(cb) {
		if (!state.player) {
			cb();
			return;
		}

		var body = JSON.stringify({
			id: 1,
			method: 'slim.request',
			params: [ state.player, [ 'status', '-', 1, 'tags:title,artist,album,duration,url' ] ]
		});
		var finished = false;
		var timer = setTimeout(function () {
			if (finished) return;
			finished = true;
			cb();
		}, 2000);

		function finish() {
			if (finished) return;
			finished = true;
			clearTimeout(timer);
			cb();
		}

		requestJson('/jsonrpc.js', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin',
			body: body
		}).then(function (data) {
			if (finished) return;
			applyStatusItem(currentItem(data && data.result));
			finish();
		}).catch(finish);
	}

	function stateTrackKey() {
		return [
			state.player,
			state.trackId,
			state.url,
			state.title,
			state.artist,
			state.album
		].join('\u001f');
	}

	function stopFollow() {
		if (state.followTimer) {
			clearInterval(state.followTimer);
			state.followTimer = null;
		}
		state.followBusy = false;
		state.followKey = '';
	}

	function checkFollow() {
		if (!state.overlay) {
			stopFollow();
			return;
		}
		if (state.followBusy || !state.player) return;
		state.followBusy = true;

		var body = JSON.stringify({
			id: 1,
			method: 'slim.request',
			params: [ state.player, [ 'status', '-', 1, 'tags:title,artist,album,duration,url' ] ]
		});

		requestJson('/jsonrpc.js', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin',
			body: body
		}).then(function (data) {
			state.followBusy = false;
			if (!state.overlay) return;

			var item = currentItem(data && data.result);
			if (!item) return;

			var key = [
				state.player,
				text(item.id || item.track_id),
				text(item.url),
				text(item.title),
				text(item.artist),
				text(item.album)
			].join('\u001f');

			if (key === state.followKey) return;
			state.followKey = key;
			applyStatusItem(item);

			if (state.dialog) state.dialog.setAttribute('data-track-id', state.trackId || '');
			var titleInput = document.getElementById('maiLyricsTitle');
			var artistInput = document.getElementById('maiLyricsArtist');
			if (titleInput) titleInput.value = state.title;
			if (artistInput) artistInput.value = state.artist;

			search();
		}).catch(function () {
			state.followBusy = false;
		});
	}

	function startFollow() {
		stopFollow();
		if (!state.button || state.button.getAttribute('data-follow-player') !== '1' || !state.player) {
			return;
		}
		state.followKey = stateTrackKey();
		state.followTimer = setInterval(checkFollow, 2000);
	}

	function open(input) {
		addStyle();

		state.onApply = null;
		state.player = '';

		if (input && typeof input === 'object' && input.nodeType !== 1) {
			state.button = null;
			state.strings = mergeStrings(input.strings);
			state.endpoint = input.endpoint || state.endpoint;
			state.translateScript = input.translateScript || state.translateScript;
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
			state.translateScript = button.getAttribute('data-translate-script') || state.translateScript;
			state.trackId = button.getAttribute('data-track-id') || '';
			state.url = button.getAttribute('data-url') || '';
			state.title = button.getAttribute('data-title') || '';
			state.artist = button.getAttribute('data-artist') || '';
			state.album = button.getAttribute('data-album') || '';
			state.duration = button.getAttribute('data-duration') || '';
			state.player = button.getAttribute('data-player') || '';
		}

		if (state.overlay || state.opening) {
			return;
		}

		state.opening = true;

		function showDialog() {
			if (state.overlay) {
				state.opening = false;
				return;
			}

			ensureViewportMeta();

			var built = buildDialog();
			state.overlay = built.overlay;
			state.dialog = built.dialog;

			lockBodyScroll();
			document.body.appendChild(state.overlay);
			document.addEventListener('keydown', onKeyDown);

			applyViewportFallback();
			if (!state.onViewportResize) {
				state.onViewportResize = applyViewportFallback;
			}
			window.addEventListener('resize', state.onViewportResize);

			state.opening = false;
			search();
			startFollow();
		}

		if (state.button && state.button.getAttribute('data-follow-player') === '1') {
			refreshFromPlayer(showDialog);
		} else {
			showDialog();
		}
	}

	window.MAILyrics = {
		open: open,
		close: close
	};
})();
