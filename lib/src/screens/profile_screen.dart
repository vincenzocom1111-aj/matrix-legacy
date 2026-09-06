import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/models.dart';
import '../app.dart'; // For MatrixScope
import '../widgets/shared_widgets.dart';

import "admin_screen.dart";
// ─── Profile Screen ───────────────────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool signUp = false;
  bool loading = false;
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = MatrixScope.of(context);
    final profile = scope.profile;
    if (scope.api.isSignedIn && profile != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 56, 16, 24),
        children: [
          const BrandHeader(),
          const SizedBox(height: 24),
          Text(
            'Your account',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Matrix ID', style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          profile.matrixId ?? '...',
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.copy, size: 18),
                        tooltip: 'Copy Matrix ID',
                        onPressed: () {
                          if (profile.matrixId != null) {
                            Clipboard.setData(
                              ClipboardData(text: profile.matrixId!),
                            );
                            showSnack(context, 'Matrix ID copied');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  InfoRow('Name', profile.fullName ?? '-'),
                  InfoRow('Email', profile.email ?? '-'),
                  InfoRow('Role', profile.isAdmin ? 'Admin' : 'Learner'),
                  const SizedBox(height: 18),
                  if (profile.isAdmin) ...[
                    FilledButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const Scaffold(body: AdminScreen()),
                        ),
                      ),
                      icon: const Icon(Icons.shield_outlined),
                      label: const Text('Open admin console'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  OutlinedButton.icon(
                    onPressed: () {
                      scope.api.signOut();
                      scope.refreshProfile();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          FutureBuilder<List<Purchase>>(
            future: scope.api.getPurchases(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const SizedBox.shrink();
              final purchases = snapshot.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Purchase history',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  if (purchases.isEmpty)
                    const EmptyBox('No purchases yet.')
                  else
                    ...purchases.map(
                      (p) => Card(
                        child: ListTile(
                          title: Text(formatInr(p.amountInr)),
                          subtitle: Text('${p.status}  ${p.createdAt ?? ''}'),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );
    }

    // ─── Sign-in / Sign-up form ───────────────────────────────────────────────
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 56, 16, 24),
      children: [
        const BrandHeader(),
        const SizedBox(height: 24),
        Text(
          signUp ? 'Join Matrix' : 'Sign in to Matrix',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 16),
        if (signUp) ...[
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Full name'),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: password,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: loading ? null : () => _submitAuth(context),
          child: Text(
            loading
                ? 'Please wait...'
                : signUp
                ? 'Create account'
                : 'Sign in',
          ),
        ),
        const SizedBox(height: 10),
        // ─── Google OAuth button ────────────────────────────────────────────
        OutlinedButton.icon(
          icon: const Icon(Icons.account_circle_outlined),
          label: const Text('Continue with Google'),
          onPressed: loading ? null : () => _googleSignIn(context),
        ),
        TextButton(
          onPressed: () => setState(() => signUp = !signUp),
          child: Text(
            signUp
                ? 'Already have an account? Sign in'
                : 'New here? Create account',
          ),
        ),
      ],
    );
  }

  Future<void> _submitAuth(BuildContext context) async {
    final scope = MatrixScope.of(context);
    setState(() => loading = true);
    try {
      if (signUp) {
        await scope.api.signUp(
          name.text.trim(),
          email.text.trim(),
          password.text,
        );
        if (context.mounted) {
          showSnack(context, 'Check your email to confirm your account.');
          setState(() => signUp = false);
        }
      } else {
        await scope.api.signIn(email.text.trim(), password.text);
        await scope.refreshProfile();
      }
    } catch (error) {
      if (context.mounted) showSnack(context, error.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _googleSignIn(BuildContext context) async {
    final scope = MatrixScope.of(context);
    try {
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        if (context.mounted) {
          showSnack(context, 'Google sign-in did not return a token. Please try again.');
        }
        return;
      }
      await scope.api.signInWithGoogleIdToken(idToken);
      await scope.refreshProfile();
    } on GoogleSignInException catch (e) {
      if (context.mounted) {
        if (e.code == GoogleSignInExceptionCode.canceled) {
          // User dismissed the picker — no error needed.
          return;
        }
        showSnack(context, 'Google sign-in failed: ${e.description ?? e.code}');
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Google sign-in failed: $e');
      }
    }
  }
}
