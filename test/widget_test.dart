import 'package:git_flow/main.dart';
import 'package:git_flow/models.dart';
import 'package:git_flow/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BranchStatus labels common git states', () {
    final now = DateTime(2026);

    expect(
      BranchStatus(
        aheadCount: 0,
        behindCount: 0,
        hasLocalChanges: false,
        hasConflicts: false,
        lastCheckedAt: now,
      ).label,
      'Up to date',
    );
    expect(
      BranchStatus(
        aheadCount: 0,
        behindCount: 2,
        hasLocalChanges: false,
        hasConflicts: false,
        lastCheckedAt: now,
      ).label,
      '2 updates behind',
    );
    expect(
      BranchStatus(
        aheadCount: 1,
        behindCount: 0,
        hasLocalChanges: false,
        hasConflicts: false,
        lastCheckedAt: now,
      ).label,
      '1 commit ahead',
    );
    expect(
      BranchStatus(
        aheadCount: 1,
        behindCount: 1,
        hasLocalChanges: false,
        hasConflicts: false,
        lastCheckedAt: now,
      ).label,
      'Diverged',
    );
  });

  testWidgets('repository picker renders saved repositories', (tester) async {
    const repo = RepositoryInfo(
      id: 'repo-1',
      name: 'ecommerce-project',
      path: r'D:\Projects\ecommerce-project',
      defaultBranch: 'main',
      remoteUrl: 'git@example.com:ecommerce-project.git',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepositoryPicker(
            repositories: const [repo],
            selectedRepo: repo,
            onChooseFolder: () {},
            onSelect: (_) {},
            onNext: () {},
          ),
        ),
      ),
    );

    expect(find.text('Select Repository'), findsOneWidget);
    expect(find.text('ecommerce-project'), findsOneWidget);
    expect(find.text(r'D:\Projects\ecommerce-project'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });

  test('compareVersions handles release tags', () {
    expect(compareVersions('1.0.3', '1.0.2'), greaterThan(0));
    expect(compareVersions('v1.0.2', '1.0.2'), 0);
    expect(compareVersions('1.0.1', '1.0.2'), lessThan(0));
  });
}
