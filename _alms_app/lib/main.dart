// Alms GPS: shares the phone's location with floridabuddhistmonastery.org/alms-live/
// while the alms round is in progress. Keeps sending with the screen off by running
// an Android foreground service (a notification stays visible while sharing).
//
// Writes to Firebase Realtime Database /alms, same format as the web sender
// (/alms-live/send/):  {active, hidden?, lat?, lng?, acc?, t}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:google_mlkit_subject_segmentation/google_mlkit_subject_segmentation.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
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

// Head shot: take the top square of the cut-out (the face), make it a circle and
// paint it over the head of the faceless robed figure (108x297, head centre 54,27).
img.Image composeFace(img.Image cut, img.Image robePng) {
  // Head from the photo goes *behind* the robe, so the neck tucks into the
  // neckline. The head is trimmed to a soft oval so no photo shoulders show.
  final robe = robePng.convert(numChannels: 4);
  int opaque(int y, bool left) {
    for (var i = 0; i < cut.width; i++) {
      final x = left ? i : cut.width - 1 - i;
      if (cut.getPixel(x, y).a > 128) return x;
    }
    return -1;
  }

  final probeY = (cut.height * 0.12).round().clamp(0, cut.height - 1);
  final l = opaque(probeY, true), rr = opaque(probeY, false);
  final headW = (l >= 0 && rr > l) ? rr - l : cut.width;
  final headCx = (l >= 0 && rr > l) ? (l + rr) / 2 : cut.width / 2;
  const targetW = 38.0,
      topY = 0.0,
      cx = 54.0; // head size/place on 108x297 body
  final s = targetW / headW;
  // Oval around the head (in photo pixels): scalp to just below the chin.
  final ox = headCx, oy = headW * 0.62, rx = headW * 0.56, ry = headW * 0.78;
  final out = img.Image(width: robe.width, height: robe.height, numChannels: 4);
  for (var y = 0; y < out.height; y++) {
    final sy = (y - topY) / s;
    if (sy < 0 || sy >= cut.height || sy > oy + ry) continue;
    for (var x = 0; x < out.width; x++) {
      final sx = (x - cx) / s + headCx;
      if (sx < 0 || sx >= cut.width) continue;
      final dx = (sx - ox) / rx, dy = (sy - oy) / ry;
      final e = dx * dx + dy * dy;
      if (e >= 1) continue;
      final edge = e > 0.8 ? (1 - e) / 0.2 : 1.0; // feather the oval edge
      final f = cut.getPixelInterpolate(sx, sy);
      out.setPixelRgba(x, y, f.r, f.g, f.b, (f.a * edge).round());
    }
  }
  return img.compositeImage(out, robe);
}

class AlmsApp extends StatelessWidget {
  const AlmsApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Alms GPS',
    theme: ThemeData(colorSchemeSeed: Colors.orange, useMaterial3: true),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.orange,
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const HomePage(),
  );
}

// ---------------- Firebase (REST) ----------------

class Firebase {
  Firebase(this.prefs);
  final SharedPreferences prefs;
  String? _idToken;
  DateTime _exp = DateTime(2000);

  String get dbUrl =>
      (prefs.getString('dbUrl') ?? '').replaceAll(RegExp(r'/+$'), '');
  String get apiKey => prefs.getString('apiKey') ?? '';
  bool get signedIn => (prefs.getString('refreshToken') ?? '').isNotEmpty;

  Future<void> signIn(
    String dbUrl,
    String apiKey,
    String email,
    String password,
  ) async {
    await prefs.setString('dbUrl', dbUrl.trim());
    await prefs.setString('apiKey', apiKey.trim());
    final r = await http.post(
      Uri.parse(
        'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${this.apiKey}',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'returnSecureToken': true,
      }),
    );
    final d = jsonDecode(r.body);
    if (d['error'] != null) throw Exception(d['error']['message']);
    _idToken = d['idToken'];
    _exp = DateTime.now().add(
      Duration(seconds: int.parse(d['expiresIn']) - 120),
    );
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
      body:
          'grant_type=refresh_token&refresh_token=${Uri.encodeQueryComponent(rt)}',
    );
    final d = jsonDecode(r.body);
    if (d['error'] != null)
      throw Exception('Sign-in expired, please sign in again');
    _idToken = d['id_token'];
    _exp = DateTime.now().add(
      Duration(seconds: int.parse(d['expires_in']) - 120),
    );
    await prefs.setString('refreshToken', d['refresh_token']);
    return _idToken!;
  }

  Future<void> write(Map<String, Object> data) async {
    data['t'] = {'.sv': 'timestamp'};
    final tok = await _token();
    final r = await http
        .put(
          Uri.parse('$dbUrl/alms.json?auth=${Uri.encodeQueryComponent(tok)}'),
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200)
      throw Exception('Write failed (${r.statusCode}): ${r.body}');
  }

  // Trail of points for the lotus path on the map (/alms_trail). Never written
  // inside the private zone; erased at Start; the map hides it 3 hours after the last point.
  Future<void> addTrail(double lat, double lng) async {
    final tok = await _token();
    final r = await http
        .post(
          Uri.parse(
            '$dbUrl/alms_trail.json?auth=${Uri.encodeQueryComponent(tok)}',
          ),
          body: jsonEncode({
            'lat': lat,
            'lng': lng,
            't': {'.sv': 'timestamp'},
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200)
      throw Exception('Trail write failed (${r.statusCode}): ${r.body}');
  }

  // Guest monk photos (/alms_guests/<id> = {img: data URL}). Names stay on the phone.
  Future<void> putGuest(String id, String dataUrl) async {
    final tok = await _token();
    final r = await http
        .put(
          Uri.parse(
            '$dbUrl/alms_guests/$id.json?auth=${Uri.encodeQueryComponent(tok)}',
          ),
          body: jsonEncode({'img': dataUrl}),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200)
      throw Exception('Photo upload failed (${r.statusCode}): ${r.body}');
  }

  Future<void> deleteGuest(String id) async {
    final tok = await _token();
    await http
        .delete(
          Uri.parse(
            '$dbUrl/alms_guests/$id.json?auth=${Uri.encodeQueryComponent(tok)}',
          ),
        )
        .timeout(const Duration(seconds: 20));
  }

  Future<void> clearTrail() async {
    final tok = await _token();
    await http
        .delete(
          Uri.parse(
            '$dbUrl/alms_trail.json?auth=${Uri.encodeQueryComponent(tok)}',
          ),
        )
        .timeout(const Duration(seconds: 20));
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
    SharedPreferences.getInstance().then(
      (p) => setState(() {
        prefs = p;
        fb = Firebase(p);
        dbCtl.text = p.getString('dbUrl') ?? defaultDbUrl;
        keyCtl.text = p.getString('apiKey') ?? defaultApiKey;
        emailCtl.text = defaultEmail;
      }),
    );
  }

  bool get sharing => sub != null;

  // Guest monks: [{id, name, img (base64 PNG)}] stored on this phone.
  List<Map<String, dynamic>> get guests =>
      (jsonDecode(prefs?.getString('guests') ?? '[]') as List)
          .cast<Map<String, dynamic>>();
  Future<void> saveGuests(List<Map<String, dynamic>> g) =>
      prefs!.setString('guests', jsonEncode(g));
  List<String> get walking => prefs?.getStringList('walking') ?? [];

  // A guest's photo is online only while he is ticked as walking.
  Future<void> setWalking(String id, bool on) async {
    try {
      final g = guests.firstWhere((x) => x['id'] == id, orElse: () => {});
      if (on && g['img'] != null) {
        await fb!.putGuest(id, 'data:image/png;base64,${g['img']}');
      } else if (!on) {
        await fb!.deleteGuest(id);
      }
    } catch (e) {
      setStatus(
        on ? 'Could not upload the photo' : 'Could not remove the photo online',
        '$e',
      );
      if (on) return;
    }
    final w = walking.where((x) => x != id).toList();
    if (on) w.add(id);
    await prefs!.setStringList('walking', w);
    await setMonks(monks); // re-clamp the total and update the map
  }

  int get monks => (prefs?.getInt('monks') ?? 1).clamp(1 + walking.length, 20);
  Future<void> setMonks(int n) async {
    await prefs!.setInt('monks', n.clamp(1 + walking.length, 20));
    setState(() {});
    final p = lastPos;
    if (sharing && p != null) send(p, true); // update the map right away
  }

  ({double lat, double lng})? get zone {
    final s = prefs?.getString('zone');
    if (s == null) return null;
    final m = jsonDecode(s);
    return (
      lat: (m['lat'] as num).toDouble(),
      lng: (m['lng'] as num).toDouble(),
    );
  }

  void setStatus(String s, [String d = '']) {
    if (mounted)
      setState(() {
        status = s;
        detail = d;
      });
  }

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setStatus(
        'Location is turned off',
        'Turn on Location in Android settings.',
      );
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied)
      p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      setStatus(
        'Location permission denied',
        'Allow location for Alms GPS in Android settings.',
      );
      return false;
    }
    return true;
  }

  Future<void> start() async {
    if (!await ensurePermission()) return;
    setStatus('Waiting for GPS…');
    try {
      await fb!.clearTrail(); // fresh lotus trail for each alms round
    } catch (_) {}
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'Alms GPS is sharing your location',
        notificationText:
            'Open the app and tap Stop when the alms round is over.',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    sub = Geolocator.getPositionStream(locationSettings: settings).listen((
      pos,
    ) {
      lastPos = pos;
      send(pos, false);
    }, onError: (e) => setStatus('GPS problem', '$e'));
    hb = Timer.periodic(const Duration(seconds: 20), (_) {
      final p = lastPos;
      if (p != null && DateTime.now().difference(lastSentAt) >= heartbeat)
        send(p, true);
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
            lastSent!.latitude,
            lastSent!.longitude,
            pos.latitude,
            pos.longitude,
          );
    if (!force && since < sendEvery && moved < minMoveM) return;
    if (!force && since < heartbeat && moved < 3) return;

    final z = zone;
    final inZone =
        z != null &&
        Geolocator.distanceBetween(z.lat, z.lng, pos.latitude, pos.longitude) <
            zoneRadiusM;
    final Map<String, Object> data = inZone
        ? {'active': true, 'hidden': true, 'monks': monks, 'guests': walking}
        : {
            'active': true,
            'monks': monks,
            'guests': walking,
            'lat': double.parse(pos.latitude.toStringAsFixed(6)),
            'lng': double.parse(pos.longitude.toStringAsFixed(6)),
            'acc': pos.accuracy.round(),
          };
    sending = true;
    lastSent = pos;
    lastSentAt = now;
    try {
      await fb!.write(data);
      if (!inZone)
        await fb!.addTrail(data['lat'] as double, data['lng'] as double);
      final n = DateTime.now();
      final t =
          '${n.hour}:${n.minute.toString().padLeft(2, '0')}:${n.second.toString().padLeft(2, '0')}';
      setStatus(
        inZone ? 'Sharing, hidden (private zone)' : 'Sharing live',
        'Last sent $t · accuracy ±${pos.accuracy.round()} m',
      );
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
      await fb!.write({
        'active': false,
        'monks': monks,
      }); // lotus trail stays; map hides it after 3 hours
      setStatus('Not sharing', 'The map now shows the alms round has ended.');
    } catch (e) {
      setStatus(
        'Could not reach server',
        '$e\nThe map will time out by itself.',
      );
    }
  }

  Future<void> setZone() async {
    if (!await ensurePermission()) return;
    final pos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
    );
    await prefs!.setString(
      'zone',
      jsonEncode({'lat': pos.latitude, 'lng': pos.longitude}),
    );
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
    if (fb == null)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Alms GPS')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(status, style: Theme.of(context).textTheme.titleLarge),
                    if (detail.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(detail),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (!fb!.signedIn) ...loginForm() else ...mainControls(),
          ],
        ),
      ),
    );
  }

  List<Widget> loginForm() => [
    const Text('Enter the password once. The phone stays signed in.'),
    TextField(
      controller: emailCtl,
      keyboardType: TextInputType.emailAddress,
      decoration: const InputDecoration(labelText: 'Sender email'),
    ),
    TextField(
      controller: passCtl,
      obscureText: true,
      decoration: const InputDecoration(labelText: 'Password'),
    ),
    const SizedBox(height: 16),
    FilledButton(onPressed: doSignIn, child: const Text('Sign in')),
    ExpansionTile(
      title: const Text('Advanced'),
      tilePadding: EdgeInsets.zero,
      children: [
        TextField(
          controller: dbCtl,
          decoration: const InputDecoration(labelText: 'Database URL'),
        ),
        TextField(
          controller: keyCtl,
          decoration: const InputDecoration(labelText: 'Web API key'),
        ),
      ],
    ),
  ];

  bool busyGuest = false;

  Future<void> addGuest() async {
    final nameCtl = TextEditingController();
    ImageSource? source;
    var kind = 'faceless'; // faceless | full | head
    final name = await showDialog<String>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Add guest monk'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name (kept on this phone only)',
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'faceless', label: Text('Faceless')),
                  ButtonSegment(value: 'full', label: Text('Full body')),
                  ButtonSegment(value: 'head', label: Text('Head shot')),
                ],
                selected: {kind},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setD(() => kind = v.first),
              ),
              const SizedBox(height: 8),
              Text(
                {
                  'faceless': 'No photo. He shows as a plain robed figure.',
                  'full': 'Use a full-length standing photo, used as taken.',
                  'head':
                      'Use a head-and-shoulders photo. His face is put on the robed figure.',
                }[kind]!,
              ),
              if (kind != 'faceless')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Only with the guest monk\'s permission. The photo is shown on the public '
                    'map only when you tick him as walking.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Cancel'),
            ),
            if (kind == 'faceless')
              FilledButton(
                onPressed: () => Navigator.pop(c, nameCtl.text.trim()),
                child: const Text('Add'),
              ),
            if (kind != 'faceless')
              TextButton(
                onPressed: () {
                  source = ImageSource.gallery;
                  Navigator.pop(c, nameCtl.text.trim());
                },
                child: const Text('From gallery'),
              ),
            if (kind != 'faceless')
              FilledButton(
                onPressed: () {
                  source = ImageSource.camera;
                  Navigator.pop(c, nameCtl.text.trim());
                },
                child: const Text('Take photo'),
              ),
          ],
        ),
      ),
    );
    if (name == null) return;
    final headShot = kind == 'head';
    if (kind == 'faceless') {
      final id = 'g${DateTime.now().millisecondsSinceEpoch}';
      await saveGuests(
        guests..add({
          'id': id,
          'name': name.isEmpty ? 'Guest monk' : name,
          'img': null,
        }),
      );
      setState(() {});
      return;
    }
    if (source == null) return;
    final shot = await ImagePicker().pickImage(
      source: source!,
      maxWidth: 1200,
      maxHeight: 1600,
      imageQuality: 92,
    );
    if (shot == null) return;
    setState(() => busyGuest = true);
    setStatus('Cutting out the photo…');
    final seg = SubjectSegmenter(
      options: SubjectSegmenterOptions(
        enableForegroundBitmap: true,
        enableForegroundConfidenceMask: false,
        enableMultipleSubjects: SubjectResultOptions(
          enableConfidenceMask: false,
          enableSubjectBitmap: false,
        ),
      ),
    );
    try {
      // The first time, Google Play services downloads the cutout model; wait and retry.
      SubjectSegmentationResult? res;
      for (var attempt = 0; res == null; attempt++) {
        try {
          res = await seg.processImage(InputImage.fromFilePath(shot.path));
        } catch (e) {
          if (!'$e'.contains('to be downloaded') || attempt >= 12) rethrow;
          setStatus(
            'Downloading the cutout tool…',
            'First time only. Please keep the app open.',
          );
          await Future.delayed(const Duration(seconds: 5));
        }
      }
      final fg = res.foregroundBitmap;
      if (fg == null)
        throw Exception('No person found in the photo. Please try again.');
      var im = img.decodePng(fg)!;
      im = img.trim(im, mode: img.TrimMode.transparent);
      if (headShot) im = await faceOnBody(im);
      if (im.height > 220)
        im = img.copyResize(
          im,
          height: 220,
          interpolation: img.Interpolation.average,
        );
      final b64 = base64Encode(img.encodePng(im));
      final id = 'g${DateTime.now().millisecondsSinceEpoch}';
      final g = guests
        ..add({
          'id': id,
          'name': name.isEmpty ? 'Guest monk' : name,
          'img': b64,
        });
      await saveGuests(g);
      setStatus(
        sharing ? status : 'Not sharing',
        'Guest added. Tick him when he walks with you.',
      );
    } catch (e) {
      setStatus('Could not add guest', '$e');
    } finally {
      await seg.close();
      if (mounted) setState(() => busyGuest = false);
    }
  }

  // Head shot: take the top square of the cut-out (the face), make it a circle
  // and paint it over the head of the faceless robed figure.
  Future<img.Image> faceOnBody(img.Image cut) async {
    final data = await rootBundle.load('assets/guest_robe.png');
    return composeFace(cut, img.decodePng(data.buffer.asUint8List())!);
  }

  Future<void> removeGuest(Map<String, dynamic> g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${g['name']}?'),
        content: const Text(
          'The photo is deleted from this phone and from the website.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await setWalking(g['id'], false); // also removes it online
    await saveGuests(guests.where((x) => x['id'] != g['id']).toList());
    setState(() {});
  }

  List<Widget> guestControls() => [
    const Divider(height: 32),
    Text('Guest monks', style: Theme.of(context).textTheme.titleMedium),
    const Text(
      'Tick the guests walking today. Others in the count show as faceless figures.',
    ),
    for (final g in guests)
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: g['img'] == null
            ? Image.asset(
                'assets/guest_body.png',
                height: 56,
                width: 24,
                fit: BoxFit.contain,
              )
            : Image.memory(
                base64Decode(g['img']),
                height: 56,
                width: 24,
                fit: BoxFit.contain,
              ),
        title: Text(g['name']),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Checkbox(
              value: walking.contains(g['id']),
              onChanged: (v) => setWalking(g['id'], v == true),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => removeGuest(g),
            ),
          ],
        ),
      ),
    OutlinedButton.icon(
      onPressed: busyGuest ? null : addGuest,
      icon: const Icon(Icons.photo_camera),
      label: Text(busyGuest ? 'Working…' : 'Add guest monk'),
    ),
  ];

  List<Widget> mainControls() {
    final big = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(72),
      textStyle: const TextStyle(fontSize: 22),
    );
    return [
      Row(
        children: [
          Expanded(
            child: Text(
              'Monks on alms round',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton.outlined(
            onPressed: monks > 1 + walking.length
                ? () => setMonks(monks - 1)
                : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '$monks',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          IconButton.outlined(
            onPressed: monks < 20 ? () => setMonks(monks + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      const SizedBox(height: 12),
      sharing
          ? FilledButton(
              style: big.copyWith(
                backgroundColor: const WidgetStatePropertyAll(Colors.red),
              ),
              onPressed: stop,
              child: const Text('Stop sharing'),
            )
          : FilledButton(
              style: big.copyWith(
                backgroundColor: WidgetStatePropertyAll(Colors.green.shade700),
              ),
              onPressed: start,
              child: const Text('Start sharing'),
            ),
      const SizedBox(height: 12),
      const Text(
        'You can lock the phone while sharing. A notification stays visible until you tap Stop.',
      ),
      ...guestControls(),
      const Divider(height: 32),
      Text(
        'Private zone: ${zone == null ? 'not set' : 'set (${zoneRadiusM.round()} m radius)'}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const Text(
        'Inside this zone the website shows "starting" with no location. '
        'The zone is stored only on this phone.',
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: sharing ? null : setZone,
        child: const Text('Set private zone at my current spot'),
      ),
      OutlinedButton(
        onPressed: sharing || zone == null
            ? null
            : () async {
                await prefs!.remove('zone');
                setState(() {});
              },
        child: const Text('Remove private zone'),
      ),
      const Divider(height: 32),
      TextButton(
        onPressed: sharing
            ? null
            : () async {
                await fb!.signOut();
                setState(() {});
              },
        child: const Text('Sign out'),
      ),
    ];
  }
}
