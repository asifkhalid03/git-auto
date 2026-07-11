import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'app_storage.dart';
import 'git_service.dart';
import 'models.dart';

void main() {
  runApp(const GitWorkflowApp());
}

class GitWorkflowApp extends StatelessWidget {
  const GitWorkflowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Git Workflow',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5865F2),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F9FD),
        useMaterial3: true,
      ),
      home: const GitWorkflowHome(),
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
  final _uuid = const Uuid();

  var _repositories = <RepositoryInfo>[];
  var _branches = <TrackedBranch>[];
  var _operations = <GitOperationResult>[];
  final _currentBranches = <String, String>{};
  RepositoryInfo? _selectedRepo;
  var _loading = true;
  var _busy = false;
  var _autoRefreshing = false;
  var _cardSize = 360.0;
  String? _message;
  SyncAnimationState? _syncAnimation;
  Timer? _autoRefreshTimer;

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
      _selectedRepo = _repositories.firstOrNull;
      _loading = false;
    });
    unawaited(_loadCurrentBranches());
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
    return branch;
  }

  Future<void> _save() async {
    await _storage.save(
      AppStateSnapshot(
        repositories: _repositories,
        branches: _branches,
        operations: _operations.take(25).toList(),
      ),
    );
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
        builder: (_) =>
            CommitDialog(branchName: branch.branchName, files: files),
      );
      if (request == null) return;
      final result = await _git.commitBranch(
        worktreePath: repo.path,
        branchName: branch.branchName,
        message: request.message,
        files: request.files,
      );
      await _recordOperation(result);
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
          files: commitRequest.files,
        );
        await _recordOperation(commitResult);
        await _refreshTrackedBranches(repo);
        if (!commitResult.success) return;
      }

      if (!mounted) return;
      setState(() {
        _syncAnimation = SyncAnimationState(
          targetBranch: request.targetBranch,
          sourceBranches: request.sourceBranches,
          bothDirections: request.bothDirections,
        );
      });
      try {
        final result = await _git.syncMergeBranches(
          repoPath: repo.path,
          targetBranch: request.targetBranch,
          sourceBranches: request.sourceBranches,
          bothDirections: request.bothDirections,
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
        ..._branches.where((branch) => branch.repoId != repo.id),
        ...next,
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
                constraints: const BoxConstraints(maxWidth: 1160),
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
                          repositories: _repositories,
                          branches: selectedBranches,
                          operations: _operations,
                          message: _message,
                          busy: _busy,
                          syncAnimation: _syncAnimation,
                          checkoutBlocked: checkoutBlocked,
                          cardSize: _cardSize,
                          onChooseFolder: _chooseRepository,
                          onChangeRepo: (repo) =>
                              setState(() => _selectedRepo = repo),
                          onCardSizeChanged: (value) =>
                              setState(() => _cardSize = value),
                          onEditBranches: () => _selectBranches(selectedRepo),
                          onRefresh: _refreshBranch,
                          onPull: _pullBranch,
                          onCheckout: _checkoutBranch,
                          onCommit: _commitBranch,
                          onPush: _pushBranch,
                          onUndoCommit: _undoLastCommit,
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
    required this.repositories,
    required this.branches,
    required this.operations,
    required this.message,
    required this.busy,
    required this.syncAnimation,
    required this.checkoutBlocked,
    required this.cardSize,
    required this.onChooseFolder,
    required this.onChangeRepo,
    required this.onCardSizeChanged,
    required this.onEditBranches,
    required this.onRefresh,
    required this.onPull,
    required this.onCheckout,
    required this.onCommit,
    required this.onPush,
    required this.onUndoCommit,
    required this.onSyncBranches,
    super.key,
  });

  final RepositoryInfo repo;
  final String currentBranch;
  final List<RepositoryInfo> repositories;
  final List<TrackedBranch> branches;
  final List<GitOperationResult> operations;
  final String? message;
  final bool busy;
  final SyncAnimationState? syncAnimation;
  final bool checkoutBlocked;
  final double cardSize;
  final VoidCallback onChooseFolder;
  final ValueChanged<RepositoryInfo> onChangeRepo;
  final ValueChanged<double> onCardSizeChanged;
  final VoidCallback onEditBranches;
  final ValueChanged<TrackedBranch> onRefresh;
  final ValueChanged<TrackedBranch> onPull;
  final ValueChanged<TrackedBranch> onCheckout;
  final ValueChanged<TrackedBranch> onCommit;
  final ValueChanged<TrackedBranch> onPush;
  final ValueChanged<TrackedBranch> onUndoCommit;
  final VoidCallback onSyncBranches;

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
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      repo.path,
                      style: const TextStyle(color: Color(0xFF647086)),
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
                      (item) =>
                          DropdownMenuItem(value: item, child: Text(item.name)),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value != null) onChangeRepo(value);
                },
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : onChooseFolder,
                icon: const Icon(Icons.add),
                label: const Text('Add Repo'),
              ),
            ],
          ),
          const Divider(height: 42),
          Row(
            children: [
              Text('Branches', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              BranchCardSizeSlider(
                value: cardSize,
                onChanged: busy ? null : onCardSizeChanged,
              ),
              const SizedBox(width: 16),
              OutlinedButton.icon(
                onPressed: busy || branches.length < 2 ? null : onSyncBranches,
                icon: const Icon(Icons.merge_type),
                label: const Text('Sync / Merge'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: busy ? null : onEditBranches,
                icon: const Icon(Icons.tune),
                label: const Text('Select Branches'),
              ),
            ],
          ),
          const SizedBox(height: 22),
          if (branches.isEmpty)
            const EmptyState(text: 'No branches selected yet.')
          else
            Expanded(
              child: Stack(
                children: [
                  GridView.builder(
                    itemCount: branches.length,
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: cardSize,
                      mainAxisExtent: cardSize * 0.92,
                      crossAxisSpacing: 24,
                      mainAxisSpacing: 24,
                    ),
                    itemBuilder: (context, index) => BranchCard(
                      branch: branches[index],
                      isCurrentBranch:
                          branches[index].branchName == currentBranch,
                      checkoutBlocked: checkoutBlocked,
                      busy: busy,
                      onRefresh: () => onRefresh(branches[index]),
                      onPull: () => onPull(branches[index]),
                      onCheckout: () => onCheckout(branches[index]),
                      onCommit: () => onCommit(branches[index]),
                      onPush: () => onPush(branches[index]),
                      onUndoCommit: () => onUndoCommit(branches[index]),
                    ),
                  ),
                  if (syncAnimation != null)
                    Positioned.fill(
                      child: SyncMergeOverlay(
                        branches: branches
                            .map((branch) => branch.branchName)
                            .toList(),
                        state: syncAnimation!,
                        maxCardExtent: cardSize,
                        cardHeight: cardSize * 0.92,
                      ),
                    ),
                ],
              ),
            ),
          if (syncAnimation != null) ...[
            const SizedBox(height: 12),
            SyncMergeLegend(state: syncAnimation!),
          ],
          if (message != null) ...[
            const SizedBox(height: 12),
            Text(message!, style: const TextStyle(color: Color(0xFF647086))),
          ],
          if (operations.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Last operation: ${operations.first.operation} '
              '${operations.first.success ? 'succeeded' : 'failed'}',
              style: const TextStyle(color: Color(0xFF647086)),
            ),
          ],
        ],
      ),
    );
  }
}

class BranchCard extends StatelessWidget {
  const BranchCard({
    required this.branch,
    required this.isCurrentBranch,
    required this.checkoutBlocked,
    required this.busy,
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
  final VoidCallback onRefresh;
  final VoidCallback onPull;
  final VoidCallback onCheckout;
  final VoidCallback onCommit;
  final VoidCallback onPush;
  final VoidCallback onUndoCommit;

  @override
  Widget build(BuildContext context) {
    final status = branch.lastStatus;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE0E5EE)),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined, color: Color(0xFF6D5DF2)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  branch.branchName,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (isCurrentBranch) ...[
                const SizedBox(width: 8),
                const CurrentBranchBadge(),
              ],
              IconButton(
                tooltip: 'Refresh',
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 18),
          StatusBadge(status: status),
          const SizedBox(height: 20),
          Text(
            'Last pull: ${formatRelative(branch.lastPullAt)}',
            style: const TextStyle(fontSize: 16, color: Color(0xFF445064)),
          ),
          const SizedBox(height: 8),
          Text(
            'Checked: ${formatRelative(status?.lastCheckedAt)}',
            style: const TextStyle(color: Color(0xFF8A94A6)),
          ),
          const SizedBox(height: 8),
          Text(
            'Commit: ${formatCommit(status)}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF647086)),
          ),
          const SizedBox(height: 6),
          Text(
            '${status?.changedFilesCount ?? 0} uncommitted ${status?.changedFilesCount == 1 ? 'change' : 'changes'}',
            style: TextStyle(
              color: (status?.hasLocalChanges ?? false)
                  ? const Color(0xFFDD8500)
                  : const Color(0xFF647086),
              fontWeight: (status?.hasLocalChanges ?? false)
                  ? FontWeight.w700
                  : FontWeight.w400,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              IconButton.filledTonal(
                tooltip: 'Pull',
                onPressed: busy || !isCurrentBranch ? null : onPull,
                icon: const Icon(Icons.download),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Commit',
                onPressed: busy || !isCurrentBranch ? null : onCommit,
                icon: const Icon(Icons.add_task),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Undo last commit',
                onPressed: busy || !isCurrentBranch ? null : onUndoCommit,
                icon: const Icon(Icons.undo),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                tooltip: 'Push',
                onPressed: busy || !isCurrentBranch ? null : onPush,
                icon: const Icon(Icons.upload),
              ),
              const Spacer(),
              IconButton.filled(
                tooltip: isCurrentBranch
                    ? 'Already checked out'
                    : checkoutBlocked
                    ? 'Checkout with uncommitted changes'
                    : 'Checkout branch',
                onPressed: busy || isCurrentBranch ? null : onCheckout,
                icon: const Icon(Icons.login),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class SyncAnimationState {
  const SyncAnimationState({
    required this.targetBranch,
    required this.sourceBranches,
    required this.bothDirections,
  });

  final String targetBranch;
  final List<String> sourceBranches;
  final bool bothDirections;

  bool includes(String branchName) =>
      branchName == targetBranch || sourceBranches.contains(branchName);

  List<String> get orderedBranches => [targetBranch, ...sourceBranches];

  String get label => bothDirections
      ? orderedBranches.join(' <-> ')
      : '${sourceBranches.join(' -> ')} -> $targetBranch';
}

class SyncMergeOverlay extends StatefulWidget {
  const SyncMergeOverlay({
    required this.branches,
    required this.state,
    required this.maxCardExtent,
    required this.cardHeight,
    super.key,
  });

  final List<String> branches;
  final SyncAnimationState state;
  final double maxCardExtent;
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
            branches: widget.branches,
            state: widget.state,
            maxCardExtent: widget.maxCardExtent,
            cardHeight: widget.cardHeight,
            progress: _controller.value,
          ),
        ),
      ),
    );
  }
}

class SyncMergePainter extends CustomPainter {
  const SyncMergePainter({
    required this.branches,
    required this.state,
    required this.maxCardExtent,
    required this.cardHeight,
    required this.progress,
  });

  final List<String> branches;
  final SyncAnimationState state;
  final double maxCardExtent;
  final double cardHeight;
  final double progress;

  static const _spacing = 24.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (branches.length < 2 || size.width <= 0) return;

    final centers = _branchCenters(size);
    final target = centers[state.targetBranch];
    if (target == null) return;

    final glowPaint = Paint()
      ..color = const Color(0xFF5865F2).withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    final targetPulse = 42 + 10 * progress;
    canvas.drawCircle(target, targetPulse, glowPaint);
    canvas.drawCircle(
      target,
      24,
      glowPaint..color = const Color(0xFF0EA044).withValues(alpha: 0.16),
    );

    final linePaint = Paint()
      ..color = const Color(0xFF5865F2).withValues(alpha: 0.5)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final dotPaint = Paint()
      ..color = const Color(0xFF5865F2)
      ..style = PaintingStyle.fill;
    final sourcePaint = Paint()
      ..color = const Color(0xFFDD8500).withValues(alpha: 0.16)
      ..style = PaintingStyle.fill;

    final links = state.bothDirections
        ? [
            for (var i = 1; i < state.orderedBranches.length; i++)
              (
                from: state.orderedBranches[i - 1],
                to: state.orderedBranches[i],
              ),
            for (var i = state.orderedBranches.length - 2; i >= 0; i--)
              (
                from: state.orderedBranches[i + 1],
                to: state.orderedBranches[i],
              ),
          ]
        : [
            for (final source in state.sourceBranches)
              (from: source, to: state.targetBranch),
          ];

    for (var i = 0; i < links.length; i++) {
      final source = centers[links[i].from];
      final destination = centers[links[i].to];
      if (source == null || destination == null || source == destination) {
        continue;
      }

      canvas.drawCircle(
        source,
        28 + 4 * ((progress + i * 0.2) % 1),
        sourcePaint,
      );

      final control = Offset(
        (source.dx + destination.dx) / 2,
        (source.dy + destination.dy) / 2 - 56,
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

      for (var dot = 0; dot < 3; dot++) {
        final t = (progress + dot / 3 + i * 0.12) % 1;
        final point = _quadraticPoint(source, control, destination, t);
        canvas.drawCircle(point, 5.5, dotPaint);
      }
    }
  }

  Map<String, Offset> _branchCenters(Size size) {
    final columns = (size.width / maxCardExtent).ceil().clamp(
      1,
      branches.length,
    );
    final cardWidth = (size.width - _spacing * (columns - 1)) / columns;
    final centers = <String, Offset>{};
    for (var i = 0; i < branches.length; i++) {
      final column = i % columns;
      final row = i ~/ columns;
      final x = column * (cardWidth + _spacing) + cardWidth / 2;
      final y = row * (cardHeight + _spacing) + cardHeight / 2;
      if (y <= size.height + cardHeight) {
        centers[branches[i]] = Offset(x, y);
      }
    }
    return centers;
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
        oldDelegate.branches != branches ||
        oldDelegate.state != state ||
        oldDelegate.maxCardExtent != maxCardExtent ||
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
              child: Text(
                state.label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF344160),
                  fontWeight: FontWeight.w600,
                ),
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
              min: 280,
              max: 480,
              divisions: 10,
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

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, super.key});

  final BranchStatus? status;

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
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
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
  const CurrentBranchBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF0EA044).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          'Current',
          style: TextStyle(
            color: Color(0xFF0EA044),
            fontWeight: FontWeight.w700,
            fontSize: 12,
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

class _SyncMergeDialogState extends State<SyncMergeDialog> {
  late String _targetBranch = widget.branches.contains(widget.currentBranch)
      ? widget.currentBranch
      : widget.branches.first;
  late List<String> _sourceOrder = widget.branches
      .where((branch) => branch != _targetBranch)
      .toList();
  late Set<String> _enabledSources = {..._sourceOrder};
  var _mode = SyncMergeMode.bothDirections;
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
    final selectedBranches = [_targetBranch, ...selectedSources];
    final modeText = _mode == SyncMergeMode.bothDirections
        ? 'Each selected branch receives the merged changes.'
        : 'Only $_targetBranch receives the selected source branches.';
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
            const SizedBox(height: 10),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _pushAfterSync,
              title: const Text('Push after sync'),
              subtitle: Text(
                _mode == SyncMergeMode.bothDirections
                    ? 'Off by default. Enable only when you want to push every selected branch.'
                    : 'Off by default. Enable only when you want to push the target branch.',
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
                    : 'Merge into',
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
                  : 'Merge sources in this order',
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
              : () => Navigator.of(context).pop(
                  SyncMergeRequest(
                    _targetBranch,
                    selectedSources,
                    bothDirections: _mode == SyncMergeMode.bothDirections,
                    pushAfterSync: _pushAfterSync,
                  ),
                ),
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

  List<String> get branchesToPush =>
      bothDirections ? [targetBranch, ...sourceBranches] : [targetBranch];
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
                    Icon(
                      bothDirections
                          ? Icons.compare_arrows
                          : Icons.arrow_forward,
                      size: 18,
                      color: const Color(0xFF5865F2),
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
        ? ' Then ${bothDirections ? 'all selected branches are' : 'the target branch is'} pushed.'
        : '';
    final syncText = bothDirections
        ? 'Forward pass then backward pass keeps all selected branches aligned.'
        : 'The source branches merge into the selected target only.';
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
    super.key,
  });

  final String branchName;
  final List<String> files;
  final String? title;
  final String? intro;
  final String actionLabel;
  final String initialMessage;

  @override
  State<CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<CommitDialog> {
  final _controller = TextEditingController();
  late final Set<String> _files = {...widget.files};

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialMessage;
  }

  @override
  void dispose() {
    _controller.dispose();
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
              : () => Navigator.of(
                  context,
                ).pop(CommitRequest(_controller.text, _files.toList())),
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

class CommitRequest {
  const CommitRequest(this.message, this.files);
  final String message;
  final List<String> files;
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
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFF5865F2)
                  : const Color(0xFFE0E5EE),
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
  const AppPanel({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 640),
      padding: const EdgeInsets.all(38),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE0E5EE)),
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
        child: Text(text, style: const TextStyle(color: Color(0xFF647086))),
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
    stdout: stdout,
    stderr: stderr,
    startedAt: startedAt,
    finishedAt: finishedAt,
  );
}
