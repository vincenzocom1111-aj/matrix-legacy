/// Models for the AI course-generation pipeline.
library;

// ─── Generation job (mirrors /status response from AI server) ───────────────

class CourseGenerationJob {
  CourseGenerationJob({
    required this.jobId,
    required this.status,
    this.stage = '',
    this.stageMessage = '',
    this.partialText = '',
    this.tokensGenerated = 0,
    this.resultText,
    this.errorMessage,
  });

  factory CourseGenerationJob.fromJson(Map<String, dynamic> json) =>
      CourseGenerationJob(
        jobId: json['job_id']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        stage: json['stage']?.toString() ?? '',
        stageMessage: json['stage_message']?.toString() ?? '',
        partialText: json['partial_text']?.toString() ?? '',
        tokensGenerated: (json['tokens_generated'] as num?)?.toInt() ?? 0,
        resultText: json['result_text']?.toString(),
        errorMessage: json['error_message']?.toString(),
      );

  final String jobId;
  final String status; // pending | processing | done | failed
  final String stage; // extracting | analyzing | generating | done | failed
  final String stageMessage; // Real-time descriptive status message
  final String partialText; // live streaming preview
  final int tokensGenerated;
  final String? resultText;
  final String? errorMessage;

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending' || status == 'processing';
}

// ─── Parsed [img:...] token ──────────────────────────────────────────────────

/// Represents one [img:{id}|{shortTitle}|{description}] token found in
/// generated course content.
class ParsedImageToken {
  ParsedImageToken({
    required this.id,
    required this.shortTitle,
    required this.description,
    this.imageUrl,
  });

  final String id;
  final String shortTitle;
  final String description;

  /// Filled by the admin after uploading the real diagram/figure.
  String? imageUrl;

  bool get isFilled => imageUrl != null && imageUrl!.isNotEmpty;
}

// ─── Content segment (for rendering interleaved text + image placeholders) ──

/// A segment of generated content — either plain text or an image token.
sealed class ContentSegment {
  const ContentSegment();
}

class TextSegment extends ContentSegment {
  const TextSegment(this.text);
  final String text;
}

class TokenSegment extends ContentSegment {
  const TokenSegment(this.token);
  final ParsedImageToken token;
}

// ─── Parser ──────────────────────────────────────────────────────────────────

/// Regex that matches: [img:fig1.1|FM receiver|Shows antenna and RF amp...]
final _tokenRegex = RegExp(
  r'\[img:([^\|\]]+)\|([^\|\]]+)\|([^\]]+)\]',
  caseSensitive: false,
);

/// Parses generated text into interleaved [TextSegment] + [TokenSegment] list.
/// Also returns a deduplicated map of all tokens keyed by id.
({List<ContentSegment> segments, Map<String, ParsedImageToken> tokenMap})
parseGeneratedContent(String text) {
  final segments = <ContentSegment>[];
  final tokenMap = <String, ParsedImageToken>{};

  int cursor = 0;
  for (final match in _tokenRegex.allMatches(text)) {
    // Text before this token
    if (match.start > cursor) {
      final chunk = text.substring(cursor, match.start).trim();
      if (chunk.isNotEmpty) segments.add(TextSegment(chunk));
    }

    final id = match.group(1)!.trim();
    final title = match.group(2)!.trim();
    final desc = match.group(3)!.trim();

    // Deduplicate by id — first occurrence creates the token object;
    // subsequent references to the same id reuse it.
    final token = tokenMap.putIfAbsent(
      id,
      () => ParsedImageToken(id: id, shortTitle: title, description: desc),
    );
    segments.add(TokenSegment(token));

    cursor = match.end;
  }

  // Trailing text
  if (cursor < text.length) {
    final chunk = text.substring(cursor).trim();
    if (chunk.isNotEmpty) segments.add(TextSegment(chunk));
  }

  return (segments: segments, tokenMap: tokenMap);
}
