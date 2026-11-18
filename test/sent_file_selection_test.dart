import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/sent_file_selection.dart';

void main() {
  test('removes only the exact files included in the completed batch', () {
    final sentFirst = Object();
    final sentSecond = Object();
    final stillQueued = Object();
    final selected = [sentFirst, sentSecond, stillQueued];

    removeSuccessfullySentFiles(selected, [sentFirst, sentSecond]);

    expect(selected, [stillQueued]);
  });

  test('leaves the selection unchanged when the completed batch is empty', () {
    final queued = Object();
    final selected = [queued];

    removeSuccessfullySentFiles(selected, const <Object>[]);

    expect(selected, [queued]);
  });
}
