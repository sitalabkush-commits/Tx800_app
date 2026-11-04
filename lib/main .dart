import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

// ───────────────────────── CONFIG ─────────────────────────
const String kApiUrl = 'https://tx800-backend.vercel.app/api';
const String kUserId = 'android_user';
const String kTtsLang = 'bn-BD';

const double kSpeechThresholdDb = -38; // এর উপরে হলে কথা বলছে ধরা হবে
const int kSilenceStopMs = 1500; // কথা বলার পর এতক্ষণ চুপ থাকলে রেকর্ড বন্ধ
const int kNoSpeechTimeoutMs = 5000; // কিছু না বললে ৫ সেকেন্ডে বন্ধ
const int kMaxRecordMs = 30000;

const Color kBg = Color(0xFF040A10);
const Color kCyan = Color(0xFF00F0FF);
const Color kPanel = Color(0xFF0A1420);
const Color kGreen = Color(0xFF2EE6A6);
const Color kBlue = Color(0xFF5B9BFF);
const String kMono = 'monospace';

enum VoiceState { idle, listening, processing, speaking }

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
  ));
  runApp(const Tx800App());
}

class Tx800App extends StatelessWidget {
  const Tx800App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tx 800 Mini',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: kBg),
      home: const HudScreen(),
    );
  }
}

// ───────────────────────── ANIMATION CLOCK ─────────────────────────
class HudClock extends ChangeNotifier {
  double angle = 0; // rotation (speed depends on state)
  double time = 0; // plain seconds
  double speed = 0.35;
  double level = 0; // smoothed audio level 0..1
  double targetLevel = 0;

  void tick(double dt) {
    angle += dt * speed;
    time += dt;
    level += (targetLevel - level) * math.min(1, dt * 12);
    notifyListeners();
  }
}

// ───────────────────────── SYNTH (no asset needed) ─────────────────────────
class Synth {
  static Uint8List _wav(Float64List s, int sr) {
    final n = s.length;
    final b = ByteData(44 + n * 2);
    void str(int o, String t) {
      for (var i = 0; i < t.length; i++) {
        b.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    b.setUint32(4, 36 + n * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little);
    b.setUint16(22, 1, Endian.little);
    b.setUint32(24, sr, Endian.little);
    b.setUint32(28, sr * 2, Endian.little);
    b.setUint16(32, 2, Endian.little);
    b.setUint16(34, 16, Endian.little);
    str(36, 'data');
    b.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      b.setInt16(44 + i * 2, (s[i].clamp(-1.0, 1.0) * 32767).toInt(), Endian.little);
    }
    return b.buffer.asUint8List();
  }

  static void _normalize(Float64List s, double peakTarget) {
    var peak = 0.0;
    for (final v in s) {
      if (v.abs() > peak) peak = v.abs();
    }
    if (peak == 0) return;
    final k = peakTarget / peak;
    for (var i = 0; i < s.length; i++) {
      s[i] *= k;
    }
  }

  /// 12 সেকেন্ডের seamless লুপ: গভীর ambient pad (সব ফ্রিকোয়েন্সি পূর্ণ সাইকেলে শেষ হয়)
  static Uint8List ambient() {
    const sr = 22050;
    const dur = 12;
    final n = sr * dur;
    final s = Float64List(n);
    const tones = <List<double>>[
      [55.0, 0.9],
      [82.5, 0.6],
      [110.0, 0.7],
      [165.0, 0.45],
      [220.0, 0.25],
      [330.0, 0.12],
    ];
    const detune = 2 / 12;
    const tau = 2 * math.pi;
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      var v = 0.0;
      for (var k = 0; k < tones.length; k++) {
        final f = tones[k][0];
        final a = tones[k][1];
        final lfo = (k + 1) / 12.0;
        final mod = 0.65 + 0.35 * math.sin(tau * lfo * t + k);
        v += (math.sin(tau * f * t) + 0.7 * math.sin(tau * (f + detune) * t)) * a * mod;
      }
      s[i] = v;
    }
    _normalize(s, 0.6);
    return _wav(s, sr);
  }

  /// সাই-ফাই arpeggio (মাইক ট্যাপ সাউন্ড)
  static Uint8List arpeggio() {
    const sr = 22050;
    const notes = [220.0, 261.63, 329.63, 440.0, 523.25, 659.25, 880.0];
    const step = 0.085;
    final n = (sr * 1.4).toInt();
    final s = Float64List(n);
    const tau = 2 * math.pi;
    for (var k = 0; k < notes.length; k++) {
      final start = (k * step * sr).toInt();
      final len = (0.5 * sr).toInt();
      final f = notes[k];
      for (var i = 0; i < len && start + i < n; i++) {
        final t = i / sr;
        final env = math.exp(-t * 7) * (1 - math.exp(-t * 400));
        final v = math.sin(tau * f * t) * 0.6 +
            math.sin(tau * 2 * f * t) * 0.2 +
            math.sin(tau * 3 * f * t) * 0.08;
        s[start + i] += v * env;
      }
    }
    final d = (0.18 * sr).toInt();
    for (var i = n - 1; i >= d; i--) {
      s[i] += s[i - d] * 0.35;
    }
    _normalize(s, 0.8);
    return _wav(s, sr);
  }
}

// ───────────────────────── MAIN SCREEN ─────────────────────────
class HudScreen extends StatefulWidget {
  const HudScreen({super.key});
  @override
  State<HudScreen> createState() => _HudScreenState();
}

class _HudScreenState extends State<HudScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final HudClock clock = HudClock();
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  final AudioRecorder _rec = AudioRecorder();
  final AudioPlayer _bgm = AudioPlayer();
  final AudioPlayer _sfx = AudioPlayer();
  final FlutterTts _tts = FlutterTts();

  VoiceState _state = VoiceState.idle;
  bool _revealed = false; // শুরুতে status + response box লুকানো
  double _vol = 0.75;

  String _userText = '';
  String _reply = '';
  String _link = '—'; // UPLINK: OK / ERROR
  String? _notice;

  String? _bgmPath;
  String? _sfxPath;
  String? _recPath;

  StreamSubscription<Amplitude>? _ampSub;
  Timer? _recTimer;
  bool _heard = false;
  DateTime _recStart = DateTime.now();
  DateTime _lastVoice = DateTime.now();
  double _elapsed = 0;
  double _silentMs = 0;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((d) {
      final dt = (d - _lastTick).inMicroseconds / 1e6;
      _lastTick = d;
      clock.tick(dt.clamp(0.0, 0.1).toDouble());
    })..start();
    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _recTimer?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    _bgm.dispose();
    _sfx.dispose();
    _tts.stop();
    clock.dispose();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  // ── boot: audio files, music, tts ──
  Future<String> _prepareSound(String assetName, Uint8List Function() fallback, String ext) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/tx_$assetName$ext');
    Uint8List bytes;
    try {
      // assets/audio/<assetName>.mp3 থাকলে সেটাই ব্যবহার হবে
      final data = await rootBundle.load('assets/audio/$assetName.mp3');
      bytes = data.buffer.asUint8List();
      final f = File('${dir.path}/tx_$assetName.mp3');
      await f.writeAsBytes(bytes, flush: true);
      return f.path;
    } catch (_) {
      bytes = fallback();
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    }
  }

  Future<void> _boot() async {
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContextConfig(focus: AudioContextConfigFocus.mixWithOthers).build(),
      );
      _bgmPath = await _prepareSound('bgm', Synth.ambient, '.wav');
      _sfxPath = await _prepareSound('arpeggio', Synth.arpeggio, '.wav');
      await _bgm.setReleaseMode(ReleaseMode.loop);
      await _bgm.setVolume(_bgmTarget);
      await _bgm.play(DeviceFileSource(_bgmPath!));
    } catch (e) {
      debugPrint('audio boot error: $e');
    }
    try {
      await _tts.setLanguage(kTtsLang);
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(1.0);
      await _tts.setVolume(_vol);
      await _tts.awaitSpeakCompletion(true);
    } catch (e) {
      debugPrint('tts boot error: $e');
    }
  }

  double get _bgmTarget {
    final base = _vol * 0.5;
    switch (_state) {
      case VoiceState.idle:
        return base;
      case VoiceState.listening:
        return base * 0.15;
      case VoiceState.processing:
        return base * 0.3;
      case VoiceState.speaking:
        return base * 0.3;
    }
  }

  void _applyVolume() {
    _bgm.setVolume(_bgmTarget);
    _tts.setVolume(_vol);
  }

  void _setState(VoiceState s) {
    _set(() => _state = s);
    switch (s) {
      case VoiceState.idle:
        clock.speed = 0.35;
        clock.targetLevel = 0;
        break;
      case VoiceState.listening:
        clock.speed = 0.9;
        break;
      case VoiceState.processing:
        clock.speed = 3.2;
        clock.targetLevel = 0.5;
        break;
      case VoiceState.speaking:
        clock.speed = 1.4;
        break;
    }
    _applyVolume();
  }

  // ── tap handler ──
  Future<void> _onMicTap() async {
    HapticFeedback.mediumImpact();
    if (_state == VoiceState.processing) return;
    if (_state == VoiceState.listening) {
      await _finishRecording();
      return;
    }
    if (_state == VoiceState.speaking) {
      await _tts.stop();
      _setState(VoiceState.idle);
      return;
    }

    _set(() {
      _revealed = true;
      _notice = null;
      _reply = '';
      _userText = '';
      _link = '—';
    });

    final st = await Permission.microphone.request();
    if (!st.isGranted) {
      _set(() => _notice = st.isPermanentlyDenied
          ? 'মাইক্রোফোন পারমিশন বন্ধ। Settings থেকে চালু করুন।'
          : 'মাইক্রোফোন পারমিশন দিতে হবে।');
      if (st.isPermanentlyDenied) openAppSettings();
      return;
    }

    // arpeggio feedback
    try {
      if (_sfxPath != null) {
        await _sfx.stop();
        await _sfx.play(DeviceFileSource(_sfxPath!), volume: _vol.clamp(0.1, 1.0).toDouble());
      }
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 700));

    await _startRecording();
  }

  Future<void> _startRecording() async {
    try {
      final dir = await getTemporaryDirectory();
      _recPath = '${dir.path}/tx_input.wav';
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _recPath!,
      );
    } catch (e) {
      _set(() => _notice = 'রেকর্ডিং শুরু করা যায়নি: $e');
      _setState(VoiceState.idle);
      return;
    }

    _heard = false;
    _stopping = false;
    _elapsed = 0;
    _silentMs = 0;
    _recStart = DateTime.now();
    _lastVoice = _recStart;
    _setState(VoiceState.listening);

    _ampSub = _rec
        .onAmplitudeChanged(const Duration(milliseconds: 80))
        .listen((a) {
      final db = a.current;
      clock.targetLevel = ((db + 55) / 55).clamp(0.0, 1.0).toDouble();
      if (db > kSpeechThresholdDb) {
        _heard = true;
        _lastVoice = DateTime.now();
      }
    });

    _recTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final now = DateTime.now();
      final ms = now.difference(_recStart).inMilliseconds;
      _elapsed = ms / 1000;
      _silentMs = now.difference(_lastVoice).inMilliseconds.toDouble();
      _set(() {});
      if (_heard && _silentMs > kSilenceStopMs) {
        _finishRecording();
      } else if (!_heard && ms > kNoSpeechTimeoutMs) {
        _finishRecording();
      } else if (ms > kMaxRecordMs) {
        _finishRecording();
      }
    });
  }

  Future<void> _finishRecording() async {
    if (_stopping) return;
    _stopping = true;
    _recTimer?.cancel();
    await _ampSub?.cancel();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}

    if (!_heard || path == null) {
      _set(() => _notice = 'কোনো কথা শোনা যায়নি। আবার ট্যাপ করুন।');
      _setState(VoiceState.idle);
      return;
    }

    _setState(VoiceState.processing);
    await _sendToBackend(path);
  }

  Future<void> _sendToBackend(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      final b64 = base64Encode(bytes);
      final res = await http
          .post(
            Uri.parse(kApiUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': kUserId, 'audio': b64}),
          )
          .timeout(const Duration(seconds: 45));

      if (res.statusCode != 200) {
        throw Exception('Server ${res.statusCode}');
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final reply = (data['reply'] ?? '').toString().trim();
      final userText = (data['user_text'] ?? '').toString().trim();

      _set(() {
        _reply = reply.isEmpty ? '...' : reply;
        _userText = userText;
        _link = 'UPLINK: OK';
      });
      if (reply.isNotEmpty) {
        await _speak(reply);
      } else {
        _setState(VoiceState.idle);
      }
    } on TimeoutException {
      _fail('সার্ভার সাড়া দিচ্ছে না (timeout)।');
    } catch (e) {
      _fail('সংযোগ ব্যর্থ: $e');
    }
  }

  void _fail(String msg) {
    _set(() {
      _notice = msg;
      _link = 'UPLINK: ERROR';
    });
    _setState(VoiceState.idle);
  }

  Future<void> _speak(String text) async {
    _setState(VoiceState.speaking);
    try {
      final ok = await _tts.isLanguageAvailable(kTtsLang);
      if (ok == false) {
        _set(() => _notice =
            'বাংলা TTS ভয়েস নেই। Settings › Text-to-speech এ Google বাংলা ভয়েস ইনস্টল করুন।');
      }
      await _tts.setLanguage(kTtsLang);
      await _tts.setVolume(_vol);
      await _tts.speak(text);
    } catch (e) {
      _set(() => _notice = 'TTS সমস্যা: $e');
    }
    if (mounted && _state == VoiceState.speaking) {
      _setState(VoiceState.idle);
    }
  }

  // ───────────── UI ─────────────
  String get _statusText {
    switch (_state) {
      case VoiceState.idle:
        return 'TAP TO START';
      case VoiceState.listening:
        return 'LISTENING... ${_elapsed.toStringAsFixed(1)}s';
      case VoiceState.processing:
        return 'PROCESSING...';
      case VoiceState.speaking:
        return 'SPEAKING...';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: GridPainter(clock))),
          Positioned.fill(
            child: ListenableBuilder(
              listenable: clock,
              builder: (_, __) {
                final pulse = 0.5 + 0.5 * math.sin(clock.time * 1.8);
                final base = _state == VoiceState.idle ? 0.16 : 0.26;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.35),
                      radius: 0.95,
                      colors: [
                        kCyan.withOpacity(base + 0.08 * pulse + clock.level * 0.12),
                        Colors.transparent,
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(child: CustomPaint(painter: BracketPainter())),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 16),
              child: Column(
                children: [
                  _topInfo(),
                  const SizedBox(height: 18),
                  _badges(),
                  Expanded(
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.contain,
                        child: SizedBox(width: 330, height: 330, child: _orb()),
                      ),
                    ),
                  ),
                  _statusBlock(),
                  const SizedBox(height: 16),
                  _responseCard(),
                  const SizedBox(height: 12),
                  _volumeBar(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topInfo() {
    return Row(
      children: [
        Text('SYS.VER 4.09.2',
            style: TextStyle(
                fontFamily: kMono, fontSize: 12, letterSpacing: 2.5, color: Colors.white.withOpacity(.45))),
        const Spacer(),
        Icon(Icons.network_cell, size: 16, color: kCyan.withOpacity(.8)),
        const SizedBox(width: 8),
        const Icon(Icons.battery_full, size: 18, color: kGreen),
      ],
    );
  }

  Widget _badges() {
    final listening = _state == VoiceState.listening;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _Badge('HEARING', listening ? kCyan : kCyan.withOpacity(.55), blink: listening, clock: clock),
        _Badge('BG: ACTIVE', kGreen, clock: clock),
        _Badge('FACE LOCK', kBlue, clock: clock),
      ],
    );
  }

  Widget _orb() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _onMicTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(child: CustomPaint(painter: OrbPainter(clock, () => _state))),
          ListenableBuilder(
            listenable: clock,
            builder: (_, __) {
              final glow = 0.5 + 0.5 * math.sin(clock.time * 2.2);
              final boost = _state == VoiceState.listening ? clock.level * 0.5 : 0.0;
              return Container(
                width: 128,
                height: 128,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kCyan.withOpacity(.07),
                  border: Border.all(color: kCyan, width: 3),
                  boxShadow: [
                    BoxShadow(
                      color: kCyan.withOpacity(.35 + .2 * glow + boost * .3),
                      blurRadius: 28 + 22 * glow + 30 * boost,
                      spreadRadius: 2 + 6 * boost,
                    ),
                  ],
                ),
                child: Center(child: _bars()),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _bars() {
    const base = [0.35, 0.7, 1.0, 0.55, 0.85, 0.4, 0.25];
    double amp;
    switch (_state) {
      case VoiceState.idle:
        amp = 0.45;
        break;
      case VoiceState.listening:
        amp = 0.25 + clock.level * 1.3;
        break;
      case VoiceState.processing:
        amp = 0.8;
        break;
      case VoiceState.speaking:
        amp = 0.55 + 0.35 * math.sin(clock.time * 3);
        break;
    }
    final speedK = _state == VoiceState.idle ? 1.5 : 6.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(base.length, (i) {
        final wave = 0.5 + 0.5 * math.sin(clock.time * speedK + i * 1.1);
        final h = (8 + 40 * base[i] * amp * (0.35 + 0.65 * wave)).clamp(6.0, 56.0).toDouble();
        return Container(
          width: 4,
          height: h,
          margin: const EdgeInsets.symmetric(horizontal: 3.5),
          decoration: BoxDecoration(
            color: kCyan,
            borderRadius: BorderRadius.circular(4),
            boxShadow: [BoxShadow(color: kCyan.withOpacity(.6), blurRadius: 6)],
          ),
        );
      }),
    );
  }

  Widget _statusBlock() {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 500),
      opacity: _revealed ? 1 : 0,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        offset: _revealed ? Offset.zero : const Offset(0, 0.6),
        child: Column(
          children: [
            Text(
              _statusText,
              style: TextStyle(
                fontFamily: kMono,
                fontSize: 17,
                letterSpacing: 4,
                color: Colors.white.withOpacity(.88),
              ),
            ),
            const SizedBox(height: 12),
            _progress(),
          ],
        ),
      ),
    );
  }

  Widget _progress() {
    return ListenableBuilder(
      listenable: clock,
      builder: (_, __) {
        double start = 0, width = 0;
        switch (_state) {
          case VoiceState.idle:
            width = 0;
            break;
          case VoiceState.listening:
            width = _heard
                ? (1 - _silentMs / kSilenceStopMs).clamp(0.08, 1.0).toDouble()
                : (_elapsed / (kNoSpeechTimeoutMs / 1000)).clamp(0.02, 1.0).toDouble();
            break;
          case VoiceState.processing:
            width = 0.3;
            start = (clock.time * 0.9 % 1.4) - 0.3;
            break;
          case VoiceState.speaking:
            width = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(clock.time * 4));
            break;
        }
        return Container(
          width: 270,
          height: 6,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: FractionallySizedBox(
              alignment: Alignment(-1 + 2 * (start / math.max(0.001, 1 - width)).clamp(0.0, 1.0).toDouble(), 0),
              widthFactor: width.clamp(0.0, 1.0).toDouble(),
              child: Container(
                decoration: BoxDecoration(
                  color: kCyan,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: [BoxShadow(color: kCyan.withOpacity(.7), blurRadius: 8)],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _responseCard() {
    String body;
    if (_notice != null) {
      body = _notice!;
    } else if (_reply.isNotEmpty) {
      body = _reply;
    } else {
      switch (_state) {
        case VoiceState.listening:
          body = 'Sensors calibrated. Awaiting voice input...';
          break;
        case VoiceState.processing:
          body = 'Analyzing audio signal. Neural link active...';
          break;
        default:
          body = 'Standing by.';
      }
    }
    final isError = _notice != null;
    final tag = _state == VoiceState.idle ? 'STANDBY' : 'LINKED';
    final sub = switch (_state) {
      VoiceState.idle => 'READY FOR INPUT',
      VoiceState.listening => 'MIC INPUT ONLINE',
      VoiceState.processing => 'CLOUD SYNTHESIS RUNNING',
      VoiceState.speaking => 'AUDIO OUTPUT ONLINE',
    };

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 500),
      opacity: _revealed ? 1 : 0,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutCubic,
        offset: _revealed ? Offset.zero : const Offset(0, 0.35),
        child: IgnorePointer(
          ignoring: !_revealed,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              color: kPanel.withOpacity(.78),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: kCyan.withOpacity(.35), width: 1.2),
              boxShadow: [BoxShadow(color: kCyan.withOpacity(.08), blurRadius: 24)],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.access_time_filled, size: 20, color: kCyan),
                    const SizedBox(width: 10),
                    const Text('RESPONSE SYNTHESIS',
                        style: TextStyle(
                            fontFamily: kMono,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2.2,
                            color: Colors.white)),
                    const Spacer(),
                    Text(_link,
                        style: TextStyle(
                            fontFamily: kMono,
                            fontSize: 11,
                            letterSpacing: 1.2,
                            color: _link.contains('ERROR') ? Colors.redAccent : kCyan.withOpacity(.6))),
                  ],
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: kCyan.withOpacity(.15)),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 130),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_userText.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text('YOU › $_userText',
                                style: TextStyle(
                                    fontSize: 13, color: kCyan.withOpacity(.7), height: 1.35)),
                          ),
                        Text(
                          isError ? body : '"$body"',
                          style: TextStyle(
                            fontSize: 17,
                            height: 1.4,
                            color: isError ? Colors.orangeAccent : Colors.white.withOpacity(.95),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(.3),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: kCyan.withOpacity(.18)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: kCyan.withOpacity(.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.bolt, color: kCyan, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'VOICE LINK: ${_state == VoiceState.idle ? 'IDLE' : 'ACTIVE'}',
                              style: const TextStyle(
                                  fontFamily: kMono,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.6,
                                  color: Colors.white),
                            ),
                            const SizedBox(height: 2),
                            Text(sub,
                                style: TextStyle(
                                    fontFamily: kMono,
                                    fontSize: 11,
                                    letterSpacing: 1.4,
                                    color: Colors.white.withOpacity(.4))),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: kGreen.withOpacity(.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: kGreen.withOpacity(.6)),
                        ),
                        child: Text(tag,
                            style: const TextStyle(
                                fontFamily: kMono, fontSize: 11, letterSpacing: 1.4, color: kGreen)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _volumeBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: kPanel.withOpacity(.7),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: kCyan.withOpacity(.3)),
      ),
      child: Row(
        children: [
          Icon(_vol == 0 ? Icons.volume_off : Icons.volume_up, color: Colors.white.withOpacity(.6), size: 22),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: kCyan,
                inactiveTrackColor: Colors.white.withOpacity(.12),
                overlayColor: kCyan.withOpacity(.12),
                thumbShape: const GlowThumb(),
                trackShape: const RoundedRectSliderTrackShape(),
              ),
              child: Slider(
                value: _vol,
                onChanged: (v) {
                  _set(() => _vol = v);
                  _applyVolume();
                },
              ),
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(_vol * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                    fontFamily: kMono, fontSize: 13, letterSpacing: 1, color: Colors.white.withOpacity(.7))),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── WIDGETS / PAINTERS ─────────────────────────
class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  final bool blink;
  final HudClock clock;
  const _Badge(this.label, this.color, {this.blink = false, required this.clock});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: kPanel.withOpacity(.75),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withOpacity(.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListenableBuilder(
            listenable: clock,
            builder: (_, __) {
              final a = blink ? 0.4 + 0.6 * (0.5 + 0.5 * math.sin(clock.time * 8)) : 1.0;
              return Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(a),
                  boxShadow: [BoxShadow(color: color.withOpacity(.8 * a), blurRadius: 6)],
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          Text(label,
              style: TextStyle(
                  fontFamily: kMono, fontSize: 12.5, letterSpacing: 2, color: Colors.white.withOpacity(.85))),
        ],
      ),
    );
  }
}

class GlowThumb extends SliderComponentShape {
  const GlowThumb();
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(26, 26);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final c = context.canvas;
    c.drawCircle(center, 15, Paint()
      ..color = kCyan.withOpacity(.55)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    c.drawCircle(center, 10, Paint()..color = kCyan);
    c.drawCircle(center, 4, Paint()..color = kBg.withOpacity(.35));
  }
}

class GridPainter extends CustomPainter {
  final HudClock clock;
  GridPainter(this.clock) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = kCyan.withOpacity(.045)
      ..strokeWidth = 1;
    const g = 34.0;
    for (double x = 0; x <= size.width; x += g) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y <= size.height; y += g) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    // scan line
    final y = size.height * (0.28 + 0.32 * (0.5 + 0.5 * math.sin(clock.time * 0.5)));
    final rect = Rect.fromLTWH(0, y - 1, size.width, 2);
    final shader = LinearGradient(
      colors: [Colors.transparent, kCyan.withOpacity(.55), Colors.transparent],
    ).createShader(rect);
    canvas.drawRect(rect, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant GridPainter old) => false;
}

class BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = kCyan.withOpacity(.75)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const inset = 12.0;
    const len = 26.0;
    final w = size.width, h = size.height;
    canvas.drawPath(Path()..moveTo(inset, inset + len)..lineTo(inset, inset)..lineTo(inset + len, inset), p);
    canvas.drawPath(Path()..moveTo(w - inset - len, inset)..lineTo(w - inset, inset)..lineTo(w - inset, inset + len), p);
    canvas.drawPath(Path()..moveTo(inset, h - inset - len)..lineTo(inset, h - inset)..lineTo(inset + len, h - inset), p);
    canvas.drawPath(Path()..moveTo(w - inset - len, h - inset)..lineTo(w - inset, h - inset)..lineTo(w - inset, h - inset - len), p);
  }

  @override
  bool shouldRepaint(covariant BracketPainter old) => false;
}

class OrbPainter extends CustomPainter {
  final HudClock clock;
  final VoiceState Function() stateOf;
  OrbPainter(this.clock, this.stateOf) : super(repaint: clock);

  void _dashed(Canvas c, Offset ctr, double r, double rot, int dashes, double fill, Paint p) {
    final seg = 2 * math.pi / dashes;
    final rect = Rect.fromCircle(center: ctr, radius: r);
    for (var i = 0; i < dashes; i++) {
      c.drawArc(rect, rot + i * seg, seg * fill, false, p);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 330;
    final ctr = Offset(size.width / 2, size.height / 2);
    final a = clock.angle;
    final active = stateOf() != VoiceState.idle;
    final intensity = (active ? 1.0 : 0.65) + clock.level * 0.3;

    Paint line(double alpha, double w) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = kCyan.withOpacity((alpha * intensity).clamp(0.0, 1.0).toDouble());

    _dashed(canvas, ctr, 158 * k, a * 0.5, 64, 0.35, line(.35, 1.2));
    _dashed(canvas, ctr, 143 * k, -a * 0.8, 30, 0.6, line(.5, 1.4));
    _dashed(canvas, ctr, 124 * k, a * 0.4, 96, 0.3, line(.28, 1.0));
    _dashed(canvas, ctr, 172 * k, -a * 0.3, 40, 0.15, line(.18, 1.0));

    // bright arcs with glow
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = kCyan.withOpacity(.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final bright = line(.95, 2.8);
    final r1 = Rect.fromCircle(center: ctr, radius: 150 * k);
    final r2 = Rect.fromCircle(center: ctr, radius: 135 * k);
    for (final p in [glow, bright]) {
      canvas.drawArc(r1, a * 0.7 - 0.9, 0.9, false, p);
      canvas.drawArc(r2, -a * 0.9 + 2.4, 0.7, false, p);
      canvas.drawArc(r1, a * 0.7 + 3.2, 0.4, false, p);
    }

    // cardinal dots
    final dot = Paint()..color = kCyan;
    final dotGlow = Paint()
      ..color = kCyan.withOpacity(.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
    final dr = 100 * k;
    for (var i = 0; i < 4; i++) {
      final ang = i * math.pi / 2 + math.sin(clock.time * 0.8) * 0.06;
      final o = ctr + Offset(math.cos(ang), math.sin(ang)) * dr;
      canvas.drawCircle(o, 6, dotGlow);
      canvas.drawCircle(o, 3.5, dot);
    }

    // white drifting dots
    final white = Paint()..color = Colors.white.withOpacity(.9);
    for (var i = 0; i < 2; i++) {
      final ang = a * (0.6 + i * 0.3) + i * 3.4;
      final o = ctr + Offset(math.cos(ang), math.sin(ang)) * (118 * k + i * 22 * k);
      canvas.drawCircle(o, 2.2, white);
    }

    // pulse halo when listening
    if (stateOf() == VoiceState.listening) {
      final t = (clock.time * 1.2) % 1;
      canvas.drawCircle(
        ctr,
        (70 + 90 * t) * k,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = kCyan.withOpacity((1 - t) * .5),
      );
    }
  }

  @override
  bool shouldRepaint(covariant OrbPainter old) => false;
}
