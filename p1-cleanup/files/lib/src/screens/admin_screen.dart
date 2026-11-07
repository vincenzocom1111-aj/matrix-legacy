import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../models/models.dart';
import '../app.dart'; // For MatrixScope
import '../widgets/shared_widgets.dart';
import '../components/module_text_renderer.dart';
import '../screens/upload_img_screen.dart';
import 'admin_reindex_screen.dart';
import 'banners_admin_screen.dart';

// ─── Admin Screen ─────────────────────────────────────────────────────────────

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  Future<List<Course>>? future;

  void _reload() {
    final api = MatrixScope.of(context).api;
    setState(() {
      future = api.adminListCourses();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (future == null) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 56, 16, 24),
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
              padding: EdgeInsets.zero,
              alignment: Alignment.centerLeft,
            ),

            const Expanded(child: BrandHeader()),

            IconButton(
              icon: const Icon(Icons.view_carousel_outlined),
              tooltip: 'Banners',
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const BannersAdminScreen()));
              },
            ),
            IconButton(
              icon: const Icon(Icons.upload_file),
              tooltip: 'Upload',
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const UploadScreen()));
              },
            ),
            IconButton(
              icon: const Icon(Icons.auto_awesome),
              tooltip: 'AI Reindex',
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const AdminReindexScreen()));
              },
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Admin', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          'Manage courses and text modules from a compact mobile console.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => showCourseEditor(context, null, onSaved: _reload),
          icon: const Icon(Icons.add),
          label: const Text('New course'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BannersAdminScreen()));
          },
          icon: const Icon(Icons.view_carousel_outlined),
          label: const Text('Manage banners'),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<Course>>(
          future: future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LoadingList();
            }
            if (snapshot.hasError) return ErrorBox(snapshot.error.toString());
            final courses = snapshot.data ?? [];
            return Column(
              children: courses
                  .map(
                    (course) => Card(
                      child: ListTile(
                        title: Text(course.title),
                        subtitle: Text(course.category ?? course.slug),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Edit course
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              tooltip: 'Edit',
                              onPressed: () => showCourseEditor(
                                context,
                                CourseDraft(
                                  id: course.id,
                                  slug: course.slug,
                                  title: course.title,
                                  subtitle: course.subtitle ?? '',
                                  description: course.description ?? '',
                                  category: course.category ?? '',
                                  priceInr: course.priceInr,
                                  isPublished: true,
                                  coverImageUrl: course.coverImageUrl,
                                ),
                                onSaved: _reload,
                              ),
                            ),
                            // Delete course
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 18,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              tooltip: 'Delete',
                              onPressed: () =>
                                  _confirmDeleteCourse(context, course),
                            ),
                            // Manage modules
                            IconButton(
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      AdminCourseScreen(course: course),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Future<void> _confirmDeleteCourse(BuildContext context, Course course) async {
    final api = MatrixScope.of(context).api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete course?'),
        content: Text('This will permanently delete "${course.title}".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await api.adminDeleteCourse(course.id);
        _reload();
        if (context.mounted) showSnack(context, 'Course deleted.');
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString());
      }
    }
  }
}

// ─── Admin Course (Modules) Screen ────────────────────────────────────────────

class AdminCourseScreen extends StatefulWidget {
  const AdminCourseScreen({super.key, required this.course});
  final Course course;

  @override
  State<AdminCourseScreen> createState() => _AdminCourseScreenState();
}

class _AdminCourseScreenState extends State<AdminCourseScreen> {
  late Future<CourseDetail?> future;

  void _reload() {
    setState(() {
      future = MatrixScope.of(context).api.getCourse(widget.course.slug);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    future = MatrixScope.of(context).api.getCourse(widget.course.slug);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.course.title)),
      body: FutureBuilder<CourseDetail?>(
        future: future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final detail = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FilledButton.icon(
                onPressed: () => showModuleEditor(
                  context,
                  detail.course.id,
                  null,
                  onSaved: _reload,
                ),
                icon: const Icon(Icons.add),
                label: const Text('New text module'),
              ),
              const SizedBox(height: 12),
              ...detail.modules.map(
                (module) => Card(
                  child: ListTile(
                    title: Text(module.title),
                    subtitle: Text(module.description ?? 'Text module'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Edit content (opens full editor with tabs)
                        IconButton(
                          icon: const Icon(Icons.edit_note),
                          tooltip: 'Edit content',
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  AdminModuleEditorScreen(module: module),
                            ),
                          ),
                        ),
                        // Edit metadata
                        IconButton(
                          icon: const Icon(Icons.tune, size: 18),
                          tooltip: 'Edit metadata',
                          onPressed: () => showModuleEditor(
                            context,
                            detail.course.id,
                            module,
                            onSaved: _reload,
                          ),
                        ),
                        // Delete
                        IconButton(
                          icon: Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          tooltip: 'Delete',
                          onPressed: () =>
                              _confirmDeleteModule(context, module),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteModule(
    BuildContext context,
    TextModule module,
  ) async {
    final api = MatrixScope.of(context).api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete module?'),
        content: Text('This will permanently delete "${module.title}".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await api.adminDeleteModule(module.id);
        _reload();
        if (context.mounted) showSnack(context, 'Module deleted.');
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString());
      }
    }
  }
}

// ─── Admin Module Editor Screen (Tabs: Text | Q&A | Versions) ────────────────

class AdminModuleEditorScreen extends StatefulWidget {
  const AdminModuleEditorScreen({super.key, required this.module});
  final TextModule module;

  @override
  State<AdminModuleEditorScreen> createState() =>
      _AdminModuleEditorScreenState();
}

class _AdminModuleEditorScreenState extends State<AdminModuleEditorScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.module.title),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.edit_note), text: 'Text'),
            Tab(icon: Icon(Icons.quiz_outlined), text: 'Q&A'),
            Tab(icon: Icon(Icons.history), text: 'Versions'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _TextEditorTab(module: widget.module),
          _QaManagerTab(moduleId: widget.module.id),
          _VersionsTab(moduleId: widget.module.id),
        ],
      ),
    );
  }
}

// ── Text Editor Tab ───────────────────────────────────────────────────────────

class _TextEditorTab extends StatefulWidget {
  const _TextEditorTab({required this.module});
  final TextModule module;

  @override
  State<_TextEditorTab> createState() => _TextEditorTabState();
}

class _TextEditorTabState extends State<_TextEditorTab> {
  final _ctrl = TextEditingController();
  bool _previewMode = false;
  bool _saving = false;
  bool _loaded = false;
  final Map<String, ModuleMedia> _mediaMap = {};
  final ImagePicker _picker = ImagePicker();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _loadLatest();
    }
  }

  Future<void> _loadLatest() async {
    final api = MatrixScope.of(context).api;
    try {
      final versions = await api.adminListModuleTextVersions(widget.module.id);
      final latest = versions.where((v) => v.isLatest).firstOrNull;
      if (latest != null) {
        final content = await api.adminGetModuleTextVersion(
          widget.module.id,
          latest.version,
        );
        if (mounted) _ctrl.text = content;
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final api = MatrixScope.of(context).api;
    setState(() => _saving = true);
    try {
      await api.adminSaveModuleText(widget.module.id, _ctrl.text);
      if (mounted) showSnack(context, 'Saved new version.');
    } catch (e) {
      if (mounted) showSnack(context, e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _insert(String snippet) {
    final sel = _ctrl.selection;
    final text = _ctrl.text;
    final start = sel.start < 0 ? text.length : sel.start;
    final end = sel.end < 0 ? text.length : sel.end;
    final next = text.replaceRange(start, end, snippet);
    _ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + snippet.length),
    );
  }

  Future<void> _uploadImage() async {
    try {
      final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        final token = 'IMG_${DateTime.now().millisecondsSinceEpoch}';
        setState(() {
          _mediaMap[token] = ModuleMedia(url: image.path);
        });
        _insert('\n[IMG: $token]\n');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to pick image: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _ToolBtn('H1', () => _insert('# ')),
              _ToolBtn('H2', () => _insert('## ')),
              _ToolBtn('H3', () => _insert('### ')),
              _ToolBtn('Bold', () => _insert('**bold**')),
              _ToolBtn('Italic', () => _insert('*italic*')),
              _ToolBtn('List', () => _insert('\n- item\n- item\n')),
              _ToolBtn('1.', () => _insert('\n1. item\n2. item\n')),
              _ToolBtn('Code', () => _insert('\n```\ncode\n```\n')),
              _ToolBtn('Quote', () => _insert('\n> quote\n')),
              _ToolBtn('Math', () => _insert(r'$E = mc^2$')),
              _ToolBtn('Upload IMG', _uploadImage),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(_previewMode ? Icons.edit : Icons.visibility),
                tooltip: _previewMode ? 'Edit' : 'Preview',
                onPressed: () => setState(() => _previewMode = !_previewMode),
              ),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save, size: 16),
                label: Text(_saving ? 'Saving…' : 'Save version'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // Editor or Preview
        Expanded(
          child: _previewMode
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: MatrixTextRenderer.fromContent(
                    content: _ctrl.text,
                    mediaMap: _mediaMap,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _ctrl,
                    maxLines: null,
                    expands: true,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      height: 1.55,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText:
                          'Write module content here.\n# Heading\n**bold**, *italic*\n- list\n[IMG: key.png]\n\$math\$',
                      alignLabelWithHint: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn(this.label, this.onTap);
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 4),
    child: OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(36, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11)),
    ),
  );
}

// ── Q&A Manager Tab ───────────────────────────────────────────────────────────

class _QaManagerTab extends StatefulWidget {
  const _QaManagerTab({required this.moduleId});
  final String moduleId;

  @override
  State<_QaManagerTab> createState() => _QaManagerTabState();
}

class _QaManagerTabState extends State<_QaManagerTab> {
  Future<List<ModuleQa>>? _future;

  void _reload() {
    final api = MatrixScope.of(context).api;
    setState(() {
      _future = api.adminListModuleQa(widget.moduleId);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: () => _showQaEditor(context, null),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add question'),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<ModuleQa>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return CenteredError(snapshot.error.toString());
              }
              final items = snapshot.data ?? [];
              if (items.isEmpty) return const EmptyBox('No questions yet.');
              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final q = items[i];
                  return Card(
                    child: ListTile(
                      title: Text(q.question),
                      subtitle: q.answer.isNotEmpty
                          ? Text(
                              q.answer,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () => _showQaEditor(context, q),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Theme.of(context).colorScheme.error,
                            ),
                            onPressed: () => _deleteQa(context, q),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _showQaEditor(BuildContext context, ModuleQa? existing) {
    final questionCtrl = TextEditingController(text: existing?.question ?? '');
    final answerCtrl = TextEditingController(text: existing?.answer ?? '');
    final orderCtrl = TextEditingController(
      text: (existing?.displayOrder ?? 0).toString(),
    );

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                existing == null ? 'New question' : 'Edit question',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: questionCtrl,
                decoration: const InputDecoration(labelText: 'Question'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: answerCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Answer',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: orderCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Display order'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  try {
                    final api = MatrixScope.of(context).api;
                    await api.adminUpsertModuleQa(
                      id: existing?.id,
                      moduleId: widget.moduleId,
                      question: questionCtrl.text.trim(),
                      answerText: answerCtrl.text.trim(),
                      displayOrder: int.tryParse(orderCtrl.text) ?? 0,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                    _reload();
                  } catch (e) {
                    if (ctx.mounted) showSnack(ctx, e.toString());
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteQa(BuildContext context, ModuleQa q) async {
    final api = MatrixScope.of(context).api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete question?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await api.adminDeleteModuleQa(q.id);
        _reload();
        if (context.mounted) showSnack(context, 'Question deleted.');
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString());
      }
    }
  }
}

// ── Versions Tab ──────────────────────────────────────────────────────────────

class _VersionsTab extends StatefulWidget {
  const _VersionsTab({required this.moduleId});
  final String moduleId;

  @override
  State<_VersionsTab> createState() => _VersionsTabState();
}

class _VersionsTabState extends State<_VersionsTab> {
  Future<List<ModuleTextVersion>>? _future;
  int? _previewVersion;
  String _previewContent = '';
  bool _loadingPreview = false;

  void _reload() {
    final api = MatrixScope.of(context).api;
    setState(() {
      _future = api.adminListModuleTextVersions(widget.moduleId);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) _reload();
  }

  Future<void> _loadPreview(int version) async {
    setState(() {
      _previewVersion = version;
      _loadingPreview = true;
    });
    try {
      final content = await MatrixScope.of(
        context,
      ).api.adminGetModuleTextVersion(widget.moduleId, version);
      if (mounted) {
        setState(() {
          _previewContent = content;
          _loadingPreview = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  Future<void> _restore(BuildContext context, int version) async {
    final api = MatrixScope.of(context).api;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restore v$version?'),
        content: const Text(
          'This creates a new version with the same content.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        final newV = await api.adminRestoreModuleTextVersion(
          widget.moduleId,
          version,
        );
        if (context.mounted) {
          showSnack(context, 'Restored as v$newV');
          _reload();
        }
      } catch (e) {
        if (context.mounted) showSnack(context, e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<ModuleTextVersion>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final versions = snapshot.data ?? [];
        return Row(
          children: [
            // Version list
            SizedBox(
              width: 140,
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: versions.length,
                itemBuilder: (context, i) {
                  final v = versions[i];
                  final selected = _previewVersion == v.version;
                  return Card(
                    color: selected
                        ? Theme.of(context).colorScheme.primaryContainer
                        : null,
                    child: InkWell(
                      onTap: () => _loadPreview(v.version),
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'v${v.version}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (v.isLatest) ...[
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'latest',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onPrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              v.createdAt.isNotEmpty
                                  ? v.createdAt.substring(0, 10)
                                  : '—',
                              style: const TextStyle(fontSize: 10),
                            ),
                            if (!v.isLatest && selected)
                              TextButton(
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  minimumSize: const Size(0, 24),
                                ),
                                onPressed: () => _restore(context, v.version),
                                child: const Text(
                                  'Restore',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const VerticalDivider(width: 1),
            // Preview pane
            Expanded(
              child: _previewVersion == null
                  ? const Center(
                      child: Text(
                        'Select a version to preview.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : _loadingPreview
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: MatrixTextRenderer.fromContent(
                        content: _previewContent,
                        mediaMap: const {},
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
