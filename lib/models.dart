import 'dart:convert';

class RepositoryInfo {
  const RepositoryInfo({
    required this.id,
    required this.name,
    required this.path,
    required this.defaultBranch,
    required this.remoteUrl,
  });

  final String id;
  final String name;
  final String path;
  final String defaultBranch;
  final String remoteUrl;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'defaultBranch': defaultBranch,
    'remoteUrl': remoteUrl,
  };

  factory RepositoryInfo.fromJson(Map<String, dynamic> json) => RepositoryInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    path: json['path'] as String,
    defaultBranch: json['defaultBranch'] as String? ?? '',
    remoteUrl: json['remoteUrl'] as String? ?? '',
  );
}

class TrackedBranch {
  const TrackedBranch({
    required this.repoId,
    required this.branchName,
    required this.upstream,
    required this.worktreePath,
    this.lastPullAt,
    this.lastStatus,
  });

  final String repoId;
  final String branchName;
  final String upstream;
  final String worktreePath;
  final DateTime? lastPullAt;
  final BranchStatus? lastStatus;

  TrackedBranch copyWith({
    String? repoId,
    String? branchName,
    String? upstream,
    String? worktreePath,
    DateTime? lastPullAt,
    BranchStatus? lastStatus,
  }) => TrackedBranch(
    repoId: repoId ?? this.repoId,
    branchName: branchName ?? this.branchName,
    upstream: upstream ?? this.upstream,
    worktreePath: worktreePath ?? this.worktreePath,
    lastPullAt: lastPullAt ?? this.lastPullAt,
    lastStatus: lastStatus ?? this.lastStatus,
  );

  Map<String, dynamic> toJson() => {
    'repoId': repoId,
    'branchName': branchName,
    'upstream': upstream,
    'worktreePath': worktreePath,
    'lastPullAt': lastPullAt?.toIso8601String(),
    'lastStatus': lastStatus?.toJson(),
  };

  factory TrackedBranch.fromJson(Map<String, dynamic> json) => TrackedBranch(
    repoId: json['repoId'] as String,
    branchName: json['branchName'] as String,
    upstream: json['upstream'] as String? ?? '',
    worktreePath: json['worktreePath'] as String,
    lastPullAt: json['lastPullAt'] == null
        ? null
        : DateTime.parse(json['lastPullAt'] as String),
    lastStatus: json['lastStatus'] == null
        ? null
        : BranchStatus.fromJson(json['lastStatus'] as Map<String, dynamic>),
  );
}

class BranchStatus {
  const BranchStatus({
    required this.aheadCount,
    required this.behindCount,
    required this.hasLocalChanges,
    required this.hasConflicts,
    required this.lastCheckedAt,
    this.changedFilesCount = 0,
    this.lastCommitHash = '',
    this.lastCommitMessage = '',
    this.error,
  });

  final int aheadCount;
  final int behindCount;
  final bool hasLocalChanges;
  final bool hasConflicts;
  final DateTime lastCheckedAt;
  final int changedFilesCount;
  final String lastCommitHash;
  final String lastCommitMessage;
  final String? error;

  bool get hasError => error != null && error!.isNotEmpty;

  String get label {
    if (hasError) return 'Error';
    if (hasConflicts) return 'Conflicts';
    if (hasLocalChanges) return 'Local changes';
    if (aheadCount > 0 && behindCount > 0) {
      return 'Diverged';
    }
    if (behindCount > 0) {
      return '$behindCount ${behindCount == 1 ? 'update' : 'updates'} behind';
    }
    if (aheadCount > 0) {
      return '$aheadCount ${aheadCount == 1 ? 'commit' : 'commits'} ahead';
    }
    return 'Up to date';
  }

  Map<String, dynamic> toJson() => {
    'aheadCount': aheadCount,
    'behindCount': behindCount,
    'hasLocalChanges': hasLocalChanges,
    'hasConflicts': hasConflicts,
    'lastCheckedAt': lastCheckedAt.toIso8601String(),
    'changedFilesCount': changedFilesCount,
    'lastCommitHash': lastCommitHash,
    'lastCommitMessage': lastCommitMessage,
    'error': error,
  };

  factory BranchStatus.fromJson(Map<String, dynamic> json) => BranchStatus(
    aheadCount: json['aheadCount'] as int? ?? 0,
    behindCount: json['behindCount'] as int? ?? 0,
    hasLocalChanges: json['hasLocalChanges'] as bool? ?? false,
    hasConflicts: json['hasConflicts'] as bool? ?? false,
    lastCheckedAt: DateTime.parse(json['lastCheckedAt'] as String),
    changedFilesCount: json['changedFilesCount'] as int? ?? 0,
    lastCommitHash: json['lastCommitHash'] as String? ?? '',
    lastCommitMessage: json['lastCommitMessage'] as String? ?? '',
    error: json['error'] as String?,
  );
}

class GitOperationResult {
  const GitOperationResult({
    required this.operation,
    required this.branchName,
    required this.success,
    required this.stdout,
    required this.stderr,
    required this.startedAt,
    required this.finishedAt,
  });

  final String operation;
  final String branchName;
  final bool success;
  final String stdout;
  final String stderr;
  final DateTime startedAt;
  final DateTime finishedAt;

  String get summary {
    final text = [stdout.trim(), stderr.trim()].where((e) => e.isNotEmpty);
    return text.isEmpty ? 'No output' : text.join('\n');
  }

  Map<String, dynamic> toJson() => {
    'operation': operation,
    'branchName': branchName,
    'success': success,
    'stdout': stdout,
    'stderr': stderr,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt.toIso8601String(),
  };

  factory GitOperationResult.fromJson(Map<String, dynamic> json) =>
      GitOperationResult(
        operation: json['operation'] as String,
        branchName: json['branchName'] as String,
        success: json['success'] as bool,
        stdout: json['stdout'] as String? ?? '',
        stderr: json['stderr'] as String? ?? '',
        startedAt: DateTime.parse(json['startedAt'] as String),
        finishedAt: DateTime.parse(json['finishedAt'] as String),
      );
}

class AppStateSnapshot {
  const AppStateSnapshot({
    required this.repositories,
    required this.branches,
    required this.operations,
  });

  final List<RepositoryInfo> repositories;
  final List<TrackedBranch> branches;
  final List<GitOperationResult> operations;

  Map<String, dynamic> toJson() => {
    'repositories': repositories.map((repo) => repo.toJson()).toList(),
    'branches': branches.map((branch) => branch.toJson()).toList(),
    'operations': operations.map((op) => op.toJson()).toList(),
  };

  factory AppStateSnapshot.fromJson(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    return AppStateSnapshot(
      repositories: (json['repositories'] as List<dynamic>? ?? [])
          .map((item) => RepositoryInfo.fromJson(item as Map<String, dynamic>))
          .toList(),
      branches: (json['branches'] as List<dynamic>? ?? [])
          .map((item) => TrackedBranch.fromJson(item as Map<String, dynamic>))
          .toList(),
      operations: (json['operations'] as List<dynamic>? ?? [])
          .map(
            (item) => GitOperationResult.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  static const empty = AppStateSnapshot(
    repositories: [],
    branches: [],
    operations: [],
  );
}
