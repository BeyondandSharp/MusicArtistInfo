/*
 * MusicArtistInfo - on-demand lyrics translation.
 *
 * Loaded lazily by the "Translate lyrics" button on the standard web UI
 * lyrics page.  It queues a translation job, polls its status and refreshes
 * the displayed lyrics when the translated LRC file has been written.
 */
(function () {
	'use strict';

	if (window.MAILyricsTranslate) {
		return;
	}

	var DEFAULTS = {
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
		busy: false,
		pollTimer: null,
		watchKey: ''
	};

	function text(value) {
		return value === null || value === undefined ? '' : String(value);
	}

	function mergeStrings(raw) {
		var parsed = {};
		try {
			parsed = raw ? JSON.parse(raw) : {};
		}
		catch (e) {
			parsed = {};
		}

		var merged = {};
		Object.keys(DEFAULTS).forEach(function (key) {
			merged[key] = text(parsed[key]) || DEFAULTS[key];
		});
		return merged;
	}

	function readButton(button) {
		return {
			endpoint: button.getAttribute('data-endpoint') || '/plugins/MusicArtistInfo/lyrics',
			trackId: text(button.getAttribute('data-track-id')),
			url: text(button.getAttribute('data-url')),
			title: text(button.getAttribute('data-title')),
			artist: text(button.getAttribute('data-artist')),
			album: text(button.getAttribute('data-album')),
			player: text(button.getAttribute('data-player')),
			strings: mergeStrings(button.getAttribute('data-strings'))
		};
	}

	function statusNode() {
		return document.getElementById('maiLyricsPageStatus');
	}

	function setStatus(message, isError) {
		var node = statusNode();
		if (!node) return;
		node.textContent = message || '';
		node.style.color = isError ? '#b00' : '';
	}

	function queryString(params) {
		return Object.keys(params).filter(function (key) {
			return params[key] !== '' && params[key] !== null && params[key] !== undefined;
		}).map(function (key) {
			return encodeURIComponent(key) + '=' + encodeURIComponent(params[key]);
		}).join('&');
	}

	function requestJson(url, options) {
		return fetch(url, options).then(function (response) {
			return response.text().then(function (body) {
				var data = {};
				try {
					data = body ? JSON.parse(body) : {};
				}
				catch (e) {
					data = { error: 'invalid-response' };
				}
				if (!response.ok && !data.error) {
					data.error = 'http-' + response.status;
				}
				return data;
			});
		});
	}

	function errorMessage(strings, code) {
		switch (code) {
			case 'no-file':
				return strings.translate_no_file;
			case 'already-translated':
				return strings.translate_already;
			case 'disabled':
				return strings.translate_disabled;
			case 'already-target':
				return strings.translate_already_target;
			default:
				return strings.translate_failed + (code ? ': ' + code : '');
		}
	}

	function skipMessage(strings, reason) {
		return strings.translate_skipped.replace('%s', reason || '');
	}

	function refreshDisplay(info, strings) {
		var params = {
			track_id: info.trackId,
			url: info.url,
			title: info.title,
			artist: info.artist
		};

		var command = ['musicartistinfo', 'lyrics'];
		['track_id', 'url', 'title', 'artist'].forEach(function (key) {
			if (params[key]) command.push(key + ':' + params[key]);
		});

		return fetch('/jsonrpc.js', {
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			credentials: 'same-origin',
			body: JSON.stringify({
				id: 1,
				method: 'slim.request',
				params: ['', command]
			})
		}).then(function (response) {
			return response.json();
		}).then(function (data) {
			var result = data && data.result ? data.result : {};
			var lyrics = text(result.lyrics);
			if (!lyrics) {
				setStatus(errorMessage(strings, result.error), true);
				return;
			}
			var display = document.getElementById('maiLyricsText');
			if (display) {
				display.textContent = lyrics;
				display.style.whiteSpace = 'pre-wrap';
			}
			setStatus(strings.translated, false);
		}).catch(function () {
			setStatus(strings.translate_failed, true);
		});
	}

	function stopWatch() {
		if (state.pollTimer) {
			clearTimeout(state.pollTimer);
			state.pollTimer = null;
		}
		state.watchKey = '';
	}

	function watchStatus(key, info, strings, deadline) {
		state.watchKey = key;
		var expireAt = deadline || (Date.now() + 180000);

		function poll() {
			if (state.watchKey !== key) return;
			if (Date.now() > expireAt) {
				setStatus(strings.translate_failed, true);
				stopWatch();
				return;
			}

			var url = info.endpoint + '/translate-status?' + queryString({ key: key, _: Date.now() });
			requestJson(url, { credentials: 'same-origin' }).then(function (data) {
				if (state.watchKey !== key) return;

				if (data.error) {
					setStatus(errorMessage(strings, data.error), true);
					stopWatch();
					return;
				}

				var jobState = text(data.state);
				if (jobState === 'done') {
					stopWatch();
					refreshDisplay(info, strings);
					return;
				}

				if (jobState === 'failed') {
					setStatus(errorMessage(strings, text(data.reason || data.error || 'failed')), true);
					stopWatch();
					return;
				}

				if (jobState === 'skipped') {
					var reason = text(data.reason);
					stopWatch();

					// Detection now runs in the worker, so an already-target
					// result arrives as a skipped status rather than an
					// immediate error.  Offer the same "translate anyway"
					// confirmation here and retry with force=1.
					if (reason === 'already-target' && window.confirm && window.confirm(strings.translate_already_target)) {
						setStatus(strings.translating, false);
						translate(info, true).then(function (retry) {
							if (retry && retry.queued && retry.key) {
								setStatus(strings.translate_queued, false);
								watchStatus(retry.key, info, strings);
								return;
							}
							if (retry && retry.error) {
								setStatus(errorMessage(strings, retry.error), true);
								return;
							}
							if (retry && retry.state === 'done') {
								refreshDisplay(info, strings);
								return;
							}
							setStatus(skipMessage(strings, (retry && retry.reason) || reason), true);
						}).catch(function () {
							setStatus(strings.translate_failed, true);
						});
						return;
					}

					setStatus(skipMessage(strings, reason), true);
					return;
				}

				setStatus(strings.translating, false);
				state.pollTimer = setTimeout(poll, 1500);
			}).catch(function () {
				if (state.watchKey !== key) return;
				setStatus(strings.translate_failed, true);
				stopWatch();
			});
		}

		poll();
	}

	function translate(info, force) {
		var params = {
			track_id: info.trackId,
			url: info.url,
			title: info.title,
			artist: info.artist,
			player: info.player,
			_: Date.now()
		};
		if (force) params.force = 1;

		var url = info.endpoint + '/translate?' + queryString(params);

		return requestJson(url, {
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			credentials: 'same-origin'
		});
	}

	function start(button) {
		if (state.busy) return;
		state.busy = true;

		var info = readButton(button);
		var strings = info.strings;
		button.disabled = true;
		setStatus(strings.translating, false);

		function finish() {
			state.busy = false;
			button.disabled = false;
		}

		function handle(data, forced) {
			if (data && data.error === 'already-target' && !forced) {
				if (window.confirm && !window.confirm(strings.translate_already_target)) {
					setStatus('', false);
					finish();
					return;
				}
				translate(info, true).then(function (retry) {
					handle(retry, true);
				}).catch(function () {
					setStatus(strings.translate_failed, true);
					finish();
				});
				return;
			}

			if (!data || data.error) {
				setStatus(errorMessage(strings, data && data.error), true);
				finish();
				return;
			}

			if (data.queued && data.key) {
				setStatus(strings.translate_queued, false);
				finish();
				watchStatus(data.key, info, strings);
				return;
			}

			if (data.state === 'done') {
				refreshDisplay(info, strings);
				finish();
				return;
			}

			if (data.state === 'skipped' || data.skip) {
				setStatus(skipMessage(strings, data.reason || data.skip), true);
				finish();
				return;
			}

			setStatus(strings.translate_failed, true);
			finish();
		}

		translate(info, false).then(function (data) {
			handle(data, false);
		}).catch(function () {
			setStatus(strings.translate_failed, true);
			finish();
		});
	}

	window.MAILyricsTranslate = {
		start: start,
		watch: function (key, info, strings) {
			if (key) watchStatus(key, info, strings || DEFAULTS);
		},
		refresh: function (info) {
			refreshDisplay(info, info && info.strings ? info.strings : DEFAULTS);
		},
		stop: stopWatch
	};
})();
