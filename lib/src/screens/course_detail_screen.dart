import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../app.dart'; // For MatrixScope
import '../widgets/shared_widgets.dart';

import "reader_screen.dart";
// ─── Course Detail Screen ─────────────────────────────────────────────────────

class CourseDetailScreen extends StatefulWidget {
  const CourseDetailScreen({super.key, required this.slug});
  final String slug;

  @override
  State<CourseDetailScreen> createState() => _CourseDetailScreenState();
}

class _CourseDetailScreenState extends State<CourseDetailScreen> {
  late Future<CourseDetail?> future;
  Library? library;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = MatrixScope.of(context);
    future = scope.api.getCourse(widget.slug);
    if (scope.api.isSignedIn) {
      scope.api
          .getLibrary()
          .then((v) {
            if (mounted) setState(() => library = v);
          })
          .catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = MatrixScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Course')),
      body: FutureBuilder<CourseDetail?>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return CenteredError(snapshot.error.toString());
          }
          final detail = snapshot.data;
          if (detail == null) return const CenteredError('Course not found.');

          final ownsCourse =
              library?.courses.any((c) => c.id == detail.course.id) ?? false;
          final ownedModules =
              library?.modules.map((m) => m.id).toSet() ?? <String>{};

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CourseHero(course: detail.course),
              const SizedBox(height: 20),
              // ─── Buy / In Library button ──────────────────────────────────
              if (ownsCourse)
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    scope.setTab(2);
                  },
                  icon: const Icon(Icons.menu_book),
                  label: const Text('In your library'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _showPurchaseSheet(context, detail.course),
                  icon: const Icon(Icons.shopping_bag_outlined),
                  label: Text(
                    'Buy full course  ${formatInr(detail.course.priceInr)}',
                  ),
                ),
              const SizedBox(height: 20),
              Text(
                'Text modules',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              if (detail.modules.isEmpty)
                const EmptyBox('No text modules added yet.')
              else
                ...detail.modules.asMap().entries.map((entry) {
                  final module = entry.value;
                  final isOwned =
                      ownsCourse ||
                      ownedModules.contains(module.id) ||
                      module.isFreePreview ||
                      (module.isFreeForMembers && scope.api.isSignedIn);
                  return ModuleTile(
                    module: module,
                    index: entry.key + 1,
                    open: isOwned,
                    signedIn: scope.api.isSignedIn,
                    onOpen: () {
                      if (!scope.api.isSignedIn && !module.isFreePreview) {
                        showSnack(context, 'Sign in to open this module.');
                        scope.setTab(4);
                        Navigator.pop(context);
                        return;
                      }
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReaderScreen(moduleId: module.id),
                        ),
                      );
                    },
                    onBuy: () => _showPurchaseSheet(context, detail.course),
                  );
                }),
            ],
          );
        },
      ),
    );
  }
}

// ─── Purchase Sheet ───────────────────────────────────────────────────────────

/// Shows a bottom sheet explaining that purchase is completed on the web,
/// with a direct "Open in browser" button — replacing the dead-end snackbar.
void _showPurchaseSheet(BuildContext context, Course course) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Complete your purchase',
            style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Purchases are processed securely on the Matrix web platform. '  
            'Tap the button below — your access will sync back to this app '  
            'automatically once the payment is confirmed.',
            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
          const SizedBox(height: 8),
          Text(
            course.title,
            style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Theme.of(ctx).colorScheme.primary,
            ),
          ),
          Text(
            formatInr(course.priceInr),
            style: Theme.of(ctx).textTheme.bodyLarge,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                final uri = Uri.parse(
                  'https://matrix.app/courses/${course.slug}',
                );
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Open in browser to purchase'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    ),
  );
}
