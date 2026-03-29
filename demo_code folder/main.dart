import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:go_router/go_router.dart';
import 'package:krushi_market_mobile/core/network/api_service.dart';
import 'package:krushi_market_mobile/core/services/app_update_service.dart';
import 'package:krushi_market_mobile/core/services/firebase_messaging_service.dart';
import 'package:krushi_market_mobile/features/commodity/providers/favorites_provider.dart';
import 'package:provider/provider.dart';
import 'package:krushi_market_mobile/features/auth/domain/models/location_data.dart';
import 'package:krushi_market_mobile/features/auth/presentation/controllers/login_controller.dart';
import 'package:krushi_market_mobile/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:krushi_market_mobile/router.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.white,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
        ),
      );

      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);

      // ✅ Firebase, env, location, auth check - Parallel init
      final futures = await Future.wait([
        _initializeFirebase(),
        _loadEnvironment(),
        _loadLocationData(),
        ApiService.refreshToken(),
        _checkAuthStatus(),
      ], eagerError: false);

      final authStatus = futures[4] as Map<String, dynamic>;

      // ✅ ⏳ Auto resume token timer if already logged in
      await _resumeTokenRefreshIfNeeded();

      // ✅ Run app immediately
      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => LoginController(AuthRepositoryImpl()),
              lazy: false,
            ),
            ChangeNotifierProvider(create: (_) => FavoritesProvider()),
          ],
          child: MyApp(initialRoute: authStatus['route']),
        ),
      );

      // ✅ Initialize FCM after app starts
      _initializeFirebaseMessaging();
    },
    (error, stack) {
      debugPrint('🔴 Uncaught App Error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}

// 🔹 Firebase initialization
Future<void> _initializeFirebase() async {
  try {
    await Firebase.initializeApp();
    debugPrint('✅ Firebase initialized');
  } catch (e, stackTrace) {
    debugPrint("❌ Firebase initialization error: $e");
    debugPrint("Stack trace: $stackTrace");
  }
}

// 🔹 Environment load
Future<void> _loadEnvironment() async {
  try {
    await dotenv.load();
    debugPrint('✅ Environment loaded');
  } catch (e) {
    debugPrint('⚠️ Error loading .env file: $e');
  }
}

// 🔹 Location data load
Future<void> _loadLocationData() async {
  try {
    await LocationData.loadData();
    debugPrint('✅ Location data loaded');
  } catch (e) {
    debugPrint('⚠️ Error loading location data: $e');
  }
}

// 🔹 Auth status check
Future<Map<String, dynamic>> _checkAuthStatus() async {
  try {
    final authCheck = await Future.any([
      Future(() async {
        final firebaseUser = FirebaseAuth.instance.currentUser;
        final isLogged = await ApiService.isLoggedIn();
        return firebaseUser != null && isLogged;
      }),
      Future.delayed(const Duration(seconds: 2), () => false),
    ]);

    final route = authCheck ? '/' : '/login';
    debugPrint(
      authCheck ? '✅ User authenticated' : '⚠️ User not authenticated',
    );

    return {'route': route, 'isAuthenticated': authCheck};
  } catch (e) {
    debugPrint("❌ Auth check error: $e");
    return {'route': '/login', 'isAuthenticated': false};
  }
}

// 🔹 Auto resume token refresh on app start
Future<void> _resumeTokenRefreshIfNeeded() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString('accessToken');
    final expiresIn = prefs.getInt('accessExpiry');

    if (accessToken != null && expiresIn != null) {
      debugPrint('🔁 Resuming token refresh timer at app start...');
      await TokenRefreshManager.startTimer(expiresIn);
    } else {
      debugPrint('ℹ️ No active tokens found, skipping timer resume');
    }
  } catch (e) {
    debugPrint("⚠️ Error resuming token timer: $e");
  }
}

// 🔹 FCM initialization
Future<void> _initializeFirebaseMessaging() async {
  try {
    await FirebaseMessagingService.initialize();

    FirebaseMessagingService.onNotificationTapped = (navData) {
      _handleNotificationNavigation(navData);
    };

    unawaited(FirebaseMessagingService.subscribeToTopic('all_users'));
    unawaited(FirebaseMessagingService.subscribeToTopic('farmers'));

    debugPrint('✅ FCM initialized');
  } catch (e, stackTrace) {
    debugPrint("❌ FCM initialization error: $e");
    debugPrint("Stack trace: $stackTrace");
  }
}

Future<void> _handleNotificationNavigation(Map<String, dynamic> navData) async {
  final route = navData['route']?.toString().trim() ?? '';
  final commodity = navData['commodity']?.toString().trim() ?? '';
  final code = navData['code']?.toString().trim() ?? '';
  final newsId = navData['news_id']?.toString().trim() ?? '';

  for (int i = 0; i < 10; i++) {
    if (rootNavigatorKey.currentContext != null) break;
    await Future.delayed(const Duration(milliseconds: 200));
  }

  final context = rootNavigatorKey.currentContext;
  if (context == null) {
    debugPrint('❌ Navigator context not available after retries');
    return;
  }

  final firebaseUser = FirebaseAuth.instance.currentUser;
  if (firebaseUser == null) {
    debugPrint('🚫 User not authenticated, blocking notification navigation');
    return;
  }

  try {
    final goRouter = GoRouter.of(context);
    bool routeExists = goRouter.configuration.routes.any(
      (r) => _routeExists(r, route),
    );

    if (routeExists && route.isNotEmpty) {
      if (commodity.isNotEmpty && code.isNotEmpty) {
        context.push(route, extra: {'commodity': commodity, 'code': code});
      } else if (newsId.isNotEmpty) {
        context.push(route, extra: {'news_id': newsId});
      } else {
        context.push(route);
      }
    } else {
      debugPrint('⚠️ Invalid or non-existent route: $route');
    }
  } catch (e, stackTrace) {
    debugPrint('❌ Navigation error: $e');
    debugPrint('Stack trace: $stackTrace');
  }
}

bool _routeExists(RouteBase routeBase, String target) {
  if (routeBase is GoRoute) {
    final cleanPath = routeBase.path.replaceAll('/', '');
    if (cleanPath == target.replaceAll('/', '')) return true;
  }
  if (routeBase is ShellRoute) {
    return routeBase.routes.any((child) => _routeExists(child, target));
  }
  if (routeBase is GoRoute && routeBase.routes.isNotEmpty) {
    return routeBase.routes.any((child) => _routeExists(child, target));
  }
  return false;
}

class MyApp extends StatefulWidget {
  final String initialRoute;
  const MyApp({super.key, required this.initialRoute});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_checked) {
        _checked = true;
        unawaited(AppUpdateService.checkForUpdate(context));
      }
    });
  }

  // 🔁 Background → Foreground auto timer resume
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed) {
      final prefs = await SharedPreferences.getInstance();
      final accessToken = prefs.getString('accessToken');
      final expiresIn = prefs.getInt('accessExpiry');
      if (accessToken != null && expiresIn != null) {
        await TokenRefreshManager.startTimer(expiresIn);
        debugPrint("🔄 Token timer resumed on app resume");
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'Krushi Market',
      theme: ThemeData(
        fontFamily: 'Roboto',
        primarySwatch: Colors.lightGreen,
        useMaterial3: true,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.lightGreen,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.white,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: Colors.lightGreen,
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      routerConfig: createAppRouter(widget.initialRoute, rootNavigatorKey),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(
              MediaQuery.of(context).textScaleFactor.clamp(0.8, 1.3),
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
