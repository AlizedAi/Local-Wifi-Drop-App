import 'package:flutter/foundation.dart';

/// Runtime language selection. Translations are intentionally added later.
class AppLanguageController {
  AppLanguageController._();

  static final AppLanguageController instance = AppLanguageController._();

  static const String english = 'en';
  static const String persian = 'fa';

  final ValueNotifier<String> language = ValueNotifier<String>(english);

  void select(String value) {
    if (value == english || value == persian) {
      language.value = value;
    }
  }
}
