import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api_client.dart';
import 'core/clock.dart';
import 'core/storage.dart';
import 'features/auth/login_screen.dart';
import 'features/shell/workspace_shell.dart';
import 'features/workspaces/workspaces_screen.dart';
import 'state/auth_controller.dart';
import 'state/workspaces_controller.dart';
import 'widgets/timmy_logo.dart';

class TimmyApp extends StatelessWidget {
  const TimmyApp({super.key, required this.api, required this.storage, this.clock});

  final ApiClient api;
  final AppStorage storage;

  /// Defaults to the system clock.
  final Clock? clock;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<AppStorage>.value(value: storage),
        Provider<Clock>.value(value: clock ?? DateTime.now),
        ChangeNotifierProvider(
          create: (_) => AuthController(api, storage)..restore(),
        ),
      ],
      child: MaterialApp(
        title: 'Timmy',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const _AuthGate(),
      ),
    );
  }
}

/// Flutter's seed-based generator mutes the seed's chroma, which turns the
/// logo's lavender and navy into a dull grey-violet. So the accents are set
/// from the logo's colors explicitly, and the generator only supplies the
/// neutral, lavender-tinted surfaces.
ColorScheme _scheme(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: TimmyBrand.periwinkle,
    brightness: brightness,
  );
  return switch (brightness) {
    Brightness.light => base.copyWith(
        primary: TimmyBrand.navy,
        onPrimary: Colors.white,
        primaryContainer: const Color(0xFFDDD8F8),
        onPrimaryContainer: TimmyBrand.navy,
        secondaryContainer: const Color(0xFFEBD9EE),
        onSecondaryContainer: TimmyBrand.navy,
      ),
    Brightness.dark => base.copyWith(
        primary: TimmyBrand.periwinkle,
        onPrimary: TimmyBrand.navy,
        primaryContainer: const Color(0xFF383C78),
        onPrimaryContainer: const Color(0xFFE2DEFB),
        secondaryContainer: const Color(0xFF5A4560),
        onSecondaryContainer: const Color(0xFFF3DFF5),
      ),
  };
}

ThemeData _theme(Brightness brightness) {
  final scheme = _scheme(brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // Compact desktop sizing: the app lives in a small window.
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 38),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    ),
  );
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    return switch (auth.status) {
      AuthStatus.initializing => const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      AuthStatus.signedOut => const LoginScreen(),
      // Keyed by user so a different account never inherits another's state.
      AuthStatus.signedIn => _SignedIn(key: ValueKey(auth.user!.id)),
    };
  }
}

class _SignedIn extends StatelessWidget {
  const _SignedIn({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) =>
          WorkspacesController(context.read<ApiClient>(), context.read<AppStorage>())..load(),
      child: Consumer<WorkspacesController>(
        builder: (context, workspaces, _) {
          final selected = workspaces.selected;
          if (selected == null) return const WorkspacesScreen();
          return WorkspaceShell(key: ValueKey(selected.id), workspace: selected);
        },
      ),
    );
  }
}
