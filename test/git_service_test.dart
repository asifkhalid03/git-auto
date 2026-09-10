import 'dart:io';

import 'package:git_flow/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late GitService git;
  final externalCleanup = <Directory>[];

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('git_service_test_');
    git = GitService();
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    for (final dir in externalCleanup) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
    externalCleanup.clear();
  });

  test('validateRepository rejects a non-git folder', () async {
    await expectLater(
      git.validateRepository(path: tempDir.path, id: 'repo-1'),
      throwsA(isA<GitException>()),
    );
  });

  test(
    'validates repository, lists remote branches, and creates detached worktree',
    () async {
      final repoDir = await Directory(
        '${tempDir.path}${Platform.pathSeparator}repo',
      ).create();
      final remoteDir = '${tempDir.path}${Platform.pathSeparator}remote.git';
      final otherDir = '${tempDir.path}${Platform.pathSeparator}other-clone';

      await _runGit(['init', '--bare', remoteDir], tempDir.path);
      await _runGit(['init', '-b', 'main', '.'], repoDir.path);
      await _runGit(['config', 'user.email', 'test@example.com'], repoDir.path);
      await _runGit(['config', 'user.name', 'Test User'], repoDir.path);
      await File(
        '${repoDir.path}${Platform.pathSeparator}README.md',
      ).writeAsString('hello');
      await _runGit(['add', 'README.md'], repoDir.path);
      await _runGit(['commit', '-m', 'Initial commit'], repoDir.path);
      await _runGit(['remote', 'add', 'origin', remoteDir], repoDir.path);
      await _runGit(['push', '-u', 'origin', 'main'], repoDir.path);
      await _runGit(['symbolic-ref', 'HEAD', 'refs/heads/main'], remoteDir);
      await _runGit(['branch', 'develop'], repoDir.path);
      await _runGit(['switch', 'develop'], repoDir.path);
      await File(
        '${repoDir.path}${Platform.pathSeparator}develop.txt',
      ).writeAsString('develop branch');
      await _runGit(['add', 'develop.txt'], repoDir.path);
      await _runGit(['commit', '-m', 'Develop branch'], repoDir.path);
      await _runGit(['switch', 'main'], repoDir.path);

      await _runGit(['clone', '-b', 'main', remoteDir, otherDir], tempDir.path);
      await _runGit(['switch', '-c', 'remote-only'], otherDir);
      await _runGit(['config', 'user.email', 'test@example.com'], otherDir);
      await _runGit(['config', 'user.name', 'Test User'], otherDir);
      await File(
        '$otherDir${Platform.pathSeparator}remote.txt',
      ).writeAsString('remote branch');
      await _runGit(['add', 'remote.txt'], otherDir);
      await _runGit(['commit', '-m', 'Remote branch'], otherDir);
      await _runGit(['push', '-u', 'origin', 'remote-only'], otherDir);

      final repo = await git.validateRepository(
        path: repoDir.path,
        id: 'repo-1',
      );
      expect(await git.currentBranch(repo.path), 'main');

      await git.fetchBranches(repo.path);
      final branches = await git.listBranches(repo.path, includeRemote: true);
      final worktreeRoot = await Directory(
        '${tempDir.path}${Platform.pathSeparator}.app_worktrees',
      ).create();

      final worktreePath = await git.ensureWorktree(
        repoPath: repo.path,
        repoId: repo.id,
        branchName: 'remote-only',
        worktreesRoot: worktreeRoot,
      );
      if (!worktreePath.startsWith(tempDir.path)) {
        externalCleanup.add(Directory(worktreePath).parent);
      }
      final head = await _runGit([
        'rev-parse',
        '--abbrev-ref',
        'HEAD',
      ], worktreePath);
      final checkoutResult = await git.checkoutBranch(
        repoPath: repo.path,
        branchName: 'remote-only',
      );
      await _runGit(['switch', 'main'], repo.path);
      await File(
        '${repo.path}${Platform.pathSeparator}untracked.txt',
      ).writeAsString('local scratch');
      final uncommittedStatus = await git.getBranchStatus(
        repo.path,
        'origin/main',
      );
      final dirtyCheckoutResult = await git.checkoutBranch(
        repoPath: repo.path,
        branchName: 'develop',
      );
      final confirmedDirtyCheckoutResult = await git.checkoutBranch(
        repoPath: repo.path,
        branchName: 'develop',
        allowDirty: true,
      );
      expect(dirtyCheckoutResult.success, isFalse);
      await File('${repo.path}${Platform.pathSeparator}untracked.txt').delete();
      await _runGit(['switch', 'main'], repo.path);
      final cleanCheckoutResult = await git.checkoutBranch(
        repoPath: repo.path,
        branchName: 'develop',
      );
      final dirtyStatus = await git.getBranchStatus(
        repo.path,
        'origin/develop',
      );
      final syncResult = await git.syncMergeBranches(
        repoPath: repo.path,
        targetBranch: 'remote-only',
        sourceBranches: ['develop'],
      );
      await _runGit(['branch', '--set-upstream-to', 'origin/main'], repo.path);
      final syncPushResult = await git.pushSyncedBranches(
        repoPath: repo.path,
        branchNames: ['develop'],
      );
      final sameNameUpstream = await git.upstreamFor(repo.path, 'develop');
      final syncedRefStatus = await git.getBranchStatus(
        repo.path,
        sameNameUpstream,
        revision: 'develop',
        includeWorkingTree: false,
      );
      final remoteDevelopAfterSync = await _runGit([
        'rev-parse',
        'refs/heads/develop',
      ], remoteDir);
      await File(
        '${repo.path}${Platform.pathSeparator}push.txt',
      ).writeAsString('push me');
      await _runGit(['add', 'push.txt'], repo.path);
      await _runGit(['commit', '-m', 'Push branch'], repo.path);
      final undoResult = await git.undoLastCommit(
        repoPath: repo.path,
        branchName: 'develop',
      );
      final undoStatus = await git.getBranchStatus(repo.path, 'origin/develop');
      await _runGit(['commit', '-m', 'Push branch'], repo.path);
      final pushResult = await git.pushBranch(
        worktreePath: repo.path,
        branchName: 'develop',
      );
      final remoteDevelop = await _runGit([
        'rev-parse',
        'refs/heads/develop',
      ], remoteDir);

      expect(repo.name, isNotEmpty);
      expect(branches, contains('develop'));
      expect(branches, contains('remote-only'));
      expect(head.stdout.trim(), 'HEAD');
      expect(await Directory(worktreePath).exists(), isTrue);
      expect(checkoutResult.success, isTrue);
      expect(uncommittedStatus.changedFilesCount, 1);
      expect(confirmedDirtyCheckoutResult.success, isTrue);
      expect(cleanCheckoutResult.success, isTrue);
      expect(await git.currentBranch(repo.path), 'develop');
      expect(dirtyStatus.lastCommitHash, isNotEmpty);
      expect(syncResult.success, isTrue, reason: syncResult.summary);
      expect(syncPushResult.success, isTrue, reason: syncPushResult.summary);
      expect(sameNameUpstream, 'origin/develop');
      expect(syncedRefStatus.aheadCount, 0);
      expect(syncedRefStatus.behindCount, 0);
      expect(remoteDevelopAfterSync.stdout.trim(), isNotEmpty);
      expect(undoResult.success, isTrue, reason: undoResult.summary);
      expect(undoStatus.changedFilesCount, greaterThan(0));
      expect(pushResult.success, isTrue, reason: pushResult.summary);
      expect(remoteDevelop.stdout.trim(), isNotEmpty);
      expect(
        await File('${repo.path}${Platform.pathSeparator}remote.txt').exists(),
        isTrue,
      );
    },
  );

  test('syncMergeBranches one way follows branch path order', () async {
    final repoDir = await Directory(
      '${tempDir.path}${Platform.pathSeparator}repo',
    ).create();

    await _runGit(['init', '-b', 'branch-a', '.'], repoDir.path);
    await _runGit(['config', 'user.email', 'test@example.com'], repoDir.path);
    await _runGit(['config', 'user.name', 'Test User'], repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}a.txt',
    ).writeAsString('a');
    await _runGit(['add', 'a.txt'], repoDir.path);
    await _runGit(['commit', '-m', 'A branch'], repoDir.path);

    await _runGit(['switch', '-c', 'branch-b'], repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}b.txt',
    ).writeAsString('b');
    await _runGit(['add', 'b.txt'], repoDir.path);
    await _runGit(['commit', '-m', 'B branch'], repoDir.path);

    await _runGit(['switch', 'branch-a'], repoDir.path);
    await _runGit(['switch', '-c', 'branch-c'], repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}c.txt',
    ).writeAsString('c');
    await _runGit(['add', 'c.txt'], repoDir.path);
    await _runGit(['commit', '-m', 'C branch'], repoDir.path);

    await _runGit(['switch', 'branch-a'], repoDir.path);
    final result = await git.syncMergeBranches(
      repoPath: repoDir.path,
      targetBranch: 'branch-a',
      sourceBranches: ['branch-b', 'branch-c'],
    );

    expect(result.success, isTrue, reason: result.summary);
    await _runGit(['switch', 'branch-a'], repoDir.path);
    expect(
      await File('${repoDir.path}${Platform.pathSeparator}b.txt').exists(),
      isFalse,
      reason: 'branch-a is the source and should not receive branch-b',
    );
    await _runGit(['switch', 'branch-b'], repoDir.path);
    expect(
      await File('${repoDir.path}${Platform.pathSeparator}a.txt').exists(),
      isTrue,
      reason: 'branch-b should receive branch-a',
    );
    expect(
      await File('${repoDir.path}${Platform.pathSeparator}c.txt').exists(),
      isFalse,
      reason: 'branch-b should not receive branch-c in one-way sync',
    );
    await _runGit(['switch', 'branch-c'], repoDir.path);
    expect(
      await File('${repoDir.path}${Platform.pathSeparator}a.txt').exists(),
      isTrue,
      reason: 'branch-c should receive branch-a through branch-b',
    );
    expect(
      await File('${repoDir.path}${Platform.pathSeparator}b.txt').exists(),
      isTrue,
      reason: 'branch-c should receive branch-b',
    );
  });

  test(
    'syncMergeBranches can sync selected branches both directions',
    () async {
      final repoDir = await Directory(
        '${tempDir.path}${Platform.pathSeparator}repo',
      ).create();

      await _runGit(['init', '-b', 'branch-a', '.'], repoDir.path);
      await _runGit(['config', 'user.email', 'test@example.com'], repoDir.path);
      await _runGit(['config', 'user.name', 'Test User'], repoDir.path);
      await File(
        '${repoDir.path}${Platform.pathSeparator}a.txt',
      ).writeAsString('a');
      await _runGit(['add', 'a.txt'], repoDir.path);
      await _runGit(['commit', '-m', 'A branch'], repoDir.path);

      await _runGit(['switch', '-c', 'branch-b'], repoDir.path);
      await File(
        '${repoDir.path}${Platform.pathSeparator}b.txt',
      ).writeAsString('b');
      await _runGit(['add', 'b.txt'], repoDir.path);
      await _runGit(['commit', '-m', 'B branch'], repoDir.path);

      await _runGit(['switch', 'branch-a'], repoDir.path);
      await _runGit(['switch', '-c', 'branch-c'], repoDir.path);
      await File(
        '${repoDir.path}${Platform.pathSeparator}c.txt',
      ).writeAsString('c');
      await _runGit(['add', 'c.txt'], repoDir.path);
      await _runGit(['commit', '-m', 'C branch'], repoDir.path);

      await _runGit(['switch', 'branch-a'], repoDir.path);
      final result = await git.syncMergeBranches(
        repoPath: repoDir.path,
        targetBranch: 'branch-a',
        sourceBranches: ['branch-b', 'branch-c'],
        bothDirections: true,
      );

      expect(result.success, isTrue, reason: result.summary);
      for (final branch in ['branch-a', 'branch-b', 'branch-c']) {
        await _runGit(['switch', branch], repoDir.path);
        expect(
          await File('${repoDir.path}${Platform.pathSeparator}a.txt').exists(),
          isTrue,
          reason: '$branch should contain branch-a changes',
        );
        expect(
          await File('${repoDir.path}${Platform.pathSeparator}b.txt').exists(),
          isTrue,
          reason: '$branch should contain branch-b changes',
        );
        expect(
          await File('${repoDir.path}${Platform.pathSeparator}c.txt').exists(),
          isTrue,
          reason: '$branch should contain branch-c changes',
        );
      }
    },
  );

  test('syncSequentialBranches syncs each adjacent pair both ways', () async {
    final fixture = await _createThreeBranchRemoteRepo(tempDir);

    await _runGit(['switch', 'branch-b'], fixture.otherDir);
    await File(
      '${fixture.otherDir}${Platform.pathSeparator}remote-b.txt',
    ).writeAsString('remote b');
    await _runGit(['add', 'remote-b.txt'], fixture.otherDir);
    await _runGit(['commit', '-m', 'Remote B update'], fixture.otherDir);
    await _runGit(['push'], fixture.otherDir);

    final steps = <String>[];
    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    final result = await git.syncSequentialBranches(
      repoPath: fixture.repoDir.path,
      startBranch: 'branch-a',
      nextBranches: ['branch-b', 'branch-c'],
      onStep: (step) async {
        steps.add('${step.fromBranch}->${step.toBranch}');
      },
    );

    expect(result.success, isTrue, reason: result.summary);
    expect(
      steps,
      containsAllInOrder([
        'branch-c->branch-b',
        'branch-b->branch-a',
        'branch-a->branch-b',
        'branch-b->branch-c',
      ]),
    );
    for (final branch in ['branch-a', 'branch-b', 'branch-c']) {
      await _runGit(['switch', branch], fixture.repoDir.path);
      expect(
        await File(
          '${fixture.repoDir.path}${Platform.pathSeparator}remote-b.txt',
        ).exists(),
        isTrue,
        reason: '$branch should receive branch-b pulled changes',
      );
    }
    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    final mergeMessage = await _runGit(
      ['log', '-1', '--pretty=%s'],
      fixture.repoDir.path,
    );
    expect(
      mergeMessage.stdout.trim(),
      "Merge branch 'branch-b' into branch-a",
    );
  });

  test(
    'syncSequentialBranches passes branch-c pulled changes through adjacent pairs',
    () async {
      final fixture = await _createThreeBranchRemoteRepo(tempDir);

      await _runGit(['switch', 'branch-c'], fixture.otherDir);
      await File(
        '${fixture.otherDir}${Platform.pathSeparator}remote-c.txt',
      ).writeAsString('remote c');
      await _runGit(['add', 'remote-c.txt'], fixture.otherDir);
      await _runGit(['commit', '-m', 'Remote C update'], fixture.otherDir);
      await _runGit(['push'], fixture.otherDir);

      final steps = <String>[];
      await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
      final result = await git.syncSequentialBranches(
        repoPath: fixture.repoDir.path,
        startBranch: 'branch-a',
        nextBranches: ['branch-b', 'branch-c'],
        onStep: (step) async {
          steps.add('${step.fromBranch}->${step.toBranch}');
        },
      );

      expect(result.success, isTrue, reason: result.summary);
      expect(
        steps,
        containsAllInOrder([
          'branch-c->branch-b',
          'branch-b->branch-a',
          'branch-a->branch-b',
          'branch-b->branch-c',
        ]),
      );
      for (final branch in ['branch-a', 'branch-b', 'branch-c']) {
        await _runGit(['switch', branch], fixture.repoDir.path);
        expect(
          await File(
            '${fixture.repoDir.path}${Platform.pathSeparator}remote-c.txt',
          ).exists(),
          isTrue,
          reason: '$branch should receive branch-c pulled changes',
        );
      }
    },
  );

  test(
    'syncSequentialBranches runs both-way pair merges without remote changes',
    () async {
      final fixture = await _createThreeBranchRemoteRepo(tempDir);

      final steps = <String>[];
      await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
      final result = await git.syncSequentialBranches(
        repoPath: fixture.repoDir.path,
        startBranch: 'branch-a',
        nextBranches: ['branch-b', 'branch-c'],
        onStep: (step) async {
          steps.add('${step.fromBranch}->${step.toBranch}');
        },
      );

      expect(result.success, isTrue, reason: result.summary);
      expect(steps, [
        'branch-c->branch-b',
        'branch-b->branch-a',
        'branch-a->branch-b',
        'branch-b->branch-c',
      ]);
      for (final branch in ['branch-a', 'branch-b', 'branch-c']) {
        await _runGit(['switch', branch], fixture.repoDir.path);
        expect(
          await File(
            '${fixture.repoDir.path}${Platform.pathSeparator}b.txt',
          ).exists(),
          isTrue,
          reason: '$branch should receive branch-b changes',
        );
        expect(
          await File(
            '${fixture.repoDir.path}${Platform.pathSeparator}c.txt',
          ).exists(),
          isTrue,
          reason: '$branch should receive branch-c changes through pair sync',
        );
      }
    },
  );

  test('syncSequentialBranches pushes branches after cascade merges', () async {
    final fixture = await _createThreeBranchRemoteRepo(tempDir);

    await _runGit(['switch', 'branch-c'], fixture.repoDir.path);
    await File(
      '${fixture.repoDir.path}${Platform.pathSeparator}local-c-push.txt',
    ).writeAsString('local c');
    await _runGit(['add', 'local-c-push.txt'], fixture.repoDir.path);
    await _runGit(['commit', '-m', 'Local C push'], fixture.repoDir.path);
    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);

    final result = await git.syncSequentialBranches(
      repoPath: fixture.repoDir.path,
      startBranch: 'branch-a',
      nextBranches: ['branch-b', 'branch-c'],
      pushAfterMerge: true,
    );

    expect(result.success, isTrue, reason: result.summary);

    await _runGit(['fetch', 'origin', 'branch-a'], fixture.otherDir);
    final remoteAFile = await _runGit([
      'show',
      'origin/branch-a:local-c-push.txt',
    ], fixture.otherDir);
    await _runGit(['fetch', 'origin', 'branch-b'], fixture.otherDir);
    final remoteBFile = await _runGit([
      'show',
      'origin/branch-b:local-c-push.txt',
    ], fixture.otherDir);

    expect(remoteAFile.stdout.trim(), 'local c');
    expect(remoteBFile.stdout.trim(), 'local c');
  });

  test('mergeBranchIntoCurrent pulls source and merges into current', () async {
    final fixture = await _createThreeBranchRemoteRepo(tempDir);
    final progress = <String>[];

    await _runGit(['switch', 'branch-b'], fixture.otherDir);
    await File(
      '${fixture.otherDir}${Platform.pathSeparator}remote-b-merge.txt',
    ).writeAsString('remote b merge');
    await _runGit(['add', 'remote-b-merge.txt'], fixture.otherDir);
    await _runGit(['commit', '-m', 'Remote B merge'], fixture.otherDir);
    await _runGit(['push'], fixture.otherDir);

    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    final result = await git.mergeBranchIntoCurrent(
      repoPath: fixture.repoDir.path,
      currentBranch: 'branch-a',
      sourceBranch: 'branch-b',
      onProgress: (message) async => progress.add(message),
    );

    expect(result.success, isTrue, reason: result.summary);
    expect(await git.currentBranch(fixture.repoDir.path), 'branch-a');
    expect(
      await File(
        '${fixture.repoDir.path}${Platform.pathSeparator}remote-b-merge.txt',
      ).exists(),
      isTrue,
    );
    expect(
      progress,
      containsAllInOrder([
        'Checking out branch-b',
        'Pulling branch-b',
        'Checking out branch-a',
        'Merging branch-b into branch-a',
      ]),
    );
    final mergeMessage = await _runGit(
      ['log', '-1', '--pretty=%s'],
      fixture.repoDir.path,
    );
    expect(
      mergeMessage.stdout.trim(),
      "Merge branch 'branch-b' into branch-a",
    );
  });

  test('mergeBranchIntoCurrent reports conflicts and aborts safely', () async {
    final fixture = await _createThreeBranchRemoteRepo(tempDir);
    final conflicts = <MergeConflictPreview>[];

    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    await File(
      '${fixture.repoDir.path}${Platform.pathSeparator}shared.txt',
    ).writeAsString('branch a');
    await _runGit(['add', 'shared.txt'], fixture.repoDir.path);
    await _runGit(['commit', '-m', 'Branch A shared'], fixture.repoDir.path);
    await _runGit(['push'], fixture.repoDir.path);

    await _runGit(['switch', 'branch-b'], fixture.repoDir.path);
    await File(
      '${fixture.repoDir.path}${Platform.pathSeparator}shared.txt',
    ).writeAsString('branch b');
    await _runGit(['add', 'shared.txt'], fixture.repoDir.path);
    await _runGit(['commit', '-m', 'Branch B shared'], fixture.repoDir.path);
    await _runGit(['push'], fixture.repoDir.path);

    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    final result = await git.mergeBranchIntoCurrent(
      repoPath: fixture.repoDir.path,
      currentBranch: 'branch-a',
      sourceBranch: 'branch-b',
      onConflicts: (items) async => conflicts.addAll(items),
    );
    final unmerged = await _runGit([
      'diff',
      '--name-only',
      '--diff-filter=U',
    ], fixture.repoDir.path);

    expect(result.success, isFalse);
    expect(conflicts, hasLength(1));
    expect(conflicts.first.sourceBranch, 'branch-b');
    expect(conflicts.first.targetBranch, 'branch-a');
    expect(conflicts.first.files, contains('shared.txt'));
    expect(await git.currentBranch(fixture.repoDir.path), 'branch-a');
    expect(unmerged.stdout.trim(), isEmpty);
  });

  test('commitBranch can amend the latest commit', () async {
    final repoDir = await Directory(
      '${tempDir.path}${Platform.pathSeparator}repo',
    ).create();

    await _runGit(['init', '-b', 'main', '.'], repoDir.path);
    await _configureUser(repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}file.txt',
    ).writeAsString('first');
    await _runGit(['add', 'file.txt'], repoDir.path);
    await _runGit(['commit', '-m', 'Initial'], repoDir.path);

    await File(
      '${repoDir.path}${Platform.pathSeparator}file.txt',
    ).writeAsString('first\nsecond');
    final result = await git.commitBranch(
      worktreePath: repoDir.path,
      branchName: 'main',
      message: 'Initial amended',
      description: 'Extra details',
      files: ['file.txt'],
      amend: true,
    );
    final count = await _runGit(['rev-list', '--count', 'HEAD'], repoDir.path);
    final message = await _runGit(['log', '-1', '--pretty=%B'], repoDir.path);

    expect(result.success, isTrue, reason: result.summary);
    expect(count.stdout.trim(), '1');
    expect(message.stdout, contains('Initial amended'));
    expect(message.stdout, contains('Extra details'));
  });

  test(
    'pullSelectedBranches pulls each selected branch and restores start branch',
    () async {
      final fixture = await _createThreeBranchRemoteRepo(tempDir);

      await _runGit(['switch', 'branch-b'], fixture.otherDir);
      await File(
        '${fixture.otherDir}${Platform.pathSeparator}remote-b-pull.txt',
      ).writeAsString('remote b');
      await _runGit(['add', 'remote-b-pull.txt'], fixture.otherDir);
      await _runGit(['commit', '-m', 'Remote B pull'], fixture.otherDir);
      await _runGit(['push'], fixture.otherDir);

      await _runGit(['switch', 'branch-c'], fixture.otherDir);
      await File(
        '${fixture.otherDir}${Platform.pathSeparator}remote-c-pull.txt',
      ).writeAsString('remote c');
      await _runGit(['add', 'remote-c-pull.txt'], fixture.otherDir);
      await _runGit(['commit', '-m', 'Remote C pull'], fixture.otherDir);
      await _runGit(['push'], fixture.otherDir);

      await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
      final result = await git.pullSelectedBranches(
        repoPath: fixture.repoDir.path,
        startBranch: 'branch-a',
        branchNames: ['branch-a', 'branch-b', 'branch-c'],
      );

      expect(result.success, isTrue, reason: result.summary);
      expect(await git.currentBranch(fixture.repoDir.path), 'branch-a');

      await _runGit(['switch', 'branch-b'], fixture.repoDir.path);
      expect(
        await File(
          '${fixture.repoDir.path}${Platform.pathSeparator}remote-b-pull.txt',
        ).exists(),
        isTrue,
      );
      await _runGit(['switch', 'branch-c'], fixture.repoDir.path);
      expect(
        await File(
          '${fixture.repoDir.path}${Platform.pathSeparator}remote-c-pull.txt',
        ).exists(),
        isTrue,
      );
    },
  );

  test('pullSelectedBranches blocks dirty current branch', () async {
    final fixture = await _createThreeBranchRemoteRepo(tempDir);

    await _runGit(['switch', 'branch-a'], fixture.repoDir.path);
    await File(
      '${fixture.repoDir.path}${Platform.pathSeparator}dirty.txt',
    ).writeAsString('dirty');

    final result = await git.pullSelectedBranches(
      repoPath: fixture.repoDir.path,
      startBranch: 'branch-a',
      branchNames: ['branch-a', 'branch-b'],
    );

    expect(result.success, isFalse);
    expect(result.summary, contains('local changes on branch-a'));
    expect(await git.currentBranch(fixture.repoDir.path), 'branch-a');
  });

  test('preflightSequentialMergeConflicts reports conflicts safely', () async {
    final repoDir = await Directory(
      '${tempDir.path}${Platform.pathSeparator}repo',
    ).create();

    await _runGit(['init', '-b', 'branch-a', '.'], repoDir.path);
    await _configureUser(repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}shared.txt',
    ).writeAsString('base\n');
    await _runGit(['add', 'shared.txt'], repoDir.path);
    await _runGit(['commit', '-m', 'Base'], repoDir.path);

    await _runGit(['switch', '-c', 'branch-b'], repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}shared.txt',
    ).writeAsString('branch b\n');
    await _runGit(['commit', '-am', 'Branch B change'], repoDir.path);

    await _runGit(['switch', 'branch-a'], repoDir.path);
    await File(
      '${repoDir.path}${Platform.pathSeparator}shared.txt',
    ).writeAsString('branch a\n');
    await _runGit(['commit', '-am', 'Branch A change'], repoDir.path);

    final conflicts = await git.preflightSequentialMergeConflicts(
      repoPath: repoDir.path,
      startBranch: 'branch-a',
      nextBranches: ['branch-b'],
    );
    final unmerged = await _runGit([
      'diff',
      '--name-only',
      '--diff-filter=U',
    ], repoDir.path);

    expect(conflicts, isNotEmpty);
    expect(conflicts.first.sourceBranch, 'branch-b');
    expect(conflicts.first.targetBranch, 'branch-a');
    expect(conflicts.first.conflictCount, 1);
    expect(conflicts.first.files, contains('shared.txt'));
    expect(await git.currentBranch(repoDir.path), 'branch-a');
    expect(unmerged.stdout.trim(), isEmpty);
  });
}

Future<_ThreeBranchFixture> _createThreeBranchRemoteRepo(
  Directory tempDir,
) async {
  final repoDir = await Directory(
    '${tempDir.path}${Platform.pathSeparator}repo',
  ).create();
  final remoteDir = '${tempDir.path}${Platform.pathSeparator}remote.git';
  final otherDir = '${tempDir.path}${Platform.pathSeparator}other-clone';

  await _runGit(['init', '--bare', remoteDir], tempDir.path);
  await _runGit(['init', '-b', 'branch-a', '.'], repoDir.path);
  await _configureUser(repoDir.path);
  await File(
    '${repoDir.path}${Platform.pathSeparator}a.txt',
  ).writeAsString('a');
  await _runGit(['add', 'a.txt'], repoDir.path);
  await _runGit(['commit', '-m', 'A branch'], repoDir.path);
  await _runGit(['remote', 'add', 'origin', remoteDir], repoDir.path);
  await _runGit(['push', '-u', 'origin', 'branch-a'], repoDir.path);

  await _runGit(['switch', '-c', 'branch-b'], repoDir.path);
  await File(
    '${repoDir.path}${Platform.pathSeparator}b.txt',
  ).writeAsString('b');
  await _runGit(['add', 'b.txt'], repoDir.path);
  await _runGit(['commit', '-m', 'B branch'], repoDir.path);
  await _runGit(['push', '-u', 'origin', 'branch-b'], repoDir.path);

  await _runGit(['switch', 'branch-a'], repoDir.path);
  await _runGit(['switch', '-c', 'branch-c'], repoDir.path);
  await File(
    '${repoDir.path}${Platform.pathSeparator}c.txt',
  ).writeAsString('c');
  await _runGit(['add', 'c.txt'], repoDir.path);
  await _runGit(['commit', '-m', 'C branch'], repoDir.path);
  await _runGit(['push', '-u', 'origin', 'branch-c'], repoDir.path);
  await _runGit(['switch', 'branch-a'], repoDir.path);
  await _runGit(['symbolic-ref', 'HEAD', 'refs/heads/branch-a'], remoteDir);

  await _runGit(['clone', remoteDir, otherDir], tempDir.path);
  await _configureUser(otherDir);
  await _runGit(['switch', 'branch-b'], otherDir);
  await _runGit(['switch', 'branch-c'], otherDir);

  return _ThreeBranchFixture(
    repoDir: repoDir,
    remoteDir: remoteDir,
    otherDir: otherDir,
  );
}

Future<void> _configureUser(String workingDirectory) async {
  await _runGit(['config', 'user.email', 'test@example.com'], workingDirectory);
  await _runGit(['config', 'user.name', 'Test User'], workingDirectory);
}

class _ThreeBranchFixture {
  const _ThreeBranchFixture({
    required this.repoDir,
    required this.remoteDir,
    required this.otherDir,
  });

  final Directory repoDir;
  final String remoteDir;
  final String otherDir;
}

Future<_ProcessOutput> _runGit(
  List<String> args,
  String workingDirectory,
) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: workingDirectory,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed\n${result.stderr}\n${result.stdout}');
  }
  return _ProcessOutput(result.stdout.toString(), result.stderr.toString());
}

class _ProcessOutput {
  const _ProcessOutput(this.stdout, this.stderr);
  final String stdout;
  final String stderr;
}
