// Public live map for the alms round. Reads /alms from Firebase Realtime Database
// using its REST streaming API (no Firebase SDK needed).
(function () {
  var cfg = window.ALMS_LIVE || {};
  var statusEl = document.getElementById('alms-status');
  var mapEl = document.getElementById('alms-map');
  if (!statusEl || !mapEl) return;

  var STALE_MS = 10 * 60 * 1000; // no update for 10 min -> "last seen"
  var ENDED_MS = 45 * 60 * 1000; // no update for 45 min -> treat as ended

  function setStatus(text, cls) {
    statusEl.textContent = text;
    statusEl.className = cls || 'notice--info';
  }

  if (!cfg.databaseUrl) {
    setStatus('The live map is not set up yet.', 'notice--warning');
    mapEl.style.display = 'none';
    return;
  }

  // Default view: Geneva, FL area (town level, not the monastery itself).
  var map = L.map(mapEl).setView([28.74, -81.12], 12);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; OpenStreetMap contributors'
  }).addTo(map);

  var marker = null;
  var circle = null;
  var state = null;
  var firstFix = true;

  function minutesAgo(t) {
    var m = Math.round((Date.now() - t) / 60000);
    return m <= 0 ? 'just now' : m === 1 ? '1 minute ago' : m + ' minutes ago';
  }

  function clearMarker() {
    if (marker) { map.removeLayer(marker); marker = null; }
    if (circle) { map.removeLayer(circle); circle = null; }
  }

  function render() {
    var s = state;
    var age = s && s.t ? Date.now() - s.t : Infinity;

    if (!s || !s.active || age > ENDED_MS) {
      clearMarker();
      firstFix = true;
      setStatus('The alms round is not in progress right now. The usual time is 7:30 – 8:45 AM.', 'notice--info');
      return;
    }

    if (s.hidden || typeof s.lat !== 'number' || typeof s.lng !== 'number') {
      clearMarker();
      setStatus('The alms round is starting. The location will appear once the monks are on the road.', 'notice--success');
      return;
    }

    var ll = [s.lat, s.lng];
    if (!marker) {
      marker = L.marker(ll, { title: 'Bhikkhus on alms round' }).addTo(map);
      circle = L.circle(ll, { radius: s.acc || 30, weight: 1, fillOpacity: 0.1 }).addTo(map);
    } else {
      marker.setLatLng(ll);
      circle.setLatLng(ll).setRadius(s.acc || 30);
    }
    marker.setOpacity(age > STALE_MS ? 0.5 : 1);
    if (firstFix) { map.setView(ll, 16); firstFix = false; }

    if (age > STALE_MS) {
      setStatus('Last seen ' + minutesAgo(s.t) + '. The signal may have been lost.', 'notice--warning');
    } else {
      setStatus('The alms round is in progress. Updated ' + minutesAgo(s.t) + '.', 'notice--success');
    }
  }

  // Apply a Firebase stream event ({path, data}) to our local copy of /alms.
  function apply(path, data, merge) {
    if (path === '/' || path === '') {
      state = merge ? Object.assign({}, state || {}, data) : data;
    } else {
      var key = path.replace(/^\//, '').split('/')[0];
      state = Object.assign({}, state || {});
      if (data === null) delete state[key]; else state[key] = data;
    }
    render();
  }

  var url = cfg.databaseUrl.replace(/\/$/, '') + '/alms.json';

  function poll() {
    fetch(url).then(function (r) { return r.json(); })
      .then(function (d) { state = d; render(); })
      .catch(function () { setStatus('Could not reach the live map. Retrying…', 'notice--warning'); });
  }

  if (window.EventSource) {
    var es = new EventSource(url);
    es.addEventListener('put', function (e) { var m = JSON.parse(e.data); apply(m.path, m.data, false); });
    es.addEventListener('patch', function (e) { var m = JSON.parse(e.data); apply(m.path, m.data, true); });
    es.onerror = function () { poll(); }; // EventSource reconnects by itself; poll meanwhile
  } else {
    poll();
    setInterval(poll, 15000);
  }

  // Re-render every 30 s so "x minutes ago" and staleness stay current.
  setInterval(render, 30000);
})();
