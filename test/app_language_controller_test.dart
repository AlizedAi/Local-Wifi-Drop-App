import 'package:flutter_test/flutter_test.dart';
import 'package:local_wifi_drop/src/app_language_controller.dart';

void main() {
  final language = AppLanguageController.instance;

  tearDown(() {
    language.language.value = AppLanguageController.english;
  });

  test('English is the default language', () {
    expect(language.language.value, AppLanguageController.english);
    expect(language.translate('Send'), 'Send');
  });

  test('Persian translates interface labels but preserves technical values', () {
    language.language.value = AppLanguageController.persian;

    expect(language.translate('Send'), 'ارسال');
    expect(language.translate('Receive'), 'دریافت');
    expect(language.translate('Log'), 'Log');
    expect(language.translate('192.168.1.25'), '192.168.1.25');
    expect(language.translate('example_document.pdf'), 'example_document.pdf');
  });
}
