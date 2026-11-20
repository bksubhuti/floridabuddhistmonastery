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

  // One figure per monk (up to 5 drawn), walking in a line; feet of the first on the spot.
  // The resident monk's photo leads; guests are faceless.
  function monkIcon(n) {
    var shown = Math.min(n, 5), w = 24, step = 14, width = w + (shown - 1) * step, html = '';
    for (var i = shown - 1; i >= 0; i--) {
      // first figure is the resident monk's photo; extra (guest) monks are faceless figures
      html += '<img src="' + (i === 0 ? '/images/monk-marker.png' : '/images/monk-guest.svg') +
        '" style="position:absolute;left:' + (i * step) + 'px;top:0;width:24px;height:66px">';
    }
    if (n > shown) html += '<span class="alms-count">' + n + '</span>';
    return L.divIcon({ className: 'monk-marker', html: html, iconSize: [width, 66], iconAnchor: [12, 65] });
  }

  function render() {
    var s = state;
    var monks = s && s.monks > 0 ? Math.round(s.monks) : 1;
    var who = monks === 1 ? 'The monk is' : monks + ' monks are';
    var age = s && s.t ? Date.now() - s.t : Infinity;

    if (!s || !s.active || age > ENDED_MS) {
      clearMarker();
      firstFix = true;
      setStatus(trailShown
        ? 'The alms round has ended. The lotus flowers show today\'s path.'
        : 'The alms round is not in progress right now. The usual time is 7:30 – 8:45 AM.', 'notice--info');
      return;
    }

    if (s.hidden || typeof s.lat !== 'number' || typeof s.lng !== 'number') {
      clearMarker();
      setStatus('The alms round is starting (' + monks + (monks === 1 ? ' monk' : ' monks') + '). The location will appear once ' + (monks === 1 ? 'the monk is' : 'they are') + ' on the road.', 'notice--success');
      return;
    }

    var ll = [s.lat, s.lng];
    if (!marker) {
      marker = L.marker(ll, { title: 'Bhikkhus on alms round', icon: monkIcon(1), zIndexOffset: 1000 }).addTo(map);
      marker._monks = 1;
      circle = L.circle(ll, { radius: s.acc || 30, weight: 1, fillOpacity: 0.1 }).addTo(map);
    } else {
      marker.setLatLng(ll);
      circle.setLatLng(ll).setRadius(s.acc || 30);
    }
    if (marker._monks !== monks) { marker.setIcon(monkIcon(monks)); marker._monks = monks; }
    marker.setOpacity(age > STALE_MS ? 0.5 : 1);
    if (firstFix && !trailFitted) { map.setView(ll, 16); firstFix = false; }

    if (age > STALE_MS) {
      setStatus('Last seen ' + minutesAgo(s.t) + '. The signal may have been lost.', 'notice--warning');
    } else {
      setStatus(who + ' on the alms round. Updated ' + minutesAgo(s.t) + '.', 'notice--success');
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

  // ---------- Lotus trail (/alms_trail) ----------
  var TRAIL_KEEP_MS = 3 * 60 * 60 * 1000; // trail disappears 3 h after its last point
  var LOTUS_EVERY_PX = 22;                 // one lotus about every 22 screen pixels (any zoom)
  var STAMP_EVERY_MS = 10 * 60 * 1000;     // a time label every 10 minutes
  function clock(t) {
    return new Date(t).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', timeZone: 'America/New_York' });
  }
  var trailPts = {};
  var trailShown = false;
  var trailFitted = false;
  var lotusLayer = L.layerGroup().addTo(map);
  var lotusIcon = L.icon({ iconUrl: '/images/lotus.svg', iconSize: [20, 16], iconAnchor: [10, 14], className: 'lotus-marker' });

  function drawTrail() {
    var pts = Object.keys(trailPts).map(function (k) { return trailPts[k]; })
      .filter(function (p) { return p && typeof p.lat === 'number' && typeof p.lng === 'number' && p.t; })
      .sort(function (a, b) { return a.t - b.t; });
    lotusLayer.clearLayers();
    var newest = pts.length ? pts[pts.length - 1].t : 0;
    trailShown = pts.length > 0 && Date.now() - newest < TRAIL_KEEP_MS;
    if (!trailShown) return;
    var last = null;
    var nextStamp = Math.ceil(pts[0].t / STAMP_EVERY_MS) * STAMP_EVERY_MS;
    pts.forEach(function (p) {
      var ll = L.latLng(p.lat, p.lng);
      if (p.t >= nextStamp) {
        L.marker(ll, {
          icon: L.divIcon({ className: 'alms-stamp', html: clock(nextStamp), iconSize: null, iconAnchor: [-8, 8] }),
          interactive: false, keyboard: false, zIndexOffset: -500
        }).addTo(lotusLayer);
        while (nextStamp <= p.t) nextStamp += STAMP_EVERY_MS;
      }
      var px = map.latLngToLayerPoint(ll);
      if (last && last.distanceTo(px) < LOTUS_EVERY_PX) return;
      L.marker(ll, { icon: lotusIcon, interactive: false, keyboard: false, zIndexOffset: -1000 }).addTo(lotusLayer);
      last = px;
    });
    if (!trailFitted) { // first view: show the whole trail (and the monk, if out walking)
      var b = L.latLngBounds(pts.map(function (p) { return [p.lat, p.lng]; }));
      if (marker) b.extend(marker.getLatLng());
      map.fitBounds(b, { padding: [40, 40], maxZoom: 17 });
      trailFitted = true;
      firstFix = false;
    }
  }

  function applyTrail(path, data, merge) {
    if (path === '/' || path === '') {
      if (!merge) trailPts = {};
      Object.assign(trailPts, data || {});
      if (!data && !merge) trailFitted = false;
    } else {
      var key = path.replace(/^\//, '').split('/')[0];
      if (data === null) delete trailPts[key]; else trailPts[key] = data;
    }
    drawTrail();
    render();
  }

  map.on('zoomend', drawTrail);

  var trailUrl = cfg.databaseUrl.replace(/\/$/, '') + '/alms_trail.json';
  function pollTrail() {
    fetch(trailUrl).then(function (r) { return r.json(); })
      .then(function (d) { applyTrail('/', d, false); }).catch(function () {});
  }
  if (window.EventSource) {
    var tes = new EventSource(trailUrl);
    tes.addEventListener('put', function (e) { var m = JSON.parse(e.data); applyTrail(m.path, m.data, false); });
    tes.addEventListener('patch', function (e) { var m = JSON.parse(e.data); applyTrail(m.path, m.data, true); });
    tes.onerror = function () { pollTrail(); };
  } else {
    pollTrail();
    setInterval(pollTrail, 15000);
  }

  // Re-render every 30 s so "x minutes ago", staleness and the 3-hour trail limit stay current.
  setInterval(function () { drawTrail(); render(); }, 30000);
})();
