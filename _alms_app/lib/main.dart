// Alms GPS: shares the phone's location with floridabuddhistmonastery.org/alms-live/
// while the alms round is in progress. Keeps sending with the screen off by running
// an Android foreground service (a notification stays visible while sharing).
//
// Writes to Firebase Realtime Database /alms, same format as the web sender
// (/alms-live/send/):  {active, hidden?, lat?, lng?, acc?, t}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const sendEvery = Duration(seconds: 15); // at most one update per 15 s...
const minMoveM = 15.0; // ...unless moved this far
const heartbeat = Duration(seconds: 60); // resend at least once a minute
const zoneRadiusM = 400.0;

// Built-in settings (all public values; the password is typed on the phone).
const defaultDbUrl = 'https://fbm-alms-default-rtdb.firebaseio.com';
const defaultApiKey = 'AIzaSyDu_EiFHovixjbgT8w0EB-vYI_UgCw-Wl4';
const defaultEmail = 'bksubhuti@gmail.com';

void main() => runApp(const AlmsApp());

class AlmsApp extends StatelessWidget {
  const AlmsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Alms GPS',
        theme: ThemeData(colorSchemeSeed: Colors.orange, useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: Colors.orange, brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      );
}

// ---------------- Firebase (REST) ----------------

class Firebase {
  Firebase(this.prefs);
  final SharedPreferences prefs;
  String? _idToken;
  DateTime _exp = DateTime(2000);

  String get dbUrl => (prefs.getString('dbUrl') ?? '').replaceAll(RegExp(r'/+$'), '');
  String get apiKey => prefs.getString('apiKey') ?? '';
  bool get signedIn => (prefs.getString('refreshToken') ?? '').isNotEmpty;

  Future<void> signIn(String dbUrl, String apiKey, String email, String password) async {
    await prefs.setString('dbUrl', dbUrl.trim());
    await prefs.setString('apiKey', apiKey.trim());
    final r = await http.post(
      Uri.parse(
          'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${this.apiKey}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim(), 'password': password, 'returnSecureToken': true}),
    );
    final d = jsonDecode(r.body);
    if (d['error'] != null) throw Exception(d['error']['message']);
    _idToken = d['idToken'];
    _exp = DateTime.now().add(Duration(seconds: int.parse(d['expiresIn']) - 120));
    await prefs.setString('refreshToken', d['refreshToken']);
  }

  Future<void> signOut() async {
    _idToken = null;
    await prefs.remove('refreshToken');
  }

  Future<String> _token() async {
    if (_idToken != null && DateTime.now().isBefore(_exp)) return _idToken!;
    final rt = prefs.getString('refreshToken');
    if (rt == null) throw Exception('Not signed in');
    final r = await http.post(
      Uri.parse('https://securetoken.googleapis.com/v1/token?key=$apiKey'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: 'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(rt)}',
    );
    final d = jsonDecode(r.body);
    if (d['error'] != null) throw Exception('Sign-in expired, please sign in again');
    _idToken = d['id_token'];
    _exp = DateTime.now().add(Duration(seconds: int.parse(d['expires_in']) - 120));
    await prefs.setString('refreshToken', d['refresh_token']);
    return _idToken!;
  }

  Future<void> write(Map<String, Object> data) async {
    data['t'] = {'.sv': 'timestamp'};
    final tok = await _token();
    final r = await http
        .put(Uri.parse('$dbUrl/alms.json?auth=${Uri.encodeQueryComponent(tok)}'),
            body: jsonEncode(data))
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('Write failed (${r.statusCode}): ${r.body}');
  }
}

// ---------------- UI ----------------

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  SharedPreferences? prefs;
  Firebase? fb;

  StreamSubscription<Position>? sub;
  Timer? hb;
  Position? lastPos;
  Position? lastSent;
  DateTime lastSentAt = DateTime(2000);
  bool sending = false;

  String status = 'Not sharing';
  String detail = '';

  final dbCtl = TextEditingController();
  final keyCtl = TextEditingController();
  final emailCtl = TextEditingController();
  final passCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() {
          prefs = p;
          fb = Firebase(p);
          dbCtl.text = p.getString('dbUrl') ?? defaultDbUrl;
          keyCtl.text = p.getString('apiKey') ?? defaultApiKey;
          emailCtl.text = defaultEmail;
        }));
  }

  bool get sharing => sub != null;

  ({double lat, double lng})? get zone {
    final s = prefs?.getString('zone');
    if (s == null) return null;
    final m = jsonDecode(s);
    return (lat: (m['lat'] as num).toDouble(), lng: (m['lng'] as num).toDouble());
  }

  void setStatus(String s, [String d = '']) {
    if (mounted) setState(() { status = s; detail = d; });
  }

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setStatus('Location is turned off', 'Turn on Location in Android settings.');
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      setStatus('Location permission denied', 'Allow location for Alms GPS in Android settings.');
      return false;
    }
    return true;
  }

  Future<void> start() async {
    if (!await ensurePermission()) return;
    setStatus('Waiting for GPS…');
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Alms GPS is sharing your location',
        notificationText: 'Open the app and tap Stop when the alms round is over.',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    sub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) {
        lastPos = pos;
        send(pos, false);
      },
      onError: (e) => setStatus('GPS problem', '$e'),
    );
    hb = Timer.periodic(const Duration(seconds: 20), (_) {
      final p = lastPos;
      if (p != null && DateTime.now().difference(lastSentAt) >= heartbeat) send(p, true);
    });
    setState(() {});
  }

  Future<void> send(Position pos, bool force) async {
    if (sending) return;
    final now = DateTime.now();
    final since = now.difference(lastSentAt);
    final moved = lastSent == null
        ? double.infinity
        : Geolocator.distanceBetween(
            lastSent!.latitude, lastSent!.longitude, pos.latitude, pos.longitude);
    if (!force && since < sendEvery && moved < minMoveM) return;
    if (!force && since < heartbeat && moved < 3) return;

    final z = zone;
    final inZone = z != null &&
        Geolocator.distanceBetween(z.lat, z.lng, pos.latitude, pos.longitude) < zoneRadiusM;
    final Map<String, Object> data = inZone
        ? {'active': true, 'hidden': true}
        : {
            'active': true,
            'lat': double.parse(pos.latitude.toStringAsFixed(6)),
            'lng': double.parse(pos.longitude.toStringAsFixed(6)),
            'acc': pos.accuracy.round(),
          };
    sending = true;
    lastSent = pos;
    lastSentAt = now;
    try {
      await fb!.write(data);
      final n = DateTime.now();
      final t = '${n.hour}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}';
      setStatus(inZone ? 'Sharing, hidden (private zone)' : 'Sharing live',
          'Last sent $t · accuracy ±${pos.accuracy.round()} m');
    } catch (e) {
      lastSentAt = DateTime(2000); // retry on next fix
      setStatus('Problem sending (will retry)', '$e');
    } finally {
      sending = false;
    }
  }

  Future<void> stop() async {
    await sub?.cancel();
    hb?.cancel();
    sub = null;
    hb = null;
    lastPos = null;
    lastSent = null;
    lastSentAt = DateTime(2000);
    setStatus('Stopping…');
    try {
      await fb!.write({'active': false});
      setStatus('Not sharing', 'The map now shows the alms round has ended.');
    } catch (e) {
      setStatus('Could not reach server', '$e\nThe map will time out by itself.');
    }
  }

  Future<void> setZone() async {
    if (!await ensurePermission()) return;
    final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high));
    await prefs!.setString('zone', jsonEncode({'lat': pos.latitude, 'lng': pos.longitude}));
    setState(() {});
  }

  Future<void> doSignIn() async {
    setStatus('Signing in…');
    try {
      await fb!.signIn(dbCtl.text, keyCtl.text, emailCtl.text, passCtl.text);
      passCtl.clear();
      setStatus('Not sharing');
    } catch (e) {
      setStatus('Sign-in failed', '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (fb == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Alms GPS')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(status, style: Theme.of(context).textTheme.titleLarge),
                if (detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(detail)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          if (!fb!.signedIn) ...loginForm() else ...mainControls(),
        ]),
      ),
    );
  }

  List<Widget> loginForm() => [
        const Text('Enter the password once. The phone stays signed in.'),
        TextField(
            controller: emailCtl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Sender email')),
        TextField(
            controller: passCtl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password')),
        const SizedBox(height: 16),
        FilledButton(onPressed: doSignIn, child: const Text('Sign in')),
        ExpansionTile(
          title: const Text('Advanced'),
          tilePadding: EdgeInsets.zero,
          children: [
            TextField(controller: dbCtl, decoration: const InputDecoration(labelText: 'Database URL')),
            TextField(controller: keyCtl, decoration: const InputDecoration(labelText: 'Web API key')),
          ],
        ),
      ];

  List<Widget> mainControls() {
    final big = FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(72), textStyle: const TextStyle(fontSize: 22));
    return [
      sharing
          ? FilledButton(
              style: big.copyWith(backgroundColor: const WidgetStatePropertyAll(Colors.red)),
              onPressed: stop,
              child: const Text('Stop sharing'))
          : FilledButton(
              style: big.copyWith(backgroundColor: WidgetStatePropertyAll(Colors.green.shade700)),
              onPressed: start,
              child: const Text('Start sharing')),
      const SizedBox(height: 12),
      const Text('You can lock the phone while sharing. A notification stays visible until you tap Stop.'),
      const Divider(height: 32),
      Text('Private zone: ${zone == null ? 'not set' : 'set (${zoneRadiusM.round()} m radius)'}',
          style: Theme.of(context).textTheme.titleMedium),
      const Text('Inside this zone the website shows "starting" with no location. '
          'The zone is stored only on this phone.'),
      const SizedBox(height: 8),
      OutlinedButton(onPressed: sharing ? null : setZone, child: const Text('Set private zone at my current spot')),
      OutlinedButton(
          onPressed: sharing || zone == null
              ? null
              : () async {
                  await prefs!.remove('zone');
                  setState(() {});
                },
          child: const Text('Remove private zone')),
      const Divider(height: 32),
      TextButton(
          onPressed: sharing
              ? null
              : () async {
                  await fb!.signOut();
                  setState(() {});
                },
          child: const Text('Sign out')),
    ];
  }
}
