import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:krushi_market_mobile/core/config/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 🔁 Auto Token Refresh Timer Manager
class TokenRefreshManager {
  static Timer? _timer;

  /// ⏳ Start new timer (refresh before expiry)
  static Future<void> startTimer(int expiresInSeconds) async {
    final int refreshBefore = (expiresInSeconds - 60).clamp(
      60,
      expiresInSeconds,
    ); // 1 min early
    debugPrint("⏳ Scheduling token auto-refresh in $refreshBefore seconds");

    _timer?.cancel();
    _timer = Timer(Duration(seconds: refreshBefore), () async {
      debugPrint("🔄 Auto token refresh triggered by timer");
      try {
        await ApiService.refreshToken(); // refresh & reschedule
        final prefs = await SharedPreferences.getInstance();
        int? newExp = prefs.getInt("accessExpiry");
        if (newExp != null) {
          startTimer(newExp); // re-start with new expiry
        }
      } catch (e) {
        debugPrint("❌ Auto refresh failed: $e");
      }
    });
  }

  /// 🛑 Stop timer (logout / clear data)
  static void stopTimer() {
    _timer?.cancel();
    debugPrint("🛑 Token refresh timer stopped");
  }
}

class ApiService {
  static final String baseUrl = AppConfig.baseUrl;

  // ✅ LOGIN API (auto timer start)
  static Future<Map<String, dynamic>> login({
    required String mobile,
    required String district,
    required String taluka,
    String? fcmToken,
  }) async {
    final url = Uri.parse("$baseUrl/auth/login");
    final payload = {
      "mobile": mobile,
      "district": district,
      "taluka": taluka,
      if (fcmToken != null && fcmToken.isNotEmpty) "fcmtoken": fcmToken,
    };

    debugPrint("📤 Login Request -> ${jsonEncode(payload)}");

    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode(payload),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await saveLoginData(data);
      return data;
    } else {
      throw Exception("Login failed: ${response.body}");
    }
  }

  // ✅ Save login data & start refresh timer
  static Future<void> saveLoginData(Map<String, dynamic> response) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString("accessToken", response["tokens"]["accessToken"]);
    await prefs.setString("refreshToken", response["tokens"]["refreshToken"]);
    await prefs.setString("userId", response["user"]["id"]);
    await prefs.setString("mobile", response["user"]["mobile"]);
    await prefs.setString("district", response["user"]["district"]);
    await prefs.setString("taluka", response["user"]["taluka"]);

    if (response["user"]["fcmtoken"] != null) {
      await prefs.setString("fcmToken", response["user"]["fcmtoken"]);
    }

    // 🕒 Save expiry and start timer
    final expiresIn = response["tokens"]["expiresIn"];
    if (expiresIn != null) {
      final int seconds = expiresIn is int
          ? expiresIn
          : (expiresIn.toString().contains('m')
                ? int.tryParse(expiresIn.replaceAll(RegExp(r'[^0-9]'), ''))! *
                      60
                : int.tryParse(expiresIn.toString()) ?? 900);
      await prefs.setInt("accessExpiry", seconds);
      await TokenRefreshManager.startTimer(seconds);
    }

    debugPrint("✅ Login data saved & timer started");
  }

  // ✅ Refresh Token API (auto timer reset)
  static Future<Map<String, dynamic>> refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final rt = prefs.getString("refreshToken");

    if (rt == null) throw Exception("No refresh token found");

    final url = Uri.parse("$baseUrl/auth/refresh");
    final response = await http.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"refreshToken": rt}),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      await prefs.setString("accessToken", data["tokens"]["accessToken"]);
      await prefs.setString("refreshToken", data["tokens"]["refreshToken"]);

      // 🕒 Reset timer with new expiry
      final expiresIn = data["tokens"]["expiresIn"];
      if (expiresIn != null) {
        final int seconds = expiresIn is int
            ? expiresIn
            : (expiresIn.toString().contains('m')
                  ? int.tryParse(expiresIn.replaceAll(RegExp(r'[^0-9]'), ''))! *
                        60
                  : int.tryParse(expiresIn.toString()) ?? 900);
        await prefs.setInt("accessExpiry", seconds);
        await TokenRefreshManager.startTimer(seconds);
      }

      debugPrint("✅ Token refreshed & timer reset");
      return data;
    } else {
      await clearUserData();
      throw Exception("Token refresh failed: ${response.body}");
    }
  }

  // ✅ Clear all user data
  static Future<void> clearUserData() async {
    final prefs = await SharedPreferences.getInstance();
    TokenRefreshManager.stopTimer();
    await prefs.clear();
    debugPrint("🧹 Cleared all user data");
  }

  // ✅ Check login state
  static Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final access = prefs.getString("accessToken");
    final refresh = prefs.getString("refreshToken");
    final uid = prefs.getString("userId");

    if (access == null || refresh == null || uid == null) return false;
    final firebaseUser = FirebaseAuth.instance.currentUser;
    if (firebaseUser == null) return false;
    return true;
  }

  // ✅ Get current user data
  static Future<Map<String, String?>> getUserData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      "userId": prefs.getString("userId"),
      "mobile": prefs.getString("mobile"),
      "district": prefs.getString("district"),
      "taluka": prefs.getString("taluka"),
      "accessToken": prefs.getString("accessToken"),
      "fcmToken": prefs.getString("fcmToken"),
    };
  }

  // ✅ FCM Token update
  static Future<bool> updateFcmToken(String fcmToken) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final accessToken = prefs.getString("accessToken");
      if (accessToken == null) return false;

      final url = Uri.parse("$baseUrl/user/update-fcm-token");
      final res = await http.post(
        url,
        headers: {
          "Content-Type": "application/json",
          "Authorization": "Bearer $accessToken",
        },
        body: jsonEncode({"fcmToken": fcmToken}),
      );

      if (res.statusCode == 200) {
        await prefs.setString("fcmToken", fcmToken);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint("❌ updateFcmToken error: $e");
      return false;
    }
  }

  // ✅ Logout
  static Future<bool> logout(String refreshToken) async {
    try {
      final url = Uri.parse('$baseUrl/auth/logout');
      final res = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"refreshToken": refreshToken}),
      );
      await clearUserData();
      await FirebaseAuth.instance.signOut();
      return res.statusCode == 200;
    } catch (e) {
      await clearUserData();
      return false;
    }
  }

  // ✅ Authorized Requests (auto refresh on 401)
  static Future<http.Response> authorizedGet(String endpoint) async =>
      _authorizedRequest(endpoint, method: 'GET');

  static Future<http.Response> authorizedPost(
    String endpoint,
    Map<String, dynamic> body,
  ) async => _authorizedRequest(endpoint, method: 'POST', body: body);

  static Future<http.Response> authorizedPut(
    String endpoint,
    Map<String, dynamic> body,
  ) async => _authorizedRequest(endpoint, method: 'PUT', body: body);

  static Future<http.Response> authorizedDelete(String endpoint) async =>
      _authorizedRequest(endpoint, method: 'DELETE');

  static Future<http.Response> _authorizedRequest(
    String endpoint, {
    required String method,
    Map<String, dynamic>? body,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    String? accessToken = prefs.getString("accessToken");

    Uri url = Uri.parse("$baseUrl$endpoint");
    Map<String, String> headers = {
      "Content-Type": "application/json",
      if (accessToken != null) "Authorization": "Bearer $accessToken",
    };

    http.Response response;
    switch (method) {
      case 'POST':
        response = await http.post(
          url,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
        break;
      case 'PUT':
        response = await http.put(
          url,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
        break;
      case 'DELETE':
        response = await http.delete(url, headers: headers);
        break;
      default:
        response = await http.get(url, headers: headers);
    }

    if (response.statusCode == 401) {
      try {
        await refreshToken();
        accessToken = prefs.getString("accessToken");
        if (accessToken == null) return response;
        headers["Authorization"] = "Bearer $accessToken";
        switch (method) {
          case 'POST':
            response = await http.post(
              url,
              headers: headers,
              body: jsonEncode(body ?? {}),
            );
            break;
          case 'PUT':
            response = await http.put(
              url,
              headers: headers,
              body: jsonEncode(body ?? {}),
            );
            break;
          case 'DELETE':
            response = await http.delete(url, headers: headers);
            break;
          default:
            response = await http.get(url, headers: headers);
        }
      } catch (_) {
        return response;
      }
    }

    return response;
  }
}
