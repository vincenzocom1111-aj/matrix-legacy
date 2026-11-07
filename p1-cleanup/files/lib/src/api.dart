import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'components/text_blocks.dart';
import 'models/models.dart';
import 'models/pending_image_token.dart';
import 'ai/gemini_embedding_api.dart';

const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://kcqehpdrnudycntbvqke.supabase.co',
);

const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtjcWVocGRybnVkeWNudGJ2cWtlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI0OTA3NzgsImV4cCI6MjA5ODA2Njc3OH0.rEISnpUZXEJ_NUDvDx0_sMile8UVfjAgJoGW3k-lWoo',
);

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

final MatrixApi matrixApi = MatrixApi();

class MatrixApi {
  MatrixApi({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  Session? session;

  bool get isSignedIn => session != null;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sessionStr = prefs.getString('auth_session');
      if (sessionStr != null) {
        session = Session.fromJson(jsonDecode(sessionStr));
      }
    } catch (e) {
      debugPrint('Failed to load session: $e');
    }
  }

  Future<void> _saveSession() async {
    if (session == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('auth_session', jsonEncode(session!.toJson()));
    } catch (e) {
      debugPrint('Failed to save session: $e');
    }
  }

  Future<List<Course>> listCourses() async {
    final rows = await _restGet('courses', {
      'select':
          'id,slug,title,subtitle,description,cover_image_url,category,price_inr,is_published,program,branch,semester,created_at',
      'is_published': 'eq.true',
      'order': 'created_at.desc',
    });
    return rows.map<Course>((row) => Course.fromJson(row)).toList();
  }

  Future<CourseDetail?> getCourse(String slug) async {
    final courses = await _restGet('courses', {
      'select':
          'id,slug,title,subtitle,description,cover_image_url,category,price_inr,is_published,program,branch,semester,created_at',
      'slug': 'eq.$slug',
      'is_published': 'eq.true',
      'limit': '1',
    });
    if (courses.isEmpty) return null;
    final course = Course.fromJson(courses.first);
    final modules = await _restGet('modules', {
      'select':
          'id,course_id,title,description,display_order,price_inr,page_count,is_free_preview,is_free_for_members,module_type,latest_text_version',
      'course_id': 'eq.${course.id}',
      'order': 'display_order.asc',
    });
    return CourseDetail(
      course: course,
      modules: modules
          .map<TextModule>((row) => TextModule.fromJson(row))
          .toList(),
    );
  }

  Future<void> signIn(String email, String password) async {
    final data = await _authPost('/token?grant_type=password', {
      'email': email,
      'password': password,
    });
    session = Session.fromJson(data);
    await _saveSession();
  }

  Future<void> signUp(String name, String email, String password) async {
    await _authPost('/signup', {
      'email': email,
      'password': password,
      'data': {'full_name': name},
    });
  }

  /// Completes sign-in using a native Google ID token obtained via
  /// Credential Manager (google_sign_in package). No browser/redirect
  /// involved — Skip Nonce Check must be enabled in Supabase's Google
  /// provider settings for this to work reliably (see Module E1).
  Future<void> signInWithGoogleIdToken(String idToken) async {
    final data = await _authPost('/token?grant_type=id_token', {
      'provider': 'google',
      'id_token': idToken,
    });
    session = Session.fromJson(data);
    await _saveSession();
  }

  void signOut() {
    session = null;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.remove('auth_session'),
    );
  }

  /// Attempts to silently refresh the access token using the stored refresh_token.
  /// Returns true if successful, false if the refresh token is missing/invalid.
  Future<bool> refreshSession() async {
    final refreshToken = session?.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return false;
    try {
      final data = await _authPost('/token?grant_type=refresh_token', {
        'refresh_token': refreshToken,
      });
      session = Session.fromJson(data);
      await _saveSession();
      return true;
    } catch (e) {
      debugPrint('Token refresh failed: $e');
      return false;
    }
  }

  Future<Profile?> getProfile() async {
    _requireSession();
    final rows = await _restGet('profiles', {
      'select': 'id,matrix_id,email,full_name,avatar_url,created_at',
      'id': 'eq.${session!.userId}',
      'limit': '1',
    });
    if (rows.isEmpty) return null;
    final roleRows = await _restGet('user_roles', {
      'select': 'role',
      'user_id': 'eq.${session!.userId}',
    });
    return Profile.fromJson(
      rows.first,
      isAdmin: roleRows.any((row) => row['role'] == 'admin'),
    );
  }

  Future<Library> getLibrary() async {
    _requireSession();
    final purchaseRows = await _restGet('purchases', {
      'select': 'id,course_id,module_id,amount_inr,status,created_at',
      'status': 'eq.completed',
      'order': 'created_at.desc',
    });
    final purchases = purchaseRows
        .map<Purchase>((row) => Purchase.fromJson(row))
        .toList();

    final courseIds = purchases
        .map((p) => p.courseId)
        .whereType<String>()
        .toSet()
        .toList();
    final moduleIds = purchases
        .map((p) => p.moduleId)
        .whereType<String>()
        .toSet()
        .toList();

    final courses = courseIds.isEmpty
        ? <Course>[]
        : (await _restGet('courses', {
            'select':
                'id,slug,title,subtitle,cover_image_url,category,price_inr',
            'id': 'in.(${courseIds.join(',')})',
          })).map<Course>((row) => Course.fromJson(row)).toList();

    final modules = moduleIds.isEmpty
        ? <TextModule>[]
        : (await _restGet('modules', {
            'select':
                'id,course_id,title,description,display_order,price_inr,page_count,is_free_preview,is_free_for_members,module_type,latest_text_version',
            'id': 'in.(${moduleIds.join(',')})',
            'order': 'display_order.asc',
          })).map<TextModule>((row) => TextModule.fromJson(row)).toList();

    return Library(courses: courses, modules: modules, purchases: purchases);
  }

  Future<Map<String, String>> getImageTokenMap() async {
    final rows = await _restGet('course_images', {
      'select': 'token,storage_path',
    });
    final map = <String, String>{};
    for (final row in rows) {
      final token = row['token']?.toString();
      final storagePath = row['storage_path']?.toString();
      if (token != null && storagePath != null) {
        map[token] = publicImageUrl(storagePath);
      }
    }
    return map;
  }

  Future<ModuleText> getModuleText(String moduleId) async {
    _requireSession();
    final modules = await _restGet('modules', {
      'select':
          'id,course_id,title,description,display_order,price_inr,page_count,is_free_preview,is_free_for_members,module_type,latest_text_version',
      'id': 'eq.$moduleId',
      'limit': '1',
    });
    if (modules.isEmpty) throw ApiException('Module not found.');
    final module = TextModule.fromJson(modules.first);
    final versions = await _restGet('module_text_versions', {
      'select': 'version,content,created_at,is_latest',
      'module_id': 'eq.$moduleId',
      'is_latest': 'eq.true',
      'limit': '1',
    });
    if (versions.isEmpty) {
      throw ApiException('This module has no text content yet.');
    }
    final qaRows = await _restGet('module_qa', {
      'select': 'id,question,answer_text,answer_images,display_order,embedding',
      'module_id': 'eq.$moduleId',
      'order': 'display_order.asc',
    });
    // Fetch media for inline image rendering
    final mediaRows = await _restGet('module_media', {
      'select': 'key,storage_path,mime_type',
      'module_id': 'eq.$moduleId',
    });
    final mediaMap = <String, ModuleMedia>{};
    for (final m in mediaRows) {
      final key = m['key']?.toString();
      final storagePath = m['storage_path']?.toString();
      if (key != null && storagePath != null) {
        // Construct the URL using the storage path
        final url =
            '$supabaseUrl/storage/v1/object/public/course-media/$storagePath';
        mediaMap[key] = ModuleMedia(
          url: url,
          mimeType: m['mime_type']?.toString(),
        );
      }
    }

    // Merge in global course_images tokens
    final imageTokens = await getImageTokenMap();
    for (final entry in imageTokens.entries) {
      mediaMap.putIfAbsent(
        entry.key,
        () => ModuleMedia(url: entry.value, mimeType: null),
      );
    }

    return ModuleText(
      module: module,
      content: versions.first['content']?.toString() ?? '',
      questions: qaRows.map<ModuleQa>((row) => ModuleQa.fromJson(row)).toList(),
      mediaMap: mediaMap,
    );
  }

  Future<List<Purchase>> getPurchases() async {
    _requireSession();
    final rows = await _restGet('purchases', {
      'select': 'id,course_id,module_id,amount_inr,status,created_at',
      'order': 'created_at.desc',
    });
    return rows.map<Purchase>((row) => Purchase.fromJson(row)).toList();
  }

  // ─── AI Chat Cache ───────────────────────────────────────────────────────

  /// Returns {token: description} for the given tokens that have a
  /// non-null description set. Tokens with no description are omitted.
  Future<Map<String, String>> getImageDescriptions(List<String> tokens) async {
    if (tokens.isEmpty) return {};
    final rows = await _restGet('course_images', {
      'select': 'token,description',
      'token': 'in.(${tokens.join(',')})',
    });
    final map = <String, String>{};
    for (final row in rows) {
      final token = row['token']?.toString();
      final description = row['description']?.toString();
      if (token != null && description != null && description.trim().isNotEmpty) {
        map[token] = description.trim();
      }
    }
    return map;
  }

  /// Returns all modules for a course ordered by display_order.
  /// Used by the AI to build course context for Gemini. Public, no auth.
  Future<List<TextModule>> listModulesByCourseId(String courseId) async {
    final rows = await _restGet('modules', {
      'select':
          'id,course_id,title,description,display_order,price_inr,page_count,is_free_preview,is_free_for_members,module_type,latest_text_version',
      'course_id': 'eq.$courseId',
      'order': 'display_order.asc',
    });
    return rows.map<TextModule>((r) => TextModule.fromJson(r)).toList();
  }

  /// Calls the match_ai_cache RPC for vector similarity search.
  /// Returns rows sorted by similarity descending. Public, no auth.
  Future<List<Map<String, dynamic>>> callMatchAiCache({
    required String courseId,
    required List<double> embedding,
    required double threshold,
    int count = 3,
  }) async {
    final result = await _rpcPost('match_ai_cache', {
      'p_course_id': courseId,
      'p_embedding': embedding,
      'p_threshold': threshold,
      'p_count': count,
    });
    if (result == null) return [];
    return (result as List).cast<Map<String, dynamic>>();
  }

  /// Inserts a new Q&A entry into the ai_qa_cache table. Public, no auth.
  Future<void> insertAiCache(Map<String, dynamic> row) async {
    await _restPost('ai_qa_cache', row);
  }

  /// Increments the hit_count of a cache entry by 1. Public, no auth.
  Future<void> patchAiCacheHitCount(String id) async {
    // PostgREST does not support raw SQL expressions in PATCH body.
    // Workaround: fetch current count, then patch with count + 1.
    final rows = await _restGet('ai_qa_cache', {
      'select': 'hit_count',
      'id': 'eq.$id',
      'limit': '1',
    });
    if (rows.isEmpty) return;
    final current = (rows.first as Map<String, dynamic>)['hit_count'];
    final currentCount = (current as num?)?.toInt() ?? 0;
    await _restPatch(
      'ai_qa_cache',
      {'id': 'eq.$id'},
      {'hit_count': currentCount + 1},
    );
  }

  // ─── AI Quiz Cache ───────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> callMatchQuizCache({
    required String courseId,
    required List<double> embedding,
    required double threshold,
    int count = 1,
  }) async {
    final result = await _rpcPost('match_quiz_cache', {
      'p_course_id': courseId,
      'p_embedding': embedding,
      'p_threshold': threshold,
      'p_count': count,
    });
    if (result == null) return [];
    return (result as List).cast<Map<String, dynamic>>();
  }

  Future<void> insertQuizCache(Map<String, dynamic> row) async {
    await _restPost('ai_quiz_cache', row);
  }

  // ─── Course Content RAG ──────────────────────────────────────────────────

  /// Deletes all existing chunks for a course. Called before reindexing.
  Future<void> adminDeleteCourseChunks(String courseId) async {
    _requireSession();
    await _restDelete('course_content_chunks', {'course_id': 'eq.$courseId'});
  }

  /// Inserts a single content chunk with its embedding.
  Future<void> adminInsertCourseChunk({
    required String courseId,
    required String moduleId,
    required int chunkIndex,
    required String chunkText,
    required List<double> embedding,
  }) async {
    _requireSession();
    await _restPost('course_content_chunks', {
      'course_id': courseId,
      'module_id': moduleId,
      'chunk_index': chunkIndex,
      'chunk_text': chunkText,
      'embedding': embedding,
    });
  }

  /// Retrieves the top [count] most relevant chunks for [courseId] given
  /// a question's [embedding]. Public, no auth — used during chat.
  Future<List<Map<String, dynamic>>> callMatchCourseChunks({
    required String courseId,
    required List<double> embedding,
    int count = 5,
  }) async {
    final result = await _rpcPost('match_course_chunks', {
      'p_course_id': courseId,
      'p_embedding': embedding,
      'p_count': count,
    });
    if (result == null) return [];
    return (result as List).cast<Map<String, dynamic>>();
  }

  /// Returns true if a course has at least one indexed chunk.
  Future<bool> courseHasChunks(String courseId) async {
    final rows = await _restGet('course_content_chunks', {
      'select': 'id',
      'course_id': 'eq.$courseId',
      'limit': '1',
    });
    return rows.isNotEmpty;
  }

  // ─── Admin: courses ─────────────────────────────────────────────────────────

  Future<List<Course>> adminListCourses() async {
    _requireSession();
    final rows = await _restGet('courses', {
      'select':
          'id,slug,title,subtitle,description,cover_image_url,category,price_inr,is_published,program,branch,semester,created_at',
      'order': 'created_at.desc',
    });
    return rows.map<Course>((row) => Course.fromJson(row)).toList();
  }

  Future<void> adminSaveCourse(CourseDraft draft) async {
    _requireSession();
    if (draft.id == null) {
      await _restPost('courses', draft.toJson());
    } else {
      await _restPatch('courses', {'id': 'eq.${draft.id}'}, draft.toJson());
    }
  }

  Future<void> adminSaveModule(ModuleDraft draft) async {
    _requireSession();
    if (draft.id == null) {
      await _restPost('modules', draft.toJson());
    } else {
      await _restPatch('modules', {'id': 'eq.${draft.id}'}, draft.toJson());
    }
  }

  Future<void> adminDeleteCourse(String id) async {
    _requireSession();
    await _restDelete('courses', {'id': 'eq.$id'});
  }

  Future<void> adminDeleteModule(String id) async {
    _requireSession();
    await _restDelete('modules', {'id': 'eq.$id'});
  }

  // Public: only active banners, in display order. No auth required.
  Future<List<AppBanner>> listBanners() async {
    final rows = await _restGet('banners', {
      'select':
          'id,image_url,is_active,display_order,redirect_course_slug,created_at',
      'is_active': 'eq.true',
      'order': 'display_order.asc',
    });
    return rows.map<AppBanner>((row) => AppBanner.fromJson(row)).toList();
  }

  // Admin: every banner, active or hidden.
  Future<List<AppBanner>> adminListBanners() async {
    _requireSession();
    final rows = await _restGet('banners', {
      'select':
          'id,image_url,is_active,display_order,redirect_course_slug,created_at',
      'order': 'display_order.asc',
    });
    return rows.map<AppBanner>((row) => AppBanner.fromJson(row)).toList();
  }

  Future<void> adminSaveBanner(BannerDraft draft) async {
    _requireSession();
    if (draft.id == null) {
      await _restPost('banners', draft.toJson());
    } else {
      await _restPatch('banners', {'id': 'eq.${draft.id}'}, draft.toJson());
    }
  }

  Future<void> adminDeleteBanner(String id) async {
    _requireSession();
    await _restDelete('banners', {'id': 'eq.$id'});
  }

  // ─── Admin: module text versions ────────────────────────────────────────────

  Future<List<ModuleTextVersion>> adminListModuleTextVersions(
    String moduleId,
  ) async {
    _requireSession();
    final rows = await _restGet('module_text_versions', {
      'select': 'id,version,is_latest,created_at,editor_id',
      'module_id': 'eq.$moduleId',
      'order': 'version.desc',
    });
    return rows
        .map<ModuleTextVersion>((r) => ModuleTextVersion.fromJson(r))
        .toList();
  }

  Future<String> adminGetModuleTextVersion(String moduleId, int version) async {
    _requireSession();
    final rows = await _restGet('module_text_versions', {
      'select': 'content',
      'module_id': 'eq.$moduleId',
      'version': 'eq.$version',
      'limit': '1',
    });
    return rows.isEmpty ? '' : rows.first['content']?.toString() ?? '';
  }

  Future<int> adminRestoreModuleTextVersion(
    String moduleId,
    int version,
  ) async {
    _requireSession();
    final content = await adminGetModuleTextVersion(moduleId, version);
    final versions = await _restGet('module_text_versions', {
      'select': 'version',
      'module_id': 'eq.$moduleId',
      'order': 'version.desc',
      'limit': '1',
    });
    final next = versions.isEmpty
        ? 1
        : ((versions.first['version'] as num?)?.toInt() ?? 0) + 1;
    // Mark old latest as not latest
    await _restPatch(
      'module_text_versions',
      {'module_id': 'eq.$moduleId', 'is_latest': 'eq.true'},
      {'is_latest': false},
    );
    await _restPost('module_text_versions', {
      'module_id': moduleId,
      'version': next,
      'content': content,
      'is_latest': true,
      'editor_id': session!.userId,
    });
    return next;
  }

  // ─── Admin: module Q&A ───────────────────────────────────────────────────────

  Future<List<ModuleQa>> adminListModuleQa(String moduleId) async {
    _requireSession();
    final rows = await _restGet('module_qa', {
      'select': 'id,question,answer_text,answer_images,display_order',
      'module_id': 'eq.$moduleId',
      'order': 'display_order.asc',
    });
    return rows.map<ModuleQa>((r) => ModuleQa.fromJson(r)).toList();
  }

  Future<void> adminUpsertModuleQa({
    String? id,
    required String moduleId,
    required String question,
    required String answerText,
    int displayOrder = 0,
  }) async {
    _requireSession();

    // Compute the answer's embedding once, at save time, so it never needs
    // to be recomputed across any student/session during Revision Mode.
    // Non-fatal if it fails — the Q&A still saves, just without revision
    // support until the next edit succeeds in embedding it.
    List<double>? embedding;
    try {
      embedding = await GeminiEmbeddingApi().embed(answerText);
    } catch (e) {
      debugPrint('Failed to embed QA answer (non-fatal): $e');
    }

    final body = {
      'question': question,
      'answer_text': answerText,
      'display_order': displayOrder,
      if (embedding != null) 'embedding': embedding,
    };

    if (id == null) {
      await _restPost('module_qa', {'module_id': moduleId, ...body});
    } else {
      await _restPatch('module_qa', {'id': 'eq.$id'}, body);
    }
  }

  Future<void> adminDeleteModuleQa(String id) async {
    _requireSession();
    await _restDelete('module_qa', {'id': 'eq.$id'});
  }

  // ─── Google OAuth ────────────────────────────────────────────────────────────

  /// Returns the Supabase Google OAuth URL. The caller should open this in a
  /// browser; on redirect the user will land back in the app.
  String getGoogleOAuthUrl(String redirectTo) {
    final uri = Uri.parse('$supabaseUrl/auth/v1/authorize').replace(
      queryParameters: {'provider': 'google', 'redirect_to': redirectTo},
    );
    return uri.toString();
  }

  /// Call this with the deep-link URI received via matrixf://auth/callback.
  /// Supabase appends the session tokens in the URL fragment (#access_token=...&refresh_token=...).
  Future<bool> handleOAuthCallback(Uri uri) async {
    // Supabase puts tokens in the fragment, e.g. #access_token=...&refresh_token=...&token_type=bearer
    final fragment = uri.fragment;
    if (fragment.isEmpty) return false;
    final params = Uri.splitQueryString(fragment);
    final accessToken = params['access_token'];
    if (accessToken == null) return false;

    // Build a minimal Session from the fragment tokens
    final userId = _parseUserIdFromJwt(accessToken);
    final email = _parseEmailFromJwt(accessToken);
    session = Session(
      accessToken: accessToken,
      refreshToken: params['refresh_token'],
      userId: userId,
      email: email,
    );
    await _saveSession();
    return true;
  }

  /// Decode the `sub` claim from a JWT without a library.
  String _parseUserIdFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return '';
      final payload = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(payload));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      return map['sub']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Decode the `email` claim from a JWT without a library.
  String? _parseEmailFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length != 3) return null;
      final payload = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(payload));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      return map['email']?.toString();
    } catch (_) {
      return null;
    }
  }

  // ─── Admin: module text save (unchanged) ─────────────────────────────────────

  Future<void> adminSaveModuleText(String moduleId, String content) async {
    _requireSession();
    final versions = await _restGet('module_text_versions', {
      'select': 'version',
      'module_id': 'eq.$moduleId',
      'order': 'version.desc',
      'limit': '1',
    });
    final nextVersion = versions.isEmpty
        ? 1
        : ((versions.first['version'] as num?)?.toInt() ?? 0) + 1;
    await _restPost('module_text_versions', {
      'module_id': moduleId,
      'version': nextVersion,
      'content': content,
      'is_latest': true,
      'editor_id': session!.userId,
    });
  }

  // ─── Admin: image tokens (course_images) ────────────────────────────────────

  /// Scans every course's latest module content for [IMG:]/[GIF:] tokens
  /// and returns the ones that have no uploaded image in course_images yet.
  /// Deduplicated globally by token (first occurrence wins for display).
  Future<List<PendingImageToken>> adminScanPendingImageTokens() async {
    _requireSession();

    // 1. All modules — for id -> (title, course_id) lookup.
    final moduleRows = await _restGet('modules', {
      'select': 'id,title,course_id',
    });
    final moduleInfo = <String, Map<String, String>>{};
    for (final row in moduleRows) {
      final id = row['id']?.toString();
      if (id == null) continue;
      moduleInfo[id] = {
        'title': row['title']?.toString() ?? 'Untitled module',
        'course_id': row['course_id']?.toString() ?? '',
      };
    }

    // 2. All courses (including unpublished/drafts) — for title lookup.
    final courses = await adminListCourses();
    final courseTitleById = {for (final c in courses) c.id: c.title};

    // 3. Latest content for every module, in one query.
    final versionRows = await _restGet('module_text_versions', {
      'select': 'module_id,content',
      'is_latest': 'eq.true',
    });

    // 4. Tokens that already have an uploaded image.
    final imageRows = await _restGet('course_images', {'select': 'token'});
    final uploadedTokens = imageRows
        .map((r) => r['token']?.toString().toLowerCase())
        .whereType<String>()
        .toSet();

    // 5. Scan content, collect tokens not yet uploaded.
    final seen = <String>{};
    final pending = <PendingImageToken>[];
    for (final row in versionRows) {
      final moduleId = row['module_id']?.toString();
      final content = row['content']?.toString();
      if (moduleId == null || content == null) continue;
      final info = moduleInfo[moduleId];
      if (info == null) continue;

      final tokenMap = extractMediaTokensWithDescriptions(content);
      for (final entry in tokenMap.entries) {
        final key = entry.key;
        final lower = key.toLowerCase();
        if (uploadedTokens.contains(lower)) continue;
        if (seen.contains(lower)) continue;
        seen.add(lower);
        pending.add(PendingImageToken(
          token: key,
          moduleId: moduleId,
          moduleTitle: info['title']!,
          courseId: info['course_id']!,
          courseTitle: courseTitleById[info['course_id']] ?? 'Unknown course',
          inlineDescription: entry.value,
        ));
      }
    }

    return pending;
  }

  Future<List<Map<String, dynamic>>> adminListImageTokens() async {
    _requireSession();
    final rows = await _restGet('course_images', {
      'select': 'id,token,storage_path,created_at',
      'order': 'created_at.desc',
    });
    return rows.cast<Map<String, dynamic>>();
  }

  Future<String> adminUploadImageToken(
    String token,
    File file, {
    String? description,
  }) async {
    _requireSession();

    final ext = file.path.split('.').last.toLowerCase();
    final storagePath = '$token.$ext';

    final bytes = await file.readAsBytes();
    final mimeType = _mimeFromExt(ext);

    final uploadUri = Uri.parse(
      '$supabaseUrl/storage/v1/object/course-images/$storagePath',
    );
    final request = await _client.postUrl(uploadUri);
    request.headers.set('apikey', supabaseAnonKey);
    request.headers.set(
      'Authorization',
      'Bearer ${session?.accessToken ?? supabaseAnonKey}',
    );
    request.headers.set('Content-Type', mimeType);
    request.headers.set('x-upsert', 'true');
    request.add(bytes);
    final response = await request.close();
    await _readResponse(response);

    await _restPost('course_images', {
      'token': token,
      'storage_path': storagePath,
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });

    return publicImageUrl(storagePath);
  }

  Future<void> adminUpdateImageDescription(String id, String description) async {
    _requireSession();
    await _restPatch('course_images', {'id': 'eq.$id'}, {
      'description': description.trim(),
    });
  }

  Future<void> adminDeleteImageToken({
    required String id,
    required String storagePath,
  }) async {
    _requireSession();

    final deleteUri = Uri.parse(
      '$supabaseUrl/storage/v1/object/course-images/$storagePath',
    );
    final request = await _client.deleteUrl(deleteUri);
    _setRestHeaders(request);
    await _readResponse(await request.close());

    await _restDelete('course_images', {'id': 'eq.$id'});
  }

  String _mimeFromExt(String ext) {
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'jpg':
      case 'jpeg':
      default:
        return 'image/jpeg';
    }
  }

  String publicImageUrl(String storagePath) =>
      '$supabaseUrl/storage/v1/object/public/course-images/$storagePath';

  Future<void> _restDelete(String table, Map<String, String> query) async {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/$table',
    ).replace(queryParameters: query);
    final request = await _client.deleteUrl(uri);
    _setRestHeaders(request);
    await _readResponse(await request.close());
  }

  Future<dynamic> _authPost(String path, Map<String, dynamic> body) async {
    final uri = Uri.parse('$supabaseUrl/auth/v1$path');
    final request = await _client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set('apikey', supabaseAnonKey);
    request.write(jsonEncode(body));
    final response = await request.close();
    return _readResponse(response);
  }

  Future<List<dynamic>> _restGet(
    String table,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/$table',
    ).replace(queryParameters: query);
    final request = await _client.getUrl(uri);
    _setRestHeaders(request);
    final response = await request.close();
    final data = await _readResponse(response);
    return data is List ? data : <dynamic>[];
  }

  Future<void> _restPost(String table, Map<String, dynamic> body) async {
    final request = await _client.postUrl(
      Uri.parse('$supabaseUrl/rest/v1/$table'),
    );
    _setRestHeaders(request);
    request.headers.contentType = ContentType.json;
    request.headers.set('Prefer', 'return=minimal');
    request.write(jsonEncode(body));
    await _readResponse(await request.close());
  }

  Future<void> _restPatch(
    String table,
    Map<String, String> query,
    Map<String, dynamic> body,
  ) async {
    final uri = Uri.parse(
      '$supabaseUrl/rest/v1/$table',
    ).replace(queryParameters: query);
    final request = await _client.patchUrl(uri);
    _setRestHeaders(request);
    request.headers.contentType = ContentType.json;
    request.headers.set('Prefer', 'return=minimal');
    request.write(jsonEncode(body));
    await _readResponse(await request.close());
  }

  Future<dynamic> _rpcPost(String fn, Map<String, dynamic> body) async {
    final request = await _client.postUrl(
      Uri.parse('$supabaseUrl/rest/v1/rpc/$fn'),
    );
    _setRestHeaders(request);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    return _readResponse(await request.close());
  }

  void _setRestHeaders(HttpClientRequest request) {
    request.headers.set('apikey', supabaseAnonKey);
    request.headers.set(
      'Authorization',
      'Bearer ${session?.accessToken ?? supabaseAnonKey}',
    );
  }

  Future<dynamic> _readResponse(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    if (!ok) {
      try {
        final data = jsonDecode(text);
        throw ApiException(
          data['msg']?.toString() ??
              data['message']?.toString() ??
              data['error_description']?.toString() ??
              'Request failed (${response.statusCode}).',
        );
      } on FormatException {
        throw ApiException(text.isEmpty ? 'Request failed.' : text);
      }
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  void _requireSession() {
    if (session == null) throw ApiException('Please sign in first.');
  }
}
