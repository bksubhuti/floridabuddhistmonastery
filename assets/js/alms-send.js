// Phone-side sender for the live alms map. Signs in with Firebase Auth (REST),
// watches GPS, and writes the current position to /alms in the Realtime Database.
(function () {
  var cfg = window.ALMS_LIVE || {};
  var $ = function (id) { return document.getElementById(id); };
  var show = function (el, on) { el.classList.toggle('hidden', !on); };

  if (!cfg.databaseUrl || !cfg.apiKey) { show($('nocfg'), true); return; }

  var DB = cfg.databaseUrl.replace(/\/$/, '') + '/alms.json';
  var SEND_EVERY_MS = 15000;   // at most one update per 15 s...
  var MIN_MOVE_M = 15;         // ...unless moved this far
  var HEARTBEAT_MS = 60000;    // resend at least every minute even if standing still
  var ZONE_RADIUS_M = 400;

  var LS_REFRESH = 'almsRefreshToken', LS_ZONE = 'almsPrivateZone';
  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) {} }

  // ---------- Auth ----------
  var idToken = null, idTokenExp = 0;

  function signIn(email, password) {
    return fetch('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=' + cfg.apiKey, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: email, password: password, returnSecureToken: true })
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d.error) throw new Error(d.error.message);
      idToken = d.idToken; idTokenExp = Date.now() + (+d.expiresIn - 120) * 1000;
      lsSet(LS_REFRESH, d.refreshToken);
    });
  }

  function getToken() {
    if (idToken && Date.now() < idTokenExp) return Promise.resolve(idToken);
    var rt = lsGet(LS_REFRESH);
    if (!rt) return Promise.reject(new Error('Not signed in'));
    return fetch('https://securetoken.googleapis.com/v1/token?key=' + cfg.apiKey, {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'grant_type=refresh_token&refresh_token=' + encodeURIComponent(rt)
    }).then(function (r) { return r.json(); }).then(function (d) {
      if (d.error) throw new Error(d.error.message || 'Sign-in expired');
      idToken = d.id_token; idTokenExp = Date.now() + (+d.expires_in - 120) * 1000;
      lsSet(LS_REFRESH, d.refresh_token);
      return idToken;
    });
  }

  function write(data) {
    data.t = { '.sv': 'timestamp' };
    return getToken().then(function (tok) {
      return fetch(DB + '?auth=' + encodeURIComponent(tok), { method: 'PUT', body: JSON.stringify(data) });
    }).then(function (r) {
      if (!r.ok) return r.text().then(function (t) { throw new Error('Write failed: ' + r.status + ' ' + t); });
    });
  }

  // ---------- Geometry / private zone ----------
  function distM(a, b) {
    var R = 6371000, toR = Math.PI / 180;
    var dLat = (b.lat - a.lat) * toR, dLng = (b.lng - a.lng) * toR;
    var h = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
      Math.cos(a.lat * toR) * Math.cos(b.lat * toR) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
    return 2 * R * Math.asin(Math.sqrt(h));
  }
  function getZone() { try { return JSON.parse(lsGet(LS_ZONE)); } catch (e) { return null; } }
  function showZone() {
    $('zoneinfo').textContent = getZone() ? 'set (' + ZONE_RADIUS_M + ' m radius)' : 'not set';
  }

  // ---------- Sharing ----------
  var watchId = null, wakeLock = null, lastSent = null, lastSentAt = 0, lastPos = null, hb = null;

  function status(text, detail) { $('status').textContent = text; $('detail').textContent = detail || ''; }

  function requestWakeLock() {
    if (!('wakeLock' in navigator) || watchId === null) return;
    navigator.wakeLock.request('screen').then(function (l) { wakeLock = l; }).catch(function () {});
  }
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') requestWakeLock();
  });

  function send(pos, force) {
    var p = { lat: pos.coords.latitude, lng: pos.coords.longitude, acc: Math.round(pos.coords.accuracy) };
    var now = Date.now();
    var zone = getZone();
    var inZone = zone && distM(zone, p) < ZONE_RADIUS_M;
    var moved = lastSent ? distM(lastSent, p) : Infinity;
    if (!force && now - lastSentAt < SEND_EVERY_MS && moved < MIN_MOVE_M) return;
    if (!force && now - lastSentAt < HEARTBEAT_MS && moved < 3) return;

    var data = inZone
      ? { active: true, hidden: true }
      : { active: true, lat: +p.lat.toFixed(6), lng: +p.lng.toFixed(6), acc: p.acc };
    lastSent = p; lastSentAt = now;
    write(data).then(function () {
      status(inZone ? 'Sharing, hidden (private zone)' : 'Sharing live',
        'Last sent ' + new Date().toLocaleTimeString() + ' · accuracy ±' + p.acc + ' m');
    }).catch(function (e) { status('Problem sending', e.message); lastSentAt = 0; });
  }

  function start() {
    if (!navigator.geolocation) { status('This browser has no GPS access'); return; }
    status('Waiting for GPS…');
    show($('start'), false); show($('stop'), true);
    watchId = navigator.geolocation.watchPosition(
      function (pos) { lastPos = pos; send(pos, false); },
      function (err) { status('GPS problem', err.message); },
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 30000 }
    );
    hb = setInterval(function () { if (lastPos) send(lastPos, Date.now() - lastSentAt >= HEARTBEAT_MS); }, 20000);
    requestWakeLock();
  }

  function stop() {
    if (watchId !== null) navigator.geolocation.clearWatch(watchId);
    watchId = null; lastSent = null; lastSentAt = 0; lastPos = null;
    clearInterval(hb);
    if (wakeLock) { wakeLock.release().catch(function () {}); wakeLock = null; }
    show($('start'), true); show($('stop'), false);
    status('Stopping…');
    write({ active: false })
      .then(function () { status('Not sharing', 'The map now shows the alms round has ended.'); })
      .catch(function (e) { status('Could not reach server', e.message + ' (the map will time out by itself)'); });
  }

  // ---------- UI wiring ----------
  function showMain(on) { show($('main'), on); show($('login'), !on); }

  $('signin').onclick = function () {
    $('signin').disabled = true;
    signIn($('email').value.trim(), $('password').value)
      .then(function () { showMain(true); status('Not sharing'); })
      .catch(function (e) { alert('Sign-in failed: ' + e.message); })
      .then(function () { $('signin').disabled = false; });
  };
  $('start').onclick = start;
  $('stop').onclick = stop;
  $('signout').onclick = function () { if (watchId !== null) stop(); lsSet(LS_REFRESH, null); idToken = null; showMain(false); };
  $('setzone').onclick = function () {
    navigator.geolocation.getCurrentPosition(function (pos) {
      lsSet(LS_ZONE, JSON.stringify({ lat: pos.coords.latitude, lng: pos.coords.longitude }));
      showZone();
    }, function (err) { alert('GPS problem: ' + err.message); }, { enableHighAccuracy: true, timeout: 30000 });
  };
  $('clearzone').onclick = function () { lsSet(LS_ZONE, null); showZone(); };

  showZone();
  showMain(!!lsGet(LS_REFRESH));
})();
