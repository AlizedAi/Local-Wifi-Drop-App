import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Runtime language selection and UI-only translations.
class AppLanguageController {
  AppLanguageController._();

  static final AppLanguageController instance = AppLanguageController._();

  static const String english = 'en';
  static const String persian = 'fa';
  static const MethodChannel _channel = MethodChannel('local_wifi_drop/settings');

  final ValueNotifier<String> language = ValueNotifier<String>(english);

  bool get isPersian => language.value == persian;

  Future<void> load() async {
    try {
      final saved = await _channel.invokeMethod<String>('getLanguage');
      if (saved == english || saved == persian) language.value = saved!;
    } on PlatformException {
      // Keep English if Android settings storage is temporarily unavailable.
    } on MissingPluginException {
      // Widget tests and non-Android targets use the English default.
    }
  }

  Future<void> select(String value) async {
    if (value != english && value != persian) return;
    language.value = value;
    try {
      await _channel.invokeMethod<void>('setLanguage', value);
    } on PlatformException {
      // The current session still uses the selected language.
    } on MissingPluginException {
      // Persistence is provided by the Android host application.
    }
  }

  String translate(String value) {
    if (!isPersian) return value;
    return _persian[value] ?? value;
  }

  static const Map<String, String> _persian = {
    'Send': 'ارسال',
    'Receive': 'دریافت',
    'Options': 'گزینه‌ها',
    'IMPORTANT': 'مهم',
    'Important': 'مهم',
    'I understand': 'متوجه شدم',
    'Languages': 'زبان',
    'Notifications': 'اعلان‌ها',
    'Storage': 'حافظه',
    'Wifi': 'وای‌فای',
    'Alert': 'هشدار',
    'About': 'درباره',
    'Exit': 'خروج',
    'Close': 'بستن',
    'SENT': 'ارسال‌شده',
    'RECEIVED': 'دریافت‌شده',
    'FAILED': 'ناموفق',
    'CANCELLED': 'لغوشده',
    'PENDING': 'در انتظار',
    'responding device(s)': 'دستگاه پاسخ‌گو',
    'file(s)': 'فایل',
    'Waiting for application events…': 'در انتظار رویدادهای برنامه…',
    'Files and messages are transferred over your local Wi-Fi network without encryption. Do not send passwords, financial information, private documents, or other sensitive content. Only transfer files to devices and people you trust.': 'فایل‌ها و پیام‌ها در شبکه وای‌فای محلی شما بدون رمزنگاری منتقل می‌شوند. گذرواژه‌ها، اطلاعات مالی، اسناد خصوصی یا اطلاعات حساس دیگر را ارسال نکنید. فقط با دستگاه‌ها و افرادی فایل مبادله کنید که به آن‌ها اعتماد دارید.',
    'Alerts and transfer history': 'هشدارها و تاریخچه انتقال',

    'Alert List': 'فهرست هشدارها',
    'Clear history': 'پاک‌کردن تاریخچه',
    'No file activity yet': 'هنوز فعالیتی برای فایل ثبت نشده است',
    'Choose File': 'انتخاب فایل',
    'Opening files…': 'در حال بازکردن فایل‌ها…',
    'Remove file': 'حذف فایل',
    'Message': 'پیام',
    'Write message': 'پیام را بنویسید',
    'Paste': 'چسباندن',
    'Sending Progress': 'روند ارسال',
    'Ready to send': 'آماده ارسال',
    'Devices found on this network': 'دستگاه‌های پیدا‌شده در این شبکه',
    'Refresh devices': 'جست‌وجوی دوباره دستگاه‌ها',
    'No responding devices found.': 'دستگاهی پاسخ‌گو پیدا نشد.',
    'Online': 'آنلاین',
    'Device on this Wi-Fi': 'دستگاه متصل به این وای‌فای',
    'Enter IP manually': 'واردکردن دستی IP',
    'Enter device IP': 'IP دستگاه را وارد کنید',
    'Private IPv4 address': 'نشانی خصوصی IPv4',
    'Cancel': 'لغو',
    'Use IP': 'استفاده از IP',
    'Select a device on this Wi-Fi': 'یک دستگاه در این وای‌فای انتخاب کنید',
    'Detecting this device…': 'در حال شناسایی این دستگاه…',
    'Device IP unavailable': 'IP دستگاه در دسترس نیست',
    'Waiting for sender IP': 'در انتظار IP فرستنده',
    'File Name': 'نام فایل',
    'No incoming file': 'فایلی در حال دریافت نیست',
    'Accept': 'پذیرفتن',
    'Reject': 'ردکردن',
    'Received Files · Last 3': 'فایل‌های دریافت‌شده · ۳ مورد آخر',
    'No received files': 'فایلی دریافت نشده است',
    'Open': 'بازکردن',
    'Delete': 'حذف',
    'Receiving Progress': 'روند دریافت',
    'Transferred: -- / --': 'انتقال‌یافته: -- / --',
    'Elapsed: --:--': 'زمان سپری‌شده: --:--',
    'From': 'از',
    'Files sent.': 'فایل‌ها ارسال شدند.',
    'The receiver rejected this batch.': 'گیرنده این مجموعه فایل را رد کرد.',
    'Transfer cancelled.': 'انتقال لغو شد.',
    'Clipboard is empty.': 'حافظه موقت خالی است.',
    'Write a message first.': 'ابتدا پیامی بنویسید.',
    'Select an online receiver first.': 'ابتدا یک گیرنده آنلاین انتخاب کنید.',
    'Message sent.': 'پیام ارسال شد.',
    'This IP has no online Local WiFi Drop message receiver.': 'در این IP گیرنده آنلاین پیام Local WiFi Drop وجود ندارد.',
    'Enter a valid private IPv4 address.': 'یک نشانی خصوصی IPv4 معتبر وارد کنید.',
    'Could not open the file picker: ': 'بازکردن انتخاب‌گر فایل ممکن نشد: ',
    'Message could not be delivered: ': 'تحویل پیام ممکن نشد: ',
    'Could not send files: ': 'ارسال فایل‌ها ممکن نشد: ',
    'Wi-Fi device scan failed: ': 'جست‌وجوی دستگاه‌های وای‌فای ناموفق بود: ',
    'Could not receive files: ': 'دریافت فایل‌ها ممکن نشد: ',
    'No message sender is available to reply to.': 'فرستنده‌ای برای پاسخ‌دادن در دسترس نیست.',
    'Could not send message: ': 'ارسال پیام ممکن نشد: ',
    'Could not open the received files folder: ': 'بازکردن پوشه فایل‌های دریافتی ممکن نشد: ',
    'Could not delete file: ': 'حذف فایل ممکن نشد: ',
  };
}
