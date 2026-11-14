/*
 * MusicArtistInfo - follow the playing track on the standard LMS lyrics page.
 *
 * The standard web UI renders this page for one specific track.  When that
 * track is the one currently playing, this watcher keeps the lyrics and the
 * chooser button in sync if the player moves on to another track.  Pages
 * opened for a track which is not playing are left alone.
 */
(function () {
	'use strict';

	if (window.__MAI_LYRICS_WATCHER__) {
		return;
	}
	window.__MAI_LYRICS_WATCHER__ = true;

	var textEl = document.getElementById('maiLyricsText');
	var statusEl = document.getElementById('maiLyricsPageStatus');
	var chooserButton = document.querySelector('.maiLyricsChooserButton');
	if (!textEl || !chooserButton) {
		return;
	}

	var strings = {};
	try {
		strings = JSON.parse(chooserButton.getAttribute('data-strings') || '{}') || {};
	} catch (e) {}

	var player = chooserButton.getAttribute('data-player') || '';
	if (!player) {
		return;
	}

	var page = pageInfo(chooserButton);
	var followPage = chooserButton.getAttribute('data-follow-player') === '1';
	var following = false;
	var lastKey = '';
	var lyricsSeq = 0;
	var timer = null;

	function text(value) {
		return value === null || value === undefined ? '' : String(value);
	}

	function pageInfo(button) {
		return {
			id: button.getAttribute('data-track-id') || '',
			url: button.getAttribute('data-url') || '',
			title: button.getAttribute('data-title') || '',
			artist: button.getAttribute('data-artist') || '',
			album: button.getAttribute('data-album') || '',
			duration: button.getAttribute('data-duration') || ''
		};
	}

	function setStatus(message) {
		if (!statusEl) return;
		statusEl.textContent = message || '';
	}

	function setLyrics(lyrics) {
		textEl.textContent = lyrics || '';
	}

	function rpc(command, cb) {
		var xhr = new XMLHttpRequest();
		xhr.open('POST', '/jsonrpc.js', true);
		xhr.withCredentials = true;
		xhr.setRequestHeader('Content-Type', 'application/json');
		xhr.onreadystatechange = function () {
			if (xhr.readyState !== 4) return;
			var data = null;
			try {
				data = JSON.parse(xhr.responseText);
			} catch (e) {}
			cb(data && data.result ? data.result : null);
		};
		xhr.onerror = function () {
			cb(null);
		};
		xhr.send(JSON.stringify({
			id: Date.now(),
			method: 'slim.request',
			params: [ player, command ]
		}));
	}

	function currentItem(result) {
		if (!result || !result.playlist_loop || !result.playlist_loop.length) {
			return null;
		}

		var list = result.playlist_loop;
		var index = parseInt(result.playlist_cur_index, 10);
		if (!isNaN(index)) {
			for (var i = 0; i < list.length; i++) {
				if (parseInt(list[i]['playlist index'], 10) === index) {
					return list[i];
				}
			}
		}

		return list[0] || null;
	}

	function trackKey(item) {
		return [
			text(item.id || item.track_id),
			text(item.url),
			text(item.title),
			text(item.artist)
		].join('\u001f');
	}

	function isPageTrack(item) {
		if (page.id && item.id) {
			return String(page.id) === String(item.id);
		}
		if (page.url && item.url) {
			return page.url === item.url;
		}
		if (page.title && item.title) {
			return page.title === item.title && (!page.artist || page.artist === item.artist);
		}
		return false;
	}

	function setAttr(button, name, value) {
		if (!button) return;
		button.setAttribute(name, text(value));
	}

	function markFollowing() {
		var buttons = document.querySelectorAll('.maiLyricsChooserButton, .maiLyricsTranslateButton');
		for (var i = 0; i < buttons.length; i++) {
			buttons[i].setAttribute('data-follow-player', '1');
		}
	}

	function updateButtons(item) {
		var buttons = document.querySelectorAll('.maiLyricsChooserButton, .maiLyricsTranslateButton');
		for (var i = 0; i < buttons.length; i++) {
			var button = buttons[i];
			setAttr(button, 'data-track-id', item.id);
			setAttr(button, 'data-url', item.url);
			setAttr(button, 'data-title', item.title);
			setAttr(button, 'data-artist', item.artist);
			setAttr(button, 'data-album', item.album);
			setAttr(button, 'data-player', player);
			if (button.classList && button.classList.contains('maiLyricsChooserButton')) {
				setAttr(button, 'data-duration', item.duration);
			}
		}
	}

	function updatePage(item, oldTitle) {
		var image = document.querySelector('#browsedbList img[alt="coverArt"]') || document.querySelector('#browsedbList img');
		if (image) {
			var stamp = Date.now();
			image.src = '/music/current/cover_150x150_f?player=' + encodeURIComponent(player) + '&_=' + stamp;
			var link = image.parentNode && image.parentNode.tagName === 'A' ? image.parentNode : null;
			if (link) {
				link.href = '/music/current/cover.jpg?player=' + encodeURIComponent(player) + '&_=' + stamp;
			}
		}

		if (!oldTitle || !item.title || !/^\d+$/.test(text(item.id))) return;

		var links = document.querySelectorAll('#crumblist a, #statusMessage a');
		for (var i = 0; i < links.length; i++) {
			var label = links[i].textContent || '';
			if (label.indexOf(oldTitle) < 0) continue;
			links[i].textContent = label.split(oldTitle).join(item.title);
			links[i].href = '/songinfo.html?player=' + encodeURIComponent(player) + '&item=' + encodeURIComponent(item.id);
		}
	}

	function loadLyrics(item) {
		var seq = ++lyricsSeq;

		setLyrics('');
		setStatus(strings.loading || 'Searching for lyrics...');

		var command = ['musicartistinfo', 'lyrics'];
		if (item.id) command.push('track_id:' + text(item.id));
		if (item.url) command.push('url:' + text(item.url));
		if (item.title) command.push('title:' + text(item.title));
		if (item.artist) command.push('artist:' + text(item.artist));
		if (item.album) command.push('album:' + text(item.album));
		if (item.duration) command.push('duration:' + text(item.duration));

		rpc(command, function (result) {
			if (seq !== lyricsSeq) return;

			var lyrics = result && result.lyrics;
			if (lyrics && /\S/.test(lyrics)) {
				setLyrics(lyrics);
				setStatus('');
				return;
			}

			setStatus((result && result.error) || strings.none || 'No lyrics found');
		});
	}

	function trackChanged(item) {
		var oldTitle = page.title;
		page = {
			id: text(item.id),
			url: text(item.url),
			title: text(item.title),
			artist: text(item.artist),
			album: text(item.album),
			duration: text(item.duration)
		};
		lastKey = trackKey(item);

		updateButtons(item);
		markFollowing();
		updatePage(item, oldTitle);


		loadLyrics(item);
	}

	function poll() {
		rpc(['status', '-', 1, 'tags:title,artist,album,duration,url'], function (result) {
			var item = currentItem(result);
			if (!item) {
				return schedule();
			}

			if (!following) {
				if (followPage || isPageTrack(item)) {
					following = true;
					if (isPageTrack(item)) {
						page = pageInfo(chooserButton);
						markFollowing();
						lastKey = trackKey(item);
					}
					else {
						lastKey = '';
						trackChanged(item);
					}
				}
				return schedule();
			}

			var key = trackKey(item);
			if (key !== lastKey) {
				trackChanged(item);
			}

			schedule();
		});
	}

	function schedule() {
		if (timer) clearTimeout(timer);
		timer = setTimeout(poll, 2000);
	}

	schedule();
})();
