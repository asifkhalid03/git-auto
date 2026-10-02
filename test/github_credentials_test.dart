import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:git_flow/github_credentials.dart';

void main() {
  test(
    'remembers selected collaborator across fetch, pull, push and restart',
    () async {
      final fake = _Git();
      final credentials = GitHubCredentials(run: fake.run);
      await credentials.prepare('repo', ['fetch', '--prune']);
      await credentials.prepare('repo', ['pull', '--no-rebase', '--no-edit']);
      await credentials.prepare('repo', [
        'push',
        '-u',
        'origin',
        'HEAD:branch-a',
      ]);
      await GitHubCredentials(
        run: fake.run,
      ).prepare('repo', ['fetch', '--all']);
      expect(fake.selections, 1);
      expect(fake.accounts['repo:${fake.url}'], 'collaborator');
      expect(fake.accounts.values, isNot(contains('secret-test-token')));
    },
  );

  test(
    'accounts are separate for different workspaces and push remotes',
    () async {
      final fake = _Git();
      final credentials = GitHubCredentials(run: fake.run);
      await credentials.prepare('repo-a', ['fetch', '--prune']);
      fake.selectedAccount = 'another-user';
      await credentials.prepare('repo-b', ['fetch', '--prune']);
      fake.pushUrl = 'https://github.com/another-org/fork.git';
      await credentials.prepare('repo-a', [
        'push',
        '-u',
        'origin',
        'HEAD:branch-a',
      ]);
      expect(fake.accounts['repo-a:${fake.url}'], 'collaborator');
      expect(fake.accounts['repo-b:${fake.url}'], 'another-user');
      expect(fake.accounts['repo-a:${fake.pushUrl}'], 'another-user');
      expect(fake.selections, 3);
    },
  );

  test(
    'cancelled selection stops without saving account or leaking credentials',
    () async {
      final fake = _Git()..cancel = true;
      await expectLater(
        GitHubCredentials(run: fake.run).prepare('repo', ['fetch', '--prune']),
        throwsA(
          isA<GitHubCredentialException>().having(
            (error) => error.message,
            'safe error',
            allOf(contains('cancelled'), isNot(contains('secret-test-token'))),
          ),
        ),
      );
      expect(fake.selections, 1);
      expect(fake.accounts, isEmpty);
    },
  );

  test('local commands never request credentials', () async {
    final fake = _Git();
    final credentials = GitHubCredentials(run: fake.run);
    for (final command in ['switch', 'status', 'log', 'merge']) {
      await credentials.prepare('repo', [command]);
    }
    expect(fake.calls, 0);
  });

  test(
    'explicit usernames, SSH and local remotes do not open account picker',
    () async {
      for (final url in [
        'https://chosen@github.com/org/repo.git',
        'git@github.com:org/repo.git',
        'D:/repos/remote.git',
      ]) {
        final fake = _Git()..url = url;
        await GitHubCredentials(
          run: fake.run,
        ).prepare('repo', ['fetch', '--prune']);
        expect(fake.selections, 0);
      }
    },
  );
}

class _Git {
  var url = 'https://github.com/team/repo.git';
  String? pushUrl;
  var selectedAccount = 'collaborator';
  var cancel = false;
  var selections = 0;
  var calls = 0;
  final accounts = <String, String>{};

  Future<ProcessResult> run(
    List<String> args,
    String repo, {
    String? input,
  }) async {
    calls++;
    ProcessResult result(String stdout, [int code = 0]) =>
        ProcessResult(0, code, stdout, '');
    if (args.first == 'branch') return result('branch-a\n');
    if (args.first == 'remote') {
      if (args.length == 1) return result('origin\n');
      return result('${args.contains('--push') ? pushUrl ?? url : url}\n');
    }
    if (args.first == 'config') {
      if (args[1] == '--get') return result('origin\n');
      if (args[1] == '--get-urlmatch') {
        final account = accounts['$repo:${args.last}'];
        return result(account ?? '', account == null ? 1 : 0);
      }
      expect(args[1], '--local');
      final key = args[2].substring('credential.'.length);
      accounts['$repo:${key.substring(0, key.length - '.username'.length)}'] =
          args.last;
      return result('');
    }
    expect(args, containsAllInOrder(['credential', 'fill']));
    expect(input, startsWith('url=https://github.com/'));
    selections++;
    return result(
      'username=$selectedAccount\npassword=secret-test-token\n',
      cancel ? 1 : 0,
    );
  }
}
