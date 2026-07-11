import 'dart:convert';
import 'dart:io';

const appVersion = '1.0.3';

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.url,
    required this.publishedAt,
    required this.assets,
  });

  final String version;
  final String url;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  bool get isNewerThanCurrent => compareVersions(version, appVersion) > 0;

  factory ReleaseInfo.fromJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    return ReleaseInfo(
      version: normalizeVersion(tag),
      url: json['html_url'] as String? ?? '',
      publishedAt: DateTime.tryParse(json['published_at'] as String? ?? ''),
      assets: (json['assets'] as List<dynamic>? ?? [])
          .map((asset) => ReleaseAsset.fromJson(asset as Map<String, dynamic>))
          .toList(),
    );
  }
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final String downloadUrl;
  final int size;

  factory ReleaseAsset.fromJson(Map<String, dynamic> json) => ReleaseAsset(
    name: json['name'] as String? ?? '',
    downloadUrl: json['browser_download_url'] as String? ?? '',
    size: json['size'] as int? ?? 0,
  );
}

class UpdateService {
  Future<ReleaseInfo> latestRelease() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse(
          'https://api.github.com/repos/asifkhalid03/git-auto/releases/latest',
        ),
      );
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Git Auto update checker',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw UpdateException(
          'Unable to check updates (${response.statusCode}).',
        );
      }
      return ReleaseInfo.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

String normalizeVersion(String value) {
  final version = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
  return version.isEmpty ? '0.0.0' : version;
}

int compareVersions(String left, String right) {
  final leftParts = _versionParts(left);
  final rightParts = _versionParts(right);
  final length = leftParts.length > rightParts.length
      ? leftParts.length
      : rightParts.length;
  for (var i = 0; i < length; i++) {
    final leftValue = i < leftParts.length ? leftParts[i] : 0;
    final rightValue = i < rightParts.length ? rightParts[i] : 0;
    if (leftValue != rightValue) return leftValue.compareTo(rightValue);
  }
  return 0;
}

List<int> _versionParts(String version) {
  return normalizeVersion(
    version,
  ).split(RegExp(r'[.+-]')).map((part) => int.tryParse(part) ?? 0).toList();
}
