import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

const _geminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: '',
);

class GeminiImageApiException implements Exception {
  GeminiImageApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Raw bytes of a generated image plus the MIME type Gemini reported for it.
class GeneratedImage {
  const GeneratedImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;

  /// File extension to save/upload under, derived from [mimeType].
  String get extension {
    switch (mimeType) {
      case 'image/webp':
        return 'webp';
      case 'image/jpeg':
        return 'jpg';
      case 'image/png':
      default:
        return 'png';
    }
  }
}

class GeminiImageApi {
  GeminiImageApi({HttpClient? client})
      : _client = client ?? (HttpClient()
          // Gemini image generation is slow (10–60 s). Set generous timeouts
          // to prevent the connection being dropped before the response arrives.
          ..connectionTimeout = const Duration(minutes: 3)
          ..idleTimeout = const Duration(minutes: 3));

  final HttpClient _client;

  // gemini-2.5-flash-image ("nano banana") — Gemini's current image
  // generation model. Free tier: ~500 requests/day, ~10-15 requests/minute.
  static const _baseUrl =
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-2.5-flash-image:generateContent';

  /// Generates a single image from [prompt] and returns its raw bytes.
  Future<GeneratedImage> generate(String prompt) async {
    if (_geminiApiKey.isEmpty) {
      throw GeminiImageApiException(
        'GEMINI_API_KEY is not set. Use --dart-define=GEMINI_API_KEY=<key>.',
      );
    }

    final uri = Uri.parse('$_baseUrl?key=$_geminiApiKey');
    final request = await _client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'contents': [
          {
            'parts': [
              {'text': prompt},
            ],
          },
        ],
        'generationConfig': {
          'responseModalities': ['TEXT', 'IMAGE'],
        },
      }),
    );

    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();

    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok) {
      if (response.statusCode == 429) {
        debugPrint(
          '[GeminiImageApi] ⚠️  QUOTA EXCEEDED (429) — '
          'Gemini API rate limit hit. '
          'Wait a minute or check your quota at https://aistudio.google.com. '
          'Raw body: $body',
        );
      }
      throw GeminiImageApiException(
        'Image generation failed: ${response.statusCode} — $body',
      );
    }

    final Map<String, dynamic> data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw GeminiImageApiException(
        'Image generation failed: invalid response body.',
      );
    }

    final candidates = data['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw GeminiImageApiException(
        'Image generation failed: no candidates returned '
        '(the prompt may have been blocked by safety filters).',
      );
    }

    final parts = candidates.first['content']?['parts'];
    if (parts is! List) {
      throw GeminiImageApiException(
        'Image generation failed: unexpected response shape.',
      );
    }

    for (final part in parts) {
      if (part is Map && part['inlineData'] is Map) {
        final inline = part['inlineData'] as Map;
        final b64 = inline['data'];
        if (b64 is String && b64.isNotEmpty) {
          return GeneratedImage(
            bytes: base64Decode(b64),
            mimeType: inline['mimeType']?.toString() ?? 'image/png',
          );
        }
      }
    }

    throw GeminiImageApiException(
      'Image generation failed: response contained no image data.',
    );
  }
}
