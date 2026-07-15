import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:open_filex/open_filex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shimmer/shimmer.dart';
import 'package:google_api_availability/google_api_availability.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'firebase_options.dart';
import 'platform_checks.dart';

import 'web_ad_manager_stub.dart' if (dart.library.js_util) 'web_ad_manager_web.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel devChannel = AndroidNotificationChannel(
  'developer_alerts_v3', 
  'Developer Vault Alerts',
  description: 'Urgent notifications for developer uploads',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
  showBadge: true,
);

const AndroidNotificationChannel regionChannel = AndroidNotificationChannel(
  'region_alerts_v3', 
  'Regional Updates',
  description: 'Live updates for subscribed regions',
  importance: Importance.max,
  playSound: true,
  enableVibration: true,
);

DateTime _lastAdTime = DateTime.fromMillisecondsSinceEpoch(0);
Map<String, String> _adConfig = {
  'ads': dotenv.env['ADMOB_PUBLISHER_ID'] ?? '5878584013742794',
  'banner_id': dotenv.env['ADMOB_BANNER_ID'] ?? '7832732481',
  'interstitial_id': dotenv.env['ADMOB_INTERSTITIAL_ID'] ?? '5178192130',
  'rewarded_id': dotenv.env['ADMOB_REWARDED_ID'] ?? '5537741639',
  'web_slot_id': dotenv.env['ADMOB_WEB_SLOT_ID'] ?? '6311371130',
};

String _getAdUnitId(String type) {
  if (kDebugMode) {
    if (type == 'banner') return 'ca-app-pub-3940256099942544/6300978111';
    if (type == 'interstitial') return 'ca-app-pub-3940256099942544/1033173712';
    if (type == 'rewarded') return 'ca-app-pub-3940256099942544/5224354917';
  }
  String rawAds = _adConfig['ads'] ?? '';
  RegExp pubRegex = RegExp(r'(\d{16})');
  var pubMatch = pubRegex.firstMatch(rawAds);
  String pub = pubMatch != null ? pubMatch.group(1)! : '5878584013742794';
  String rawUnit = _adConfig['${type}_id'] ?? '';
  if (rawUnit.contains('/')) rawUnit = rawUnit.split('/').last;
  return 'ca-app-pub-$pub/$rawUnit';
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)) {
    try { MobileAds.instance.initialize(); } catch (_) {}
  }

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseFirestore.instance.settings = const Settings(persistenceEnabled: true, cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED);

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    if (!kIsWeb) {
      const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('ic_launcher_foreground');
      const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
      await flutterLocalNotificationsPlugin.initialize(initializationSettings);

      final androidPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(devChannel);
      await androidPlugin?.createNotificationChannel(regionChannel);

      await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(alert: true, badge: true, sound: true);
    }

    FirebaseFirestore.instance.collection('app_version').doc('ads').get().timeout(const Duration(seconds: 3)).then((doc) {
      if (doc.exists && doc.data() != null) {
        doc.data()!.forEach((k, v) => _adConfig[k] = v.toString().trim());
      }
    }).catchError((_) {});

    if (kIsWeb) {
      registerWebAdView(pubId: _adConfig['ads']!, slotId: _adConfig['web_slot_id']!);
      registerWebIframe('iframe-entry', 'https://allegretto-eisteddfod.co.za/entry-forms/');
      registerWebIframe('iframe-syllabus', 'https://allegretto-eisteddfod.co.za/documents-information/allegretto-syllabus/');
    }

    _requestPermissions();
    final prefs = await SharedPreferences.getInstance();
    FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(prefs.getBool('data_collection_enabled') ?? true);
    
    runApp(const AllegrettoApp());
  } catch (e) {
    runApp(const AllegrettoApp());
  }
}

Future<void> _requestPermissions() async {
  try {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt >= 33) {
        await Permission.notification.request();
      }
    }
    await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
  } catch (e) {
    debugPrint('Permission request failed: $e');
  }
}

class AllegrettoApp extends StatefulWidget {
  const AllegrettoApp({super.key});
  @override
  State<AllegrettoApp> createState() => _AllegrettoAppState();
}

class _AllegrettoAppState extends State<AllegrettoApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  void toggleTheme() => setState(() => _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  
  @override
  void initState() {
    super.initState();
    _setupNotifications();
  }

  Future<void> _setupNotifications() async {
    _updateTokenInFirestore();
    FirebaseMessaging.instance.onTokenRefresh.listen((_) => _updateTokenInFirestore());

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      RemoteNotification? notification = message.notification;
      String? title = notification?.title ?? message.data['title'] ?? 'Allegretto Update';
      String? body = notification?.body ?? message.data['body'] ?? 'New data available.';

      if (!kIsWeb) {
        String channelId = message.data['channelId'] ?? devChannel.id;
        flutterLocalNotificationsPlugin.show(
          message.hashCode,
          title,
          body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channelId,
              channelId == regionChannel.id ? regionChannel.name : devChannel.name,
              icon: 'ic_launcher_foreground',
              importance: Importance.max,
              priority: Priority.max,
              visibility: NotificationVisibility.public,
            ),
          ),
        );
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(children: [
              const Icon(Icons.cloud_done, color: Colors.grey, size: 18),
              const SizedBox(width: 12),
              Expanded(child: Text('CLOUD SIGNAL: $title')),
            ]),
            backgroundColor: const Color(0xFF212121),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          )
        );
      }
    });
  }

  static Future<void> _updateTokenInFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      String? token = await FirebaseMessaging.instance.getToken(
        vapidKey: kIsWeb ? dotenv.env['FCM_VAPID_KEY'] : null
      );
      if (token != null) {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'fcmToken': token,
          'platform': kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios'),
          'lastTokenUpdate': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Sync failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeController(
      toggleTheme: toggleTheme,
      themeMode: _themeMode,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: _themeMode,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.light, colorSchemeSeed: Colors.red),
        darkTheme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: Colors.red, scaffoldBackgroundColor: const Color(0xFF121212)),
        home: const AppVersionWrapper(child: AuthWrapper()),
      ),
    );
  }
}

class AppVersionWrapper extends StatefulWidget {
  final Widget child;
  const AppVersionWrapper({super.key, required this.child});
  @override
  State<AppVersionWrapper> createState() => _AppVersionWrapperState();
}

class _AppVersionWrapperState extends State<AppVersionWrapper> {
  bool _isChecking = true;
  String? _updateUrl;
  String? _updateMessage;
  String? _publicDate;
  String? _publicTime;

  @override
  void initState() { super.initState(); _checkVersion(); }

  Future<void> _checkVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final doc = await FirebaseFirestore.instance.collection('app_version').doc('app_version').get()
          .timeout(const Duration(seconds: 2));
      if (doc.exists && doc.data() != null) {
        final data = doc.data()!;
        final minV = data['min_version'] as String?;
        if (minV != null && _isNewer(minV, packageInfo.version)) {
          setState(() { 
            _updateUrl = data['update_url']; 
            _updateMessage = data['update_message'];
            _publicDate = data['public_date'];
            _publicTime = data['public_time'];
            _isChecking = false; 
          });
          return;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _isChecking = false);
  }

  bool _isNewer(String target, String current) {
    try {
      List<int> t = target.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      List<int> c = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
      for (int i = 0; i < t.length; i++) {
        if (i >= c.length) return true;
        if (t[i] > c[i]) return true;
        if (t[i] < c[i]) return false;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_updateUrl != null) {
      return Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.black, Color(0xFF1A1A1A), Color(0xFF121212)],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(40.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: Colors.red.withOpacity(0.2), blurRadius: 40, spreadRadius: 5),
                          BoxShadow(color: const Color(0xFFB71C1C).withOpacity(0.1), blurRadius: 100, spreadRadius: 10),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(100),
                        child: Image.asset('assets/icon/allegretto.png', height: 160, fit: BoxFit.cover),
                      ),
                    ),
                    const SizedBox(height: 50),
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [const Color(0xFFB71C1C), const Color(0xFFE53935), const Color(0xFFB71C1C)],
                        stops: [0.0, 0.5, 1.0],
                      ).createShader(bounds),
                      child: const Text(
                        'NEW UPDATE AVAILABLE',
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 4, color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ALLEGRETTO EISTEDDFOD',
                      style: TextStyle(fontSize: 12, letterSpacing: 3, color: Colors.white54, fontWeight: FontWeight.w400),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _updateMessage ?? 'A new version of Allegretto is available with important improvements and features.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.5, fontWeight: FontWeight.w300),
                          ),
                          if (_publicDate != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Released: $_publicDate${_publicTime != null ? ' at $_publicTime' : ''}',
                              style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 0.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 60),
                    ElevatedButton(
                      onPressed: () => launchUrl(Uri.parse(_updateUrl!), mode: LaunchMode.externalApplication),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        minimumSize: const Size(double.infinity, 64),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
                        elevation: 20,
                        shadowColor: Colors.black,
                      ),
                      child: const Text('UPDATE NOW', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16)),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'REQUIRED FOR CONTINUED ACCESS',
                      style: TextStyle(color: Colors.white24, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return widget.child;
  }
}

class ThemeController extends InheritedWidget {
  final VoidCallback toggleTheme;
  final ThemeMode themeMode;
  const ThemeController({super.key, required this.toggleTheme, required this.themeMode, required super.child});
  static ThemeController? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ThemeController>();
  @override
  bool updateShouldNotify(ThemeController oldWidget) => themeMode != oldWidget.themeMode;
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(stream: FirebaseAuth.instance.authStateChanges(), builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Scaffold(body: Center(child: CircularProgressIndicator()));
      if (snapshot.hasData) {
        _AllegrettoAppState._updateTokenInFirestore();
        return SessionTracker(child: const MainNavigationPage());
      }
      return const LoginPage();
    });
  }
}

class SessionTracker extends StatefulWidget {
  final Widget child;
  const SessionTracker({super.key, required this.child});
  @override
  State<SessionTracker> createState() => _SessionTrackerState();
}

class _SessionTrackerState extends State<SessionTracker> with WidgetsBindingObserver {
  late DateTime _startTime;
  String? _sessionId;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _startSession(); }
  @override
  void dispose() { _endSession(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) _endSession();
    else if (state == AppLifecycleState.resumed) _startSession();
  }
  void _startSession() { _startTime = DateTime.now(); _sessionId = const Uuid().v4(); _logStart(); }
  void _endSession() { if (_sessionId != null) { DataCollector.endFirestoreSession(_sessionId!, DateTime.now().difference(_startTime).inSeconds); _sessionId = null; } }
  Future<void> _logStart() async { DataCollector.startFirestoreSession(_sessionId!, await DataCollector.getDeviceInfo()); }
  @override
  Widget build(BuildContext context) => widget.child;
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLogin = true;
  bool _isLoading = false;
  late AnimationController _logoAnim;

  @override
  void initState() {
    super.initState();
    _logoAnim = AnimationController(vsync: this, duration: const Duration(milliseconds: 2500))..repeat(reverse: true);
  }
  
  @override
  void dispose() { _logoAnim.dispose(); super.dispose(); }

  Future<void> _submit() async {
    final e = _emailController.text.trim();
    final p = _passwordController.text.trim();
    if (e.isEmpty || p.isEmpty) return;
    setState(() => _isLoading = true);
    try {
      if (_isLogin) await FirebaseAuth.instance.signInWithEmailAndPassword(email: e, password: p);
      else {
        final res = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: e, password: p);
        if (res.user != null) {
          await FirebaseFirestore.instance.collection('users').doc(res.user!.uid).set({
            'email': e, 'createdAt': FieldValue.serverTimestamp(), 'is_subscribed': false, 'is_pro': false, 'is_developer': 'false', 'allowDataSale': true, 'hasSeenConsent': false, 'subscribed_regions': [], 'platform': kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios')
          }, SetOptions(merge: true));
        }
      }
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString()), backgroundColor: const Color(0xFFD32F2F)));
    } finally { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isLoading = true);
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() => _isLoading = false);
        return;
      }
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final UserCredential userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
      if (userCredential.user != null) {
        await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).set({
          'email': userCredential.user!.email,
          'createdAt': FieldValue.serverTimestamp(),
          'is_subscribed': false,
          'is_pro': false,
          'is_developer': 'false',
          'allowDataSale': true,
          'hasSeenConsent': false,
          'subscribed_regions': [],
          'platform': kIsWeb ? 'web' : (defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios')
        }, SetOptions(merge: true));
      }
    } catch (err) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Google Sign-In failed: ${err.toString()}'), backgroundColor: const Color(0xFFD32F2F)));
    } finally { if (mounted) setState(() => _isLoading = false); }
  }

  Future<void> _resetPassword() async {
    final emailController = TextEditingController(text: _emailController.text.trim());
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF212121),
        title: const Text('Reset Password', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: emailController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Email Address',
                labelStyle: const TextStyle(color: Colors.white70),
                prefixIcon: const Icon(Icons.email, color: Colors.white70),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.redAccent)),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'A password reset link will be sent to your email address.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          ElevatedButton(
            onPressed: () async {
              final email = emailController.text.trim();
              if (email.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter your email address'), backgroundColor: const Color(0xFFD32F2F)),
                );
                return;
              }
              Navigator.pop(context);
              try {
                await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Password reset email sent! Check your inbox.'),
                      backgroundColor: Colors.green,
                      duration: Duration(seconds: 4),
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: const Color(0xFFD32F2F)),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Send Link', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Colors.black, Color(0xFF1A1A1A), Color(0xFF121212)],
          ),
        ),
        child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.all(40.0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 60),
          AnimatedBuilder(
            animation: _logoAnim,
            builder: (context, child) {
              return Center(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: Colors.red.withOpacity(0.2 + (_logoAnim.value * 0.15)), blurRadius: 40 + (_logoAnim.value * 30), spreadRadius: 5),
                      BoxShadow(color: const Color(0xFFB71C1C).withOpacity(0.3), blurRadius: 100, spreadRadius: 10),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(100),
                    child: Image.asset('assets/icon/allegretto.png', height: 190, fit: BoxFit.cover),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 50),
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(colors: [const Color(0xFFB71C1C), const Color(0xFFE53935), const Color(0xFFB71C1C)], stops: [0.0, 0.5, 1.0]).createShader(bounds),
            child: const Text('ALLEGRETTO', style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 8, color: Colors.white), textAlign: TextAlign.center),
          ),
          const Text('MUSIC • DRAMA • DANCE • ART', style: TextStyle(fontSize: 12, letterSpacing: 3, color: Colors.white54, fontWeight: FontWeight.w400), textAlign: TextAlign.center),
          const SizedBox(height: 70),
          TextField(controller: _emailController, style: const TextStyle(color: Colors.white, fontSize: 16), decoration: InputDecoration(labelText: 'Email Address', labelStyle: const TextStyle(color: Colors.white60), prefixIcon: const Icon(Icons.alternate_email, color: Colors.white38), enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12)), focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.redAccent)))),
          const SizedBox(height: 25),
          TextField(controller: _passwordController, obscureText: true, style: const TextStyle(color: Colors.white, fontSize: 16), decoration: InputDecoration(labelText: 'Password', labelStyle: const TextStyle(color: Colors.white60), prefixIcon: const Icon(Icons.lock_person_outlined, color: Colors.white38), enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white12)), focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.redAccent)))),
          const SizedBox(height: 12),
          if (_isLogin) Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _resetPassword,
              child: const Text('Forgot Password?', style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w500)),
            ),
          ),
          const SizedBox(height: 38),
          _isLoading ? const Center(child: CircularProgressIndicator(color: Colors.white)) : ElevatedButton(onPressed: _submit, style: ElevatedButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)), elevation: 20, shadowColor: Colors.black), child: Text(_isLogin ? 'ENTER PORTAL' : 'CREATE ACCOUNT', style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 2, fontSize: 16))),
          const SizedBox(height: 20),
          // Google Sign-In temporarily disabled due to configuration issues
          // if (!kIsWeb) Container(
          //   height: 1,
          //   margin: const EdgeInsets.symmetric(vertical: 20),
          //   decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.transparent, Colors.white24, Colors.transparent])),
          // ),
          // if (!kIsWeb) _isLoading ? const SizedBox.shrink() : ElevatedButton.icon(
          //   onPressed: _signInWithGoogle,
          //   icon: const Icon(Icons.g_mobiledata, color: Colors.white),
          //   label: const Text('Continue with Google', style: TextStyle(fontWeight: FontWeight.w600, letterSpacing: 1, fontSize: 14)),
          //   style: ElevatedButton.styleFrom(
          //     backgroundColor: Colors.white10,
          //     foregroundColor: Colors.white,
          //     minimumSize: const Size(double.infinity, 56),
          //     shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: BorderSide(color: Colors.white24)),
          //   ),
          // ),
          const SizedBox(height: 20),
          TextButton(onPressed: () => setState(() => _isLogin = !_isLogin), child: Text(_isLogin ? 'NEW TO ALLEGRETTO? REGISTER' : 'ALREADY HAVE AN ACCOUNT? SIGN IN', style: const TextStyle(color: Colors.white38, fontSize: 11, letterSpacing: 1))),
          const SizedBox(height: 40),
        ]))),
      ),
    );
  }
}

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});
  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage> {
  int _selectedIndex = 0;
  bool _isSubscribed = false;
  bool _isPro = false;
  bool _isDeveloper = false;
  InterstitialAd? _interstitialAd;
  bool _isOffline = false;
  final List<bool> _pageLoaded = [true, false, false, false, true];

  @override
  void initState() { 
    super.initState(); 
    _checkSubscriptions(); 
    _loadInterstitialAd(); 
    _initConnectivity(); 
  }

  Future<void> _initConnectivity() async {
    final res = await Connectivity().checkConnectivity();
    setState(() => _isOffline = res.isEmpty || res.contains(ConnectivityResult.none));
    Connectivity().onConnectivityChanged.listen((r) => setState(() => _isOffline = r.isEmpty || r.contains(ConnectivityResult.none)));
  }

  void _checkSubscriptions() {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return;
    FirebaseFirestore.instance.collection('users').doc(u.uid).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        final isDev = doc.data()?['is_developer'] == 'true' || doc.data()?['is_developer'] == true;
        setState(() {
          _isDeveloper = isDev;
          _isSubscribed = (doc.data()?['is_subscribed'] ?? false) || _isDeveloper;
          _isPro = (doc.data()?['is_pro'] ?? false) || _isDeveloper;
        });
        if (isDev && !kIsWeb) {
          FirebaseMessaging.instance.subscribeToTopic('developers');
        } else if (!kIsWeb) {
          FirebaseMessaging.instance.unsubscribeFromTopic('developers');
        }
      }
    });
  }

  void _loadInterstitialAd() {
    if (kIsWeb || _isSubscribed || _isPro) return;
    InterstitialAd.load(adUnitId: _getAdUnitId('interstitial'), request: const AdRequest(), adLoadCallback: InterstitialAdLoadCallback(onAdLoaded: (ad) => _interstitialAd = ad, onAdFailedToLoad: (e) => debugPrint('Ad failed: $e')));
  }

  void _showAdThenOpen(String? url) {
    if (url == null || url.isEmpty) return;
    final diff = DateTime.now().difference(_lastAdTime).inSeconds;
    if (kIsWeb || _isSubscribed || _isPro || _interstitialAd == null || diff < 10) { _openPDF(url); }
    else {
      _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(onAdDismissedFullScreenContent: (ad) { _lastAdTime = DateTime.now(); ad.dispose(); _loadInterstitialAd(); _openPDF(url); }, onAdFailedToShowFullScreenContent: (ad, e) { ad.dispose(); _loadInterstitialAd(); _openPDF(url); });
      _interstitialAd!.show();
    }
  }

  Future<void> _openPDF(String url) async {
    if (kIsWeb) { launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); return; }
    try {
      final fileName = url.split('/').last;
      final dir = _isPro ? await getApplicationDocumentsDirectory() : await getTemporaryDirectory();
      final path = '${dir.path}/$fileName';
      if (!File(path).existsSync()) await Dio().download(url, path);
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (c) => PDFViewerScreen(path: path, url: url, isPro: _isPro)));
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error opening PDF'))); }
  }

  @override
  Widget build(BuildContext context) {
    bool full = _isSubscribed || _isPro;
    if (_isOffline && !kIsWeb) {
      return Scaffold(appBar: AppBar(title: const Text('Allegretto')), body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.signal_wifi_off, size: 64, color: Colors.grey), const SizedBox(height: 16), const Text('Offline.'), if (_isPro) ElevatedButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const OfflineLibraryPage())), child: const Text('Offline Library'))])));
    }
    
    Widget body = IndexedStack(index: _selectedIndex, children: [
      _pageLoaded[0] ? AllegrettoWebView(url: 'https://allegretto-eisteddfod.co.za/entry-forms/', isSubscribed: full, viewType: 'iframe-entry', title: 'Entry Forms', onOpenPDF: _showAdThenOpen) : const SizedBox.shrink(),
      _pageLoaded[1] ? AllegrettoWebView(url: 'https://allegretto-eisteddfod.co.za/documents-information/allegretto-syllabus/', isSubscribed: full, viewType: 'iframe-syllabus', title: 'Syllabus', onOpenPDF: _showAdThenOpen) : const SizedBox.shrink(),
      _pageLoaded[2] ? DatesPage(onOpenPDF: _showAdThenOpen) : const SizedBox.shrink(),
      _pageLoaded[3] ? PerformanceDatesPage(onOpenPDF: _showAdThenOpen, isPro: _isPro) : const SizedBox.shrink(),
      _pageLoaded[4] ? const QRValidationPage() : const SizedBox.shrink(),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Allegretto Eisteddfod'), 
        leading: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance.collection('dev_files')
              .where('createdAt', isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(const Duration(hours: 48))))
              .snapshots(),
          builder: (context, snapshot) {
            bool hasNew = _isDeveloper && snapshot.hasData && snapshot.data!.docs.isNotEmpty;
            return IconButton(
              icon: Badge(
                isLabelVisible: hasNew,
                backgroundColor: const Color(0xFFD32F2F),
                label: hasNew ? Text(snapshot.data!.docs.length.toString()) : null,
                child: const Icon(Icons.settings),
              ),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const AccountSettingsPage())),
            );
          },
        ),
        actions: [
          if (_isPro) Container(margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.amber, borderRadius: BorderRadius.circular(12)), child: const Text('PRO', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12))),
          if (_isPro && !kIsWeb) IconButton(icon: const Icon(Icons.offline_pin_outlined), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const OfflineLibraryPage()))),
        ]
      ),
      body: Column(children: [Expanded(child: body), if (!full) const AdBannerWidget()]),
      bottomNavigationBar: BottomNavigationBar(currentIndex: _selectedIndex, type: BottomNavigationBarType.fixed, onTap: (i) => setState(() { _selectedIndex = i; _pageLoaded[i] = true; }), items: const [
        BottomNavigationBarItem(icon: Icon(Icons.description), label: 'Entry'),
        BottomNavigationBarItem(icon: Icon(Icons.menu_book), label: 'Syllabus'),
        BottomNavigationBarItem(icon: Icon(Icons.calendar_today), label: 'Dates'),
        BottomNavigationBarItem(icon: Icon(Icons.event_note), label: 'Regions'),
        BottomNavigationBarItem(icon: Icon(Icons.qr_code_scanner), label: 'QR Scan'),
      ]),
    );
  }
}

class PDFViewerScreen extends StatefulWidget {
  final String path;
  final String url;
  final bool isPro;
  const PDFViewerScreen({super.key, required this.path, required this.url, required this.isPro});
  @override
  State<PDFViewerScreen> createState() => _PDFViewerScreenState();
}

class _PDFViewerScreenState extends State<PDFViewerScreen> {
  int _adsWatched = 0;
  RewardedAd? _rewardedAd;
  bool _isAdLoading = false;
  @override
  void initState() { super.initState(); if (!widget.isPro) _loadRewardedAd(); }
  void _loadRewardedAd() {
    if (_isAdLoading) return;
    setState(() => _isAdLoading = true);
    RewardedAd.load(adUnitId: _getAdUnitId('rewarded'), request: const AdRequest(), rewardedAdLoadCallback: RewardedAdLoadCallback(onAdLoaded: (ad) => setState(() { _rewardedAd = ad; _isAdLoading = false; }), onAdFailedToLoad: (e) => setState(() => _isAdLoading = false)));
  }
  void _showAd() {
    if (_rewardedAd == null) { _loadRewardedAd(); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Loading Ad...'))); return; }
    _rewardedAd!.show(onUserEarnedReward: (ad, reward) {
      setState(() => _adsWatched++);
      if (_adsWatched >= 2) _startDownload();
      else ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Watch 1 more ad to unlock download!')));
    });
    _rewardedAd = null; _loadRewardedAd();
  }
  Future<void> _startDownload() async {
    try {
      Directory? dir;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) dir = Directory('/storage/emulated/0/Download');
      else dir = await getApplicationDocumentsDirectory();
      final savePath = '${dir!.path}/${widget.url.split('/').last}';
      await Dio().download(widget.url, savePath);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved to: $savePath'), action: SnackBarAction(label: 'Open', onPressed: () => OpenFilex.open(savePath))));
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download failed.'))); }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF Viewer'), actions: [if (widget.url.isNotEmpty) IconButton(icon: Icon(widget.isPro || _adsWatched >= 2 ? Icons.download : Icons.ondemand_video), onPressed: () => (widget.isPro || _adsWatched >= 2) ? _startDownload() : _showAd())]),
      body: Column(children: [
        if (!widget.isPro && _adsWatched < 2) Container(color: Colors.amber.withOpacity(0.2), padding: const EdgeInsets.all(8), child: Center(child: Text('Ads Watched: $_adsWatched / 2 to download', style: const TextStyle(fontWeight: FontWeight.bold)))),
        Expanded(child: PdfViewer.file(widget.path)),
        if (!widget.isPro) const AdBannerWidget()
      ]),
    );
  }
}

class OfflineLibraryPage extends StatefulWidget {
  const OfflineLibraryPage({super.key});
  @override
  State<OfflineLibraryPage> createState() => _OfflineLibraryPageState();
}

class _OfflineLibraryPageState extends State<OfflineLibraryPage> {
  List<File> _files = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final dir = await getApplicationDocumentsDirectory();
    setState(() => _files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.pdf')).toList());
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline Library')),
    body: ListView.builder(itemCount: _files.length, itemBuilder: (c, i) => ListTile(leading: Icon(Icons.picture_as_pdf, color: const Color(0xFFD32F2F)), title: Text(_files[i].path.split('/').last), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (c) => PDFViewerScreen(path: _files[i].path, url: '', isPro: true))), trailing: IconButton(icon: const Icon(Icons.delete), onPressed: () { _files[i].deleteSync(); _load(); }))),
  );
}

class DatesPage extends StatelessWidget {
  final Function(String) onOpenPDF;
  const DatesPage({super.key, required this.onOpenPDF});
  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot>(stream: FirebaseFirestore.instance.collection('app_config').snapshots(), builder: (c, s) {
    if (!s.hasData) return const Center(child: CircularProgressIndicator());
    List<Widget> items = [];
    for (var d in s.data!.docs) { (d.data() as Map).forEach((k, v) { if (v.toString().startsWith('http')) items.add(ListTile(title: Text(k), onTap: () => onOpenPDF(v))); }); }
    return ListView(children: items);
  });
}

class PerformanceDatesPage extends StatelessWidget {
  final Function(String) onOpenPDF;
  final bool isPro;
  const PerformanceDatesPage({super.key, required this.onOpenPDF, required this.isPro});
  @override
  Widget build(BuildContext context) => StreamBuilder<QuerySnapshot>(stream: FirebaseFirestore.instance.collection('region_config').snapshots(), builder: (c, s) {
    if (!s.hasData) return const Center(child: CircularProgressIndicator());
    return ListView.builder(itemCount: s.data!.docs.length, itemBuilder: (c, i) => ListTile(title: Text(s.data!.docs[i].id), trailing: const Icon(Icons.arrow_forward_ios, size: 16), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (c) => RegionDetailView(regionName: s.data!.docs[i].id, onOpenPDF: onOpenPDF, isPro: isPro)))));
  });
}

class RegionDetailView extends StatefulWidget {
  final String regionName;
  final Function(String) onOpenPDF;
  final bool isPro;
  const RegionDetailView({super.key, required this.regionName, required this.onOpenPDF, required this.isPro});
  @override
  State<RegionDetailView> createState() => _RegionDetailViewState();
}

class _RegionDetailViewState extends State<RegionDetailView> {
  bool _isSubscribed = false;
  final u = FirebaseAuth.instance.currentUser;

  @override
  void initState() { super.initState(); _checkSubscription(); }

  void _checkSubscription() {
    if (u == null) return;
    FirebaseFirestore.instance.collection('users').doc(u!.uid).snapshots().listen((doc) {
      if (mounted && doc.exists) {
        List subs = doc.data()?['subscribed_regions'] ?? [];
        setState(() => _isSubscribed = subs.contains(widget.regionName));
      }
    });
  }

  void _toggleSubscription() async {
    if (u == null) return;
    String topic = 'region_${widget.regionName.replaceAll(' ', '_')}';
    if (_isSubscribed) {
      if (!kIsWeb) await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
      await FirebaseFirestore.instance.collection('users').doc(u!.uid).update({'subscribed_regions': FieldValue.arrayRemove([widget.regionName])});
    } else {
      if (!kIsWeb) await FirebaseMessaging.instance.subscribeToTopic(topic);
      await FirebaseFirestore.instance.collection('users').doc(u!.uid).update({'subscribed_regions': FieldValue.arrayUnion([widget.regionName])});
    }
    setState(() => _isSubscribed = !_isSubscribed);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_isSubscribed ? 'Subscribed to updates' : 'Unsubscribed')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.regionName), actions: [IconButton(icon: Icon(_isSubscribed ? Icons.notifications_active : Icons.notifications_none, color: _isSubscribed ? Colors.amber : null), onPressed: _toggleSubscription)]), 
    body: StreamBuilder<DocumentSnapshot>(stream: FirebaseFirestore.instance.collection('region_config').doc(widget.regionName).snapshots(), builder: (c, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      List<Widget> items = [];
      (s.data!.data() as Map?)?.forEach((k, v) { if (v.toString().startsWith('http')) items.add(ListTile(title: Text(k), onTap: () => widget.onOpenPDF(v))); });
      return ListView(children: items);
    })
  );
}

class QRValidationPage extends StatefulWidget {
  const QRValidationPage({super.key});
  @override
  State<QRValidationPage> createState() => _QRValidationPageState();
}

class _QRValidationPageState extends State<QRValidationPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _scanned = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;
    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue != null) {
      setState(() => _scanned = true);
      Navigator.push(context, MaterialPageRoute(builder: (_) => EntryFormPage(qrData: barcode!.rawValue!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            fit: BoxFit.cover,
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFD32F2F), width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UserDashboardPage())),
                  child: const Text('My Entries', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: const Text('Point at a QR code', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

class EntryFormPage extends StatefulWidget {
  final String qrData;
  const EntryFormPage({super.key, required this.qrData});
  @override
  State<EntryFormPage> createState() => _EntryFormPageState();
}

class _EntryFormPageState extends State<EntryFormPage> {
  final _adultNameCtrl = TextEditingController();
  final _studentNameCtrl = TextEditingController();
  final _studentSurnameCtrl = TextEditingController();
  final _studentSchoolCtrl = TextEditingController();
  final _studentGradeCtrl = TextEditingController();
  String? _marksProofPath;
  String? _paymentProofPath;
  bool _saving = false;

  @override
  void dispose() {
    _adultNameCtrl.dispose();
    _studentNameCtrl.dispose();
    _studentSurnameCtrl.dispose();
    _studentSchoolCtrl.dispose();
    _studentGradeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickImage(bool isMarks) async {
    final picker = ImagePicker();
    final result = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (result != null) {
      setState(() {
        if (isMarks) {
          _marksProofPath = result.path;
        } else {
          _paymentProofPath = result.path;
        }
      });
    }
  }

  Future<String> _uploadImage(String filePath, String entryId, String type) async {
    final file = File(filePath);
    final ref = FirebaseStorage.instance.ref('entries/$entryId/${type}_proof.jpg');
    await ref.putFile(file);
    return await ref.getDownloadURL();
  }

  Future<void> _submit() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_adultNameCtrl.text.trim().isEmpty || _studentNameCtrl.text.trim().isEmpty || _studentSurnameCtrl.text.trim().isEmpty || _studentSchoolCtrl.text.trim().isEmpty || _studentGradeCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('All fields are required'), backgroundColor: const Color(0xFFD32F2F)));
      return;
    }
    setState(() => _saving = true);
    try {
      final docRef = await FirebaseFirestore.instance.collection('entries').add({
        'uid': user.uid,
        'adultName': _adultNameCtrl.text.trim(),
        'studentName': _studentNameCtrl.text.trim(),
        'studentSurname': _studentSurnameCtrl.text.trim(),
        'studentSchool': _studentSchoolCtrl.text.trim(),
        'studentGrade': _studentGradeCtrl.text.trim(),
        'qrData': widget.qrData,
        'paymentProofUrl': '',
        'marksProofUrl': '',
        'marksUploadAttempts': 0,
        'paymentStatus': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      });
      final entryId = docRef.id;
      if (_marksProofPath != null) {
        final url = await _uploadImage(_marksProofPath!, entryId, 'marks');
        await docRef.update({'marksProofUrl': url, 'marksUploadAttempts': FieldValue.increment(1)});
      }
      if (_paymentProofPath != null) {
        final url = await _uploadImage(_paymentProofPath!, entryId, 'payment');
        await docRef.update({'paymentProofUrl': url, 'paymentStatus': 'paid'});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry saved'), backgroundColor: Colors.green));
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const UserDashboardPage()));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e'), backgroundColor: const Color(0xFFD32F2F)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        leading: IconButton(icon: Icon(Icons.arrow_back, color: const Color(0xFF757575)), onPressed: () => Navigator.pop(context)),
        title: const Text('New Entry', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0xFF2C2C2C), borderRadius: BorderRadius.circular(8)),
              child: Text('QR: ${widget.qrData}', style: const TextStyle(color: const Color(0xFF9E9E9E), fontSize: 13, fontFamily: 'monospace')),
            ),
            const SizedBox(height: 24),
            _buildLabel('Adult Name (Mom, Dad, Looker)'),
            const SizedBox(height: 6),
            _buildTextField(_adultNameCtrl, 'e.g. John'),
            const SizedBox(height: 16),
            _buildLabel('Student Name'),
            const SizedBox(height: 6),
            _buildTextField(_studentNameCtrl, 'Student name'),
            const SizedBox(height: 16),
            _buildLabel('Student Surname'),
            const SizedBox(height: 6),
            _buildTextField(_studentSurnameCtrl, 'Student surname'),
            const SizedBox(height: 16),
            _buildLabel('Student School'),
            const SizedBox(height: 6),
            _buildTextField(_studentSchoolCtrl, 'School name'),
            const SizedBox(height: 16),
            _buildLabel('Student Grade'),
            const SizedBox(height: 6),
            _buildTextField(_studentGradeCtrl, 'e.g. Grade 10'),
            const SizedBox(height: 24),
            _buildLabel('Proof of Student Marks (with QR code on image)'),
            const SizedBox(height: 8),
            _buildUploadBtn('Upload Image', _marksProofPath, () => _pickImage(true)),
            const SizedBox(height: 24),
            _buildLabel('Proof of Payment (optional)'),
            const SizedBox(height: 8),
            _buildUploadBtn('Upload Image', _paymentProofPath, () => _pickImage(false)),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), padding:  const EdgeInsets.symmetric(vertical: 16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                onPressed: _saving ? null : _submit,
                child: _saving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)) : const Text('Submit Entry', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLabel(String text) {
    return Text(text, style: const TextStyle(color: const Color(0xFF9E9E9E), fontSize: 14));
  }

  Widget _buildTextField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: const Color(0xFF757575)),
        filled: true,
        fillColor: const Color(0xFF2C2C2C),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  Widget _buildUploadBtn(String label, String? path, VoidCallback onTap) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: onTap,
            child: Text(path != null ? 'Change Image' : label, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ),
        if (path != null) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path), height: 200, width: double.infinity, fit: BoxFit.cover),
          ),
        ],
      ],
    );
  }
}

class UserDashboardPage extends StatefulWidget {
  const UserDashboardPage({super.key});
  @override
  State<UserDashboardPage> createState() => _UserDashboardPageState();
}

class _UserDashboardPageState extends State<UserDashboardPage> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchEntries();
  }

  Future<void> _fetchEntries() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() => _loading = true);
    try {
      final q = FirebaseFirestore.instance.collection('entries').where('uid', isEqualTo: user.uid);
      final snapshot = await q.get();
      _entries = snapshot.docs.map((d) => {'id': d.id, ...d.data()}).toList();
      _entries.sort((a, b) => (b['createdAt'] as String? ?? '').compareTo(a['createdAt'] as String? ?? ''));
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addMarksProof(String entryId, int attempts) async {
    if (attempts >= 4) return;
    final picker = ImagePicker();
    final result = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (result == null) return;
    setState(() => _loading = true);
    try {
      final file = File(result.path);
      final ref = FirebaseStorage.instance.ref('entries/$entryId/marks_proof.jpg');
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('entries').doc(entryId).update({
        'marksProofUrl': url,
        'marksUploadAttempts': FieldValue.increment(1),
      });
      _fetchEntries();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to upload'), backgroundColor: const Color(0xFFD32F2F)));
      setState(() => _loading = false);
    }
  }

  Future<void> _addPaymentProof(String entryId) async {
    final picker = ImagePicker();
    final result = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (result == null) return;
    setState(() => _loading = true);
    try {
      final file = File(result.path);
      final ref = FirebaseStorage.instance.ref('entries/$entryId/payment_proof.jpg');
      await ref.putFile(file);
      final url = await ref.getDownloadURL();
      await FirebaseFirestore.instance.collection('entries').doc(entryId).update({
        'paymentProofUrl': url,
        'paymentStatus': 'paid',
      });
      _fetchEntries();
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to upload'), backgroundColor: const Color(0xFFD32F2F)));
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        leading: IconButton(icon: Icon(Icons.arrow_back, color: const Color(0xFF757575)), onPressed: () => Navigator.pop(context)),
        title: const Text('My Entries', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text('${_entries.length} entr${_entries.length == 1 ? 'y' : 'ies'}', style: const TextStyle(color: const Color(0xFF757575), fontSize: 14)),
          ),
          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator(color: const Color(0xFFE53935)))),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: _entries.length,
              itemBuilder: (c, i) => _buildEntryCard(_entries[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(Map<String, dynamic> entry) {
    final id = entry['id'] as String;
    final qrData = entry['qrData'] as String? ?? '';
    final createdAt = entry['createdAt'] as String? ?? '';
    final adultName = entry['adultName'] as String? ?? '';
    final studentName = entry['studentName'] as String? ?? '';
    final studentSurname = entry['studentSurname'] as String? ?? '';
    final studentSchool = entry['studentSchool'] as String? ?? '';
    final studentGrade = entry['studentGrade'] as String? ?? '';
    final marksProofUrl = entry['marksProofUrl'] as String? ?? '';
    final marksUploadAttempts = entry['marksUploadAttempts'] as int? ?? 0;
    final paymentStatus = entry['paymentStatus'] as String? ?? 'pending';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF2C2C2C), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('QR: $qrData', style: const TextStyle(color: const Color(0xFF9E9E9E), fontSize: 13, fontFamily: 'monospace')),
          const SizedBox(height: 4),
          Text(createdAt.isNotEmpty ? createdAt.replaceFirst('T', ' ').substring(0, 19) : '', style: const TextStyle(color: const Color(0xFF757575), fontSize: 12)),
          const SizedBox(height: 4),
          Text('Adult: $adultName', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          Text('Student: $studentName $studentSurname', style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          Text('School: $studentSchool | Grade: $studentGrade', style: const TextStyle(color: const Color(0xFF9E9E9E), fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(marksProofUrl.isNotEmpty ? 'Marks Proof: Uploaded' : 'Marks Proof: Not uploaded',
                style: TextStyle(color: marksProofUrl.isNotEmpty ? const Color(0xFF9E9E9E) : const Color(0xFF757575), fontSize: 13)),
              const Spacer(),
              if (marksUploadAttempts < 4 && marksProofUrl.isEmpty)
                GestureDetector(
                  onTap: () => _addMarksProof(id, marksUploadAttempts),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFFD32F2F), borderRadius: BorderRadius.circular(6)),
                    child: Text('Add Marks (${4 - marksUploadAttempts} tries left)', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
              if (marksUploadAttempts >= 4 && marksProofUrl.isEmpty)
                const Text('Portal Locked', style: TextStyle(color: const Color(0xFFD32F2F), fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: paymentStatus == 'paid' ? const Color(0xFF2C2C2C) : const Color(0xFF424242),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(paymentStatus == 'paid' ? 'Paid' : 'Payment Pending',
                  style: TextStyle(color: paymentStatus == 'paid' ? const Color(0xFF9E9E9E) : const Color(0xFF757575), fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const Spacer(),
              if (paymentStatus != 'paid')
                GestureDetector(
                  onTap: () => _addPaymentProof(id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: const Color(0xFFD32F2F), borderRadius: BorderRadius.circular(6)),
                    child: const Text('Add Payment', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});
  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  bool _isDeveloper = false;
  bool _isSubscribed = false;
  bool _isPro = false;
  bool _allowDataSale = true;
  String _ver = "";
  final u = FirebaseAuth.instance.currentUser;

  @override
  void initState() { super.initState(); _load(); }
  void _load() async {
    final info = await PackageInfo.fromPlatform(); setState(() => _ver = "${info.version}+${info.buildNumber}");
    if (u != null) {
      FirebaseFirestore.instance.collection('users').doc(u!.uid).snapshots().listen((d) {
        if (mounted && d.exists) setState(() {
          _isDeveloper = d.data()?['is_developer'] == 'true' || d.data()?['is_developer'] == true;
          _isSubscribed = (d.data()?['is_subscribed'] ?? false);
          _isPro = (d.data()?['is_pro'] ?? false);
          _allowDataSale = d.data()?['allowDataSale'] ?? true;
        });
      });
    }
  }

  Future<void> _handleSubscription(String plan) async {
    if (kIsWeb) return;
    if (_isDeveloper || kDebugMode) {
      if (u != null) await FirebaseFirestore.instance.collection('users').doc(u!.uid).update({if (plan == 'Ads') 'is_subscribed': true, if (plan == 'Pro') 'is_pro': true, 'lastPaymentDate': FieldValue.serverTimestamp()});
      return;
    }
  }

  Future<void> _handleUnsubscribe(String plan) async {
    final confirm = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Confirm'), content: Text('Are you sure?'), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('No')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Yes'))]));
    if (confirm == true && u != null) {
      await FirebaseFirestore.instance.collection('users').doc(u!.uid).update({if (plan == 'Ads') 'is_subscribed': false, if (plan == 'Pro') 'is_pro': false});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tc = ThemeController.of(context);
    final headerStyle = const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: const Color(0xFFBDBDBD));
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(title: const Text('Account Settings'), backgroundColor: Colors.transparent, elevation: 0),
      body: ListView(padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16), children: [
        Text('Profile Info', style: headerStyle),
        const SizedBox(height: 12),
        _buildInfoContainer('Email', u?.email ?? ''),
        const SizedBox(height: 32),
        Text('Diagnostic Dashboard', style: headerStyle),
        const SizedBox(height: 12),
        _buildDiagnosticStatus(),
        if (_isDeveloper) ...[
          const SizedBox(height: 32),
          Text('Developer Options', style: headerStyle),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () async {
              try {
                await FirebaseMessaging.instance.subscribeToTopic('developers');
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Subscribed to developer notifications'), backgroundColor: Colors.green));
              } catch (e) {
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to subscribe: $e'), backgroundColor: const Color(0xFFD32F2F)));
              }
            },
            icon: const Icon(Icons.notifications_active),
            label: const Text('Force Subscribe to Notifications'),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)))
          ),
          const SizedBox(height: 12),
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('dev_files')
                .where('createdAt', isGreaterThan: Timestamp.fromDate(DateTime.now().subtract(const Duration(hours: 48))))
                .snapshots(),
            builder: (context, snapshot) {
              bool hasNew = snapshot.hasData && snapshot.data!.docs.isNotEmpty;
              return Column(
                children: [
                  ElevatedButton.icon(
                    onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => const DeveloperUploadPage())),
                    icon: Badge(
                      isLabelVisible: hasNew,
                      label: Text(snapshot.data?.docs.length.toString() ?? ''),
                      child: const Icon(Icons.file_present),
                    ),
                    label: const Text('Developer Upload Center'),
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)))
                  ),
                ],
              );
            }
          )
        ],
        const SizedBox(height: 32),
        Text('Subscriptions', style: headerStyle),
        const SizedBox(height: 12),
        _subscriptionItem('Remove Ads', 'R 16,99', _isSubscribed, () => _handleSubscription('Ads'), () => _handleUnsubscribe('Ads')),
        const SizedBox(height: 12),
        _subscriptionItem('Pro: Offline & No Ads', 'R 33,99', _isPro, () => _handleSubscription('Pro'), () => _handleUnsubscribe('Pro')),
        const SizedBox(height: 32),
        Text('Preferences', style: headerStyle),
        const SizedBox(height: 12),
        _preferenceSwitch('Dark Mode', tc?.themeMode == ThemeMode.dark, (v) => tc?.toggleTheme()),
        _preferenceSwitch('Allow Data Collection', _allowDataSale, (v) { if (u != null) FirebaseFirestore.instance.collection('users').doc(u!.uid).update({'allowDataSale': v}); }),
        const SizedBox(height: 12),
        _buildLinkItem(Icons.policy, 'Privacy Policy', () => launchUrl(Uri.parse('https://allegretto-eisteddfod.co.za/privacy-policy/'), mode: LaunchMode.externalApplication)),
        const SizedBox(height: 48),
        ElevatedButton(onPressed: () => _confirmDelete(), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFBDBDBD), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28))), child: const Text('Delete Account', style: TextStyle(fontWeight: FontWeight.bold))),
        const SizedBox(height: 24),
        Center(child: Text('Version $_ver', style: const TextStyle(color: Colors.grey, fontSize: 12))),
        const SizedBox(height: 8),
        TextButton(onPressed: () => FirebaseAuth.instance.signOut().then((_) => Navigator.pop(context)), child: const Text('Logout', style: TextStyle(color: const Color(0xFFD32F2F)))),
      ]),
    );
  }

  Widget _buildDiagnosticStatus() {
    return FutureBuilder<NotificationSettings>(
      future: FirebaseMessaging.instance.getNotificationSettings(),
      builder: (context, snapshot) {
        final status = snapshot.data?.authorizationStatus == AuthorizationStatus.authorized ? 'Active' : 'Disabled';
        final color = status == 'Active' ? Colors.green : Colors.orange;
        return Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: color.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.3))),
              child: Row(children: [
                Icon(Icons.notifications_active, color: color, size: 20),
                const SizedBox(width: 12),
                Text('Status: $status', style: TextStyle(color: color, fontWeight: FontWeight.bold)),
                const Spacer(),
                if (status != 'Active') TextButton(onPressed: () => _requestPushPermissions(), child: const Text('Enable'))
              ]),
            ),
            const SizedBox(height: 12),
            FutureBuilder<String?>(
              future: FirebaseMessaging.instance.getToken(vapidKey: kIsWeb ? 'BGOx7mqdHPaP-Vc8DbRblmReVUp26RMPGrLueVi1yBhWXJTID4fKfAHGgYemzUXP26D5uVIJICy-QyDPAH90wqA' : null),
              builder: (context, tok) {
                return Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      width: double.infinity,
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                           const Text('DIAGNOSTIC DASHBOARD', style: TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                           const SizedBox(height: 6),
                           if (DateTime.now().year < 2024) 
                             const Padding(
                               padding: EdgeInsets.only(bottom: 8),
                               child: Text('⚠️ CRITICAL: PHONE DATE IS WRONG', style: TextStyle(color: const Color(0xFFD32F2F), fontWeight: FontWeight.bold, fontSize: 10)),
                             ),
                           if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                             FutureBuilder<GooglePlayServicesAvailability>(
                               future: GoogleApiAvailability.instance.checkGooglePlayServicesAvailability(),
                               builder: (context, gms) {
                                 final gmsStatus = gms.data?.toString().split('.').last ?? 'Checking...';
                                 return Text('Google Services: $gmsStatus', style: const TextStyle(color: Colors.white38, fontSize: 9));
                               }
                             ),
                           const SizedBox(height: 4),
                           // Token hidden for security - functionality remains intact
                           // SelectableText('Token: ${tok.data ?? "Fetching..."}', style: const TextStyle(color: Colors.white24, fontSize: 8)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () async {
                        try {
                          if (!kIsWeb) {
                            // Hardware Test using confirmed drawable resource
                            await flutterLocalNotificationsPlugin.show(
                              777,
                              'Allegretto Hardware Success',
                              'Your phone hardware is working. Cloud delivery is pending...',
                              NotificationDetails(
                                android: AndroidNotificationDetails(
                                  devChannel.id,
                                  devChannel.name,
                                  icon: 'ic_launcher_foreground',
                                  importance: Importance.max,
                                  priority: Priority.max,
                                  visibility: NotificationVisibility.public,
                                ),
                              ),
                            );
                          }
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hardware test successful!'), backgroundColor: Colors.green));
                        } catch (e) {
                          showDialog(context: context, builder: (c) => AlertDialog(title: Text('Hardware Error'), content: Text(e.toString())));
                        }

                        // Server test
                        final email = FirebaseAuth.instance.currentUser?.email ?? 'Test User';
                        await FirebaseFirestore.instance.collection('notifications').add({
                          'title': '🔔 Deep Fix V6 Test',
                          'body': 'Push signal via direct token for $email',
                          'topic': 'developers',
                          'targetToken': tok.data,
                          'createdAt': FieldValue.serverTimestamp()
                        });
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Verification signal requested from server...')));
                      },
                      icon: const Icon(Icons.speed, color: Colors.amber),
                      label: const Text('Repair & Send Manual Test'),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo.shade900, foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 48)),
                    ),
                    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                      Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: TextButton.icon(
                          onPressed: () => launchUrl(Uri.parse('package:za.co.allegretto.eisteddfod'), mode: LaunchMode.externalApplication).catchError((_) => launchUrl(Uri.parse('android.settings.SETTINGS'))),
                          icon: const Icon(Icons.battery_alert, size: 16),
                          label: const Text('Fix Battery Restrictions'),
                        ),
                      ),
                  ],
                );
              }
            ),
          ],
        );
      },
    );
  }

  Future<void> _requestPushPermissions() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      await FirebaseMessaging.instance.setAutoInitEnabled(true);
    }
    
    NotificationSettings settings = await FirebaseMessaging.instance.requestPermission(
      alert: true, 
      badge: true, 
      sound: true,
    );
    
    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      if (!kIsWeb) {
        final androidPlugin = flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(devChannel);
        await androidPlugin?.createNotificationChannel(regionChannel);
      }
      _AllegrettoAppState._updateTokenInFirestore();
    }
    
    if (mounted) setState(() {});
  }

  Widget _buildInfoContainer(String label, String value) => Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.grey, fontSize: 12)), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 16, color: Colors.white))]));
  Widget _subscriptionItem(String title, String price, bool active, VoidCallback onUpgrade, VoidCallback onCancel) => Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20), decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(12)), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.white)), const SizedBox(height: 4), Text(price, style: const TextStyle(color: Colors.grey, fontSize: 13))])), if (active) TextButton(onPressed: onCancel, child: const Text('Unsubscribe', style: TextStyle(color: const Color(0xFFD32F2F), fontSize: 12))) else ElevatedButton(onPressed: onUpgrade, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), child: const Text('Upgrade'))]));
  Widget _preferenceSwitch(String title, bool value, Function(bool) onChanged) => Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(title, style: const TextStyle(fontSize: 16, color: Colors.white)), Switch(value: value, onChanged: onChanged, activeColor: const Color(0xFFD32F2F))]));
  Widget _buildLinkItem(IconData icon, String title, VoidCallback onTap) => Container(margin: const EdgeInsets.symmetric(vertical: 4), child: ListTile(leading: Icon(icon, color: const Color(0xFFBDBDBD)), title: Text(title, style: const TextStyle(fontSize: 16, color: Colors.white)), trailing: const Icon(Icons.open_in_new, color: Colors.white38, size: 18), onTap: onTap, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), tileColor: const Color(0xFF1E1E1E), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2)));
  void _confirmDelete() { showDialog(context: context, builder: (c) => AlertDialog(title: const Text('Delete Account'), content: const Text('Are you sure? This is permanent.'), actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')), TextButton(onPressed: () async { if (u != null) { try { await FirebaseFirestore.instance.collection('users').doc(u!.uid).delete(); await u!.delete(); } catch(e) {} } Navigator.pop(c); Navigator.pop(context); }, child: const Text('Delete', style: TextStyle(color: const Color(0xFFD32F2F))))])); }
}

class DeveloperUploadPage extends StatefulWidget {
  const DeveloperUploadPage({super.key, this.currentPath = '', this.pathSegments = const ['Root']});
  final String currentPath;
  final List<String> pathSegments;
  @override
  State<DeveloperUploadPage> createState() => _DeveloperUploadPageState();
}

class _DeveloperUploadPageState extends State<DeveloperUploadPage> with SingleTickerProviderStateMixin {
  bool _isSyncing = false;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
  }

  @override
  void dispose() { _pulseCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(widget.pathSegments.length, (index) {
              return Row(children: [
                GestureDetector(
                  onTap: index == widget.pathSegments.length - 1 ? null : () {
                    for(int i=0; i < (widget.pathSegments.length - 1 - index); i++) Navigator.pop(context);
                  },
                  child: Text(widget.pathSegments[index], style: TextStyle(fontSize: 16, color: index == widget.pathSegments.length - 1 ? Colors.white : Colors.redAccent)),
                ),
                if (index < widget.pathSegments.length - 1) const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.chevron_right, size: 16, color: Colors.grey)),
              ]);
            }),
          ),
        ),
        backgroundColor: Colors.transparent, 
        actions: [
          IconButton(icon: const Icon(Icons.sync, color: Colors.redAccent), tooltip: 'Sync with Storage', onPressed: _isSyncing ? null : _syncStorage),
          IconButton(icon: const Icon(Icons.create_new_folder_outlined), onPressed: _createFolder), 
          IconButton(icon: const Icon(Icons.upload_file), onPressed: _pickAndUpload)
        ]
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('dev_files').where('parentPath', isEqualTo: widget.currentPath).limit(500).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.error_outline, color: const Color(0xFFD32F2F), size: 48), const SizedBox(height: 16), Text('Vault Security Interlock\nEnsure rules are updated.', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))])));
          
          if (snapshot.connectionState == ConnectionState.waiting) {
            return ListView.builder(
              itemCount: 10,
              itemBuilder: (c, i) => Shimmer.fromColors(
                baseColor: Colors.white10,
                highlightColor: Colors.white24,
                child: ListTile(leading: const CircleAvatar(backgroundColor: Colors.white), title: Container(height: 16, width: double.infinity, color: Colors.white), subtitle: Container(height: 10, width: 100, color: Colors.white)),
              ),
            );
          }

          final items = snapshot.data?.docs ?? [];
          if (items.isEmpty) return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.folder_open, size: 64, color: Colors.grey), SizedBox(height: 16), Text('Vault is Empty', style: TextStyle(color: Colors.grey, letterSpacing: 1.5))]));
          
          return ListView.builder(
            itemCount: items.length,
            itemBuilder: (context, i) {
              final data = items[i].data() as Map<String, dynamic>;
              bool isFolder = data['isFolder'] ?? false;
              return ListTile(
                leading: Icon(isFolder ? Icons.folder : Icons.insert_drive_file, color: i % 2 == 0 ? Colors.amber : Colors.blueGrey, size: 28),
                title: Text(data['name'] ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
                subtitle: isFolder ? null : Text('Uploader: ${data['uploader']}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                trailing: IconButton(icon: const Icon(Icons.delete_outline, color: const Color(0xFFD32F2F), size: 22), onPressed: () => _deleteItem(items[i])),
                onTap: isFolder ? () => Navigator.push(context, MaterialPageRoute(builder: (c) => DeveloperUploadPage(currentPath: data['fullPath'], pathSegments: [...widget.pathSegments, data['name']]))) : () => launchUrl(Uri.parse(data['url']), mode: LaunchMode.externalApplication),
              );
            }
          );
        }
      ),
    );
  }

  Future<void> _syncStorage() async {
    setState(() => _isSyncing = true);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Starting Background Multi-Sync...')));
    try {
      final res = await FirebaseStorage.instance.ref(widget.currentPath).listAll();
      final batch = FirebaseFirestore.instance.batch();
      
      const int chunkSize = 10;
      for (var i = 0; i < res.items.length; i += chunkSize) {
        final chunk = res.items.skip(i).take(chunkSize);
        await Future.wait(chunk.map((ref) async {
          if (ref.name == '.folder') return;
          try {
            final url = await ref.getDownloadURL();
            final docRef = FirebaseFirestore.instance.collection('dev_files').doc(ref.fullPath.replaceAll('/', '_'));
            batch.set(docRef, {'name': ref.name, 'fullPath': ref.fullPath, 'parentPath': widget.currentPath, 'url': url, 'isFolder': false, 'uploader': 'Cloud Sync', 'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
          } catch (_) {}
        }));
      }

      for (var f in res.prefixes) {
        final docRef = FirebaseFirestore.instance.collection('dev_files').doc(f.fullPath.replaceAll('/', '_'));
        batch.set(docRef, {'name': f.name, 'fullPath': f.fullPath, 'parentPath': widget.currentPath, 'isFolder': true, 'createdAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      }
      await batch.commit();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Multi-Sync Complete!'), backgroundColor: Colors.green));
    } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync failed: $e'), backgroundColor: const Color(0xFF757575))); }
    finally { if (mounted) setState(() => _isSyncing = false); }
  }

  Future<void> _pickAndUpload() async {
    try {
      final res = await FilePicker.platform.pickFiles(withData: kIsWeb);
      if (res == null) return;

      final email = FirebaseAuth.instance.currentUser?.email ?? 'Unknown';
      final file = res.files.single;
      final fileName = file.name;
      final ref = FirebaseStorage.instance.ref(widget.currentPath).child(fileName);
      final metadata = SettableMetadata(customMetadata: {'uploaderEmail': email});
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (dialogCtx) => _UploadProgressDialog(
          task: kIsWeb ? ref.putData(file.bytes!, metadata) : ref.putFile(File(file.path!), metadata),
          fileName: fileName,
          onComplete: (url) async {
            await FirebaseFirestore.instance.collection('dev_files').doc(ref.fullPath.replaceAll('/', '_')).set({
              'name': fileName, 'fullPath': ref.fullPath, 'parentPath': widget.currentPath, 'url': url,
              'isFolder': false, 'uploader': email, 'createdAt': FieldValue.serverTimestamp()
            }, SetOptions(merge: true));

            // Notification is now handled automatically by Cloud Function notifyDeveloperFileUpload

            Navigator.pop(dialogCtx);
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Vault Updated Successfully'), backgroundColor: Colors.green));
          },
          onFail: (err) {
            Navigator.pop(dialogCtx);
            _showFailDialog(err);
          },
        ),
      );
    } catch (e) { _showFailDialog(e.toString()); }
  }

  void _showFailDialog(String error) {
    showDialog(context: context, builder: (c) => AlertDialog(
      title: const Text('Upload Failed', style: TextStyle(color: const Color(0xFFD32F2F))),
      content: Text('An error occurred during transmission:\n\n$error'),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Dismiss'))],
    ));
  }

  Future<void> _createFolder() async {
    final n = await showDialog<String>(context: context, builder: (cxt) {
      final c = TextEditingController();
      return AlertDialog(title: const Text('Create Sub-Vault'), content: TextField(controller: c, decoration: const InputDecoration(hintText: 'Vault Name')), actions: [TextButton(onPressed: () => Navigator.pop(cxt), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(cxt, c.text.trim()), child: const Text('Create'))]);
    });
    if (n != null && n.isNotEmpty) {
      final fullPath = widget.currentPath.isEmpty ? n : '${widget.currentPath}/$n';
      try {
        await FirebaseStorage.instance.ref(fullPath).child('.folder').putString('placeholder');
        await FirebaseFirestore.instance.collection('dev_files').doc(fullPath.replaceAll('/', '_')).set({
          'name': n, 'fullPath': fullPath, 'parentPath': widget.currentPath, 'isFolder': true, 'createdAt': FieldValue.serverTimestamp()
        }, SetOptions(merge: true));
      } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Vault Creation Failed: $e'), backgroundColor: const Color(0xFF757575))); }
    }
  }

  Future<void> _deleteItem(DocumentSnapshot doc) async {
    final data = doc.data() as Map<String, dynamic>;
    final pass = await showDialog<String>(context: context, builder: (cxt) => AlertDialog(title: const Text('Confirm Deletion'), content: TextField(obscureText: true, onSubmitted: (v) => Navigator.pop(cxt, v), decoration: const InputDecoration(hintText: 'Admin Key Required')), actions: [TextButton(onPressed: () => Navigator.pop(cxt), child: const Text('Cancel'))]));
    if (pass == (dotenv.env['ADMIN_PASSWORD'] ?? 'AllegrettoAdmin2024')) {
      try {
        if (data['isFolder'] != true) await FirebaseStorage.instance.ref(data['fullPath']).delete();
        await doc.reference.delete();
      } catch (e) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erasure Failed: $e'), backgroundColor: const Color(0xFF757575))); }
    }
  }
}

class _UploadProgressDialog extends StatefulWidget {
  final UploadTask task;
  final String fileName;
  final Function(String) onComplete;
  final Function(String) onFail;
  const _UploadProgressDialog({required this.task, required this.fileName, required this.onComplete, required this.onFail});
  @override
  State<_UploadProgressDialog> createState() => _UploadProgressDialogState();
}

class _UploadProgressDialogState extends State<_UploadProgressDialog> {
  double _progress = 0;
  String _status = 'Initializing...';
  @override
  void initState() {
    super.initState();
    widget.task.snapshotEvents.listen((event) {
      if (mounted) setState(() {
        _progress = event.bytesTransferred / event.totalBytes;
        _status = 'Broadcasting Data: ${event.bytesTransferred ~/ 1024} KB / ${event.totalBytes ~/ 1024} KB';
      });
    }, onError: (e) => widget.onFail(e.toString()));

    widget.task.then((snapshot) async {
      final url = await snapshot.ref.getDownloadURL();
      widget.onComplete(url);
    }).catchError((e) => widget.onFail(e.toString()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [Icon(Icons.cloud_upload_outlined, color: Colors.redAccent), SizedBox(width: 12), Text('Vault Transmission', style: TextStyle(color: Colors.white))]),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.fileName, style: const TextStyle(color: Colors.white70, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 24),
        ClipRRect(borderRadius: BorderRadius.circular(10), child: LinearProgressIndicator(value: _progress, minHeight: 12, backgroundColor: Colors.white10, color: Colors.redAccent)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(_status, style: const TextStyle(color: Colors.white38, fontSize: 10)),
          Text('${(_progress * 100).toInt()}%', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
      ]),
    );
  }
}

class AllegrettoWebView extends StatefulWidget {
  final String url;
  final bool isSubscribed;
  final String viewType;
  final String title;
  final Function(String) onOpenPDF;
  const AllegrettoWebView({super.key, required this.url, required this.isSubscribed, required this.viewType, required this.title, required this.onOpenPDF});
  @override
  State<AllegrettoWebView> createState() => _AllegrettoWebViewState();
}

class _AllegrettoWebViewState extends State<AllegrettoWebView> {
  WebViewController? _controller;
  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _controller = WebViewController()..setJavaScriptMode(JavaScriptMode.unrestricted)..loadRequest(Uri.parse(widget.url))..setNavigationDelegate(NavigationDelegate(onNavigationRequest: (req) {
        if (req.url.toLowerCase().endsWith('.pdf')) { widget.onOpenPDF(req.url); return NavigationDecision.prevent; }
        return NavigationDecision.navigate;
      }));
    }
  }
  @override
  Widget build(BuildContext context) => Column(children: [Padding(padding: const EdgeInsets.all(8.0), child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: kIsWeb ? HtmlElementView(viewType: widget.viewType) : WebViewWidget(controller: _controller!))]);
}

class AdBannerWidget extends StatefulWidget {
  const AdBannerWidget({super.key});
  @override
  State<AdBannerWidget> createState() => _AdBannerWidgetState();
}

class _AdBannerWidgetState extends State<AdBannerWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;
  @override
  void initState() { super.initState(); if (!kIsWeb) { _bannerAd = BannerAd(adUnitId: _getAdUnitId('banner'), request: const AdRequest(), size: AdSize.banner, listener: BannerAdListener(onAdLoaded: (ad) => setState(() => _isLoaded = true), onAdFailedToLoad: (ad, err) => ad.dispose()))..load(); } }
  @override
  void dispose() { _bannerAd?.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return Container(height: 50, child: const HtmlElementView(viewType: 'ad-view-type'));
    return (_isLoaded && _bannerAd != null) ? Container(height: 50, child: AdWidget(ad: _bannerAd!)) : const SizedBox.shrink();
  }
}

class DataCollector {
  static Future<Map<String, Object>> getDeviceInfo() async { return {'platform': kIsWeb ? 'web' : 'mobile'}; }
  static Future<void> startFirestoreSession(String sid, Map info) async {
    final u = FirebaseAuth.instance.currentUser;
    if (u != null) FirebaseFirestore.instance.collection('Support').doc(sid).set({'uid': u.uid, 'info': info, 'start': FieldValue.serverTimestamp()});
  }
  static Future<void> endFirestoreSession(String sid, int dur) async {
    FirebaseFirestore.instance.collection('Support').doc(sid).update({'end': FieldValue.serverTimestamp(), 'duration': dur});
  }
}
