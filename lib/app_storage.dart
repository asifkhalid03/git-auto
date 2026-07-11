import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'models.dart';

class AppStorage {
  Future<File> _stateFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'state.json'));
  }

  Future<Directory> worktreesDirectory() async {
    final dir = await getApplicationSupportDirectory();
    final worktrees = Directory(p.join(dir.path, 'worktrees'));
    if (!await worktrees.exists()) {
      await worktrees.create(recursive: true);
    }
    return worktrees;
  }

  Future<AppStateSnapshot> load() async {
    final file = await _stateFile();
    if (!await file.exists()) {
      return AppStateSnapshot.empty;
    }
    try {
      return AppStateSnapshot.fromJson(await file.readAsString());
    } catch (_) {
      return AppStateSnapshot.empty;
    }
  }

  Future<void> save(AppStateSnapshot state) async {
    final file = await _stateFile();
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(state.toJson()));
  }
}
