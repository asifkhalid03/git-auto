import 'dart:convert';
import 'dart:io';

typedef CredentialGitRunner =
    Future<ProcessResult> Function(
      List<String> arguments,
      String workingDirectory, {
      String? input,
    });

class GitHubCredentials {
  GitHubCredentials({CredentialGitRunner? run}) : _run = run ?? _runGit;

  final CredentialGitRunner _run;

  Future<void> prepare(String repoPath, List<String> command) async {
    if (command.isEmpty ||
        !const ['fetch', 'pull', 'push'].contains(command.first)) {
      return;
    }

    final remotes = <String>[];
    if (command.first == 'fetch' && command.contains('--all')) {
      final result = await _run(['remote'], repoPath);
      if (result.exitCode != 0) return;
      remotes.addAll(
        LineSplitter.split('${result.stdout}').where((s) => s.isNotEmpty),
      );
    } else if (command.first == 'push') {
      // All application pushes explicitly target origin.
      remotes.add('origin');
    } else {
      final branch = await _run(['branch', '--show-current'], repoPath);
      final remote = await _run([
        'config',
        '--get',
        'branch.${'${branch.stdout}'.trim()}.remote',
      ], repoPath);
      remotes.add(remote.exitCode == 0 ? '${remote.stdout}'.trim() : 'origin');
    }

    for (final remote in remotes) {
      if (remote == '.') continue;
      final urls = await _run([
        'remote',
        'get-url',
        if (command.first == 'push') '--push',
        '--all',
        remote,
      ], repoPath);
      if (urls.exitCode != 0) continue;
      for (final url in LineSplitter.split('${urls.stdout}')) {
        await _rememberAccount(repoPath, url.trim());
      }
    }
  }

  Future<void> _rememberAccount(String repoPath, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return;
    }
    if (uri.userInfo.isNotEmpty) return;

    final configured = await _run([
      'config',
      '--get-urlmatch',
      'credential.username',
      url,
    ], repoPath);
    if (configured.exitCode == 0 && '${configured.stdout}'.trim().isNotEmpty) {
      return;
    }

    // Resolve the user's choice once, then persist only its username. Never
    // return credential output to operation logs or application storage.
    final credential = await _run(
      ['-c', 'credential.useHttpPath=true', 'credential', 'fill'],
      repoPath,
      input: 'url=$url\n\n',
    );
    if (credential.exitCode != 0) {
      throw const GitHubCredentialException(
        'GitHub account selection was cancelled or sign-in failed. Operation stopped.',
      );
    }
    final usernameLine = LineSplitter.split(
      '${credential.stdout}',
    ).where((line) => line.startsWith('username=')).firstOrNull;
    final username = usernameLine?.substring('username='.length) ?? '';
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9-]{0,38}$').hasMatch(username)) {
      throw const GitHubCredentialException(
        'GitHub did not return an account username. Operation stopped.',
      );
    }
    final saved = await _run([
      'config',
      '--local',
      'credential.$url.username',
      username,
    ], repoPath);
    if (saved.exitCode != 0) {
      throw const GitHubCredentialException(
        'Could not remember the GitHub account for this repository. Operation stopped.',
      );
    }
  }

  static Future<ProcessResult> _runGit(
    List<String> arguments,
    String workingDirectory, {
    String? input,
  }) async {
    final process = await Process.start(
      'git',
      arguments,
      workingDirectory: workingDirectory,
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, await stdout, await stderr);
  }
}

class GitHubCredentialException implements Exception {
  const GitHubCredentialException(this.message);
  final String message;
}
