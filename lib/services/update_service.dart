import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  const UpdateInfo({required this.version, required this.downloadUrl, this.notes});

  final String version;
  final String downloadUrl;
  final String? notes;
}

/// Checks GitHub's own Releases API for a newer build than the one
/// installed — the app isn't distributed via Play Store, so this is the
/// update-notification mechanism instead of Play's built-in one. Points at
/// the repo's *latest* release; a release only counts once its APK asset
/// is attached (not just a source-code tag), matching how `flutter build
/// apk --release` + a GitHub Release with that file attached is meant to
/// be published.
class UpdateService {
  UpdateService._();

  static const _repo = 'm7amedenho/Redline-Representative-App-ERPNEXT';

  /// Returns null on any failure (offline, rate-limited, no release yet) or
  /// when already up to date — a failed check must never block or nag the
  /// user, this is purely best-effort.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
          headers: const {'Accept': 'application/vnd.github+json'},
        ),
      );
      final response = await dio.get(
        'https://api.github.com/repos/$_repo/releases/latest',
      );
      if (response.statusCode != 200) return null;

      final raw = response.data;
      final data = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : raw as Map<String, dynamic>;

      final tagName = (data['tag_name'] as String?)?.trim();
      if (tagName == null || tagName.isEmpty) return null;
      final latestVersion = tagName.startsWith('v')
          ? tagName.substring(1)
          : tagName;

      final assets = (data['assets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      String? downloadUrl;
      for (final asset in assets) {
        final name = (asset['name'] as String?)?.toLowerCase() ?? '';
        if (name.endsWith('.apk')) {
          downloadUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      // No APK asset attached yet (e.g. a source-only tag) — fall back to
      // the release page itself so "تحديث الآن" still goes somewhere useful.
      downloadUrl ??= data['html_url'] as String?;
      if (downloadUrl == null) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      if (!_isNewer(latestVersion, packageInfo.version)) return null;

      return UpdateInfo(
        version: latestVersion,
        downloadUrl: downloadUrl,
        notes: (data['body'] as String?)?.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Plain `major.minor.patch` comparison — ignores any `+build` suffix
  /// (Android's own versionCode, not something to compare against a
  /// GitHub tag which never carries one).
  static bool _isNewer(String latest, String current) {
    List<int> parse(String v) => v
        .split('+')
        .first
        .split('.')
        .map((p) => int.tryParse(p.trim()) ?? 0)
        .toList();
    final a = parse(latest);
    final b = parse(current);
    for (var i = 0; i < 3; i++) {
      final av = i < a.length ? a[i] : 0;
      final bv = i < b.length ? b[i] : 0;
      if (av != bv) return av > bv;
    }
    return false;
  }
}
