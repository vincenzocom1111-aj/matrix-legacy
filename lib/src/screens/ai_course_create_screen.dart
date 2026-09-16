import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../ai/course_generation_service.dart';
import '../app.dart';
import '../models/models.dart';
import '../models/course_generation_job.dart';
import 'ai_course_review_screen.dart';

const _green = Color(0xff18664b);

// ─── Main screen ─────────────────────────────────────────────────────────────

class AiCourseCreateScreen extends StatefulWidget {
  const AiCourseCreateScreen({super.key});

  @override
  State<AiCourseCreateScreen> createState() => _AiCourseCreateScreenState();
}

class _AiCourseCreateScreenState extends State<AiCourseCreateScreen> {
  // ── Mode ──────────────────────────────────────────────────────────────────
  String _mode = 'create'; // 'create' | 'enhance'

  // ── Files ─────────────────────────────────────────────────────────────────
  final List<PlatformFile> _pickedFiles = [];

  // ── Text paste ────────────────────────────────────────────────────────────
  final _rawTextCtrl = TextEditingController();
  bool _showPasteField = false;

  // ── Format template ───────────────────────────────────────────────────────
  final _templateCtrl = TextEditingController(
    text:
        'Generate comprehensive module content with:\n'
        '- Clear section headings\n'
        '- Key concepts explained simply with examples\n'
        '- Bold important terms\n'
        '- A summary at the end',
  );

  // ── PYQ topics ────────────────────────────────────────────────────────────
  final _pyqCtrl = TextEditingController();
  bool _showPyq = false;

  // ── Course + module selector (enhance mode) ───────────────────────────────
  List<Course>? _courses;
  Course? _selectedCourse;
  List<TextModule>? _modules;
  TextModule? _selectedModule;
  String? _existingContent; // loaded when module is selected

  // ── Settings ──────────────────────────────────────────────────────────────
  AiServerSettings? _settings;
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  // ── Job polling ───────────────────────────────────────────────────────────
  bool _submitting = false;
  String _statusText = '';
  String _partialText = ''; // live tokens from Gemma
  int _tokensGenerated = 0;
  String _stage = ''; // 'uploading' | 'extracting' | 'generating' | 'evaluating' | 'refining'
  int? _efficiencyScore;
  // ignore: unused_field
  String? _evaluationFeedback;
  int _iteration = 1;
  Timer? _pollTimer;
  String? _activeJobId;
  final ScrollController _liveScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _rawTextCtrl.dispose();
    _templateCtrl.dispose();
    _pyqCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _liveScrollCtrl.dispose();
    super.dispose();
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> _loadSettings() async {
    final s = await AiServerSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = s;
      _urlCtrl.text = s.baseUrl;
      _keyCtrl.text = s.apiKey;
    });
    if (s.isConfigured) _loadCourses();
  }

  Future<void> _saveSettings() async {
    await AiServerSettings.save(
      baseUrl: _urlCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
    );
    if (!mounted) return;
    final nav = Navigator.of(context);
    final s = await AiServerSettings.load();
    if (!mounted) return;
    setState(() => _settings = s);
    _loadCourses();
    nav.pop(); // close settings dialog
  }

  // ── Course / module loading ────────────────────────────────────────────────

  Future<void> _loadCourses() async {
    try {
      final api = MatrixScope.of(context).api;
      final courses = await api.adminListCourses();
      if (!mounted) return;
      setState(() => _courses = courses);
    } catch (_) {}
  }

  Future<void> _onCourseSelected(Course course) async {
    setState(() {
      _selectedCourse = course;
      _selectedModule = null;
      _modules = null;
      _existingContent = null;
    });
    try {
      final api = MatrixScope.of(context).api;
      final modules = await api.listModulesByCourseId(course.id);
      if (!mounted) return;
      setState(() => _modules = modules);
    } catch (_) {}
  }

  Future<void> _onModuleSelected(TextModule module) async {
    setState(() {
      _selectedModule = module;
      _existingContent = null;
    });
    try {
      final api = MatrixScope.of(context).api;
      final mt = await api.getModuleText(module.id);
      if (!mounted) return;
      setState(() => _existingContent = mt.content);
    } catch (_) {}
  }

  // ── File picking ───────────────────────────────────────────────────────────

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'docx', 'doc', 'jpg', 'jpeg', 'png'],
    );
    if (result == null || !mounted) return;
    setState(() => _pickedFiles.addAll(result.files));
  }

  void _removeFile(int index) => setState(() => _pickedFiles.removeAt(index));

  // ── Submit ────────────────────────────────────────────────────────────────

  bool get _canSubmit {
    if (_settings == null || !_settings!.isConfigured) return false;
    final hasFiles = _pickedFiles.isNotEmpty;
    final hasPastedText =
        _showPasteField && _rawTextCtrl.text.trim().isNotEmpty;
    if (!hasFiles && !hasPastedText) return false;
    if (_mode == 'enhance' && _selectedModule == null) return false;
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit || _submitting) return;
    final settings = _settings!;

    setState(() {
      _submitting = true;
      _statusText = 'Uploading files to AI server…';
    });

    try {
      final svc = CourseGenerationService(
        baseUrl: settings.baseUrl,
        apiKey: settings.apiKey,
      );

      final files = _pickedFiles
          .where((f) => f.path != null)
          .map((f) => File(f.path!))
          .toList();

      final pyqTopics = _showPyq && _pyqCtrl.text.trim().isNotEmpty
          ? _pyqCtrl.text
                .trim()
                .split('\n')
                .map((l) => l.trim())
                .where((l) => l.isNotEmpty)
                .toList()
          : null;

      final jobId = await svc.startIngest(
        files: files,
        rawText: _showPasteField ? _rawTextCtrl.text : null,
        mode: _mode,
        formatTemplate: _templateCtrl.text.trim(),
        pyqTopics: pyqTopics,
        existingContent: _mode == 'enhance' ? _existingContent : null,
      );

      setState(() {
        _activeJobId = jobId;
        _stage = 'extracting';
        _statusText = 'Extracting text from your files…';
      });
      _startPolling(svc, jobId);
    } catch (e) {
      setState(() {
        _submitting = false;
        _statusText = '';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  void _startPolling(CourseGenerationService svc, String jobId) {
    _pollTimer?.cancel();
    // Poll every 2 seconds to get fresh partial tokens quickly
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final job = await svc.pollStatus(jobId);
        if (!mounted) return;
        if (job.isDone) {
          _pollTimer?.cancel();
          setState(() => _submitting = false);
          _navigateToReview(job);
        } else if (job.isFailed) {
          _pollTimer?.cancel();
          setState(() {
            _submitting = false;
            _statusText = '';
            _partialText = '';
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Generation failed: ${job.errorMessage}'),
              backgroundColor: Colors.red.shade700,
              duration: const Duration(seconds: 8),
            ),
          );
        } else {
          // Update live preview
          setState(() {
            _tokensGenerated = job.tokensGenerated;
            _efficiencyScore = job.efficiencyScore;
            _evaluationFeedback = job.evaluationFeedback;
            _iteration = job.iteration;
            if (job.stage.isNotEmpty) {
              _stage = job.stage;
            }
            if (job.stageMessage.isNotEmpty) {
              _statusText = job.stageMessage;
            } else if (job.partialText.isNotEmpty) {
              _stage = 'generating';
              _statusText = 'Gemma 4 is writing…';
            }
            if (job.partialText.isNotEmpty) {
              _partialText = job.partialText;
            }
          });
          // Auto-scroll to bottom so latest tokens are visible
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_liveScrollCtrl.hasClients) {
              _liveScrollCtrl.animateTo(
                _liveScrollCtrl.position.maxScrollExtent,
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
              );
            }
          });
        }
      } catch (e) {
        // Non-fatal: keep polling
        debugPrint('Poll error: $e');
      }
    });
  }

  void _navigateToReview(CourseGenerationJob job) {
    if (job.resultText == null || job.resultText!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generation returned empty content.')),
      );
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => AiCourseReviewScreen(
          generatedText: job.resultText!,
          targetCourse: _selectedCourse,
          targetModule: _selectedModule,
          mode: _mode,
          efficiencyScore: job.efficiencyScore,
        ),
      ),
    );
  }

  // ── Settings dialog ────────────────────────────────────────────────────────

  void _openSettings() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI Server Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://192.168.1.X:8000',
                prefixIcon: Icon(Icons.dns_outlined),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _keyCtrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'your-secret-key',
                prefixIcon: Icon(Icons.key_outlined),
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _saveSettings();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfffbfaf8),
      appBar: AppBar(
        title: const Text('AI Course Generator'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Server settings',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: _submitting ? _buildProgressView() : _buildForm(),
    );
  }

  // ── Progress view — live streaming panel ──────────────────────────────────

  Widget _buildProgressView() {
    final hasTokens = _partialText.isNotEmpty;
    return Column(
      children: [
        // ── Stage header ───────────────────────────────────────────────────
        Container(
          width: double.infinity,
          color: _green.withValues(alpha: .06),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: _green,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _statusText.isEmpty ? 'Starting…' : _statusText,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: _green,
                      ),
                    ),
                    if (_tokensGenerated > 0)
                      Text(
                        '$_tokensGenerated tokens generated',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                  ],
                ),
              ),
              if (_efficiencyScore != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _efficiencyScore! >= 90
                        ? const Color(0xff18664b).withValues(alpha: 0.15)
                        : Colors.orange.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _efficiencyScore! >= 90
                          ? const Color(0xff18664b)
                          : Colors.orange,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _efficiencyScore! >= 90 ? Icons.verified : Icons.speed,
                        size: 14,
                        color: _efficiencyScore! >= 90
                            ? const Color(0xff18664b)
                            : Colors.orange.shade800,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Score: $_efficiencyScore%',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _efficiencyScore! >= 90
                              ? const Color(0xff18664b)
                              : Colors.orange.shade900,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
              ],
              // Stage chips
              _StageChip(
                label: 'Extract',
                active:
                    _stage == 'extracting' ||
                    _stage == 'analyzing' ||
                    _stage == 'generating' ||
                    _stage == 'evaluating' ||
                    _stage == 'refining',
                pulsing: _stage == 'extracting',
              ),
              const SizedBox(width: 5),
              _StageChip(
                label: 'Generate',
                active: _stage == 'generating' || _stage == 'evaluating' || _stage == 'refining',
                pulsing: _stage == 'generating',
              ),
              const SizedBox(width: 5),
              _StageChip(
                label: 'Audit',
                active: _stage == 'evaluating' || _stage == 'refining',
                pulsing: _stage == 'evaluating',
              ),
              if (_stage == 'refining' || _iteration > 1) ...[
                const SizedBox(width: 5),
                _StageChip(
                  label: 'Refine (#$_iteration)',
                  active: _stage == 'refining',
                  pulsing: _stage == 'refining',
                ),
              ],
            ],
          ),
        ),

        // ── Live text preview ──────────────────────────────────────────────
        Expanded(
          child: hasTokens
              ? Container(
                  color: const Color(0xff0d1117),
                  child: Scrollbar(
                    controller: _liveScrollCtrl,
                    child: SingleChildScrollView(
                      controller: _liveScrollCtrl,
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        _partialText,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          color: Color(0xff8fff8f), // terminal green
                          height: 1.6,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ),
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 60),
                      Icon(
                        Icons.psychology_outlined,
                        size: 56,
                        color: _green.withValues(alpha: .3),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _stage == 'extracting'
                            ? 'Reading and processing your files…'
                            : _stage == 'analyzing'
                            ? 'Gemma 4 is reading content & thinking…'
                            : 'Waiting for Gemma 4 to start…',
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.grey.shade500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Text will appear here as it\'s generated',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade400,
                        ),
                      ),
                    ],
                  ),
                ),
        ),

        // ── Job ID footer ──────────────────────────────────────────────────
        if (_activeJobId != null)
          Container(
            width: double.infinity,
            color: const Color(0xff0d1117),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Job: $_activeJobId',
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey.shade600,
                fontFamily: 'monospace',
              ),
            ),
          ),
      ],
    );
  }

  // ── Form view ─────────────────────────────────────────────────────────────

  Widget _buildForm() {
    final notConfigured = _settings != null && !_settings!.isConfigured;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
      children: [
        if (notConfigured)
          _Banner(
            icon: Icons.warning_amber_rounded,
            color: Colors.orange.shade50,
            borderColor: Colors.orange.shade200,
            text: 'Configure the AI server URL and API key first.',
            actionLabel: 'Open Settings',
            onAction: _openSettings,
          ),

        // ── Mode toggle ──────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionLabel('Mode'),
        const SizedBox(height: 8),
        _ModeToggle(
          value: _mode,
          onChanged: (v) => setState(() {
            _mode = v;
            _selectedCourse = null;
            _selectedModule = null;
            _modules = null;
          }),
        ),

        // ── Course / module selector (enhance mode) ──────────────────────────
        if (_mode == 'enhance') ...[
          const SizedBox(height: 20),
          const _SectionLabel('Target Module'),
          const SizedBox(height: 8),
          _CourseModulePicker(
            courses: _courses ?? [],
            selectedCourse: _selectedCourse,
            modules: _modules,
            selectedModule: _selectedModule,
            onCourseSelected: _onCourseSelected,
            onModuleSelected: _onModuleSelected,
          ),
          if (_existingContent != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _InfoChip(
                icon: Icons.check_circle_outline,
                label:
                    'Existing content loaded (${_existingContent!.length} chars)',
              ),
            ),
        ],

        // ── File picker ───────────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionLabel('Source Material'),
        const SizedBox(height: 8),
        _FilePickerCard(
          files: _pickedFiles,
          onPick: _pickFiles,
          onRemove: _removeFile,
        ),

        // ── Paste text toggle ─────────────────────────────────────────────────
        const SizedBox(height: 8),
        _ToggleRow(
          label: 'Or paste raw text',
          value: _showPasteField,
          onChanged: (v) => setState(() => _showPasteField = v),
        ),
        if (_showPasteField) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _rawTextCtrl,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'Paste lecture notes, textbook excerpts, etc.',
              alignLabelWithHint: true,
            ),
          ),
        ],

        // ── Format template ───────────────────────────────────────────────────
        const SizedBox(height: 20),
        const _SectionLabel('Format Instructions'),
        const SizedBox(height: 8),
        TextField(
          controller: _templateCtrl,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Describe how you want the content structured…',
            alignLabelWithHint: true,
          ),
        ),

        // ── PYQ topics ────────────────────────────────────────────────────────
        const SizedBox(height: 8),
        _ToggleRow(
          label: 'Include previous year question topics',
          value: _showPyq,
          onChanged: (v) => setState(() => _showPyq = v),
        ),
        if (_showPyq) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _pyqCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText:
                  'One topic per line, e.g.\nAM modulation\nFM demodulation',
              alignLabelWithHint: true,
            ),
          ),
        ],

        // ── Submit ────────────────────────────────────────────────────────────
        const SizedBox(height: 28),
        FilledButton.icon(
          icon: const Icon(Icons.auto_awesome),
          label: Text(
            _mode == 'enhance'
                ? 'Enhance with Gemma 4'
                : 'Generate with Gemma 4',
            style: const TextStyle(fontSize: 15),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: _green,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _canSubmit ? _submit : null,
        ),

        if (!_canSubmit && _settings != null && _settings!.isConfigured) ...[
          const SizedBox(height: 8),
          Text(
            _mode == 'enhance' && _selectedModule == null
                ? 'Select a module to enhance, then add source files.'
                : 'Add at least one source file or paste text.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ],
    );
  }
}

// ─── Small reusable widgets ───────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 13,
      letterSpacing: .3,
    ),
  );
}

class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(8),
    onTap: () => onChanged(!value),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Switch(value: value, onChanged: onChanged, activeThumbColor: _green),
          const SizedBox(width: 4),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
        ],
      ),
    ),
  );
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: _green.withValues(alpha: .07),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: _green.withValues(alpha: .2)),
    ),
    child: Row(
      children: [
        Icon(icon, size: 16, color: _green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: _green),
          ),
        ),
      ],
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.color,
    required this.borderColor,
    required this.text,
    this.actionLabel,
    this.onAction,
  });
  final IconData icon;
  final Color color;
  final Color borderColor;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 16),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: borderColor),
    ),
    child: Row(
      children: [
        Icon(icon, color: borderColor),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        if (actionLabel != null)
          TextButton(
            onPressed: onAction,
            child: Text(actionLabel!, style: TextStyle(color: borderColor)),
          ),
      ],
    ),
  );
}

// ─── Mode toggle ──────────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ModeChip(
          label: 'Create new content',
          icon: Icons.add_circle_outline,
          selected: value == 'create',
          onTap: () => onChanged('create'),
        ),
        const SizedBox(width: 10),
        _ModeChip(
          label: 'Enhance existing module',
          icon: Icons.edit_note,
          selected: value == 'enhance',
          onTap: () => onChanged('enhance'),
        ),
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: selected ? _green : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? _green : Colors.black.withValues(alpha: .12),
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: selected ? Colors.white : Colors.grey.shade600,
              size: 20,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: selected ? Colors.white : Colors.grey.shade700,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ─── File picker card ─────────────────────────────────────────────────────────

class _FilePickerCard extends StatelessWidget {
  const _FilePickerCard({
    required this.files,
    required this.onPick,
    required this.onRemove,
  });
  final List<PlatformFile> files;
  final VoidCallback onPick;
  final void Function(int) onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (files.isNotEmpty) ...[
        ...List.generate(files.length, (i) {
          final f = files[i];
          final ext = (f.extension ?? '').toUpperCase();
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _ExtBadge(ext),
            title: Text(
              f.name,
              style: const TextStyle(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              _fmtSize(f.size),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
            trailing: IconButton(
              icon: Icon(Icons.close, size: 18, color: Colors.grey.shade500),
              onPressed: () => onRemove(i),
            ),
          );
        }),
        const SizedBox(height: 4),
      ],
      OutlinedButton.icon(
        icon: const Icon(Icons.attach_file),
        label: Text(
          files.isEmpty ? 'Pick PDF / DOCX / Image' : 'Add more files',
        ),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Colors.grey.shade300),
        ),
        onPressed: onPick,
      ),
    ],
  );

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _ExtBadge extends StatelessWidget {
  const _ExtBadge(this.ext);
  final String ext;

  static const _colors = {
    'PDF': Color(0xffe74c3c),
    'DOCX': Color(0xff2980b9),
    'DOC': Color(0xff2980b9),
    'JPG': Color(0xff8e44ad),
    'JPEG': Color(0xff8e44ad),
    'PNG': Color(0xff8e44ad),
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[ext] ?? Colors.grey.shade600;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          ext.length > 4 ? ext.substring(0, 4) : ext,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}

// ─── Course / module picker ───────────────────────────────────────────────────

class _CourseModulePicker extends StatelessWidget {
  const _CourseModulePicker({
    required this.courses,
    required this.selectedCourse,
    required this.modules,
    required this.selectedModule,
    required this.onCourseSelected,
    required this.onModuleSelected,
  });

  final List<Course> courses;
  final Course? selectedCourse;
  final List<TextModule>? modules;
  final TextModule? selectedModule;
  final void Function(Course) onCourseSelected;
  final void Function(TextModule) onModuleSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      DropdownButtonFormField<Course>(
        initialValue: selectedCourse,
        hint: const Text('Select course'),
        isExpanded: true,
        items: courses
            .map((c) => DropdownMenuItem(value: c, child: Text(c.title)))
            .toList(),
        onChanged: (c) {
          if (c != null) onCourseSelected(c);
        },
        decoration: const InputDecoration(labelText: 'Course'),
      ),
      if (selectedCourse != null) ...[
        const SizedBox(height: 10),
        modules == null
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              )
            : DropdownButtonFormField<TextModule>(
                initialValue: selectedModule,
                hint: const Text('Select module'),
                isExpanded: true,
                items: modules!
                    .map(
                      (m) => DropdownMenuItem(value: m, child: Text(m.title)),
                    )
                    .toList(),
                onChanged: (m) {
                  if (m != null) onModuleSelected(m);
                },
                decoration: const InputDecoration(labelText: 'Module'),
              ),
      ],
    ],
  );
}

// ─── Stage chip ───────────────────────────────────────────────────────────────

class _StageChip extends StatefulWidget {
  const _StageChip({
    required this.label,
    required this.active,
    this.pulsing = false,
  });
  final String label;
  final bool active;
  final bool pulsing;

  @override
  State<_StageChip> createState() => _StageChipState();
}

class _StageChipState extends State<_StageChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          widget.label,
          style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
        ),
      );
    }
    if (widget.pulsing) {
      return FadeTransition(opacity: _anim, child: _activeChip());
    }
    return _activeChip();
  }

  Widget _activeChip() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: _green.withValues(alpha: .15),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: _green.withValues(alpha: .4)),
    ),
    child: Text(
      widget.label,
      style: const TextStyle(
        fontSize: 10,
        color: _green,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
