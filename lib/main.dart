import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_storage.dart';
import 'git_service.dart';
import 'models.dart';
import 'update_service.dart';

final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.light);

void main() {
  runApp(const GitWorkflowApp());
}

class GitWorkflowApp extends StatelessWidget {
  const GitWorkflowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Git Flow',
          themeMode: mode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF5865F2),
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF7F9FD),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF8B8DFF),
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF0F172A),
            useMaterial3: true,
          ),
          home: const GitWorkflowHome(),
        );
      },
    );
  }
}

class GitWorkflowHome extends StatefulWidget {
  const GitWorkflowHome({super.key});

  @override
  State<GitWorkflowHome> createState() => _GitWorkflowHomeState();
}

class _GitWorkflowHomeState extends State<GitWorkflowHome> {
  final _storage = AppStorage();
  final _git = GitService();
  final _updates = UpdateService();
  final _uuid = const Uuid();

  var _repositories = <RepositoryInfo>[];
  var _branches = <TrackedBranch>[];
  var _operations = <GitOperationResult>[];
  final _currentBranches = <String, String>{};
  final _commitHistory = <String, List<CommitHistoryEntry>>{};
  final _currentChangedFiles = <String, List<String>>{};
  final _visibleCommitDrafts = <String, CommitDraft>{};
  final _lastCommitDrafts = <String, CommitDraft>{};
  RepositoryInfo? _selectedRepo;
  var _loading = true;
  var _busy = false;
  var _autoRefreshing = false;
  var _cardSize = 360.0;
  var _autoCheckUpdates = true;
  var _darkMode = false;
  var _leftPanelCollapsed = false;
  var _rightPanelCollapsed = false;
  var _checkingUpdates = false;
  String? _message;
  String? _updateError;
  ReleaseInfo? _latestRelease;
  SyncAnimationState? _syncAnimation;
  Timer? _autoRefreshTimer;
  var _commitDraftRevision = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _autoRefreshTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => unawaited(_autoRefreshSelectedRepo()),
    );
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final snapshot = await _storage.load();
    if (!mounted) return;
    setState(() {
      _repositories = snapshot.repositories;
      _branches = snapshot.branches;
      _operations = snapshot.operations;
      _autoCheckUpdates = snapshot.autoCheckUpdates;
      _darkMode = snapshot.darkMode;
      _cardSize = snapshot.cardSize.clamp(220.0, 460.0).toDouble();
      _selectedRepo = _repositories.firstOrNull;
      _loading = false;
    });
    appThemeMode.value = snapshot.darkMode ? ThemeMode.dark : ThemeMode.light;
    unawaited(_loadCurrentBranches());
    if (snapshot.autoCheckUpdates) {
      unawaited(_checkForUpdates(silent: true));
    }
  }

  Future<void> _loadCurrentBranches() async {
    for (final repo in _repositories) {
      await _refreshCurrentBranch(repo);
    }
  }

  Future<String> _refreshCurrentBranch(RepositoryInfo repo) async {
    final branch = await _git.currentBranch(repo.path);
    if (mounted) {
      setState(() => _currentBranches[repo.id] = branch);
    }
    unawaited(_refreshCurrentBranchHistory(repo, branch));
    unawaited(_refreshCurrentChangedFiles(repo, branch));
    return branch;
  }

  Future<void> _refreshCurrentBranchHistory(
    RepositoryInfo repo,
    String branch,
  ) async {
    if (branch.trim().isEmpty) return;
    final history = await _git.commitHistory(
      repoPath: repo.path,
      branchName: branch,
    );
    if (!mounted) return;
    final latestBranch = _currentBranches[repo.id];
    if (latestBranch != branch) return;
    setState(() => _commitHistory[repo.id] = history);
  }

  Future<void> _refreshCurrentChangedFiles(
    RepositoryInfo repo,
    String branch,
  ) async {
    if (branch.trim().isEmpty) return;
    final files = await _git.changedFiles(repo.path);
    if (!mounted) return;
    final latestBranch = _currentBranches[repo.id];
    if (latestBranch != branch) return;
    setState(() => _currentChangedFiles[repo.id] = files);
  }

  Future<void> _showCurrentFileDiff(
    RepositoryInfo repo,
    String filePath,
  ) async {
    try {
      final diff = await _git.diffForFile(repo.path, filePath);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => DiffDialog(filePath: filePath, diff: diff),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    }
  }

  Future<void> _commitCurrentFiles(
    RepositoryInfo repo,
    List<String> files,
    String message,
    String description,
  ) async {
    await _guarded(() async {
      final currentBranch = await _refreshCurrentBranch(repo);
      final result = await _git.commitBranch(
        worktreePath: repo.path,
        branchName: currentBranch,
        message: message,
        description: description,
        files: files,
      );
      await _recordOperation(result);
      if (result.success) {
        _rememberCommittedDraft(repo.id, currentBranch, message, description);
      }
      await _refreshCurrentBranch(repo);
      await _refreshTrackedBranches(repo);
    });
  }

  String _commitDraftKey(String repoId, String branchName) =>
      '$repoId::$branchName';

  void _rememberCommittedDraft(
    String repoId,
    String branchName,
    String message,
    String description,
  ) {
    final key = _commitDraftKey(repoId, branchName);
    setState(() {
      _lastCommitDrafts[key] = CommitDraft(
        message: message,
        description: description,
      );
      _visibleCommitDrafts.remove(key);
      _commitDraftRevision++;
    });
  }

  void _restoreCommittedDraft(String repoId, String branchName) {
    final key = _commitDraftKey(repoId, branchName);
    final draft = _lastCommitDrafts[key];
    if (draft == null) return;
    setState(() {
      _visibleCommitDrafts[key] = draft;
      _commitDraftRevision++;
    });
  }

  void _clearCommittedDraft(String repoId, String branchName) {
    final key = _commitDraftKey(repoId, branchName);
    if (!_lastCommitDrafts.containsKey(key) &&
        !_visibleCommitDrafts.containsKey(key)) {
      return;
    }
    setState(() {
      _lastCommitDrafts.remove(key);
      _visibleCommitDrafts.remove(key);
      _commitDraftRevision++;
    });
  }

  Future<void> _discardCurrentFiles(
    RepositoryInfo repo,
    List<String> files,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(
          files.length == 1
              ? 'Discard changes in ${files.first}? This cannot be undone.'
              : 'Discard changes in ${files.length} selected files? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _guarded(() async {
      final currentBranch = await _refreshCurrentBranch(repo);
      final result = await _git.discardFiles(
        worktreePath: repo.path,
        branchName: currentBranch,
        files: files,
      );
      await _recordOperation(result);
      await _refreshCurrentBranch(repo);
      await _refreshTrackedBranches(repo);
    });
  }

  Future<void> _save() async {
    await _storage.save(
      AppStateSnapshot(
        repositories: _repositories,
        branches: _branches,
        operations: _operations.take(25).toList(),
        autoCheckUpdates: _autoCheckUpdates,
        darkMode: _darkMode,
        cardSize: _cardSize,
      ),
    );
  }

  Future<void> _setDarkMode(bool value) async {
    setState(() => _darkMode = value);
    appThemeMode.value = value ? ThemeMode.dark : ThemeMode.light;
    await _save();
  }

  Future<void> _setAutoCheckUpdates(bool value) async {
    setState(() => _autoCheckUpdates = value);
    await _save();
    if (value) {
      await _checkForUpdates();
    }
  }

  Future<void> _setCardSize(double value) async {
    setState(() => _cardSize = value);
    await _save();
  }

  Future<void> _checkForUpdates({bool silent = false}) async {
    if (_checkingUpdates) return;
    setState(() {
      _checkingUpdates = true;
      _updateError = null;
    });
    try {
      final release = await _updates.latestRelease();
      if (!mounted) return;
      setState(() {
        _latestRelease = release;
        if (!silent) {
          _message = release.isNewerThanCurrent
              ? 'Update available: v${release.version}'
              : 'You are running the latest version.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _updateError = error.toString();
        if (!silent) _message = 'Update check failed: $_updateError';
      });
    } finally {
      if (mounted) {
        setState(() => _checkingUpdates = false);
      }
    }
  }

  Future<void> _openReleasePage() async {
    final url = _latestRelease?.url;
    if (url == null || url.isEmpty) return;
    await _openUrl(url);
  }

  Future<void> _downloadAndInstallUpdate() async {
    var release = _latestRelease;
    if (release == null) {
      await _checkForUpdates();
      release = _latestRelease;
    }
    if (release == null) return;

    if (!release.isNewerThanCurrent) {
      setState(() => _message = 'You are running the latest version.');
      return;
    }

    final asset = release.preferredAsset;
    if (asset == null) {
      setState(() {
        _message =
            'Update available, but no Windows installer/build asset was found.';
      });
      await _openReleasePage();
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateInstallDialog(
        release: release!,
        asset: asset,
        updateService: _updates,
        onOpenFile: _openDownloadedUpdate,
      ),
    );
  }

  Future<void> _openDownloadedUpdate(FileSystemEntity file) async {
    if (file.path.toLowerCase().endsWith('.zip')) {
      final basePath = file.path.replaceFirst(
        RegExp(r'\.zip$', caseSensitive: false),
        '',
      );
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 14);
      final targetDir = Directory('${basePath}_$stamp');
      await targetDir.create(recursive: true);

      if (Platform.isWindows) {
        final expand = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          'Expand-Archive -LiteralPath ${_psQuote(file.path)} -DestinationPath ${_psQuote(targetDir.path)} -Force',
        ]);
        if (expand.exitCode != 0) {
          throw 'Unable to extract update: ${expand.stderr}';
        }
      } else {
        final unzip = await Process.run('unzip', [
          '-o',
          file.path,
          '-d',
          targetDir.path,
        ]);
        if (unzip.exitCode != 0) {
          throw 'Unable to extract update: ${unzip.stderr}';
        }
      }

      final exe = File(
        '${targetDir.path}${Platform.pathSeparator}git_flow.exe',
      );
      if (await exe.exists()) {
        await _launchUpdatedAppAndExit(exe);
        return;
      }
      await _openDownloadedUpdate(targetDir);
      return;
    }

    if (await FileSystemEntity.isDirectory(file.path)) {
      if (Platform.isWindows) {
        await Process.start('explorer', [file.path]);
        return;
      }
      if (Platform.isMacOS) {
        await Process.start('open', [file.path]);
        return;
      }
      await Process.start('xdg-open', [file.path]);
      return;
    }

    if (Platform.isWindows) {
      if (file.path.toLowerCase().endsWith('.exe')) {
        await _launchUpdatedAppAndExit(file);
        return;
      }
      await Process.start(file.path, [], mode: ProcessStartMode.detached);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [file.path]);
      return;
    }
    await Process.start('xdg-open', [file.path]);
  }

  Future<void> _launchUpdatedAppAndExit(FileSystemEntity file) async {
    await Process.start(
      file.path,
      const [],
      mode: ProcessStartMode.detached,
      workingDirectory: File(file.path).parent.path,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    exit(0);
  }

  String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  Future<void> _openGithubProfile() async {
    await _openUrl('https://github.com/asifkhalid03');
  }

  Future<void> _openUrl(String url) async {
    if (Platform.isWindows) {
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.start('open', [url]);
      return;
    }
    await Process.start('xdg-open', [url]);
  }

  Future<void> _chooseRepository() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a Git repository',
    );
    if (path == null) return;
    await _guarded(() async {
      final repo = await _git.validateRepository(path: path, id: _uuid.v4());
      final existingIndex = _repositories.indexWhere(
        (item) => item.path == repo.path,
      );
      setState(() {
        if (existingIndex == -1) {
          _repositories = [repo, ..._repositories];
        } else {
          _repositories[existingIndex] = repo;
        }
        _selectedRepo = repo;
      });
      await _refreshCurrentBranch(repo);
      await _save();
      await _selectBranches(repo);
    });
  }

  Future<void> _selectBranches(RepositoryInfo repo) async {
    await _guarded(() async {
      final currentBranch = await _refreshCurrentBranch(repo);
      final available = await _git.listBranches(repo.path, includeRemote: true);
      final selected = _branches
          .where((branch) => branch.repoId == repo.id)
          .map((branch) => branch.branchName)
          .toSet();
      if (currentBranch.isNotEmpty) {
        selected.add(currentBranch);
      }
      if (!mounted) return;
      final result = await showDialog<List<String>>(
        context: context,
        builder: (_) => BranchSelectorDialog(
          repo: repo,
          branches: available,
          selectedBranches: selected,
          currentBranch: currentBranch,
          onFetchBranches: () async {
            await _git.fetchBranches(repo.path);
            return _git.listBranches(repo.path, includeRemote: true);
          },
        ),
      );
      if (result == null) return;
      final worktreesRoot = await _storage.worktreesDirectory();
      final tracked = <TrackedBranch>[];
      for (final branchName in result) {
        final worktreePath = await _git.ensureWorktree(
          repoPath: repo.path,
          repoId: repo.id,
          branchName: branchName,
          worktreesRoot: worktreesRoot,
        );
        final upstream = await _git.upstreamFor(repo.path, branchName);
        final previous = _branches
            .where(
              (item) => item.repoId == repo.id && item.branchName == branchName,
            )
            .firstOrNull;
        final status = await _git.getBranchStatus(
          repo.path,
          upstream,
          revision: branchName == currentBranch ? 'HEAD' : branchName,
          includeWorkingTree: branchName == currentBranch,
        );
        tracked.add(
          TrackedBranch(
            repoId: repo.id,
            branchName: branchName,
            upstream: upstream,
            worktreePath: worktreePath,
            lastPullAt: previous?.lastPullAt,
            lastStatus: status,
          ),
        );
      }
      setState(() {
        _branches = [
          ..._branches.where((branch) => branch.repoId != repo.id),
          ...tracked,
        ];
      });
      await _save();
    });
  }

  Future<void> _refreshBranch(TrackedBranch branch) async {
    await _guarded(() async {
      final currentBranch = await _refreshCurrentBranch(_selectedRepo!);
      final upstream = await _git.upstreamFor(
        _selectedRepo!.path,
        branch.branchName,
      );
      final status = await _git.getBranchStatus(
        _selectedRepo!.path,
        upstream,
        revision: branch.branchName == currentBranch
            ? 'HEAD'
            : branch.branchName,
        includeWorkingTree: branch.branchName == currentBranch,
      );
      _replaceBranch(branch.copyWith(upstream: upstream, lastStatus: status));
      await _save();
    });
  }

  Future<void> _pullBranch(TrackedBranch branch) async {
    await _guarded(() async {
      final repo = _selectedRepo!;
      final currentBranch = await _refreshCurrentBranch(repo);
      if (branch.branchName != currentBranch) {
        final failure = GitOperationResult(
          operation: 'pull',
          branchName: branch.branchName,
          success: false,
          stdout: '',
          stderr: 'Pull is only allowed on the current branch. Checkout first.',
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
        );
        await _recordOperation(failure);
        return;
      }
      final result = await _git.pullBranch(repo.path, branch.upstream);
      await _recordOperation(result.copyBranch(branch.branchName));
      final status = await _git.getBranchStatus(repo.path, branch.upstream);
      _replaceBranch(
        branch.copyWith(
          lastPullAt: result.success ? DateTime.now() : branch.lastPullAt,
          lastStatus: status,
        ),
      );
      await _save();
    });
  }

  Future<void> _pushBranch(TrackedBranch branch) async {
    await _guarded(() async {
      final repo = _selectedRepo!;
      final currentBranch = await _refreshCurrentBranch(repo);
      if (branch.branchName != currentBranch) {
        final failure = GitOperationResult(
          operation: 'push',
          branchName: branch.branchName,
          success: false,
          stdout: '',
          stderr: 'Push is only allowed on the current branch. Checkout first.',
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
        );
        await _recordOperation(failure);
        return;
      }
      final result = await _git.pushBranch(
        worktreePath: repo.path,
        branchName: branch.branchName,
      );
      await _recordOperation(result);
      if (result.success) {
        _clearCommittedDraft(repo.id, branch.branchName);
      }
      final upstream = await _git.upstreamFor(repo.path, branch.branchName);
      final status = await _git.getBranchStatus(repo.path, upstream);
      _replaceBranch(branch.copyWith(upstream: upstream, lastStatus: status));
      await _save();
    });
  }

  Future<void> _checkoutBranch(TrackedBranch branch) async {
    final repo = _selectedRepo!;
    final currentBranch = await _refreshCurrentBranch(repo);
    final currentTrackedBranch = _branches
        .where(
          (item) => item.repoId == repo.id && item.branchName == currentBranch,
        )
        .firstOrNull;
    final hasLocalChanges =
        currentTrackedBranch?.lastStatus?.hasLocalChanges ?? false;
    var allowDirty = false;
    if (hasLocalChanges) {
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => CarryChangesDialog(
          currentBranch: currentBranch,
          targetBranch: branch.branchName,
          changedFilesCount:
              currentTrackedBranch?.lastStatus?.changedFilesCount ?? 0,
        ),
      );
      if (confirmed != true) return;
      allowDirty = true;
    }

    await _guarded(() async {
      final result = await _git.checkoutBranch(
        repoPath: repo.path,
        branchName: branch.branchName,
        allowDirty: allowDirty,
      );
      await _recordOperation(result);
      final current = await _refreshCurrentBranch(repo);
      await _refreshTrackedBranches(repo);
      if (result.success) {
        setState(() => _message = 'Checked out $current');
      }
    });
  }

  Future<void> _undoLastCommit(TrackedBranch branch) async {
    await _guarded(() async {
      final repo = _selectedRepo!;
      final currentBranch = await _refreshCurrentBranch(repo);
      if (branch.branchName != currentBranch) {
        final failure = GitOperationResult(
          operation: 'undo',
          branchName: branch.branchName,
          success: false,
          stdout: '',
          stderr: 'Undo commit is only allowed on the current branch.',
          startedAt: DateTime.now(),
          finishedAt: DateTime.now(),
        );
        await _recordOperation(failure);
        return;
      }
      final result = await _git.undoLastCommit(
        repoPath: repo.path,
        branchName: branch.branchName,
      );
      await _recordOperation(result);
      if (result.success) {
        _restoreCommittedDraft(repo.id, branch.branchName);
      }
      await _refreshTrackedBranches(repo);
    });
  }

  Future<void> _commitBranch(TrackedBranch branch) async {
    await _guarded(() async {
      final repo = _selectedRepo!;
      final currentBranch = await _refreshCurrentBranch(repo);
      if (branch.branchName != currentBranch) {
        setState(() {
          _message =
              'Commit is only allowed on the current branch: $currentBranch';
        });
        return;
      }
      final files = await _git.changedFiles(repo.path);
      if (!mounted) return;
      final request = await showDialog<CommitRequest>(
        context: context,
        builder: (_) => CommitDialog(
          branchName: branch.branchName,
          files: files,
          initialMessage:
              _visibleCommitDrafts[_commitDraftKey(repo.id, branch.branchName)]
                  ?.message ??
              '',
          initialDescription:
              _visibleCommitDrafts[_commitDraftKey(repo.id, branch.branchName)]
                  ?.description ??
              '',
        ),
      );
      if (request == null) return;
      final result = await _git.commitBranch(
        worktreePath: repo.path,
        branchName: branch.branchName,
        message: request.message,
        description: request.description,
        files: request.files,
      );
      await _recordOperation(result);
      if (result.success) {
        _rememberCommittedDraft(
          repo.id,
          branch.branchName,
          request.message,
          request.description,
        );
      }
      await _refreshBranch(branch);
    });
  }

  Future<void> _syncBranches(
    RepositoryInfo repo,
    List<TrackedBranch> branches,
    String currentBranch,
  ) async {
    if (branches.length < 2) {
      setState(() => _message = 'Select at least two branches to sync.');
      return;
    }

    final request = await showDialog<SyncMergeRequest>(
      context: context,
      builder: (_) => SyncMergeDialog(
        branches: branches.map((branch) => branch.branchName).toList(),
        currentBranch: currentBranch,
      ),
    );
    if (request == null) return;

    await _guarded(() async {
      final activeBranch = await _refreshCurrentBranch(repo);
      final activeUpstream = await _git.upstreamFor(repo.path, activeBranch);
      final activeStatus = await _git.getBranchStatus(
        repo.path,
        activeUpstream,
        fetch: false,
      );
      if (activeStatus.hasConflicts) {
        setState(() {
          _message = 'Resolve conflicts on $activeBranch before syncing.';
        });
        return;
      }
      if (activeStatus.hasLocalChanges) {
        final files = await _git.changedFiles(repo.path);
        if (!mounted) return;
        final commitRequest = await showDialog<CommitRequest>(
          context: context,
          builder: (_) => CommitDialog(
            branchName: activeBranch,
            files: files,
            title: 'Commit changes before sync',
            intro:
                'Sync needs a clean working tree. Commit the current changes, then the selected branches will be merged.',
            actionLabel: 'Commit And Sync',
            initialMessage: 'Sync prep: save $activeBranch changes',
          ),
        );
        if (commitRequest == null) {
          setState(() {
            _message = 'Sync cancelled: local changes were not committed.';
          });
          return;
        }
        final commitResult = await _git.commitBranch(
          worktreePath: repo.path,
          branchName: activeBranch,
          message: commitRequest.message,
          description: commitRequest.description,
          files: commitRequest.files,
        );
        await _recordOperation(commitResult);
        await _refreshTrackedBranches(repo);
        if (!commitResult.success) return;
      }

      setState(() {
        _message = 'Refreshing and pulling current branch: $activeBranch';
      });
      final pullResult = await _git.pullBranch(repo.path, activeUpstream);
      await _recordOperation(pullResult);
      if (!pullResult.success) {
        await _refreshCurrentBranch(repo);
        await _refreshTrackedBranches(repo);
        setState(() {
          _message =
              'Sync cancelled: pull failed on current branch $activeBranch.';
        });
        return;
      }
      await _refreshCurrentBranch(repo);
      await _refreshTrackedBranches(repo);

      if (!mounted) return;
      setState(() {
        _syncAnimation = SyncAnimationState(
          targetBranch: request.targetBranch,
          sourceBranches: request.sourceBranches,
          bothDirections: request.bothDirections,
          activeFromBranch: null,
          activeToBranch: null,
          completedSteps: const [],
        );
      });
      try {
        final result = await _git.syncSequentialBranches(
          repoPath: repo.path,
          startBranch: request.targetBranch,
          nextBranches: request.sourceBranches,
          onStep: (step) async {
            if (!mounted) return;
            setState(() {
              final previous = _syncAnimation;
              _syncAnimation = SyncAnimationState(
                targetBranch: request.targetBranch,
                sourceBranches: request.sourceBranches,
                bothDirections: request.bothDirections,
                activeFromBranch: step.fromBranch,
                activeToBranch: step.toBranch,
                completedSteps: previous == null
                    ? const []
                    : [
                        ...previous.completedSteps,
                        if (previous.activeFromBranch != null &&
                            previous.activeToBranch != null)
                          SyncAnimationStep(
                            previous.activeFromBranch!,
                            previous.activeToBranch!,
                          ),
                      ],
              );
            });
            await Future<void>.delayed(const Duration(milliseconds: 260));
          },
        );
        await _recordOperation(result);
        GitOperationResult? pushResult;
        if (result.success && request.pushAfterSync) {
          pushResult = await _git.pushSyncedBranches(
            repoPath: repo.path,
            branchNames: request.branchesToPush,
          );
          await _recordOperation(pushResult);
        }
        await _restoreStartBranchAfterSync(
          repo: repo,
          syncResult: result,
          pushResult: pushResult,
          startBranch: request.targetBranch,
        );
        await _refreshCurrentBranch(repo);
        await _refreshTrackedBranches(repo);
      } finally {
        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (mounted) {
          setState(() => _syncAnimation = null);
        }
      }
    });
  }

  Future<void> _restoreStartBranchAfterSync({
    required RepositoryInfo repo,
    required GitOperationResult syncResult,
    required GitOperationResult? pushResult,
    required String startBranch,
  }) async {
    if (!syncResult.success) return;

    final restoreBranch = startBranch.trim();
    if (restoreBranch.isEmpty) return;

    final pushFailed = pushResult != null && !pushResult.success;
    final prefix = pushFailed
        ? 'Sync finished, but push failed.'
        : 'Sync finished.';
    final currentBranch = await _refreshCurrentBranch(repo);
    if (currentBranch == restoreBranch) {
      setState(() {
        _message = '$prefix Current branch is $restoreBranch.';
      });
      return;
    }

    final restore = await _git.checkoutBranch(
      repoPath: repo.path,
      branchName: restoreBranch,
    );
    if (!restore.success) {
      await _recordOperation(restore);
      return;
    }
    setState(() {
      _message = '$prefix Switched back to $restoreBranch.';
    });
  }

  Future<void> _refreshTrackedBranches(
    RepositoryInfo repo, {
    bool persist = true,
    bool fetch = true,
  }) async {
    final currentBranch = await _refreshCurrentBranch(repo);
    final next = <TrackedBranch>[];
    for (final branch in _branches.where(
      (branch) => branch.repoId == repo.id,
    )) {
      final upstream = await _git.upstreamFor(repo.path, branch.branchName);
      final status = await _git.getBranchStatus(
        repo.path,
        upstream,
        fetch: fetch,
        revision: branch.branchName == currentBranch
            ? 'HEAD'
            : branch.branchName,
        includeWorkingTree: branch.branchName == currentBranch,
      );
      next.add(branch.copyWith(upstream: upstream, lastStatus: status));
    }
    setState(() {
      _branches = [
        for (final branch in _branches)
          if (branch.repoId == repo.id)
            next.firstWhere(
              (item) => item.branchName == branch.branchName,
              orElse: () => branch,
            )
          else
            branch,
      ];
    });
    if (persist) {
      await _save();
    }
  }

  Future<void> _autoRefreshSelectedRepo() async {
    final repo = _selectedRepo;
    if (!mounted || repo == null || _busy || _autoRefreshing) return;
    final hasTrackedBranches = _branches.any(
      (branch) => branch.repoId == repo.id,
    );
    if (!hasTrackedBranches) return;

    _autoRefreshing = true;
    try {
      await _refreshTrackedBranches(repo, persist: false, fetch: false);
    } catch (_) {
      // Background refresh should not interrupt explicit user actions.
    } finally {
      _autoRefreshing = false;
    }
  }

  Future<void> _recordOperation(GitOperationResult result) async {
    setState(() {
      _operations = [result, ..._operations].take(25).toList();
      _message = _operationMessage(result);
    });
    await _save();
  }

  String _operationMessage(GitOperationResult result) {
    final branch = result.branchName.isEmpty ? 'branch' : result.branchName;
    if (result.success) {
      return '${result.operation} completed: $branch';
    }
    final detail = result.summary
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return detail.isEmpty
        ? '${result.operation} failed: $branch'
        : '${result.operation} failed: $branch - $detail';
  }

  void _replaceBranch(TrackedBranch next) {
    setState(() {
      _branches = [
        for (final branch in _branches)
          if (branch.repoId == next.repoId &&
              branch.branchName == next.branchName)
            next
          else
            branch,
      ];
    });
  }

  Future<void> _swapTrackedBranches(
    RepositoryInfo repo,
    TrackedBranch from,
    TrackedBranch to,
  ) async {
    if (from.branchName == to.branchName) return;
    setState(() {
      final repoBranches = _branches
          .where((branch) => branch.repoId == repo.id)
          .toList();
      final fromIndex = repoBranches.indexWhere(
        (branch) => branch.branchName == from.branchName,
      );
      final toIndex = repoBranches.indexWhere(
        (branch) => branch.branchName == to.branchName,
      );
      if (fromIndex == -1 || toIndex == -1) return;

      final moved = repoBranches[fromIndex];
      repoBranches[fromIndex] = repoBranches[toIndex];
      repoBranches[toIndex] = moved;

      _branches = [
        ..._branches.where((branch) => branch.repoId != repo.id),
        ...repoBranches,
      ];
      _message = 'Branch order saved.';
    });
    await _save();
  }

  Future<void> _guarded(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final selectedRepo = _selectedRepo;
    final currentBranch = selectedRepo == null
        ? ''
        : _currentBranches[selectedRepo.id] ?? '';
    final selectedBranches = selectedRepo == null
        ? <TrackedBranch>[]
        : _branches
              .where((branch) => branch.repoId == selectedRepo.id)
              .toList();
    final checkoutBlocked = selectedBranches.any(
      (branch) =>
          branch.branchName == currentBranch &&
          (branch.lastStatus?.hasLocalChanges ?? false),
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1680),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: selectedRepo == null
                      ? RepositoryPicker(
                          repositories: _repositories,
                          selectedRepo: selectedRepo,
                          onChooseFolder: _chooseRepository,
                          onSelect: (repo) =>
                              setState(() => _selectedRepo = repo),
                          onNext: selectedRepo == null
                              ? null
                              : () => _selectBranches(selectedRepo),
                        )
                      : RepositoryDashboard(
                          repo: selectedRepo,
                          currentBranch: currentBranch,
                          currentBranchHistory:
                              _commitHistory[selectedRepo.id] ?? const [],
                          currentChangedFiles:
                              _currentChangedFiles[selectedRepo.id] ?? const [],
                          currentCommitDraft:
                              _visibleCommitDrafts[_commitDraftKey(
                                selectedRepo.id,
                                currentBranch,
                              )],
                          commitDraftRevision: _commitDraftRevision,
                          repositories: _repositories,
                          branches: selectedBranches,
                          operations: _operations,
                          message: _message,
                          busy: _busy,
                          latestRelease: _latestRelease,
                          checkingUpdates: _checkingUpdates,
                          autoCheckUpdates: _autoCheckUpdates,
                          darkMode: _darkMode,
                          updateError: _updateError,
                          syncAnimation: _syncAnimation,
                          checkoutBlocked: checkoutBlocked,
                          leftPanelCollapsed: _leftPanelCollapsed,
                          rightPanelCollapsed: _rightPanelCollapsed,
                          cardSize: _cardSize,
                          onChooseFolder: _chooseRepository,
                          onChangeRepo: (repo) {
                            setState(() => _selectedRepo = repo);
                            unawaited(_refreshCurrentBranch(repo));
                          },
                          onCardSizeChanged: _setCardSize,
                          onCheckUpdates: _checkForUpdates,
                          onOpenRelease: _openReleasePage,
                          onInstallUpdate: _downloadAndInstallUpdate,
                          onOpenGithubProfile: _openGithubProfile,
                          onAutoCheckUpdatesChanged: _setAutoCheckUpdates,
                          onDarkModeChanged: _setDarkMode,
                          onToggleLeftPanel: () => setState(
                            () => _leftPanelCollapsed = !_leftPanelCollapsed,
                          ),
                          onToggleRightPanel: () => setState(
                            () => _rightPanelCollapsed = !_rightPanelCollapsed,
                          ),
                          onEditBranches: () => _selectBranches(selectedRepo),
                          onRefresh: _refreshBranch,
                          onPull: _pullBranch,
                          onCheckout: _checkoutBranch,
                          onCommit: _commitBranch,
                          onPush: _pushBranch,
                          onUndoCommit: _undoLastCommit,
                          onShowFileDiff: (file) =>
                              _showCurrentFileDiff(selectedRepo, file),
                          onCommitFiles: (files, message, description) =>
                              _commitCurrentFiles(
                                selectedRepo,
                                files,
                                message,
                                description,
                              ),
                          onDiscardFiles: (files) =>
                              _discardCurrentFiles(selectedRepo, files),
                          onSwapBranches: (from, to) =>
                              _swapTrackedBranches(selectedRepo, from, to),
                          onSyncBranches: () => _syncBranches(
                            selectedRepo,
                            selectedBranches,
                            currentBranch,
                          ),
                        ),
                ),
              ),
            ),
            if (_busy)
              const Positioned(
                top: 20,
                right: 20,
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class RepositoryPicker extends StatelessWidget {
  const RepositoryPicker({
    required this.repositories,
    required this.selectedRepo,
    required this.onChooseFolder,
    required this.onSelect,
    required this.onNext,
    super.key,
  });

  final List<RepositoryInfo> repositories;
  final RepositoryInfo? selectedRepo;
  final VoidCallback onChooseFolder;
  final ValueChanged<RepositoryInfo> onSelect;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.folder_outlined,
                size: 40,
                color: Color(0xFF5865F2),
              ),
              const SizedBox(width: 24),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Select Repository',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('Choose a local repository folder to continue.'),
                ],
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              FilledButton.icon(
                onPressed: onChooseFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose Folder'),
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: onChooseFolder,
                icon: const Icon(Icons.folder_outlined),
                label: const Text('Browse'),
              ),
            ],
          ),
          const Divider(height: 42),
          if (repositories.isEmpty)
            const EmptyState()
          else
            ...repositories.map(
              (repo) => RepositoryTile(
                repo: repo,
                selected: selectedRepo?.id == repo.id,
                onTap: () => onSelect(repo),
              ),
            ),
          const Spacer(),
          Row(
            children: [
              const Flexible(
                child: InfoNote(
                  text: 'User first selects a local repository from a folder.',
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: onNext,
                iconAlignment: IconAlignment.end,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class RepositoryDashboard extends StatelessWidget {
  const RepositoryDashboard({
    required this.repo,
    required this.currentBranch,
    required this.currentBranchHistory,
    required this.currentChangedFiles,
    required this.currentCommitDraft,
    required this.commitDraftRevision,
    required this.repositories,
    required this.branches,
    required this.operations,
    required this.message,
    required this.busy,
    required this.latestRelease,
    required this.checkingUpdates,
    required this.autoCheckUpdates,
    required this.darkMode,
    required this.updateError,
    required this.syncAnimation,
    required this.checkoutBlocked,
    required this.leftPanelCollapsed,
    required this.rightPanelCollapsed,
    required this.cardSize,
    required this.onChooseFolder,
    required this.onChangeRepo,
    required this.onCardSizeChanged,
    required this.onCheckUpdates,
    required this.onOpenRelease,
    required this.onInstallUpdate,
    required this.onOpenGithubProfile,
    required this.onAutoCheckUpdatesChanged,
    required this.onDarkModeChanged,
    required this.onToggleLeftPanel,
    required this.onToggleRightPanel,
    required this.onEditBranches,
    required this.onRefresh,
    required this.onPull,
    required this.onCheckout,
    required this.onCommit,
    required this.onPush,
    required this.onUndoCommit,
    required this.onShowFileDiff,
    required this.onCommitFiles,
    required this.onDiscardFiles,
    required this.onSwapBranches,
    required this.onSyncBranches,
    super.key,
  });

  final RepositoryInfo repo;
  final String currentBranch;
  final List<CommitHistoryEntry> currentBranchHistory;
  final List<String> currentChangedFiles;
  final CommitDraft? currentCommitDraft;
  final int commitDraftRevision;
  final List<RepositoryInfo> repositories;
  final List<TrackedBranch> branches;
  final List<GitOperationResult> operations;
  final String? message;
  final bool busy;
  final ReleaseInfo? latestRelease;
  final bool checkingUpdates;
  final bool autoCheckUpdates;
  final bool darkMode;
  final String? updateError;
  final SyncAnimationState? syncAnimation;
  final bool checkoutBlocked;
  final bool leftPanelCollapsed;
  final bool rightPanelCollapsed;
  final double cardSize;
  final VoidCallback onChooseFolder;
  final ValueChanged<RepositoryInfo> onChangeRepo;
  final ValueChanged<double> onCardSizeChanged;
  final VoidCallback onCheckUpdates;
  final VoidCallback onOpenRelease;
  final VoidCallback onInstallUpdate;
  final VoidCallback onOpenGithubProfile;
  final ValueChanged<bool> onAutoCheckUpdatesChanged;
  final ValueChanged<bool> onDarkModeChanged;
  final VoidCallback onToggleLeftPanel;
  final VoidCallback onToggleRightPanel;
  final VoidCallback onEditBranches;
  final ValueChanged<TrackedBranch> onRefresh;
  final ValueChanged<TrackedBranch> onPull;
  final ValueChanged<TrackedBranch> onCheckout;
  final ValueChanged<TrackedBranch> onCommit;
  final ValueChanged<TrackedBranch> onPush;
  final ValueChanged<TrackedBranch> onUndoCommit;
  final ValueChanged<String> onShowFileDiff;
  final void Function(List<String> files, String message, String description)
  onCommitFiles;
  final ValueChanged<List<String>> onDiscardFiles;
  final void Function(TrackedBranch from, TrackedBranch to) onSwapBranches;
  final VoidCallback onSyncBranches;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 1200;
        final isMedium = constraints.maxWidth < 1450;
        final sidePanelWidth = isCompact
            ? 220.0
            : isMedium
            ? 260.0
            : 320.0;
        final gap = isMedium ? 12.0 : 22.0;
        final panelHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 720.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: panelHeight,
              child: leftPanelCollapsed
                  ? CollapsedSidePanel(
                      tooltip: 'Show branch history',
                      icon: Icons.history,
                      onExpand: onToggleLeftPanel,
                    )
                  : CurrentBranchHistoryPanel(
                      width: sidePanelWidth,
                      branchName: currentBranch,
                      commits: currentBranchHistory,
                      onCollapse: onToggleLeftPanel,
                    ),
            ),
            SizedBox(width: gap),
            Expanded(
              child: SizedBox(
                height: panelHeight,
                child: AppPanel(
                  padding: const EdgeInsets.fromLTRB(38, 38, 38, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.folder_outlined,
                            size: 42,
                            color: Color(0xFF5865F2),
                          ),
                          const SizedBox(width: 24),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  repo.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  repo.path,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: mutedTextColor(context),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                CurrentBranchInline(branchName: currentBranch),
                              ],
                            ),
                          ),
                          DropdownButton<RepositoryInfo>(
                            value: repo,
                            items: repositories
                                .map(
                                  (item) => DropdownMenuItem(
                                    value: item,
                                    child: Text(item.name),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value != null) onChangeRepo(value);
                            },
                          ),
                          const SizedBox(width: 12),
                          Tooltip(
                            message: darkMode
                                ? 'Switch to light mode'
                                : 'Switch to dark mode',
                            child: Switch(
                              value: darkMode,
                              onChanged: busy ? null : onDarkModeChanged,
                            ),
                          ),
                          Icon(
                            darkMode ? Icons.dark_mode : Icons.light_mode,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton.icon(
                            onPressed: busy ? null : onChooseFolder,
                            icon: const Icon(Icons.add),
                            label: const Text('Add Repo'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      UpdateStatusPanel(
                        latestRelease: latestRelease,
                        checking: checkingUpdates,
                        autoCheck: autoCheckUpdates,
                        error: updateError,
                        onCheck: onCheckUpdates,
                        onOpenRelease: onOpenRelease,
                        onInstallUpdate: onInstallUpdate,
                        onAutoCheckChanged: onAutoCheckUpdatesChanged,
                      ),
                      const Divider(height: 42),
                      LayoutBuilder(
                        builder: (context, toolbarConstraints) {
                          final controls = Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              BranchCardSizeSlider(
                                value: cardSize,
                                onChanged: busy ? null : onCardSizeChanged,
                              ),
                              OutlinedButton.icon(
                                onPressed: busy || branches.length < 2
                                    ? null
                                    : onSyncBranches,
                                icon: const Icon(Icons.merge_type),
                                label: const Text('Sync / Merge'),
                              ),
                              OutlinedButton.icon(
                                onPressed: busy ? null : onEditBranches,
                                icon: const Icon(Icons.tune),
                                label: const Text('Select Branches'),
                              ),
                            ],
                          );
                          final title = Text(
                            'Branches',
                            style: Theme.of(context).textTheme.titleLarge,
                          );
                          if (toolbarConstraints.maxWidth < 720) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                title,
                                const SizedBox(height: 12),
                                controls,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              title,
                              const Spacer(),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: controls,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 22),
                      if (branches.isEmpty)
                        const EmptyState(text: 'No branches selected yet.')
                      else
                        Expanded(
                          child: BranchGrid(
                            repo: repo,
                            branches: branches,
                            currentBranch: currentBranch,
                            checkoutBlocked: checkoutBlocked,
                            busy: busy,
                            cardSize: cardSize,
                            syncAnimation: syncAnimation,
                            onSwapBranches: onSwapBranches,
                            onRefresh: onRefresh,
                            onPull: onPull,
                            onCheckout: onCheckout,
                            onCommit: onCommit,
                            onPush: onPush,
                            onUndoCommit: onUndoCommit,
                          ),
                        ),
                      if (syncAnimation != null) ...[
                        const SizedBox(height: 12),
                        SyncMergeLegend(state: syncAnimation!),
                      ],
                      const SizedBox(height: 8),
                      DashboardFooter(
                        message: message,
                        operation: operations.isEmpty ? null : operations.first,
                        onOpenGithubProfile: onOpenGithubProfile,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: gap),
            SizedBox(
              height: panelHeight,
              child: rightPanelCollapsed
                  ? CollapsedSidePanel(
                      tooltip: 'Show uncommitted files',
                      icon: Icons.difference_outlined,
                      onExpand: onToggleRightPanel,
                    )
                  : CurrentChangesPanel(
                      width: sidePanelWidth,
                      branchName: currentBranch,
                      files: currentChangedFiles,
                      commitDraft: currentCommitDraft,
                      commitDraftRevision: commitDraftRevision,
                      busy: busy,
                      onOpenDiff: onShowFileDiff,
                      onCommitFiles: onCommitFiles,
                      onDiscardFiles: onDiscardFiles,
                      onCollapse: onToggleRightPanel,
                    ),
            ),
          ],
        );
      },
    );
  }
}

bool isDarkMode(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color surfaceColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFF111827) : Colors.white;

Color elevatedSurfaceColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFF182235) : Colors.white;

Color borderColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFF334155) : const Color(0xFFE0E5EE);

Color primaryTextColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFFF8FAFC) : const Color(0xFF1F2937);

Color mutedTextColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFFCBD5E1) : const Color(0xFF647086);

Color softTextColor(BuildContext context) =>
    isDarkMode(context) ? const Color(0xFF94A3B8) : const Color(0xFF8A94A6);

class BranchCard extends StatelessWidget {
  const BranchCard({
    required this.branch,
    required this.isCurrentBranch,
    required this.checkoutBlocked,
    required this.busy,
    required this.scale,
    required this.onRefresh,
    required this.onPull,
    required this.onCheckout,
    required this.onCommit,
    required this.onPush,
    required this.onUndoCommit,
    super.key,
  });

  final TrackedBranch branch;
  final bool isCurrentBranch;
  final bool checkoutBlocked;
  final bool busy;
  final double scale;
  final VoidCallback onRefresh;
  final VoidCallback onPull;
  final VoidCallback onCheckout;
  final VoidCallback onCommit;
  final VoidCallback onPush;
  final VoidCallback onUndoCommit;

  @override
  Widget build(BuildContext context) {
    final status = branch.lastStatus;
    final titleSize = 22.0 * scale;
    final bodySize = 16.0 * scale;
    final metaSize = 14.0 * scale;
    final padding = 24.0 * scale;
    final iconSize = 24.0 * scale;
    final actionIconSize = 24.0 * scale;
    final actionButtonSize = 40.0 * scale;
    final actionGap = 8.0 * scale;
    return Container(
      decoration: BoxDecoration(
        color: surfaceColor(context),
        border: Border.all(color: borderColor(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: EdgeInsets.all(padding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_tree_outlined,
                color: const Color(0xFF6D5DF2),
                size: iconSize,
              ),
              SizedBox(width: 16 * scale),
              Expanded(
                child: Text(
                  branch.branchName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: primaryTextColor(context),
                    fontSize: titleSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (isCurrentBranch) ...[
                SizedBox(width: 8 * scale),
                CurrentBranchBadge(scale: scale),
              ],
              IconButton(
                tooltip: 'Refresh',
                onPressed: busy ? null : onRefresh,
                iconSize: actionIconSize,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          SizedBox(height: 18 * scale),
          StatusBadge(status: status, scale: scale),
          SizedBox(height: 20 * scale),
          Text(
            'Last pull: ${formatRelative(branch.lastPullAt)}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: bodySize,
              color: mutedTextColor(context),
            ),
          ),
          SizedBox(height: 8 * scale),
          Text(
            'Checked: ${formatRelative(status?.lastCheckedAt)}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: metaSize, color: softTextColor(context)),
          ),
          SizedBox(height: 8 * scale),
          Text(
            'Commit: ${formatCommit(status)}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metaSize,
              color: mutedTextColor(context),
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            '${status?.changedFilesCount ?? 0} uncommitted ${status?.changedFilesCount == 1 ? 'change' : 'changes'}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: metaSize,
              color: (status?.hasLocalChanges ?? false)
                  ? const Color(0xFFDD8500)
                  : mutedTextColor(context),
              fontWeight: (status?.hasLocalChanges ?? false)
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
          const Spacer(),
          LayoutBuilder(
            builder: (context, actionConstraints) {
              final compactGap = math.min(
                actionGap,
                math.max(2.0, actionConstraints.maxWidth / 70),
              );
              final maxButtonSize =
                  (actionConstraints.maxWidth - (compactGap * 4)) / 5;
              final buttonSize = math.min(
                actionButtonSize,
                math.max(18.0, maxButtonSize),
              );
              final iconSize = math.min(
                actionIconSize,
                math.max(12.0, buttonSize * 0.62),
              );
              Widget tonalAction({
                required String tooltip,
                required VoidCallback? onPressed,
                required IconData icon,
              }) {
                return SizedBox.square(
                  dimension: buttonSize,
                  child: IconButton.filledTonal(
                    tooltip: tooltip,
                    onPressed: onPressed,
                    iconSize: iconSize,
                    padding: EdgeInsets.zero,
                    icon: Icon(icon),
                  ),
                );
              }

              return Row(
                children: [
                  tonalAction(
                    tooltip: 'Pull',
                    onPressed: busy || !isCurrentBranch ? null : onPull,
                    icon: Icons.download,
                  ),
                  SizedBox(width: compactGap),
                  tonalAction(
                    tooltip: 'Commit',
                    onPressed: busy || !isCurrentBranch ? null : onCommit,
                    icon: Icons.add_task,
                  ),
                  SizedBox(width: compactGap),
                  tonalAction(
                    tooltip: 'Undo last commit',
                    onPressed: busy || !isCurrentBranch ? null : onUndoCommit,
                    icon: Icons.undo,
                  ),
                  SizedBox(width: compactGap),
                  tonalAction(
                    tooltip: 'Push',
                    onPressed: busy || !isCurrentBranch ? null : onPush,
                    icon: Icons.upload,
                  ),
                  const Spacer(),
                  SizedBox.square(
                    dimension: buttonSize,
                    child: IconButton.filled(
                      tooltip: isCurrentBranch
                          ? 'Already checked out'
                          : checkoutBlocked
                          ? 'Checkout with uncommitted changes'
                          : 'Checkout branch',
                      onPressed: busy || isCurrentBranch ? null : onCheckout,
                      iconSize: iconSize,
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.login),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class CurrentBranchHistoryPanel extends StatelessWidget {
  const CurrentBranchHistoryPanel({
    required this.width,
    required this.branchName,
    required this.commits,
    required this.onCollapse,
    super.key,
  });

  final double width;
  final String branchName;
  final List<CommitHistoryEntry> commits;
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: surfaceColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor(context)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0B1B3B),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                const Icon(Icons.history, color: Color(0xFF5865F2), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current branch history',
                        style: TextStyle(
                          color: primaryTextColor(context),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        branchName.isEmpty ? 'No branch selected' : branchName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedTextColor(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Collapse history',
                  onPressed: onCollapse,
                  icon: const Icon(Icons.keyboard_double_arrow_left),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: borderColor(context)),
          Expanded(
            child: commits.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        'No commits found for the current branch.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: mutedTextColor(context)),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    itemCount: commits.length,
                    itemBuilder: (context, index) {
                      return CommitHistoryTile(
                        commit: commits[index],
                        isLatest: index == 0,
                        isLast: index == commits.length - 1,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class CommitHistoryTile extends StatelessWidget {
  const CommitHistoryTile({
    required this.commit,
    required this.isLatest,
    required this.isLast,
    super.key,
  });

  final CommitHistoryEntry commit;
  final bool isLatest;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 18,
            child: Column(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isLatest
                        ? const Color(0xFFF59E0B)
                        : const Color(0xFF60A5FA),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: surfaceColor(context),
                      width: 1.5,
                    ),
                  ),
                ),
                if (!isLast)
                  const Expanded(
                    child: VerticalDivider(
                      color: Color(0xFF93C5FD),
                      width: 1,
                      thickness: 1,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          commit.message.isEmpty
                              ? '(no commit message)'
                              : commit.message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: primaryTextColor(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        commit.shortHash,
                        style: TextStyle(
                          color: softTextColor(context),
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${commit.author} · ${commit.relativeTime}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: mutedTextColor(context),
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CollapsedSidePanel extends StatelessWidget {
  const CollapsedSidePanel({
    required this.tooltip,
    required this.icon,
    required this.onExpand,
    super.key,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: surfaceColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor(context)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0B1B3B),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Tooltip(
            message: tooltip,
            child: IconButton(
              onPressed: onExpand,
              icon: Icon(icon, color: const Color(0xFF5865F2), size: 18),
            ),
          ),
        ),
      ),
    );
  }
}

class CurrentChangesPanel extends StatefulWidget {
  const CurrentChangesPanel({
    required this.width,
    required this.branchName,
    required this.files,
    required this.commitDraft,
    required this.commitDraftRevision,
    required this.busy,
    required this.onOpenDiff,
    required this.onCommitFiles,
    required this.onDiscardFiles,
    required this.onCollapse,
    super.key,
  });

  final double width;
  final String branchName;
  final List<String> files;
  final CommitDraft? commitDraft;
  final int commitDraftRevision;
  final bool busy;
  final ValueChanged<String> onOpenDiff;
  final void Function(List<String> files, String message, String description)
  onCommitFiles;
  final ValueChanged<List<String>> onDiscardFiles;
  final VoidCallback onCollapse;

  @override
  State<CurrentChangesPanel> createState() => _CurrentChangesPanelState();
}

class _CurrentChangesPanelState extends State<CurrentChangesPanel> {
  final _filterController = TextEditingController();
  final _messageController = TextEditingController();
  final _descriptionController = TextEditingController();
  var _selectedFiles = <String>{};

  @override
  void initState() {
    super.initState();
    _selectedFiles = {...widget.files};
  }

  @override
  void didUpdateWidget(covariant CurrentChangesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.branchName != widget.branchName ||
        oldWidget.commitDraftRevision != widget.commitDraftRevision) {
      _messageController.text = widget.commitDraft?.message ?? '';
      _descriptionController.text = widget.commitDraft?.description ?? '';
    }
    final currentFiles = widget.files.toSet();
    _selectedFiles = _selectedFiles
        .where((file) => currentFiles.contains(file))
        .toSet();
    if (oldWidget.files.length != widget.files.length &&
        _selectedFiles.isEmpty) {
      _selectedFiles = {...widget.files};
    }
  }

  @override
  void dispose() {
    _filterController.dispose();
    _messageController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _toggleAll(bool checked, List<String> visibleFiles) {
    setState(() {
      if (checked) {
        _selectedFiles.addAll(visibleFiles);
      } else {
        _selectedFiles.removeAll(visibleFiles);
      }
    });
  }

  void _toggleFile(String file, bool checked) {
    setState(() {
      if (checked) {
        _selectedFiles.add(file);
      } else {
        _selectedFiles.remove(file);
      }
    });
  }

  void _commitSelected() {
    widget.onCommitFiles(
      _selectedFiles.toList(),
      _messageController.text,
      _descriptionController.text,
    );
  }

  void _discardSelected() {
    widget.onDiscardFiles(_selectedFiles.toList());
  }

  void _discardAll() {
    widget.onDiscardFiles(widget.files);
  }

  @override
  Widget build(BuildContext context) {
    final filter = _filterController.text.trim().toLowerCase();
    final visibleFiles = filter.isEmpty
        ? widget.files
        : widget.files
              .where((file) => file.toLowerCase().contains(filter))
              .toList();
    final selectedCount = _selectedFiles.length;
    final allVisibleSelected =
        visibleFiles.isNotEmpty &&
        visibleFiles.every((file) => _selectedFiles.contains(file));
    final canCommit =
        !widget.busy &&
        selectedCount > 0 &&
        _messageController.text.trim().isNotEmpty;
    final canDiscard = !widget.busy && selectedCount > 0;

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: surfaceColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor(context)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0F0B1B3B),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                const Icon(
                  Icons.difference_outlined,
                  color: Color(0xFF5865F2),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uncommitted files',
                        style: TextStyle(
                          color: primaryTextColor(context),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.branchName.isEmpty
                            ? 'No branch selected'
                            : '${widget.branchName} | ${widget.files.length} ${widget.files.length == 1 ? 'file' : 'files'}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: mutedTextColor(context),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Collapse uncommitted files',
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.keyboard_double_arrow_right),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: borderColor(context)),
          Expanded(
            child: widget.files.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Text(
                        'No uncommitted files on the current branch.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: mutedTextColor(context)),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
                    itemCount: visibleFiles.length + 2,
                    separatorBuilder: (context, index) =>
                        Divider(height: 1, color: borderColor(context)),
                    itemBuilder: (context, index) {
                      if (index == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: TextField(
                            controller: _filterController,
                            enabled: !widget.busy,
                            decoration: const InputDecoration(
                              isDense: true,
                              prefixIcon: Icon(Icons.filter_list, size: 18),
                              labelText: 'Filter',
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        );
                      }
                      if (index == 1) {
                        return CheckboxListTile(
                          dense: true,
                          value: allVisibleSelected,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(
                            '$selectedCount selected of ${widget.files.length}',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: primaryTextColor(context),
                            ),
                          ),
                          onChanged: visibleFiles.isEmpty || widget.busy
                              ? null
                              : (checked) =>
                                    _toggleAll(checked ?? false, visibleFiles),
                        );
                      }
                      final file = visibleFiles[index - 2];
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        enabled: !widget.busy,
                        leading: Checkbox(
                          value: _selectedFiles.contains(file),
                          onChanged: widget.busy
                              ? null
                              : (checked) =>
                                    _toggleFile(file, checked ?? false),
                        ),
                        title: Text(
                          file,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: primaryTextColor(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right, size: 18),
                        onTap: widget.busy
                            ? null
                            : () => widget.onOpenDiff(file),
                      );
                    },
                  ),
          ),
          Divider(height: 1, color: borderColor(context)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _messageController,
                  enabled: !widget.busy,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Commit message',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _descriptionController,
                  enabled: !widget.busy,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    alignLabelWithHint: true,
                    labelText: 'Description',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: canDiscard ? _discardSelected : null,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Discard'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: 'Discard all',
                      onPressed: widget.busy || widget.files.isEmpty
                          ? null
                          : _discardAll,
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: canCommit ? _commitSelected : null,
                    icon: const Icon(Icons.check),
                    label: Text(
                      selectedCount == widget.files.length
                          ? 'Commit all to ${widget.branchName}'
                          : 'Commit $selectedCount file${selectedCount == 1 ? '' : 's'}',
                      overflow: TextOverflow.ellipsis,
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

class DiffDialog extends StatelessWidget {
  const DiffDialog({required this.filePath, required this.diff, super.key});

  final String filePath;
  final String diff;

  @override
  Widget build(BuildContext context) {
    final lines = diff.trim().isEmpty
        ? const ['No diff available.']
        : diff.replaceAll('\r\n', '\n').split('\n');
    return AlertDialog(
      title: Text(filePath, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 980,
        height: 620,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFF1F242B),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 1180,
                child: Scrollbar(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    itemCount: lines.length,
                    itemBuilder: (context, index) {
                      return DiffLineRow(
                        lineNumber: index + 1,
                        text: lines[index],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class DiffLineRow extends StatelessWidget {
  const DiffLineRow({required this.lineNumber, required this.text, super.key});

  final int lineNumber;
  final String text;

  @override
  Widget build(BuildContext context) {
    final type = _DiffLineType.from(text);
    return Container(
      color: type.background,
      constraints: const BoxConstraints(minHeight: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 62,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            color: type.gutter,
            alignment: Alignment.centerRight,
            child: Text(
              '$lineNumber',
              style: const TextStyle(
                color: Color(0xFF9CA3AF),
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
          ),
          Container(
            width: 28,
            padding: const EdgeInsets.symmetric(vertical: 4),
            color: type.gutter,
            alignment: Alignment.center,
            child: Text(
              type.marker,
              style: TextStyle(
                color: type.foreground,
                fontFamily: 'Consolas',
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: SelectableText(
                text,
                style: TextStyle(
                  color: type.foreground,
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  height: 1.35,
                  fontWeight: type.isHeader ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DiffLineKind { added, removed, hunk, header, context }

class _DiffLineType {
  const _DiffLineType({
    required this.kind,
    required this.background,
    required this.gutter,
    required this.foreground,
    required this.marker,
  });

  final _DiffLineKind kind;
  final Color background;
  final Color gutter;
  final Color foreground;
  final String marker;

  bool get isHeader =>
      kind == _DiffLineKind.header || kind == _DiffLineKind.hunk;

  static _DiffLineType from(String line) {
    if (line.startsWith('+') && !line.startsWith('+++')) {
      return const _DiffLineType(
        kind: _DiffLineKind.added,
        background: Color(0xFF123D22),
        gutter: Color(0xFF0F2F1B),
        foreground: Color(0xFFE8FFF0),
        marker: '+',
      );
    }
    if (line.startsWith('-') && !line.startsWith('---')) {
      return const _DiffLineType(
        kind: _DiffLineKind.removed,
        background: Color(0xFF4A1018),
        gutter: Color(0xFF350C12),
        foreground: Color(0xFFFFE8EA),
        marker: '-',
      );
    }
    if (line.startsWith('@@')) {
      return const _DiffLineType(
        kind: _DiffLineKind.hunk,
        background: Color(0xFF2A3038),
        gutter: Color(0xFF222831),
        foreground: Color(0xFFB7C7E6),
        marker: '',
      );
    }
    if (line.startsWith('diff --git') ||
        line.startsWith('index ') ||
        line.startsWith('---') ||
        line.startsWith('+++') ||
        line.startsWith('Untracked file:')) {
      return const _DiffLineType(
        kind: _DiffLineKind.header,
        background: Color(0xFF252B33),
        gutter: Color(0xFF20262D),
        foreground: Color(0xFFE5E7EB),
        marker: '',
      );
    }
    return const _DiffLineType(
      kind: _DiffLineKind.context,
      background: Color(0xFF1F242B),
      gutter: Color(0xFF1A1F25),
      foreground: Color(0xFFD1D5DB),
      marker: '',
    );
  }
}

class FooterCredit extends StatelessWidget {
  const FooterCredit({
    required this.onOpenGithubProfile,
    this.compact = false,
    super.key,
  });

  final VoidCallback onOpenGithubProfile;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onOpenGithubProfile,
      style: TextButton.styleFrom(
        minimumSize: Size(0, compact ? 28 : 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 6 : 12,
          vertical: compact ? 2 : 8,
        ),
      ),
      icon: GitHubMark(size: compact ? 14 : 18),
      label: Text(
        'Made with <3 MAK',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isDarkMode(context)
              ? const Color(0xFF94A3B8)
              : const Color(0xFF344160),
          fontSize: compact ? 12 : null,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class DashboardFooter extends StatelessWidget {
  const DashboardFooter({
    required this.message,
    required this.operation,
    required this.onOpenGithubProfile,
    super.key,
  });

  final String? message;
  final GitOperationResult? operation;
  final VoidCallback onOpenGithubProfile;

  @override
  Widget build(BuildContext context) {
    final operationText = operation == null
        ? null
        : 'Last operation: ${operation!.operation} '
              '${operation!.success ? 'succeeded' : 'failed'}';
    final statusParts = [
      if (message != null && message!.trim().isNotEmpty) message!.trim(),
      ?operationText,
    ];

    return SizedBox(
      height: 30,
      child: Row(
        children: [
          Expanded(
            child: Text(
              statusParts.join('  |  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: mutedTextColor(context),
                fontSize: 12,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FooterCredit(compact: true, onOpenGithubProfile: onOpenGithubProfile),
        ],
      ),
    );
  }
}

class GitHubMark extends StatelessWidget {
  const GitHubMark({required this.size, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: const GitHubMarkPainter(),
    );
  }
}

class GitHubMarkPainter extends CustomPainter {
  const GitHubMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF24292F)
      ..style = PaintingStyle.fill;
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, paint);

    final white = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final headRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + radius * 0.08),
      width: radius * 1.16,
      height: radius * 0.86,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(headRect, Radius.circular(radius * 0.32)),
      white,
    );
    canvas.drawCircle(
      Offset(center.dx - radius * 0.42, center.dy - radius * 0.35),
      radius * 0.24,
      white,
    );
    canvas.drawCircle(
      Offset(center.dx + radius * 0.42, center.dy - radius * 0.35),
      radius * 0.24,
      white,
    );

    final cutout = Paint()
      ..color = const Color(0xFF24292F)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(center.dx - radius * 0.23, center.dy - radius * 0.02),
      radius * 0.08,
      cutout,
    );
    canvas.drawCircle(
      Offset(center.dx + radius * 0.23, center.dy - radius * 0.02),
      radius * 0.08,
      cutout,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(center.dx, center.dy + radius * 0.58),
        width: radius * 0.28,
        height: radius * 0.42,
      ),
      white,
    );
  }

  @override
  bool shouldRepaint(covariant GitHubMarkPainter oldDelegate) => false;
}

class BranchGrid extends StatefulWidget {
  const BranchGrid({
    required this.repo,
    required this.branches,
    required this.currentBranch,
    required this.checkoutBlocked,
    required this.busy,
    required this.cardSize,
    required this.syncAnimation,
    required this.onSwapBranches,
    required this.onRefresh,
    required this.onPull,
    required this.onCheckout,
    required this.onCommit,
    required this.onPush,
    required this.onUndoCommit,
    super.key,
  });

  final RepositoryInfo repo;
  final List<TrackedBranch> branches;
  final String currentBranch;
  final bool checkoutBlocked;
  final bool busy;
  final double cardSize;
  final SyncAnimationState? syncAnimation;
  final void Function(TrackedBranch from, TrackedBranch to) onSwapBranches;
  final ValueChanged<TrackedBranch> onRefresh;
  final ValueChanged<TrackedBranch> onPull;
  final ValueChanged<TrackedBranch> onCheckout;
  final ValueChanged<TrackedBranch> onCommit;
  final ValueChanged<TrackedBranch> onPush;
  final ValueChanged<TrackedBranch> onUndoCommit;

  @override
  State<BranchGrid> createState() => _BranchGridState();
}

class _BranchGridState extends State<BranchGrid> {
  final _cardKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(covariant BranchGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final branchNames = widget.branches
        .map((branch) => branch.branchName)
        .toSet();
    _cardKeys.removeWhere(
      (branchName, key) => !branchNames.contains(branchName),
    );
  }

  GlobalKey _keyFor(String branchName) {
    return _cardKeys.putIfAbsent(branchName, GlobalKey.new);
  }

  @override
  Widget build(BuildContext context) {
    final scale = (widget.cardSize / 360).clamp(0.62, 1.28).toDouble();
    return Stack(
      children: [
        GridView.builder(
          itemCount: widget.branches.length,
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: widget.cardSize,
            mainAxisExtent: widget.cardSize,
            crossAxisSpacing: 24,
            mainAxisSpacing: 24,
          ),
          itemBuilder: (context, index) {
            final branch = widget.branches[index];
            return KeyedSubtree(
              key: _keyFor(branch.branchName),
              child: BranchCardDropZone(
                branch: branch,
                busy: widget.busy,
                onSwap: (from) => widget.onSwapBranches(from, branch),
                child: BranchCard(
                  branch: branch,
                  isCurrentBranch: branch.branchName == widget.currentBranch,
                  checkoutBlocked: widget.checkoutBlocked,
                  busy: widget.busy,
                  scale: scale,
                  onRefresh: () => widget.onRefresh(branch),
                  onPull: () => widget.onPull(branch),
                  onCheckout: () => widget.onCheckout(branch),
                  onCommit: () => widget.onCommit(branch),
                  onPush: () => widget.onPush(branch),
                  onUndoCommit: () => widget.onUndoCommit(branch),
                ),
              ),
            );
          },
        ),
        if (widget.syncAnimation != null)
          Positioned.fill(
            child: SyncMergeOverlay(
              cardKeys: _cardKeys,
              state: widget.syncAnimation!,
              cardHeight: widget.cardSize,
            ),
          ),
      ],
    );
  }
}

class BranchCardDropZone extends StatefulWidget {
  const BranchCardDropZone({
    required this.branch,
    required this.busy,
    required this.onSwap,
    required this.child,
    super.key,
  });

  final TrackedBranch branch;
  final bool busy;
  final ValueChanged<TrackedBranch> onSwap;
  final Widget child;

  @override
  State<BranchCardDropZone> createState() => _BranchCardDropZoneState();
}

class _BranchCardDropZoneState extends State<BranchCardDropZone> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final draggable = LongPressDraggable<TrackedBranch>(
      data: widget.branch,
      delay: const Duration(milliseconds: 180),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 300,
          child: Opacity(opacity: 0.86, child: widget.child),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.42, child: widget.child),
      child: widget.child,
    );

    return DragTarget<TrackedBranch>(
      onWillAcceptWithDetails: (details) {
        final accepts =
            !widget.busy &&
            details.data.repoId == widget.branch.repoId &&
            details.data.branchName != widget.branch.branchName;
        setState(() => _hovering = accepts);
        return accepts;
      },
      onLeave: (_) => setState(() => _hovering = false),
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onSwap(details.data);
      },
      builder: (context, candidateData, rejectedData) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            border: Border.all(
              color: _hovering ? const Color(0xFF5865F2) : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: EdgeInsets.all(_hovering ? 3 : 0),
          child: widget.busy ? widget.child : draggable,
        );
      },
    );
  }
}

class SyncAnimationState {
  const SyncAnimationState({
    required this.targetBranch,
    required this.sourceBranches,
    required this.bothDirections,
    required this.activeFromBranch,
    required this.activeToBranch,
    required this.completedSteps,
  });

  final String targetBranch;
  final List<String> sourceBranches;
  final bool bothDirections;
  final String? activeFromBranch;
  final String? activeToBranch;
  final List<SyncAnimationStep> completedSteps;

  bool includes(String branchName) =>
      branchName == targetBranch || sourceBranches.contains(branchName);

  List<String> get orderedBranches => [targetBranch, ...sourceBranches];

  String get label => bothDirections
      ? orderedBranches.join(' <-> ')
      : '${sourceBranches.join(' -> ')} -> $targetBranch';

  String get activeLabel => activeFromBranch == null || activeToBranch == null
      ? 'Preparing sync'
      : 'Merging $activeFromBranch -> $activeToBranch';
}

class SyncAnimationStep {
  const SyncAnimationStep(this.fromBranch, this.toBranch);

  final String fromBranch;
  final String toBranch;
}

class SyncMergeOverlay extends StatefulWidget {
  const SyncMergeOverlay({
    required this.cardKeys,
    required this.state,
    required this.cardHeight,
    super.key,
  });

  final Map<String, GlobalKey> cardKeys;
  final SyncAnimationState state;
  final double cardHeight;

  @override
  State<SyncMergeOverlay> createState() => _SyncMergeOverlayState();
}

class _SyncMergeOverlayState extends State<SyncMergeOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: SyncMergePainter(
            centers: _cardCenters(context),
            state: widget.state,
            cardHeight: widget.cardHeight,
            progress: _controller.value,
          ),
        ),
      ),
    );
  }

  Map<String, Offset> _cardCenters(BuildContext context) {
    final overlayBox = context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return const {};

    final centers = <String, Offset>{};
    for (final entry in widget.cardKeys.entries) {
      final cardContext = entry.value.currentContext;
      final cardBox = cardContext?.findRenderObject() as RenderBox?;
      if (cardBox == null || !cardBox.hasSize) continue;

      final globalCenter = cardBox.localToGlobal(
        cardBox.size.center(Offset.zero),
      );
      centers[entry.key] = overlayBox.globalToLocal(globalCenter);
    }
    return centers;
  }
}

class SyncMergePainter extends CustomPainter {
  const SyncMergePainter({
    required this.centers,
    required this.state,
    required this.cardHeight,
    required this.progress,
  });

  final Map<String, Offset> centers;
  final SyncAnimationState state;
  final double cardHeight;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (centers.length < 2 || size.width <= 0) return;
    for (final step in state.completedSteps) {
      _drawLink(
        canvas,
        centers,
        from: step.fromBranch,
        to: step.toBranch,
        progress: 1,
        active: false,
      );
    }

    if (state.activeFromBranch != null && state.activeToBranch != null) {
      _drawLink(
        canvas,
        centers,
        from: state.activeFromBranch!,
        to: state.activeToBranch!,
        progress: progress,
        active: true,
      );
    }
  }

  void _drawLink(
    Canvas canvas,
    Map<String, Offset> centers, {
    required String from,
    required String to,
    required double progress,
    required bool active,
  }) {
    final source = centers[from];
    final destination = centers[to];
    if (source == null || destination == null || source == destination) return;

    final linePaint = Paint()
      ..color = (active ? const Color(0xFF5865F2) : const Color(0xFF8A94A6))
          .withValues(alpha: active ? 0.72 : 0.26)
      ..strokeWidth = active ? 4 : 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()
      ..color = active ? const Color(0xFF5865F2) : const Color(0xFF8A94A6)
      ..style = PaintingStyle.fill;
    final sourcePaint = Paint()
      ..color = const Color(0xFFDD8500).withValues(alpha: active ? 0.22 : 0.08)
      ..style = PaintingStyle.fill;
    final targetPaint = Paint()
      ..color = const Color(0xFF0EA044).withValues(alpha: active ? 0.20 : 0.08)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(source, active ? 28 + 5 * progress : 18, sourcePaint);
    canvas.drawCircle(
      destination,
      active ? 32 + 8 * progress : 20,
      targetPaint,
    );

    final verticalDelta = (source.dy - destination.dy).abs();
    final controlLift = verticalDelta > cardHeight * 0.4 ? 20 : 56;
    final control = Offset(
      (source.dx + destination.dx) / 2,
      (source.dy + destination.dy) / 2 - controlLift,
    );
    final path = Path()
      ..moveTo(source.dx, source.dy)
      ..quadraticBezierTo(
        control.dx,
        control.dy,
        destination.dx,
        destination.dy,
      );
    canvas.drawPath(path, linePaint);

    if (!active) return;
    for (var dot = 0; dot < 3; dot++) {
      final t = (progress + dot / 3) % 1;
      final point = _quadraticPoint(source, control, destination, t);
      canvas.drawCircle(point, 6, dotPaint);
    }
  }

  Offset _quadraticPoint(Offset start, Offset control, Offset end, double t) {
    final inverse = 1 - t;
    return Offset(
      inverse * inverse * start.dx +
          2 * inverse * t * control.dx +
          t * t * end.dx,
      inverse * inverse * start.dy +
          2 * inverse * t * control.dy +
          t * t * end.dy,
    );
  }

  @override
  bool shouldRepaint(covariant SyncMergePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.centers != centers ||
        oldDelegate.state != state ||
        oldDelegate.cardHeight != cardHeight;
  }
}

class SyncMergeLegend extends StatelessWidget {
  const SyncMergeLegend({required this.state, super.key});

  final SyncAnimationState state;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFEEF1FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.sync, size: 18, color: Color(0xFF5865F2)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.activeLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF344160),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    state.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF647086),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BranchCardSizeSlider extends StatelessWidget {
  const BranchCardSizeSlider({
    required this.value,
    required this.onChanged,
    super.key,
  });

  final double value;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          const Tooltip(
            message: 'Smaller boxes',
            child: Icon(Icons.crop_square, size: 18, color: Color(0xFF647086)),
          ),
          Expanded(
            child: Slider(
              value: value,
              min: 220,
              max: 480,
              divisions: 13,
              label: '${value.round()} px',
              onChanged: onChanged,
            ),
          ),
          const Tooltip(
            message: 'Larger boxes',
            child: Icon(
              Icons.check_box_outline_blank,
              color: Color(0xFF647086),
            ),
          ),
        ],
      ),
    );
  }
}

class UpdateStatusPanel extends StatelessWidget {
  const UpdateStatusPanel({
    required this.latestRelease,
    required this.checking,
    required this.autoCheck,
    required this.error,
    required this.onCheck,
    required this.onOpenRelease,
    required this.onInstallUpdate,
    required this.onAutoCheckChanged,
    super.key,
  });

  final ReleaseInfo? latestRelease;
  final bool checking;
  final bool autoCheck;
  final String? error;
  final VoidCallback onCheck;
  final VoidCallback onOpenRelease;
  final VoidCallback onInstallUpdate;
  final ValueChanged<bool> onAutoCheckChanged;

  @override
  Widget build(BuildContext context) {
    final release = latestRelease;
    final hasUpdate = release?.isNewerThanCurrent ?? false;
    final statusText = error != null
        ? 'Check failed'
        : checking
        ? 'Checking'
        : hasUpdate
        ? 'Update available'
        : release == null
        ? 'Not checked'
        : 'Up to date';
    final statusColor = error != null
        ? const Color(0xFFCF3030)
        : hasUpdate
        ? const Color(0xFFDD8500)
        : const Color(0xFF0EA044);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: elevatedSurfaceColor(context),
        border: Border.all(color: borderColor(context)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.system_update_alt, color: statusColor),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                spacing: 18,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  VersionPair(
                    label: 'Current',
                    value: 'v$appVersion',
                    strong: true,
                  ),
                  VersionPair(
                    label: 'Latest',
                    value: release == null ? '-' : 'v${release.version}',
                    strong: hasUpdate,
                  ),
                  StatusPill(text: statusText, color: statusColor),
                  if (error != null)
                    Text(
                      error!,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFCF3030)),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Auto check',
                  style: TextStyle(color: Color(0xFF647086)),
                ),
                Switch(
                  value: autoCheck,
                  onChanged: checking ? null : onAutoCheckChanged,
                ),
                IconButton(
                  tooltip: 'Check for updates',
                  onPressed: checking ? null : onCheck,
                  icon: checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
                FilledButton.icon(
                  onPressed:
                      hasUpdate && release?.preferredAsset != null && !checking
                      ? onInstallUpdate
                      : null,
                  icon: const Icon(Icons.download_for_offline),
                  label: const Text('Install'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: release?.url.isEmpty ?? true
                      ? null
                      : onOpenRelease,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Release'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class VersionPair extends StatelessWidget {
  const VersionPair({
    required this.label,
    required this.value,
    required this.strong,
    super.key,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: const TextStyle(color: Color(0xFF647086))),
        Text(
          value,
          style: TextStyle(
            color: const Color(0xFF0B1736),
            fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class UpdateInstallDialog extends StatefulWidget {
  const UpdateInstallDialog({
    required this.release,
    required this.asset,
    required this.updateService,
    required this.onOpenFile,
    super.key,
  });

  final ReleaseInfo release;
  final ReleaseAsset asset;
  final UpdateService updateService;
  final Future<void> Function(FileSystemEntity file) onOpenFile;

  @override
  State<UpdateInstallDialog> createState() => _UpdateInstallDialogState();
}

class _UpdateInstallDialogState extends State<UpdateInstallDialog> {
  UpdateDownloadProgress? _progress;
  File? _downloadedFile;
  String? _error;
  var _downloading = false;
  var _opening = false;

  @override
  void initState() {
    super.initState();
    unawaited(_download());
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
    });
    try {
      final file = await widget.updateService.downloadAsset(
        widget.asset,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _downloadedFile = file);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
      }
    }
  }

  Future<void> _openDownloaded() async {
    final file = _downloadedFile;
    if (file == null) return;
    setState(() => _opening = true);
    try {
      await widget.onOpenFile(file);
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _opening = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    final fraction = progress?.fraction;
    final percent = fraction == null ? '' : '${(fraction * 100).round()}%';
    final sizeText = progress == null
        ? formatBytes(widget.asset.size)
        : '${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes > 0 ? progress.totalBytes : widget.asset.size)}';

    return AlertDialog(
      title: Text('Install update v${widget.release.version}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.asset.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              'Downloaded from GitHub Releases',
              style: TextStyle(color: mutedTextColor(context)),
            ),
            const SizedBox(height: 18),
            LinearProgressIndicator(value: fraction),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _downloadedFile == null
                      ? 'Downloading $percent'
                      : 'Download complete',
                  style: TextStyle(color: mutedTextColor(context)),
                ),
                const Spacer(),
                Text(
                  sizeText,
                  style: TextStyle(color: mutedTextColor(context)),
                ),
              ],
            ),
            if (_downloadedFile != null) ...[
              const SizedBox(height: 14),
              SelectableText(
                _downloadedFile!.path,
                style: TextStyle(color: mutedTextColor(context), fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!, style: const TextStyle(color: Color(0xFFCF3030))),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _downloading ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (_error != null)
          OutlinedButton.icon(
            onPressed: _downloading ? null : _download,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        FilledButton.icon(
          onPressed: _downloadedFile == null || _opening
              ? null
              : _openDownloaded,
          icon: const Icon(Icons.install_desktop),
          label: Text(_opening ? 'Restarting' : 'Install and restart'),
        ),
      ],
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({required this.text, required this.color, super.key});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: TextStyle(color: color, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, this.scale = 1, super.key});

  final BranchStatus? status;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final text = status?.label ?? 'Not checked';
    final color = switch (text) {
      'Up to date' => const Color(0xFF0EA044),
      'Local changes' => const Color(0xFF3154D4),
      'Error' || 'Conflicts' || 'Diverged' => const Color(0xFFCF3030),
      _ => const Color(0xFFDD8500),
    };
    return Tooltip(
      message: status?.error ?? text,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8 * scale),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 12 * scale,
            vertical: 8 * scale,
          ),
          child: Text(
            text,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 14 * scale,
            ),
          ),
        ),
      ),
    );
  }
}

class CurrentBranchInline extends StatelessWidget {
  const CurrentBranchInline({required this.branchName, super.key});

  final String branchName;

  @override
  Widget build(BuildContext context) {
    final text = branchName.isEmpty
        ? 'Current branch: detached or unknown'
        : 'Current branch: $branchName';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.adjust, size: 16, color: Color(0xFF0EA044)),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF445064),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class CurrentBranchBadge extends StatelessWidget {
  const CurrentBranchBadge({this.scale = 1, super.key});

  final double scale;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0EA044).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 8 * scale,
          vertical: 4 * scale,
        ),
        child: Text(
          'Current',
          style: TextStyle(
            color: const Color(0xFF0EA044),
            fontWeight: FontWeight.w700,
            fontSize: 12 * scale,
          ),
        ),
      ),
    );
  }
}

class BranchSelectorDialog extends StatefulWidget {
  const BranchSelectorDialog({
    required this.repo,
    required this.branches,
    required this.selectedBranches,
    required this.currentBranch,
    required this.onFetchBranches,
    super.key,
  });

  final RepositoryInfo repo;
  final List<String> branches;
  final Set<String> selectedBranches;
  final String currentBranch;
  final Future<List<String>> Function() onFetchBranches;

  @override
  State<BranchSelectorDialog> createState() => _BranchSelectorDialogState();
}

class _BranchSelectorDialogState extends State<BranchSelectorDialog> {
  late final Set<String> _selected = {...widget.selectedBranches};
  late List<String> _branches = [...widget.branches];
  var _fetching = false;
  String? _error;

  Future<void> _fetchBranches() async {
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final branches = await widget.onFetchBranches();
      if (!mounted) return;
      setState(() => _branches = branches);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _fetching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Select branches for ${widget.repo.name}'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_branches.length} branches available',
                    style: const TextStyle(color: Color(0xFF647086)),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _fetching ? null : _fetchBranches,
                  icon: _fetching
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: const Text('Fetch Branches'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFCF3030))),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: _branches.isEmpty
                  ? const Text('No branches found. Fetch to refresh remotes.')
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final branch in _branches)
                          CheckboxListTile(
                            value: _selected.contains(branch),
                            title: Row(
                              children: [
                                Expanded(child: Text(branch)),
                                if (branch == widget.currentBranch)
                                  const CurrentBranchBadge(),
                              ],
                            ),
                            secondary: const Icon(Icons.account_tree_outlined),
                            onChanged: (checked) {
                              setState(() {
                                if (checked ?? false) {
                                  _selected.add(branch);
                                } else {
                                  _selected.remove(branch);
                                }
                              });
                            },
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop([
            for (final branch in _branches)
              if (_selected.contains(branch)) branch,
          ]),
          child: const Text('Track Selected'),
        ),
      ],
    );
  }
}

class SyncMergeDialog extends StatefulWidget {
  const SyncMergeDialog({
    required this.branches,
    required this.currentBranch,
    super.key,
  });

  final List<String> branches;
  final String currentBranch;

  @override
  State<SyncMergeDialog> createState() => _SyncMergeDialogState();
}

enum SyncMergeMode { bothDirections, oneWay }

enum SyncOrderDirection { forward, backward }

class _SyncMergeDialogState extends State<SyncMergeDialog> {
  late String _targetBranch = widget.branches.contains(widget.currentBranch)
      ? widget.currentBranch
      : widget.branches.first;
  late List<String> _sourceOrder = widget.branches
      .where((branch) => branch != _targetBranch)
      .toList();
  late Set<String> _enabledSources = {..._sourceOrder};
  var _mode = SyncMergeMode.bothDirections;
  var _direction = SyncOrderDirection.forward;
  var _pushAfterSync = false;

  void _setTarget(String target) {
    setState(() {
      _targetBranch = target;
      _sourceOrder = widget.branches
          .where((branch) => branch != _targetBranch)
          .toList();
      _enabledSources = _enabledSources
          .where((branch) => branch != _targetBranch)
          .toSet();
      if (_enabledSources.isEmpty) {
        _enabledSources = {..._sourceOrder};
      }
    });
  }

  void _moveSource(int index, int delta) {
    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _sourceOrder.length) return;
    setState(() {
      final branch = _sourceOrder.removeAt(index);
      _sourceOrder.insert(nextIndex, branch);
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedSources = _sourceOrder
        .where((branch) => _enabledSources.contains(branch))
        .toList();
    final orderedForDirection = [_targetBranch, ...selectedSources];
    final selectedBranches = _mode == SyncMergeMode.bothDirections
        ? orderedForDirection
        : _direction == SyncOrderDirection.forward
        ? orderedForDirection
        : orderedForDirection.reversed.toList();
    final forwardText = orderedForDirection.join(' -> ');
    final backwardText = orderedForDirection.reversed.join(' -> ');
    final selectedPathText = _direction == SyncOrderDirection.forward
        ? forwardText
        : backwardText;
    final modeText = _mode == SyncMergeMode.bothDirections
        ? 'Branches are pulled in order. Neighbor pairs sync both ways forward, then backward, so changes propagate across the chain.'
        : 'Sequential sync follows the selected path: $selectedPathText.';
    return AlertDialog(
      title: const Text('Sync / Merge Branches'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<SyncMergeMode>(
              segments: const [
                ButtonSegment(
                  value: SyncMergeMode.bothDirections,
                  icon: Icon(Icons.sync),
                  label: Text('Both directions'),
                ),
                ButtonSegment(
                  value: SyncMergeMode.oneWay,
                  icon: Icon(Icons.call_merge),
                  label: Text('One way'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (selected) {
                setState(() => _mode = selected.first);
              },
            ),
            const SizedBox(height: 12),
            Text(modeText, style: const TextStyle(color: Color(0xFF647086))),
            if (_mode == SyncMergeMode.oneWay) ...[
              const SizedBox(height: 12),
              SegmentedButton<SyncOrderDirection>(
                segments: const [
                  ButtonSegment(
                    value: SyncOrderDirection.forward,
                    icon: Icon(Icons.arrow_forward),
                    label: Text('Forward'),
                  ),
                  ButtonSegment(
                    value: SyncOrderDirection.backward,
                    icon: Icon(Icons.arrow_back),
                    label: Text('Backward'),
                  ),
                ],
                selected: {_direction},
                onSelectionChanged: (selected) {
                  setState(() => _direction = selected.first);
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Forward: $forwardText',
                style: const TextStyle(color: Color(0xFF647086), fontSize: 12),
              ),
              Text(
                'Backward: $backwardText',
                style: const TextStyle(color: Color(0xFF647086), fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _pushAfterSync,
              title: const Text('Push after sync'),
              subtitle: Text(
                'Off by default. Enable only when you want to push every selected branch after sync.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
              onChanged: (checked) {
                setState(() => _pushAfterSync = checked ?? true);
              },
            ),
            const SizedBox(height: 18),
            DropdownButtonFormField<String>(
              initialValue: _targetBranch,
              decoration: InputDecoration(
                labelText: _mode == SyncMergeMode.bothDirections
                    ? 'Start branch'
                    : 'First branch',
              ),
              items: [
                for (final branch in widget.branches)
                  DropdownMenuItem(value: branch, child: Text(branch)),
              ],
              onChanged: (value) {
                if (value != null) _setTarget(value);
              },
            ),
            const SizedBox(height: 18),
            Text(
              _mode == SyncMergeMode.bothDirections
                  ? 'Sync branches in this order'
                  : 'One-way branches in this order',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _sourceOrder.length,
                itemBuilder: (context, index) {
                  final branch = _sourceOrder[index];
                  return CheckboxListTile(
                    value: _enabledSources.contains(branch),
                    title: Text(branch, overflow: TextOverflow.ellipsis),
                    secondary: Text('${index + 1}'),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (checked) {
                      setState(() {
                        if (checked ?? false) {
                          _enabledSources.add(branch);
                        } else {
                          _enabledSources.remove(branch);
                        }
                      });
                    },
                    subtitle: Row(
                      children: [
                        IconButton(
                          tooltip: 'Move up',
                          onPressed: index == 0
                              ? null
                              : () => _moveSource(index, -1),
                          icon: const Icon(Icons.keyboard_arrow_up),
                        ),
                        IconButton(
                          tooltip: 'Move down',
                          onPressed: index == _sourceOrder.length - 1
                              ? null
                              : () => _moveSource(index, 1),
                          icon: const Icon(Icons.keyboard_arrow_down),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            SyncPreview(
              branches: selectedBranches,
              bothDirections: _mode == SyncMergeMode.bothDirections,
              pushAfterSync: _pushAfterSync,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: selectedSources.isEmpty
              ? null
              : () {
                  final bothDirections = _mode == SyncMergeMode.bothDirections;
                  Navigator.of(context).pop(
                    SyncMergeRequest(
                      selectedBranches.first,
                      selectedBranches.skip(1).toList(),
                      bothDirections: bothDirections,
                      pushAfterSync: _pushAfterSync,
                    ),
                  );
                },
          icon: const Icon(Icons.merge_type),
          label: const Text('Run Sync'),
        ),
      ],
    );
  }
}

class SyncMergeRequest {
  const SyncMergeRequest(
    this.targetBranch,
    this.sourceBranches, {
    required this.bothDirections,
    required this.pushAfterSync,
  });

  final String targetBranch;
  final List<String> sourceBranches;
  final bool bothDirections;

  final bool pushAfterSync;

  List<String> get branchesToPush => [targetBranch, ...sourceBranches];
}

class SyncPreview extends StatelessWidget {
  const SyncPreview({
    required this.branches,
    required this.bothDirections,
    required this.pushAfterSync,
    super.key,
  });

  final List<String> branches;
  final bool bothDirections;
  final bool pushAfterSync;

  @override
  Widget build(BuildContext context) {
    if (branches.length < 2) {
      return const Text(
        'Select at least one source branch.',
        style: TextStyle(color: Color(0xFF647086)),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF4F6FF),
        border: Border.all(color: const Color(0xFFDDE2FF)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              bothDirections ? 'Sync result' : 'Merge result',
              style: const TextStyle(
                color: Color(0xFF344160),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var index = 0; index < branches.length; index++) ...[
                  BranchFlowChip(
                    label: branches[index],
                    emphasized: index == 0,
                  ),
                  if (index < branches.length - 1)
                    const Icon(
                      Icons.arrow_forward,
                      size: 18,
                      color: Color(0xFF5865F2),
                    ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Text(
              _summaryText,
              style: const TextStyle(color: Color(0xFF647086), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String get _summaryText {
    final pushText = pushAfterSync
        ? ' Then all selected branches are pushed.'
        : '';
    const syncText =
        'Each branch is pulled in order. Neighboring pairs sync both ways forward, then backward, so all selected branches receive the chain updates.';
    return '$syncText$pushText';
  }
}

class BranchFlowChip extends StatelessWidget {
  const BranchFlowChip({
    required this.label,
    required this.emphasized,
    super.key,
  });

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasized ? const Color(0xFF5865F2) : Colors.white,
        border: Border.all(
          color: emphasized ? const Color(0xFF5865F2) : const Color(0xFFD9DEEA),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: emphasized ? Colors.white : const Color(0xFF344160),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class CarryChangesDialog extends StatelessWidget {
  const CarryChangesDialog({
    required this.currentBranch,
    required this.targetBranch,
    required this.changedFilesCount,
    super.key,
  });

  final String currentBranch;
  final String targetBranch;
  final int changedFilesCount;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Carry Changes To Branch?'),
      content: SizedBox(
        width: 460,
        child: Text(
          'There ${changedFilesCount == 1 ? 'is' : 'are'} '
          '$changedFilesCount uncommitted '
          '${changedFilesCount == 1 ? 'change' : 'changes'} on '
          '$currentBranch. Checkout can try to carry these changes to '
          '$targetBranch. If Git cannot apply them cleanly, checkout will fail.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.login),
          label: const Text('Checkout And Carry'),
        ),
      ],
    );
  }
}

class CommitDialog extends StatefulWidget {
  const CommitDialog({
    required this.branchName,
    required this.files,
    this.title,
    this.intro,
    this.actionLabel = 'Commit',
    this.initialMessage = '',
    this.initialDescription = '',
    super.key,
  });

  final String branchName;
  final List<String> files;
  final String? title;
  final String? intro;
  final String actionLabel;
  final String initialMessage;
  final String initialDescription;

  @override
  State<CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<CommitDialog> {
  final _controller = TextEditingController();
  final _descriptionController = TextEditingController();
  late final Set<String> _files = {...widget.files};

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialMessage;
    _descriptionController.text = widget.initialDescription;
  }

  @override
  void dispose() {
    _controller.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? 'Commit ${widget.branchName}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.intro != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.intro!,
                  style: const TextStyle(color: Color(0xFF647086)),
                ),
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _controller,
              decoration: const InputDecoration(labelText: 'Commit message'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descriptionController,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(
                alignLabelWithHint: true,
                labelText: 'Description',
              ),
            ),
            const SizedBox(height: 18),
            if (widget.files.isEmpty)
              const Text('There are no changed files to commit.')
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final file in widget.files)
                      CheckboxListTile(
                        value: _files.contains(file),
                        title: Text(file, overflow: TextOverflow.ellipsis),
                        onChanged: (checked) {
                          setState(() {
                            if (checked ?? false) {
                              _files.add(file);
                            } else {
                              _files.remove(file);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: widget.files.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                  CommitRequest(
                    _controller.text,
                    _files.toList(),
                    description: _descriptionController.text,
                  ),
                ),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

class CommitRequest {
  const CommitRequest(this.message, this.files, {this.description = ''});
  final String message;
  final List<String> files;
  final String description;
}

class CommitDraft {
  const CommitDraft({required this.message, required this.description});

  final String message;
  final String description;
}

class RepositoryTile extends StatelessWidget {
  const RepositoryTile({
    required this.repo,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final RepositoryInfo repo;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: surfaceColor(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? const Color(0xFF5865F2) : borderColor(context),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.account_tree_outlined,
                color: Color(0xFF5865F2),
                size: 34,
              ),
              const SizedBox(width: 28),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      repo.name,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      repo.path,
                      style: const TextStyle(color: Color(0xFF647086)),
                    ),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected
                    ? const Color(0xFF5865F2)
                    : const Color(0xFFD3DAE5),
                size: 32,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppPanel extends StatelessWidget {
  const AppPanel({
    required this.child,
    this.padding = const EdgeInsets.all(38),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 640),
      padding: padding,
      decoration: BoxDecoration(
        color: surfaceColor(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor(context)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120B1B3B),
            blurRadius: 30,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: child,
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({this.text = 'No repositories added yet.', super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Text(text, style: TextStyle(color: mutedTextColor(context))),
      ),
    );
  }
}

class InfoNote extends StatelessWidget {
  const InfoNote({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFF2F1FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.info_outline, color: Color(0xFF5865F2), size: 18),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF445064)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String formatRelative(DateTime? value) {
  if (value == null) return 'never';
  final diff = DateTime.now().difference(value);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} minutes ago';
  if (diff.inHours < 24) return '${diff.inHours} hours ago';
  return '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final precision = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String formatCommit(BranchStatus? status) {
  if (status == null || status.lastCommitHash.isEmpty) return 'unknown';
  if (status.lastCommitMessage.isEmpty) return status.lastCommitHash;
  return '${status.lastCommitHash} ${status.lastCommitMessage}';
}

extension on GitOperationResult {
  GitOperationResult copyBranch(String branchName) => GitOperationResult(
    operation: operation,
    branchName: branchName,
    success: success,
    stdout: this.stdout,
    stderr: this.stderr,
    startedAt: startedAt,
    finishedAt: finishedAt,
  );
}
