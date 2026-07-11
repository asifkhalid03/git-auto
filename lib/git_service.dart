import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';

class SyncMergeStep {
  const SyncMergeStep({required this.fromBranch, required this.toBranch});

  final String fromBranch;
  final String toBranch;
}

class GitService {
  Future<RepositoryInfo> validateRepository({
    required String path,
    required String id,
  }) async {
    final inside = await _run(['rev-parse', '--is-inside-work-tree'], path);
    if (!inside.success || inside.stdout.trim() != 'true') {
      throw GitException('Selected folder is not a Git repository.');
    }

    final root = await _run(['rev-parse', '--show-toplevel'], path);
    final repoPath = root.stdout.trim().isEmpty ? path : root.stdout.trim();
    final name = p.basename(repoPath);
    final defaultBranch = await _defaultBranch(repoPath);
    final remoteUrl = await _firstRemoteUrl(repoPath);
    return RepositoryInfo(
      id: id,
      name: name,
      path: repoPath,
      defaultBranch: defaultBranch,
      remoteUrl: remoteUrl,
    );
  }

  Future<void> fetchBranches(String repoPath) async {
    final result = await _run(['fetch', '--all', '--prune'], repoPath);
    _throwIfFailed(result, 'Unable to fetch branches.');
  }

  Future<List<String>> listBranches(
    String repoPath, {
    bool includeRemote = false,
  }) async {
    final localResult = await _run([
      'for-each-ref',
      '--format=%(refname:short)',
      'refs/heads',
    ], repoPath);
    _throwIfFailed(localResult, 'Unable to list branches.');
    final branches = localResult.stdout
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toSet();

    if (includeRemote) {
      final remoteResult = await _run([
        'for-each-ref',
        '--format=%(refname:short)',
        'refs/remotes',
      ], repoPath);
      _throwIfFailed(remoteResult, 'Unable to list remote branches.');
      for (final remoteBranch
          in remoteResult.stdout
              .split(RegExp(r'\r?\n'))
              .map((line) => line.trim())
              .where((line) => line.isNotEmpty && !line.endsWith('/HEAD'))) {
        final slash = remoteBranch.indexOf('/');
        if (slash > 0 && slash < remoteBranch.length - 1) {
          branches.add(remoteBranch.substring(slash + 1));
        }
      }
    }

    return branches.toList()..sort();
  }

  Future<String> currentBranch(String repoPath) async {
    final result = await _run(['branch', '--show-current'], repoPath);
    return result.success ? result.stdout.trim() : '';
  }

  Future<String> upstreamFor(String repoPath, String branchName) async {
    final sameNameRemote = await _remoteBranchFor(repoPath, branchName);
    if (sameNameRemote.isNotEmpty) return sameNameRemote;

    final result = await _run([
      'rev-parse',
      '--abbrev-ref',
      '$branchName@{upstream}',
    ], repoPath);
    if (result.success && result.stdout.trim().isNotEmpty) {
      return result.stdout.trim();
    }
    return _remoteBranchFor(repoPath, branchName);
  }

  Future<String> ensureWorktree({
    required String repoPath,
    required String repoId,
    required String branchName,
    required Directory worktreesRoot,
  }) async {
    final safeBranch = branchName.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
    final compactRepoId = repoId.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
    final shortRepoId = compactRepoId.length > 12
        ? compactRepoId.substring(0, 12)
        : compactRepoId;
    final shortBranch = safeBranch.length > 24
        ? safeBranch.substring(0, 24)
        : safeBranch;
    final path = await _worktreePath(
      repoPath: repoPath,
      repoId: shortRepoId,
      branchName: shortBranch,
      fallbackRoot: worktreesRoot,
    );
    final dir = Directory(path);
    if (await dir.exists()) {
      final valid = await _run(['rev-parse', '--is-inside-work-tree'], path);
      if (valid.success) return path;
      await dir.delete(recursive: true);
    } else {
      await dir.parent.create(recursive: true);
    }

    final revision = await _branchRevision(repoPath, branchName);
    await _run(['worktree', 'prune'], repoPath);
    final result = await _run([
      'worktree',
      'add',
      '--detach',
      path,
      revision,
    ], repoPath);
    _throwIfFailed(result, 'Unable to create worktree for $branchName.');
    return path;
  }

  Future<BranchStatus> getBranchStatus(
    String worktreePath,
    String upstream, {
    bool fetch = true,
    String revision = 'HEAD',
    bool includeWorkingTree = true,
  }) async {
    final checkedAt = DateTime.now();
    if (fetch && upstream.isNotEmpty) {
      await _run(['fetch', '--prune'], worktreePath);
    }

    var changes = <String>[];
    if (includeWorkingTree) {
      final porcelain = await _run(['status', '--porcelain=v1'], worktreePath);
      if (!porcelain.success) {
        return BranchStatus(
          aheadCount: 0,
          behindCount: 0,
          hasLocalChanges: false,
          hasConflicts: false,
          lastCheckedAt: checkedAt,
          error: porcelain.stderr.trim().isEmpty
              ? porcelain.stdout.trim()
              : porcelain.stderr.trim(),
        );
      }
      changes = porcelain.stdout
          .split(RegExp(r'\r?\n'))
          .where((line) => line.trim().isNotEmpty)
          .toList();
    }

    var ahead = 0;
    var behind = 0;
    if (upstream.isNotEmpty) {
      final counts = await _run([
        'rev-list',
        '--left-right',
        '--count',
        '$revision...$upstream',
      ], worktreePath);
      if (counts.success) {
        final parts = counts.stdout.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2) {
          ahead = int.tryParse(parts[0]) ?? 0;
          behind = int.tryParse(parts[1]) ?? 0;
        }
      }
    }

    final commit = await _run([
      'log',
      '-1',
      '--format=%h%x00%s',
      revision,
    ], worktreePath);
    var lastCommitHash = '';
    var lastCommitMessage = '';
    if (commit.success && commit.stdout.trim().isNotEmpty) {
      final parts = commit.stdout.trim().split('\x00');
      lastCommitHash = parts.first;
      if (parts.length > 1) {
        lastCommitMessage = parts.sublist(1).join(' ');
      }
    }
    final hasConflicts = changes.any(
      (line) =>
          line.startsWith('UU') ||
          line.startsWith('AA') ||
          line.startsWith('DD') ||
          line.startsWith('AU') ||
          line.startsWith('UA') ||
          line.startsWith('DU') ||
          line.startsWith('UD'),
    );

    return BranchStatus(
      aheadCount: ahead,
      behindCount: behind,
      hasLocalChanges: changes.isNotEmpty,
      hasConflicts: hasConflicts,
      lastCheckedAt: checkedAt,
      changedFilesCount: changes.length,
      lastCommitHash: lastCommitHash,
      lastCommitMessage: lastCommitMessage,
      error: upstream.isEmpty ? 'No upstream configured' : null,
    );
  }

  Future<GitOperationResult> pullBranch(
    String worktreePath,
    String upstream,
  ) async {
    final startedAt = DateTime.now();
    if (upstream.isEmpty) {
      return _manualFailure('pull', '', 'No upstream configured.', startedAt);
    }
    final fetch = await _run(['fetch', '--prune'], worktreePath);
    if (!fetch.success) {
      return _resultFromProcess('pull', '', fetch, startedAt);
    }
    final pull = await _run(['rebase', upstream], worktreePath);
    return _resultFromProcess('pull', '', _combine(fetch, pull), startedAt);
  }

  Future<GitOperationResult> checkoutBranch({
    required String repoPath,
    required String branchName,
    bool allowDirty = false,
  }) async {
    final startedAt = DateTime.now();
    final current = await currentBranch(repoPath);
    if (current == branchName) {
      return GitOperationResult(
        operation: 'checkout',
        branchName: branchName,
        success: true,
        stdout: 'Already on $branchName.',
        stderr: '',
        startedAt: startedAt,
        finishedAt: DateTime.now(),
      );
    }

    await _run(['fetch', '--all', '--prune'], repoPath);
    final status = await _run(['status', '--porcelain=v1'], repoPath);
    if (!status.success) {
      return _resultFromProcess('checkout', branchName, status, startedAt);
    }
    if (!allowDirty && status.stdout.trim().isNotEmpty) {
      return _manualFailure(
        'checkout',
        branchName,
        'Checkout blocked: commit, stash, or discard local changes first.',
        startedAt,
      );
    }
    final local = await _run([
      'show-ref',
      '--verify',
      'refs/heads/$branchName',
    ], repoPath);
    final checkout = local.success
        ? await _run([
            'switch',
            '--ignore-other-worktrees',
            branchName,
          ], repoPath)
        : await _checkoutRemoteBranch(repoPath, branchName);
    return _resultFromProcess('checkout', branchName, checkout, startedAt);
  }

  Future<GitOperationResult> undoLastCommit({
    required String repoPath,
    required String branchName,
  }) async {
    final startedAt = DateTime.now();
    final head = await _run(['rev-parse', '--verify', 'HEAD'], repoPath);
    if (!head.success) {
      return _resultFromProcess('undo', branchName, head, startedAt);
    }
    final parent = await _run(['rev-parse', '--verify', 'HEAD~1'], repoPath);
    if (!parent.success) {
      return _manualFailure(
        'undo',
        branchName,
        'Cannot undo the first commit on this branch.',
        startedAt,
      );
    }
    final reset = await _run(['reset', '--soft', 'HEAD~1'], repoPath);
    return _resultFromProcess('undo', branchName, reset, startedAt);
  }

  Future<GitOperationResult> syncMergeBranches({
    required String repoPath,
    required String targetBranch,
    required List<String> sourceBranches,
    bool bothDirections = false,
    Future<void> Function(SyncMergeStep step)? onStep,
  }) async {
    final startedAt = DateTime.now();
    final sources = sourceBranches
        .where((branch) => branch.isNotEmpty && branch != targetBranch)
        .toList();
    if (sources.isEmpty) {
      return _manualFailure(
        'sync',
        targetBranch,
        'Select at least one source branch to merge.',
        startedAt,
      );
    }

    final status = await _run(['status', '--porcelain=v1'], repoPath);
    if (!status.success) {
      return _resultFromProcess('sync', targetBranch, status, startedAt);
    }
    if (status.stdout.trim().isNotEmpty) {
      return _manualFailure(
        'sync',
        targetBranch,
        'Commit, stash, or discard local changes before syncing branches.',
        startedAt,
      );
    }

    await _run(['fetch', '--all', '--prune'], repoPath);
    var combined = _GitProcessResult(exitCode: 0, stdout: '', stderr: '');

    Future<bool> mergeInto(String target, String source) async {
      await onStep?.call(SyncMergeStep(fromBranch: source, toBranch: target));
      final checkout = await checkoutBranch(
        repoPath: repoPath,
        branchName: target,
      );
      combined = _combine(
        combined,
        _GitProcessResult(
          exitCode: checkout.success ? 0 : 1,
          stdout: checkout.stdout,
          stderr: checkout.stderr,
        ),
      );
      if (!checkout.success) return false;

      final revision = await _branchRevision(repoPath, source);
      final merge = await _run(['merge', '--no-edit', revision], repoPath);
      combined = _combine(combined, merge);
      return merge.success;
    }

    if (bothDirections) {
      final orderedBranches = [targetBranch, ...sources];
      for (var index = 1; index < orderedBranches.length; index++) {
        final success = await mergeInto(
          orderedBranches[index],
          orderedBranches[index - 1],
        );
        if (!success) {
          return _resultFromProcess('sync', targetBranch, combined, startedAt);
        }
      }
      for (var index = orderedBranches.length - 2; index >= 0; index--) {
        final success = await mergeInto(
          orderedBranches[index],
          orderedBranches[index + 1],
        );
        if (!success) {
          return _resultFromProcess('sync', targetBranch, combined, startedAt);
        }
      }
      return _resultFromProcess('sync', targetBranch, combined, startedAt);
    }

    final checkout = await checkoutBranch(
      repoPath: repoPath,
      branchName: targetBranch,
    );
    combined = _combine(
      combined,
      _GitProcessResult(
        exitCode: checkout.success ? 0 : 1,
        stdout: checkout.stdout,
        stderr: checkout.stderr,
      ),
    );
    if (!checkout.success) {
      return _resultFromProcess('sync', targetBranch, combined, startedAt);
    }

    for (final source in sources) {
      final revision = await _branchRevision(repoPath, source);
      final merge = await _run(['merge', '--no-edit', revision], repoPath);
      combined = _combine(combined, merge);
      if (!merge.success) {
        return _resultFromProcess('sync', targetBranch, combined, startedAt);
      }
    }

    return _resultFromProcess('sync', targetBranch, combined, startedAt);
  }

  Future<List<String>> changedFiles(String worktreePath) async {
    final result = await _run(['status', '--porcelain=v1'], worktreePath);
    _throwIfFailed(result, 'Unable to read changed files.');
    return result.stdout
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .map((line) => line.length > 3 ? line.substring(3).trim() : line.trim())
        .toList();
  }

  Future<GitOperationResult> commitBranch({
    required String worktreePath,
    required String branchName,
    required String message,
    required List<String> files,
  }) async {
    final startedAt = DateTime.now();
    if (message.trim().isEmpty) {
      return _manualFailure(
        'commit',
        branchName,
        'Commit message is required.',
        startedAt,
      );
    }
    if (files.isEmpty) {
      return _manualFailure(
        'commit',
        branchName,
        'Select at least one file.',
        startedAt,
      );
    }
    final status = await getBranchStatus(worktreePath, '');
    if (status.hasConflicts) {
      return _manualFailure(
        'commit',
        branchName,
        'Resolve conflicts before committing.',
        startedAt,
      );
    }
    final add = await _run(['add', '--', ...files], worktreePath);
    if (!add.success) {
      return _resultFromProcess('commit', branchName, add, startedAt);
    }
    final commit = await _run(['commit', '-m', message.trim()], worktreePath);
    return _resultFromProcess(
      'commit',
      branchName,
      _combine(add, commit),
      startedAt,
    );
  }

  Future<GitOperationResult> pushBranch({
    required String worktreePath,
    required String branchName,
  }) async {
    final startedAt = DateTime.now();
    final status = await getBranchStatus(worktreePath, '');
    if (status.hasConflicts) {
      return _manualFailure(
        'push',
        branchName,
        'Resolve conflicts before pushing.',
        startedAt,
      );
    }
    if (status.hasLocalChanges) {
      return _manualFailure(
        'push',
        branchName,
        'Commit, stash, or discard local changes before pushing.',
        startedAt,
      );
    }
    final current = await currentBranch(worktreePath);
    if (current != branchName) {
      return _manualFailure(
        'push',
        branchName,
        'Push blocked: expected $branchName but the repository is on $current.',
        startedAt,
      );
    }
    final push = await _pushCurrentBranchToOriginBranch(
      worktreePath,
      branchName,
    );
    return _resultFromProcess('push', branchName, push, startedAt);
  }

  Future<GitOperationResult> pushSyncedBranches({
    required String repoPath,
    required List<String> branchNames,
  }) async {
    final startedAt = DateTime.now();
    final branches = {
      for (final branch in branchNames)
        if (branch.trim().isNotEmpty) branch.trim(),
    }.toList();
    if (branches.isEmpty) {
      return _manualFailure(
        'sync push',
        '',
        'Select at least one branch to push.',
        startedAt,
      );
    }

    final remotes = await _run(['remote'], repoPath);
    if (!remotes.success || remotes.stdout.trim().isEmpty) {
      return _manualFailure(
        'sync push',
        branches.join(', '),
        'No Git remote is configured for this repository.',
        startedAt,
      );
    }

    var combined = _GitProcessResult(exitCode: 0, stdout: '', stderr: '');
    for (final branch in branches) {
      final checkout = await checkoutBranch(
        repoPath: repoPath,
        branchName: branch,
      );
      combined = _combine(
        combined,
        _GitProcessResult(
          exitCode: checkout.success ? 0 : 1,
          stdout: checkout.stdout,
          stderr: checkout.stderr,
        ),
      );
      if (!checkout.success) {
        return _resultFromProcess('sync push', branch, combined, startedAt);
      }

      final status = await getBranchStatus(repoPath, '', fetch: false);
      if (status.hasConflicts) {
        return _manualFailure(
          'sync push',
          branch,
          'Resolve conflicts before pushing $branch.',
          startedAt,
        );
      }
      if (status.hasLocalChanges) {
        return _manualFailure(
          'sync push',
          branch,
          'Commit, stash, or discard local changes before pushing $branch.',
          startedAt,
        );
      }

      final current = await currentBranch(repoPath);
      if (current != branch) {
        return _manualFailure(
          'sync push',
          branch,
          'Push blocked: expected $branch but the repository is on $current.',
          startedAt,
        );
      }
      final push = await _pushCurrentBranchToOriginBranch(repoPath, branch);
      combined = _combine(combined, push);
      if (!push.success) {
        return _resultFromProcess('sync push', branch, combined, startedAt);
      }
    }

    return _resultFromProcess(
      'sync push',
      branches.join(', '),
      combined,
      startedAt,
    );
  }

  Future<_GitProcessResult> _pushCurrentBranchToOriginBranch(
    String repoPath,
    String branchName,
  ) {
    return _run([
      'push',
      '-u',
      'origin',
      'HEAD:refs/heads/$branchName',
    ], repoPath);
  }

  Future<String> _defaultBranch(String repoPath) async {
    final remote = await _run([
      'symbolic-ref',
      '--quiet',
      '--short',
      'refs/remotes/origin/HEAD',
    ], repoPath);
    if (remote.success && remote.stdout.trim().isNotEmpty) {
      return remote.stdout.trim().replaceFirst('origin/', '');
    }
    final current = await _run(['branch', '--show-current'], repoPath);
    return current.stdout.trim();
  }

  Future<String> _firstRemoteUrl(String repoPath) async {
    final remotes = await _run(['remote'], repoPath);
    final firstRemote = remotes.stdout
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (firstRemote.isEmpty) return '';
    final url = await _run(['remote', 'get-url', firstRemote], repoPath);
    return url.success ? url.stdout.trim() : '';
  }

  Future<String> _branchRevision(String repoPath, String branchName) async {
    final local = await _run(['rev-parse', '--verify', branchName], repoPath);
    if (local.success) return branchName;

    final remoteBranch = await _remoteBranchFor(repoPath, branchName);
    if (remoteBranch.isNotEmpty) return remoteBranch;
    return branchName;
  }

  Future<String> _remoteBranchFor(String repoPath, String branchName) async {
    final remotes = await _run(['remote'], repoPath);
    if (!remotes.success) return '';
    for (final remote
        in remotes.stdout
            .split(RegExp(r'\r?\n'))
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)) {
      final candidate = '$remote/$branchName';
      final result = await _run([
        'show-ref',
        '--verify',
        'refs/remotes/$candidate',
      ], repoPath);
      if (result.success) return candidate;
    }
    return '';
  }

  Future<_GitProcessResult> _checkoutRemoteBranch(
    String repoPath,
    String branchName,
  ) async {
    final remoteBranch = await _remoteBranchFor(repoPath, branchName);
    if (remoteBranch.isEmpty) {
      return _GitProcessResult(
        exitCode: 1,
        stdout: '',
        stderr: 'Branch $branchName was not found locally or on a remote.',
      );
    }
    return _run([
      'switch',
      '--ignore-other-worktrees',
      '--create',
      branchName,
      '--track',
      remoteBranch,
    ], repoPath);
  }

  Future<String> _worktreePath({
    required String repoPath,
    required String repoId,
    required String branchName,
    required Directory fallbackRoot,
  }) async {
    if (Platform.isWindows) {
      final rootPrefix = p.rootPrefix(repoPath);
      if (rootPrefix.isNotEmpty) {
        final shortRoot = Directory(p.join(rootPrefix, '.agw-wt'));
        try {
          if (!await shortRoot.exists()) {
            await shortRoot.create(recursive: true);
          }
          return p.join(shortRoot.path, repoId, branchName);
        } catch (_) {
          // Fall back to the application support directory when the drive root
          // is not writable. Git longpaths is still enabled for this path.
        }
      }
    }
    return p.join(fallbackRoot.path, repoId, branchName);
  }

  Future<_GitProcessResult> _run(
    List<String> args,
    String workingDirectory,
  ) async {
    final gitArgs = Platform.isWindows
        ? ['-c', 'core.longpaths=true', ...args]
        : args;
    final process = await Process.run(
      'git',
      gitArgs,
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
    );
    return _GitProcessResult(
      exitCode: process.exitCode,
      stdout: process.stdout.toString(),
      stderr: process.stderr.toString(),
    );
  }

  void _throwIfFailed(_GitProcessResult result, String message) {
    if (!result.success) {
      throw GitException('$message\n${result.stderr}${result.stdout}'.trim());
    }
  }

  _GitProcessResult _combine(
    _GitProcessResult first,
    _GitProcessResult second,
  ) {
    final stdout = _joinOutput(first.stdout, second.stdout);
    final stderr = _joinOutput(first.stderr, second.stderr);
    return _GitProcessResult(
      exitCode: second.exitCode,
      stdout: stdout,
      stderr: stderr,
    );
  }

  String _joinOutput(String first, String second) {
    if (first.isEmpty) return second;
    if (second.isEmpty) return first;
    if (first.endsWith('\n') || first.endsWith('\r')) {
      return '$first$second';
    }
    return '$first\n$second';
  }

  GitOperationResult _resultFromProcess(
    String operation,
    String branchName,
    _GitProcessResult result,
    DateTime startedAt,
  ) => GitOperationResult(
    operation: operation,
    branchName: branchName,
    success: result.success,
    stdout: result.stdout,
    stderr: result.stderr,
    startedAt: startedAt,
    finishedAt: DateTime.now(),
  );

  GitOperationResult _manualFailure(
    String operation,
    String branchName,
    String message,
    DateTime startedAt,
  ) => GitOperationResult(
    operation: operation,
    branchName: branchName,
    success: false,
    stdout: '',
    stderr: message,
    startedAt: startedAt,
    finishedAt: DateTime.now(),
  );
}

class GitException implements Exception {
  const GitException(this.message);
  final String message;

  @override
  String toString() => message;
}

class _GitProcessResult {
  const _GitProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}
