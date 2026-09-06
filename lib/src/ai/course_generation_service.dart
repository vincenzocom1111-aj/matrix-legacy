import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/course_generation_job.dart';

// ─── Persisted settings ───────────────────────────────────────────────────────

const _keyBaseUrl = 'ai_server_base_url';
const _keyApiKey = 'ai_server_api_key';

/// Loads and saves the AI server URL + API key from SharedPreferences.
class AiServerSettings {
  static Future<AiServerSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AiServerSettings._(
      baseUrl: prefs.getString(_keyBaseUrl) ?? '',
      apiKey: prefs.getString(_keyApiKey) ?? '',
    );
  }

  AiServerSettings._({required this.baseUrl, required this.apiKey});

  final String baseUrl; // e.g. http://192.168.1.100:8000
  final String apiKey;

  bool get isConfigured => baseUrl.trim().isNotEmpty && apiKey.trim().isNotEmpty;

  static Future<void> save({
    required String baseUrl,
    required String apiKey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, baseUrl.trim());
    await prefs.setString(_keyApiKey, apiKey.trim());
  }
}

// ─── HTTP service ─────────────────────────────────────────────────────────────

/// Handles all HTTP calls to the local Python AI server.
/// Uses dart:io HttpClient directly (same pattern as MatrixApi).
class CourseGenerationService {
  CourseGenerationService({
    required this.baseUrl,
    required this.apiKey,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  final String baseUrl;
  final String apiKey;
  final HttpClient _client;

  // ── Health check ────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> checkHealth() async {
    final uri = Uri.parse('$baseUrl/health');
    final request = await _client.getUrl(uri);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  // ── POST /ingest — multipart form data ─────────────────────────────────────

  /// Submits source material to the AI server and returns a [job_id].
  ///
  /// [files]           — list of {path, filename} for files to upload
  /// [rawText]         — optional pasted text
  /// [mode]            — "create" or "enhance"
  /// [formatTemplate]  — admin's formatting instructions
  /// [pyqTopics]       — optional list of previous-year-question topics
  /// [existingContent] — current module text (enhance mode only)
  Future<String> startIngest({
    required List<File> files,
    String? rawText,
    String mode = 'create',
    String? formatTemplate,
    List<String>? pyqTopics,
    String? existingContent,
  }) async {
    final boundary = 'boundary${DateTime.now().millisecondsSinceEpoch}';
    final uri = Uri.parse('$baseUrl/ingest');
    final request = await _client.postUrl(uri);
    request.headers.set('X-API-Key', apiKey);
    request.headers.set(
      'Content-Type',
      'multipart/form-data; boundary=$boundary',
    );

    final body = <int>[];

    // ── Form fields ──────────────────────────────────────────────────────────
    void addField(String name, String value) {
      body.addAll('--$boundary\r\n'.codeUnits);
      body.addAll(
        'Content-Disposition: form-data; name="$name"\r\n\r\n'.codeUnits,
      );
      body.addAll(utf8.encode(value));
      body.addAll('\r\n'.codeUnits);
    }

    addField('mode', mode);
    if (rawText != null && rawText.trim().isNotEmpty) {
      addField('raw_text', rawText.trim());
    }
    if (formatTemplate != null && formatTemplate.trim().isNotEmpty) {
      addField('format_template', formatTemplate.trim());
    }
    if (pyqTopics != null && pyqTopics.isNotEmpty) {
      addField('pyq_topics', jsonEncode(pyqTopics));
    }
    if (existingContent != null && existingContent.trim().isNotEmpty) {
      addField('existing_content', existingContent.trim());
    }

    // ── File parts ───────────────────────────────────────────────────────────
    for (final file in files) {
      final filename = file.path.split(Platform.pathSeparator).last;
      final ext = filename.toLowerCase().split('.').last;
      final mime = _mimeFromExt(ext);
      final fileBytes = await file.readAsBytes();

      body.addAll('--$boundary\r\n'.codeUnits);
      body.addAll(
        'Content-Disposition: form-data; name="files"; filename="$filename"\r\n'
                .codeUnits,
      );
      body.addAll('Content-Type: $mime\r\n\r\n'.codeUnits);
      body.addAll(fileBytes);
      body.addAll('\r\n'.codeUnits);
    }

    body.addAll('--$boundary--\r\n'.codeUnits);

    request.contentLength = body.length;
    request.add(body);

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Server error ${response.statusCode}: $text');
    }

    final data = jsonDecode(text) as Map<String, dynamic>;
    final jobId = data['job_id']?.toString();
    if (jobId == null || jobId.isEmpty) {
      throw Exception('Server did not return a job_id.');
    }
    return jobId;
  }

  // ── GET /status/{job_id} ────────────────────────────────────────────────────

  Future<CourseGenerationJob> pollStatus(String jobId) async {
    final uri = Uri.parse('$baseUrl/status/$jobId');
    final request = await _client.getUrl(uri);
    request.headers.set('X-API-Key', apiKey);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    if (response.statusCode == 404) {
      throw Exception('Job not found on server.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Status check failed ${response.statusCode}: $text');
    }

    return CourseGenerationJob.fromJson(
      jsonDecode(text) as Map<String, dynamic>,
    );
  }

  // ── Mime helper ─────────────────────────────────────────────────────────────

  String _mimeFromExt(String ext) {
    switch (ext) {
      case 'pdf':
        return 'application/pdf';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'doc':
        return 'application/msword';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return 'application/octet-stream';
    }
  }
}
