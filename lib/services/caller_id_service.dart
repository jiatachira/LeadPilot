part of '../main.dart';

class CallerIdService {
  static const MethodChannel channel =
      MethodChannel('com.example.call_dial/caller_id');

  static Future<Map<String, dynamic>?> getLatestCallLog({String? phone}) async {
    try {
      final res = await channel.invokeMapMethod<String, dynamic>(
        'getLatestCallLog',
        {'phone': phone},
      );
      return res;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> getPendingCallLogs() async {
    try {
      final res = await channel.invokeListMethod<dynamic>('getPendingCallLogs');
      if (res == null) return [];
      return res
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on MissingPluginException {
      return [];
    } catch (_) {
      return [];
    }
  }

  static Future<bool> isEnabled() async {
    try {
      final res = await channel.invokeMethod<bool>('isCallerIdEnabled');
      return res ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    try {
      await channel.invokeMethod('setCallerIdEnabled', {'enabled': enabled});
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> canDrawOverlays() async {
    try {
      final res = await channel.invokeMethod<bool>('canDrawOverlays');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestOverlayPermission() async {
    try {
      await channel.invokeMethod('requestOverlayPermission');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> hasPhonePermissions() async {
    try {
      final res = await channel.invokeMethod<bool>('hasPhonePermissions');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPhonePermissions() async {
    try {
      final res = await channel.invokeMethod<bool>('requestPhonePermissions');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> testCallerIdPopup() async {
    try {
      await channel.invokeMethod('testCallerIdPopup');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> testNotificationBanner() async {
    try {
      await channel.invokeMethod('testNotificationBanner');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final res =
          await channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> openAppDetailsSettings() async {
    try {
      await channel.invokeMethod('openAppDetailsSettings');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<void> dismissOverlay() async {
    try {
      await channel.invokeMethod('dismissOverlay');
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> getSimSlots() async {
    try {
      final res = await channel.invokeListMethod<dynamic>('getSimSlots');
      if (res == null) return [];
      return res
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on MissingPluginException {
      return [];
    } catch (_) {
      return [];
    }
  }

  static Future<bool> hasCallPhonePermission() async {
    try {
      final res = await channel.invokeMethod<bool>('hasCallPhonePermission');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestCallPhonePermission() async {
    try {
      final res =
          await channel.invokeMethod<bool>('requestCallPhonePermission');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<Map<String, dynamic>>> getCallingApps() async {
    try {
      final res = await channel.invokeListMethod<dynamic>('getCallingApps');
      if (res == null) return [];
      return res
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
          .toList();
    } on MissingPluginException {
      return [];
    } catch (_) {
      return [];
    }
  }

  static Future<void> openDefaultAppsSettings() async {
    try {
      await channel.invokeMethod('openDefaultAppsSettings');
    } on MissingPluginException {
      // Platform channel not implemented in test environment.
    } catch (_) {
      // Ignore failures opening settings.
    }
  }

  static Future<bool> isDefaultDialer() async {
    try {
      final res = await channel.invokeMethod<bool>('isDefaultDialer');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestDefaultDialer() async {
    try {
      final res = await channel.invokeMethod<bool>('requestDefaultDialer');
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<String> getInitialDialNumber() async {
    try {
      final res = await channel.invokeMethod<String>('getInitialDialNumber');
      return res ?? '';
    } on MissingPluginException {
      return '';
    } catch (_) {
      return '';
    }
  }

  static Future<bool> directCall({
    required String phone,
    int simSlot = -1,
    String? name,
    String? callingAppPackage,
  }) async {
    try {
      final res = await channel.invokeMethod<bool>('directCall', {
        'phone': phone,
        'simSlot': simSlot,
        'name': name,
        'callingAppPackage': callingAppPackage,
      });
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> syncStudents(List<Student> students) async {
    try {
      final payload = students.map((s) {
        final activity = studentActivityStatus(s);
        final latestComment = s.commentHistory.isNotEmpty
            ? s.commentHistory.last.trim()
            : s.comment.trim();
        return {
          'name': s.name,
          'phone': s.phone,
          'whatsappNumber': s.whatsappNumber,
          'status': s.callStatus,
          'location': s.location,
          'examType': s.examType,
          'examYear': s.examYear,
          'lastComment': latestComment,
          'streak': activity.unansweredStreak,
        };
      }).toList();

      await channel.invokeMethod('syncCallerIdData', {'students': payload});
    } on MissingPluginException {
      // In tests
    } catch (_) {}
  }

  static Future<int> getCachedCount() async {
    try {
      final res = await channel.invokeMethod<int>('getCachedStudentCount');
      return res ?? 0;
    } on MissingPluginException {
      return 0;
    } catch (_) {
      return 0;
    }
  }
}

abstract interface class ReminderScheduler {
  Future<bool> canScheduleExactAlarms();

  Future<bool> requestExactAlarmsPermission();

  Future<void> scheduleStudentReminder(Student student, DateTime dateTime);

  Future<void> cancelStudentReminder(Student student);

  Future<bool> isStudentReminderScheduled(Student student, [DateTime? dateTime]);
}

