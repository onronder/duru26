import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:duru_notes/core/crypto/crypto_box.dart';
import 'package:duru_notes/core/monitoring/app_logger.dart';
import 'package:duru_notes/core/providers/infrastructure_providers.dart'
    show analyticsProvider, loggerProvider;
import 'package:duru_notes/core/providers/search_providers.dart'
    show noteIndexerProvider;
import 'package:duru_notes/data/local/app_db.dart';
import 'package:duru_notes/domain/entities/note.dart' as domain;
import 'package:duru_notes/features/notes/pagination_notifier.dart';
import 'package:duru_notes/features/notes/providers/notes_pagination_providers.dart'
    show notesPageProvider;
import 'package:duru_notes/infrastructure/repositories/notes_core_repository.dart';
import 'package:duru_notes/models/note_kind.dart';
import 'package:duru_notes/services/analytics/analytics_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import '../../helpers/security_test_setup.dart';

class _FakeAuthClient extends GoTrueClient {
  _FakeAuthClient(this._session);

  final Session _session;

  @override
  User? get currentUser => _session.user;

  @override
  Session? get currentSession => _session;
}

class _FakeSupabaseClient extends SupabaseClient {
  _FakeSupabaseClient(String userId)
    : _session = Session(
        accessToken: 'token',
        refreshToken: 'refresh',
        tokenType: 'bearer',
        expiresIn: 3600,
        user: User(
          id: userId,
          appMetadata: const {},
          userMetadata: const {},
          aud: 'authenticated',
          email: '$userId@example.com',
          phone: '',
          createdAt: DateTime.utc(2025, 1, 1).toIso8601String(),
          updatedAt: DateTime.utc(2025, 1, 1).toIso8601String(),
          role: 'authenticated',
          identities: const [],
          factors: const [],
        ),
      ),
      super('https://stub.supabase.co', 'anon-key');

  final Session _session;

  @override
  GoTrueClient get auth => _FakeAuthClient(_session);

  @override
  SupabaseQueryBuilder from(String table) {
    throw Exception('Remote access not supported in pagination tests');
  }
}

class _TestLogger implements AppLogger {
  final List<String> breadcrumbs = [];

  @override
  void breadcrumb(String message, {Map<String, dynamic>? data}) {
    breadcrumbs.add(message);
  }

  @override
  void debug(String message, {Map<String, dynamic>? data}) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? data,
  }) {}

  @override
  Future<void> flush() async {}

  @override
  void info(String message, {Map<String, dynamic>? data}) {}

  @override
  void warn(String message, {Map<String, dynamic>? data}) {}

  @override
  void warning(String message, {Map<String, dynamic>? data}) {}
}

class _TestAnalytics extends AnalyticsService {
  final List<String> events = [];

  @override
  void event(String name, {Map<String, dynamic>? properties}) {
    events.add(name);
  }

  @override
  void trackError(
    String message, {
    String? context,
    Map<String, dynamic>? properties,
  }) {
    events.add('error:$message');
  }
}

class _CountingNotesRepository extends NotesCoreRepository {
  _CountingNotesRepository({
    required super.db,
    required super.crypto,
    required super.client,
    required super.indexer,
  });

  int listAfterCalls = 0;

  @override
  Future<List<domain.Note>> listAfter(
    DateTime? cursor, {
    int limit = 20,
  }) async {
    listAfterCalls++;
    return super.listAfter(cursor, limit: limit);
  }
}

class _PaginationHarness {
  _PaginationHarness()
    : db = AppDb.forTesting(NativeDatabase.memory()),
      logger = _TestLogger(),
      analytics = _TestAnalytics(),
      _client = _FakeSupabaseClient(_userId) {
    container = ProviderContainer(
      overrides: [
        loggerProvider.overrideWithValue(logger),
        analyticsProvider.overrideWithValue(analytics),
        notesPageProvider.overrideWith((ref) {
          return NotesPaginationNotifier(ref, repository);
        }),
      ],
    );
    final noteIndexer = container.read(noteIndexerProvider);
    crypto = SecurityTestSetup.createTestCryptoBox();
    repository = _CountingNotesRepository(
      db: db,
      crypto: crypto,
      client: _client,
      indexer: noteIndexer,
    );
  }

  static const String _userId = 'pagination-user';

  final AppDb db;
  final _FakeSupabaseClient _client;
  final _TestLogger logger;
  final _TestAnalytics analytics;
  late final ProviderContainer container;
  late final CryptoBox crypto;
  late final _CountingNotesRepository repository;

  NotesPaginationNotifier buildNotifier() {
    return container.read(notesPageProvider.notifier);
  }

  int get listAfterCalls => repository.listAfterCalls;

  Future<void> seedNotes(int count) async {
    final now = DateTime.utc(2025, 1, 1);

    final inserts = <LocalNotesCompanion>[];
    for (var i = 0; i < count; i++) {
      final noteId = 'note-$i';
      final titleBytes = await crypto.encryptStringForNote(
        userId: _userId,
        noteId: noteId,
        text: 'Title $i',
      );
      final bodyBytes = await crypto.encryptStringForNote(
        userId: _userId,
        noteId: noteId,
        text: 'Body $i',
      );

      inserts.add(
        LocalNotesCompanion.insert(
          id: noteId,
          titleEncrypted: Value(base64Encode(titleBytes)),
          bodyEncrypted: Value(base64Encode(bodyBytes)),
          createdAt: now.subtract(Duration(minutes: i)),
          updatedAt: now.subtract(Duration(minutes: i)),
          noteType: Value(NoteKind.note),
          encryptionVersion: const Value(1),
          userId: const Value(_userId),
          deleted: const Value(false),
        ),
      );
    }

    await db.batch((batch) {
      batch.insertAll(db.localNotes, inserts);
    });
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Notes pagination regression', () {
    late _PaginationHarness harness;

    setUp(() {
      harness = _PaginationHarness();
      expect(
        identical(harness.container.read(loggerProvider), harness.logger),
        isTrue,
        reason: 'loggerProvider override should return harness.logger',
      );
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('refresh only loads a single page', () async {
      await harness.seedNotes(50);

      final notifier = harness.buildNotifier();

      await notifier.refresh();

      final state = harness.container.read(notesPageProvider).value!;
      expect(state.items.length, lessThanOrEqualTo(20));
      expect(state.hasMore, isTrue);
      expect(
        state.items.map((note) => note.id).toSet().length,
        state.items.length,
      );
      expect(harness.listAfterCalls, equals(1));
    });

    test(
      'loadMore avoids duplicate fetches when called concurrently',
      () async {
        await harness.seedNotes(30);
        final notifier = harness.buildNotifier();

        final futures = <Future<void>>[
          notifier.loadMore(),
          notifier.loadMore(),
          notifier.loadMore(),
        ];
        await Future.wait(futures);

        final state = harness.container.read(notesPageProvider).value!;
        expect(state.items.length, lessThanOrEqualTo(20));
        expect(
          state.items.map((note) => note.id).toSet().length,
          state.items.length,
        );
        expect(harness.listAfterCalls, equals(1));

        await notifier.loadMore();
        final updatedState = harness.container.read(notesPageProvider).value!;
        expect(updatedState.items.length, greaterThan(20));
        expect(
          updatedState.items.map((note) => note.id).toSet().length,
          updatedState.items.length,
        );
        expect(harness.listAfterCalls, equals(2));
      },
    );

    test(
      'pagination proceeds correctly when a full page of notes are pinned',
      () async {
        // 1. Setup: 25 notes, 20 pinned, 5 unpinned
        await harness.seedNotes(25);
        final allNoteIds =
            (await harness.db.select(harness.db.localNotes).get())
                .map((e) => e.id)
                .toList();

        // Pin the first 20 notes created (which are the oldest)
        final twentyToPin = allNoteIds.sublist(5);
        await (harness.db.update(harness.db.localNotes)
              ..where((tbl) => tbl.id.isIn(twentyToPin)))
            .write(const LocalNotesCompanion(isPinned: Value(true)));

        // 2. Initial load
        final notifier = harness.buildNotifier();
        await notifier.loadMore();

        // 3. First page: 20 pinned notes
        final page1 = harness.container.read(notesPageProvider).value!;
        expect(page1.items.length, 20);
        expect(page1.items.every((note) => note.isPinned), isTrue);
        expect(page1.hasMore, isTrue);

        // 4. Load second page
        await notifier.loadMore();

        // 5. Second page: Should contain the 5 unpinned notes
        final page2 = harness.container.read(notesPageProvider).value!;
        expect(page2.items.length, 25);
        final unpinnedNotes =
            page2.items.where((note) => !note.isPinned).toList();
        expect(unpinnedNotes.length, 5,
            reason:
                'After loading the second page, we should see the 5 unpinned notes');

        // Verify no infinite loop by checking repository calls
        expect(harness.listAfterCalls, 2);
      },
    );
  });
}
