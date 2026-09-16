import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app.dart';
import '../models/course_generation_job.dart';
import '../models/models.dart';

const _green = Color(0xff18664b);

// ─── Review screen ────────────────────────────────────────────────────────────

/// Renders AI-generated course content, lets admin fill [img:...] placeholders
/// with real images, then saves the finalized content to Supabase.
class AiCourseReviewScreen extends StatefulWidget {
  const AiCourseReviewScreen({
    super.key,
    required this.generatedText,
    required this.mode,
    this.targetCourse,
    this.targetModule,
    this.efficiencyScore,
  });

  final String generatedText;
  final String mode; // 'create' | 'enhance'
  final Course? targetCourse;
  final TextModule? targetModule;
  final int? efficiencyScore;

  @override
  State<AiCourseReviewScreen> createState() => _AiCourseReviewScreenState();
}

class _AiCourseReviewScreenState extends State<AiCourseReviewScreen> {
  late List<ContentSegment> _segments;
  late Map<String, ParsedImageToken> _tokenMap;
  final ImagePicker _picker = ImagePicker();
  bool _saving = false;

  // Courses/modules for picker (when module not pre-selected)
  List<Course>? _courses;
  Course? _saveCourse;
  List<TextModule>? _saveModules;
  TextModule? _saveModule;

  @override
  void initState() {
    super.initState();
    final parsed = parseGeneratedContent(widget.generatedText);
    _segments = parsed.segments;
    _tokenMap = parsed.tokenMap;
    _saveCourse = widget.targetCourse;
    _saveModule = widget.targetModule;
    _loadCoursesIfNeeded();
  }

  Future<void> _loadCoursesIfNeeded() async {
    if (_saveCourse != null && _saveModule != null) return;
    try {
      final api = MatrixScope.of(context).api;
      final courses = await api.adminListCourses();
      if (!mounted) return;
      setState(() => _courses = courses);
    } catch (_) {}
  }

  Future<void> _onSaveCourseSelected(Course c) async {
    setState(() {
      _saveCourse = c;
      _saveModule = null;
      _saveModules = null;
    });
    try {
      final api = MatrixScope.of(context).api;
      final mods = await api.listModulesByCourseId(c.id);
      if (!mounted) return;
      setState(() => _saveModules = mods);
    } catch (_) {}
  }

  // ── Progress ──────────────────────────────────────────────────────────────

  int get _totalTokens => _tokenMap.length;
  int get _filledTokens => _tokenMap.values.where((t) => t.isFilled).length;

  // ── Image fill ────────────────────────────────────────────────────────────

  Future<void> _fillToken(ParsedImageToken token) async {
    final picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final file = File(picked.path);
    final api = MatrixScope.of(context).api;

    try {
      // Upload to Supabase Storage (reusing existing image token infrastructure)
      final url = await api.adminUploadImageToken(
        token.id,
        file,
        description: token.description,
      );
      setState(() => token.imageUrl = url);

      // Also upsert into course_image_tokens table
      await api.adminUpsertCourseImageToken(
        id: token.id,
        courseId: _saveCourse?.id,
        moduleId: _saveModule?.id,
        shortTitle: token.shortTitle,
        description: token.description,
        imageUrl: url,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  // ── Save course content ───────────────────────────────────────────────────

  Future<void> _save() async {
    final module = _saveModule;
    if (module == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a module to save to.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final api = MatrixScope.of(context).api;
      // Save raw text with [img:...] tokens intact — renderer substitutes at display time
      await api.adminSaveModuleText(module.id, widget.generatedText);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Module content saved ✓'),
          backgroundColor: _green,
        ),
      );
      Navigator.of(context)
        ..pop() // review screen
        ..pop(); // create screen
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffbfaf8),
      appBar: AppBar(
        title: const Text('Review Generated Content'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _ProgressBar(filled: _filledTokens, total: _totalTokens),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton.icon(
              icon: const Icon(Icons.save_alt),
              label: const Text('Save'),
              onPressed: _save,
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // ── Quality / Efficiency Score Banner ──────────────────────────────
          if (widget.efficiencyScore != null)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: widget.efficiencyScore! >= 90
                      ? const Color(0xff18664b).withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.efficiencyScore! >= 90
                        ? const Color(0xff18664b).withValues(alpha: 0.4)
                        : Colors.orange.shade400,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      widget.efficiencyScore! >= 90
                          ? Icons.verified_outlined
                          : Icons.warning_amber_rounded,
                      color: widget.efficiencyScore! >= 90
                          ? const Color(0xff18664b)
                          : Colors.orange.shade800,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.efficiencyScore! >= 90
                                ? 'Verified Quality: ${widget.efficiencyScore}%'
                                : 'Best-Effort Generation: ${widget.efficiencyScore}%',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: widget.efficiencyScore! >= 90
                                  ? const Color(0xff18664b)
                                  : Colors.orange.shade900,
                            ),
                          ),
                          Text(
                            widget.efficiencyScore! >= 90
                                ? 'Content passed quality audit with no critical assumptions or missing topics.'
                                : 'Generated with minor gaps or assumptions after refinement attempts.',
                            style: TextStyle(
                              fontSize: 11,
                              color: widget.efficiencyScore! >= 90
                                  ? const Color(0xff18664b).withValues(alpha: 0.8)
                                  : Colors.orange.shade900.withValues(alpha: 0.8),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Save target picker (if not pre-set) ────────────────────────────
          if (_saveModule == null)
            SliverToBoxAdapter(child: _buildTargetPicker()),

          // ── Content segments ───────────────────────────────────────────────
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _buildSegment(_segments[i]),
              childCount: _segments.length,
            ),
          ),

          // ── Bottom padding ─────────────────────────────────────────────────
          const SliverToBoxAdapter(child: SizedBox(height: 80)),
        ],
      ),

      // ── Floating save button ───────────────────────────────────────────────
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : _save,
        backgroundColor: _green,
        icon: const Icon(Icons.save_alt, color: Colors.white),
        label: Text(
          _filledTokens == _totalTokens || _totalTokens == 0
              ? 'Save Module'
              : 'Save ($_filledTokens/$_totalTokens images)',
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }

  // ── Target picker widget ──────────────────────────────────────────────────

  Widget _buildTargetPicker() {
    return Container(
      color: Colors.amber.shade50,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose which module to save this content into:',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          if (_courses == null)
            const LinearProgressIndicator()
          else ...[
            DropdownButtonFormField<Course>(
              initialValue: _saveCourse,
              hint: const Text('Select course'),
              isExpanded: true,
              items: _courses!
                  .map((c) => DropdownMenuItem(value: c, child: Text(c.title)))
                  .toList(),
              onChanged: (c) {
                if (c != null) _onSaveCourseSelected(c);
              },
              decoration: const InputDecoration(
                labelText: 'Course',
                isDense: true,
              ),
            ),
            if (_saveCourse != null) ...[
              const SizedBox(height: 8),
              _saveModules == null
                  ? const LinearProgressIndicator()
                  : DropdownButtonFormField<TextModule>(
                      initialValue: _saveModule,
                      hint: const Text('Select module'),
                      isExpanded: true,
                      items: _saveModules!
                          .map(
                            (m) => DropdownMenuItem(
                              value: m,
                              child: Text(m.title),
                            ),
                          )
                          .toList(),
                      onChanged: (m) {
                        if (m != null) setState(() => _saveModule = m);
                      },
                      decoration: const InputDecoration(
                        labelText: 'Module',
                        isDense: true,
                      ),
                    ),
            ],
          ],
        ],
      ),
    );
  }

  // ── Segment renderer ──────────────────────────────────────────────────────

  Widget _buildSegment(ContentSegment seg) {
    return switch (seg) {
      TextSegment(:final text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: _RawTextBlock(text: text),
      ),
      TokenSegment(:final token) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: _ImageTokenCard(
          token: token,
          onFill: () => _fillToken(token),
        ),
      ),
    };
  }
}

// ─── Progress bar ─────────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.filled, required this.total});
  final int filled;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total == 0) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          'No image placeholders in this content',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total == 0 ? 1 : filled / total,
                backgroundColor: Colors.grey.shade200,
                color: filled == total ? _green : Colors.orange,
                minHeight: 6,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$filled / $total images',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: filled == total ? _green : Colors.orange.shade800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Raw text block ───────────────────────────────────────────────────────────

/// Renders a plain text segment. For now shows raw markdown-style text.
/// You can swap this out for your existing [ModuleTextRenderer] if desired.
class _RawTextBlock extends StatelessWidget {
  const _RawTextBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      text,
      style: const TextStyle(fontSize: 14, height: 1.7),
    );
  }
}

// ─── Image token placeholder card ────────────────────────────────────────────

class _ImageTokenCard extends StatelessWidget {
  const _ImageTokenCard({required this.token, required this.onFill});
  final ParsedImageToken token;
  final VoidCallback onFill;

  @override
  Widget build(BuildContext context) {
    if (token.isFilled) {
      return _FilledCard(token: token, onReplace: onFill);
    }
    return _PlaceholderCard(token: token, onFill: onFill);
  }
}

class _PlaceholderCard extends StatelessWidget {
  const _PlaceholderCard({required this.token, required this.onFill});
  final ParsedImageToken token;
  final VoidCallback onFill;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.orange.shade200,
          style: BorderStyle.solid,
          width: 1.5,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: Colors.orange.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  token.id,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.orange.shade900,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  token.shortTitle,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.image_not_supported_outlined,
                color: Colors.orange.shade400,
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            token.description,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.4),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add Image'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange.shade800,
                side: BorderSide(color: Colors.orange.shade300),
              ),
              onPressed: onFill,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilledCard extends StatelessWidget {
  const _FilledCard({required this.token, required this.onReplace});
  final ParsedImageToken token;
  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _green.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _green.withValues(alpha: .25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image preview
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            child: Image.network(
              token.imageUrl!,
              width: double.infinity,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (context, e, _) => Container(
                height: 80,
                color: Colors.grey.shade100,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _green.withValues(alpha: .15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    token.id,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _green,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    token.shortTitle,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                Icon(
                  Icons.check_circle,
                  color: _green,
                  size: 18,
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: onReplace,
                  child: Text(
                    'Replace',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade500,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
