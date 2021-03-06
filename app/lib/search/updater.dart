// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:math';

import 'package:_discoveryapis_commons/_discoveryapis_commons.dart'
    show DetailedApiRequestError;
import 'package:gcloud/db.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:pub_dev/search/search_service.dart';

import '../dartdoc/backend.dart';
import '../package/models.dart' show Package;
import '../shared/exceptions.dart';
import '../shared/scheduler_stats.dart';
import '../shared/task_scheduler.dart';
import '../shared/task_sources.dart';

import 'backend.dart';

final Logger _logger = Logger('pub.search.updater');

/// Sets the index updater.
void registerIndexUpdater(IndexUpdater updater) =>
    ss.register(#_indexUpdater, updater);

/// The active index updater.
IndexUpdater get indexUpdater => ss.lookup(#_indexUpdater) as IndexUpdater;

class IndexUpdater implements TaskRunner {
  final DatastoreDB _db;
  final PackageIndex _packageIndex;
  SearchSnapshot _snapshot;
  Timer _statsTimer;
  Timer _snapshotWriteTimer;

  IndexUpdater(this._db, this._packageIndex);

  /// Loads the package index snapshot, or if it fails, creates a minimal
  /// package index with only package names and minimal information.
  Future<void> init() async {
    final isReady = await _initSnapshot();
    if (!isReady) {
      _logger.info('Loading minimum package index...');
      int cnt = 0;
      await for (final pd in searchBackend.loadMinimumPackageIndex()) {
        await _packageIndex.addPackage(pd);
        cnt++;
        if (cnt % 500 == 0) {
          _logger.info('Loaded $cnt minimum package data (${pd.package})');
        }
      }
      await _packageIndex.markReady();
      _logger.info('Minimum package index loaded with $cnt packages.');
    }
    _snapshotWriteTimer ??= Timer.periodic(
        Duration(hours: 6, minutes: Random.secure().nextInt(120)), (_) {
      _updateSnapshotIfNeeded();
    });
  }

  /// Updates all packages in the index.
  /// It is slower than searchBackend.loadMinimum_packageIndex, but provides a
  /// complete document for the index.
  @visibleForTesting
  Future<void> updateAllPackages() async {
    await for (final p in _db.query<Package>().run()) {
      final doc = await searchBackend.loadDocument(p.name);
      await _packageIndex.addPackage(doc);
    }
    await _packageIndex.markReady();
  }

  /// Returns whether the snapshot was initialized and loaded properly.
  Future<bool> _initSnapshot() async {
    try {
      _logger.info('Loading snapshot...');
      _snapshot = await snapshotStorage.fetch();
      if (_snapshot != null) {
        final int count = _snapshot.documents.length;
        _logger
            .info('Got $count packages from snapshot at ${_snapshot.updated}');
        await _packageIndex.addPackages(_snapshot.documents.values);
        // Arbitrary sanity check that the snapshot is not entirely bogus.
        // Index merge will enable search.
        if (count > 10) {
          _logger.info('Merging index after snapshot.');
          await _packageIndex.markReady();
          _logger.info('Snapshot load completed.');
          return true;
        }
      }
    } catch (e, st) {
      _logger.warning('Error while fetching snapshot.', e, st);
    }
    // Create an empty snapshot if the above failed. This will be populated with
    // package data via a separate update process.
    _snapshot ??= SearchSnapshot();
    return false;
  }

  /// Starts the scheduler to update the package index.
  void runScheduler({Stream<Task> manualTriggerTasks}) {
    manualTriggerTasks ??= Stream<Task>.empty();
    final scheduler = TaskScheduler(
      this,
      [
        ManualTriggerTaskSource(manualTriggerTasks),
        DatastoreHeadTaskSource(
          _db,
          TaskSourceModel.package,
          sleep: const Duration(minutes: 10),
        ),
        DatastoreHeadTaskSource(
          _db,
          TaskSourceModel.scorecard,
          sleep: const Duration(minutes: 10),
          skipHistory: true,
        ),
        _PeriodicUpdateTaskSource(_snapshot),
      ],
    );
    scheduler.run();

    _statsTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      updateLatestStats(scheduler.stats());
    });
  }

  Future<void> close() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _snapshotWriteTimer?.cancel();
    _snapshotWriteTimer = null;
    // TODO: close scheduler
  }

  @override
  Future<void> runTask(Task task) async {
    try {
      final sd = _snapshot.documents[task.package];

      // Skip tasks that originate before the current document in the snapshot
      // was created (e.g. the index and the snapshot was updated since the task
      // was created).
      // This preempts unnecessary work at startup (scanned Packages are updated
      // only if the index was not updated since the last snapshot), and also
      // deduplicates the periodic-updates which may not complete in 2 hours.
      if (sd != null && sd.timestamp.isAfter(task.updated)) return;

      // The index requires the analysis results in most of the cases, except:
      // - when a new package is created, and it is not in the snapshot yet, or
      // - when the last timestamp is older than 7 days in the snapshot.
      //
      // The later requirement is working on the assumption that normally the
      // index will update the packages in the snapshot every day, but if the
      // analysis won't complete for some reason, we still want to update the
      // index with a potential update to the package.
      final now = DateTime.now().toUtc();
      final requireAnalysis =
          sd != null && now.difference(sd.timestamp).inDays < 7;

      final doc = await searchBackend.loadDocument(task.package,
          requireAnalysis: requireAnalysis);
      _snapshot.add(doc);
      await _packageIndex.addPackage(doc);
    } on RemovedPackageException catch (_) {
      _logger.info('Removing: ${task.package}');
      _snapshot.remove(task.package);
      await _packageIndex.removePackage(task.package);
    } on MissingAnalysisException catch (_) {
      // Nothing to do yet, keeping old version if it exists.
    }
  }

  Future<void> _updateSnapshotIfNeeded() async {
    // TODO: make the catch-all block narrower
    try {
      if (await snapshotStorage.wasUpdatedRecently()) {
        _logger.info('Snapshot update skipped (found recent snapshot).');
      } else {
        _logger.info('Updating search snapshot...');
        await snapshotStorage.store(_snapshot);
        _logger.info('Search snapshot update completed.');
      }
    } catch (e, st) {
      _logger.warning('Unable to update search snapshot.', e, st);
    }
  }

  /// Triggers the load of the SDK index from the dartdoc storage bucket.
  void initDartSdkIndex() {
    // Don't block on SDK index updates, as it may take several minutes before
    // the dartdoc service produces the required output.
    _updateDartSdkIndex().whenComplete(() {});
  }

  Future<void> _updateDartSdkIndex() async {
    for (int i = 0;; i++) {
      try {
        _logger.info('Trying to load SDK index.');
        final data = await dartdocBackend.getDartSdkDartdocData();
        if (data != null) {
          final docs = splitLibraries(data)
              .map((lib) => createSdkDocument(lib))
              .toList();
          await dartSdkIndex.addPackages(docs);
          await dartSdkIndex.markReady();
          _logger.info('Dart SDK index loaded successfully.');
          return;
        }
      } on DetailedApiRequestError catch (e, st) {
        if (e.status == 404) {
          _logger.info('Error loading Dart SDK index.', e, st);
        } else {
          _logger.warning('Error loading Dart SDK index.', e, st);
        }
      } catch (e, st) {
        _logger.warning('Error loading Dart SDK index.', e, st);
      }
      if (i % 10 == 0) {
        _logger.warning('Unable to load Dart SDK index. Attempt: $i');
      }
      await Future.delayed(const Duration(minutes: 1));
    }
  }
}

/// A task source that generates an update task for stale documents.
///
/// It scans the current search snapshot every two hours, and selects the
/// packages that have not been updated in the last 24 hours.
class _PeriodicUpdateTaskSource implements TaskSource {
  final SearchSnapshot _snapshot;
  _PeriodicUpdateTaskSource(this._snapshot) {
    assert(_snapshot != null);
  }

  @override
  Stream<Task> startStreaming() async* {
    for (;;) {
      await Future.delayed(Duration(hours: 2));
      final now = DateTime.now();
      final tasks = _snapshot.documents.values
          .where((pd) {
            final ageInMonths = now.difference(pd.updated ?? now).inDays ~/ 30;
            // Packages updated in the past two years will get updated daily,
            // each additional month adds an extra hour to the update time
            // difference. Neglected packages (after 14 years of the last update)
            // get refreshed in the index once in a week.
            final updatePeriodHours = max(24, min(ageInMonths, 7 * 24));
            return now.difference(pd.timestamp).inHours >= updatePeriodHours;
          })
          .map((pd) => Task(pd.package, pd.version, now))
          .toList();
      _logger
          .info('Periodic scheduler found ${tasks.length} packages to update.');
      for (Task task in tasks) {
        yield task;
      }
    }
  }
}
