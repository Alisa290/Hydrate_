import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  // ============================================================
  // เวลาที่ต้องแจ้งเตือนให้ดื่มน้ำ
  // ============================================================

  final List<int> drinkHours = [7, 9, 11, 13, 15, 17, 19];

  // ============================================================
  // ปริมาณน้ำที่แนะนำในแต่ละครั้ง
  //
  // อ่านค่าจาก users/{uid}/drink_settings/two_hour_target_ml
  // เพื่อให้ตรงกับหน้าหลัก
  // ============================================================

  int drinkAmountMl = 150; // fallback กรณียังอ่าน Firebase ไม่ได้

  // ============================================================
  // Firebase
  // ============================================================

  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  static const String bottleDeviceId = 'bottle_001';

  FirebaseDatabase getRealtimeDatabase() {
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
    );
  }

  // ============================================================
  // Timer
  // ============================================================

  Timer? timer;

  // ============================================================
  // Firebase subscriptions
  // ============================================================

  StreamSubscription<DatabaseEvent>? notificationSubscription;

  StreamSubscription<DatabaseEvent>? historySubscription;

  StreamSubscription<DatabaseEvent>? pairingSubscription;

  StreamSubscription<DatabaseEvent>? drinkSettingsSubscription;

  // ============================================================
  // Notification data
  // ============================================================

  Map<String, List<DrinkNotificationData>> groupedNotifications = {};

  bool isLoading = true;

  // true เมื่อ bottle_001 เชื่อมกับ UID ของผู้ใช้ปัจจุบัน
  bool isBottleConnected = false;

  bool _isCheckingHydrationStatus = false;

  // คลาดเคลื่อนได้ ±10 mL ให้ตรงกับ ESP32
  static const double drinkToleranceMl = 10.0;

  // จำสถานะล่าสุดของแต่ละรอบ 2 ชั่วโมง ป้องกันการแจ้งซ้ำ
  String _lastHydrationWindowKey = '';
  String _lastHydrationStatus = '';

  String lastCheckedDateKey = '';

  // ============================================================
  // PHONE NOTIFICATION
  // ============================================================

  final FlutterLocalNotificationsPlugin _phoneNotifications =
      FlutterLocalNotificationsPlugin();

  bool _phoneNotificationsReady = false;

  // เวลาเริ่มต้นของการเชื่อมขวดสำหรับวันนี้
  //
  // ใช้ record แรกใน water_history ของวันนี้เป็นหลัก
  // เพื่อไม่สร้าง/ไม่แสดงแจ้งเตือนย้อนหลัง
  DateTime? _todayConnectionStart;

  // ============================================================
  // Current UID
  // ============================================================

  String? get currentUserId => FirebaseAuth.instance.currentUser?.uid;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    _initializePhoneNotifications();
    _initializeNotificationPage();

    // ตรวจระบบทุก 30 วินาที
    timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _checkDayChanged();

      if (!isBottleConnected) {
        return;
      }

      await _createReachedNotifications();

      await _checkHydrationStatus();
    });
  }

  // ============================================================
  // INITIALIZE PHONE NOTIFICATION
  // ============================================================

  Future<void> _initializePhoneNotifications() async {
    try {
      tz.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Bangkok'));

      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );

      const initializationSettings = InitializationSettings(
        android: androidSettings,
      );

      await _phoneNotifications.initialize(
        settings: initializationSettings,
      );

      final androidPlugin = _phoneNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();

      await androidPlugin?.requestNotificationsPermission();

      _phoneNotificationsReady = true;

      debugPrint('Phone notifications initialized');
    } catch (e) {
      debugPrint('Initialize phone notifications error: $e');
    }
  }

  // ============================================================
  // PHONE NOTIFICATION DETAILS
  // ============================================================

  NotificationDetails _phoneNotificationDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        'hydrate_smart_drink_reminders',
        'Hydrate Smart',
        channelDescription:
            'แจ้งเตือนเวลาการดื่มน้ำและการดื่มน้ำมากกว่าที่กำหนด',
        importance: Importance.high,
        priority: Priority.high,
        enableVibration: true,
        playSound: true,
      ),
    );
  }

  // ============================================================
  // NOTIFICATION ID
  // ============================================================

  int _drinkNotificationId(DateTime date, int hour) {
    return (date.year * 1000000) +
        (date.month * 10000) +
        (date.day * 100) +
        hour;
  }

  // ============================================================
  // SHOW PHONE NOTIFICATION NOW
  // ============================================================

  Future<void> _showPhoneNotificationNow({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_phoneNotificationsReady) {
      await _initializePhoneNotifications();
    }

    try {
      await _phoneNotifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: _phoneNotificationDetails(),
      );
    } catch (e) {
      debugPrint('Show phone notification error: $e');
    }
  }

  // ============================================================
  // FIND TODAY CONNECTION START
  //
  // ใช้ข้อมูล water_history record แรกของวันนี้
  // ซึ่งเป็นข้อมูลแรกที่ขวดเริ่มส่งให้บัญชีนี้ในวันนี้
  //
  // ถ้ายังไม่มี history จะใช้เวลาปัจจุบัน
  // เพื่อป้องกันการสร้างแจ้งเตือนย้อนหลัง
  // ============================================================

  Future<DateTime> _loadTodayConnectionStart() async {
    final uid = currentUserId;
    final now = DateTime.now();

    if (uid == null) {
      return now;
    }

    try {
      final todayKey = _formatDateKey(now);

      final records = await _loadWaterHistoryForDate(
        uid: uid,
        dateKey: todayKey,
      );

      if (records.isEmpty) {
        return now;
      }

      records.sort((a, b) => a.time.compareTo(b.time));

      return records.first.time;
    } catch (e) {
      debugPrint('Load today connection start error: $e');

      return now;
    }
  }

  // ============================================================
  // SCHEDULE PHONE DRINK REMINDERS
  //
  // สร้างเฉพาะเวลาที่ยังมาไม่ถึง
  // และต้องไม่อยู่ก่อนเวลาที่เริ่มเชื่อมขวดวันนี้
  // ============================================================

  Future<void> _scheduleFutureDrinkReminders() async {
    if (!isBottleConnected) {
      return;
    }

    if (!_phoneNotificationsReady) {
      await _initializePhoneNotifications();
    }

    final now = DateTime.now();

    _todayConnectionStart ??= await _loadTodayConnectionStart();

    final connectionStart = _todayConnectionStart ?? now;

    for (final hour in drinkHours) {
      final notificationTime = DateTime(now.year, now.month, now.day, hour, 0);

      // ไม่แจ้งย้อนหลัง
      if (!notificationTime.isAfter(now)) {
        continue;
      }

      // ไม่สร้างเวลาที่อยู่ก่อนเริ่มเชื่อมขวด
      if (notificationTime.isBefore(connectionStart)) {
        continue;
      }

      final id = _drinkNotificationId(now, hour);

      try {
        await _phoneNotifications.zonedSchedule(
          id: id,
          title: 'ถึงเวลาดื่มน้ำ',
          body: 'ควรดื่มน้ำ $drinkAmountMl ml เพื่อให้เป็นไปตามเป้าหมายวันนี้',
          scheduledDate: tz.TZDateTime(
            tz.local,
            notificationTime.year,
            notificationTime.month,
            notificationTime.day,
            notificationTime.hour,
            notificationTime.minute,
          ),
          notificationDetails: _phoneNotificationDetails(),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: 'drink_reminder',
        );
      } catch (e) {
        debugPrint('Schedule phone notification $hour:00 error: $e');
      }
    }
  }

  // ============================================================
  // CANCEL TODAY FUTURE DRINK REMINDERS
  // ============================================================

  Future<void> _cancelTodayDrinkReminders() async {
    final now = DateTime.now();

    for (final hour in drinkHours) {
      await _phoneNotifications.cancel(id: _drinkNotificationId(now, hour));
    }
  }

  // ============================================================
  // INITIALIZE
  // ============================================================

  Future<void> _initializeNotificationPage() async {
    final uid = currentUserId;

    if (uid == null) {
      if (mounted) {
        setState(() {
          isLoading = false;
          isBottleConnected = false;
          groupedNotifications = {};
        });
      }

      return;
    }

    lastCheckedDateKey = _formatDateKey(DateTime.now());

    // โหลดปริมาณน้ำต่อ 2 ชั่วโมงให้ตรงกับหน้าหลัก
    await _loadDrinkTarget();

    // ฟังการเปลี่ยนแปลงเป้าหมายแบบ Realtime
    _listenDrinkTarget();

    // ตรวจว่าผู้ใช้เชื่อมต่อกับขวดก่อน
    isBottleConnected = await _checkBottleConnectionOnce();

    if (isBottleConnected) {
      _todayConnectionStart = await _loadTodayConnectionStart();

      await _scheduleFutureDrinkReminders();
    }

    // ฟังสถานะการเชื่อมต่อแบบ Realtime
    _listenBottleConnectionStatus();

    // ฟัง notifications
    await _listenNotifications();

    if (!isBottleConnected) {
      if (mounted) {
        setState(() {
          groupedNotifications = {};
          isLoading = false;
        });
      }

      return;
    }

    // สร้างรายการเตือนตามเวลาที่มาถึงแล้ว
    await _createReachedNotifications();

    // เช็กดื่มเกินทันที
    await _checkHydrationStatus();

    // ฟัง water_history
    _listenTodayWaterHistory();
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  @override
  void dispose() {
    timer?.cancel();

    notificationSubscription?.cancel();

    historySubscription?.cancel();

    pairingSubscription?.cancel();

    drinkSettingsSubscription?.cancel();

    super.dispose();
  }

  // ============================================================
  // โหลดปริมาณน้ำที่ควรดื่มต่อ 2 ชั่วโมง
  //
  // ใช้ค่าเดียวกับหน้าหลัก:
  // users/{uid}/drink_settings/two_hour_target_ml
  // เช่น 1400 / 15 * 2 = 186.67 -> แสดง 187 ml
  // ============================================================

  Future<void> _loadDrinkTarget() async {
    final uid = currentUserId;

    if (uid == null) {
      return;
    }

    try {
      final snapshot = await getRealtimeDatabase()
          .ref('users/$uid/drink_settings/two_hour_target_ml')
          .get();

      final value = _parseDouble(snapshot.value);

      if (value > 0) {
        final rounded = value.round();

        if (mounted) {
          setState(() {
            drinkAmountMl = rounded;
          });
        } else {
          drinkAmountMl = rounded;
        }

        debugPrint('Notification 2H target: $value -> $rounded ml');
      }
    } catch (e) {
      debugPrint('Load drink target error: $e');
    }
  }

  // ============================================================
  // ฟังเป้าหมายการดื่มน้ำแบบ Realtime
  // ============================================================

  void _listenDrinkTarget() {
    drinkSettingsSubscription?.cancel();

    final uid = currentUserId;

    if (uid == null) {
      return;
    }

    final ref = getRealtimeDatabase().ref(
      'users/$uid/drink_settings/two_hour_target_ml',
    );

    drinkSettingsSubscription = ref.onValue.listen(
      (DatabaseEvent event) {
        final value = _parseDouble(event.snapshot.value);

        if (value <= 0) {
          return;
        }

        final rounded = value.round();

        if (!mounted) {
          drinkAmountMl = rounded;
          return;
        }

        setState(() {
          drinkAmountMl = rounded;
        });

        // โหลดรายการใหม่ เพื่อให้แจ้งเตือนเดิมแสดงค่าปัจจุบันด้วย
        _listenNotifications();

        debugPrint('Notification target updated: $rounded ml / 2h');
      },
      onError: (Object error) {
        debugPrint('Drink target listener error: $error');
      },
    );
  }

  // ============================================================
  // ตรวจสถานะการเชื่อมต่อขวดครั้งเดียว
  // ============================================================

  Future<bool> _checkBottleConnectionOnce() async {
    final uid = currentUserId;

    if (uid == null) {
      return false;
    }

    try {
      final snapshot = await getRealtimeDatabase()
          .ref('devices/$bottleDeviceId/active_user_id')
          .get();

      final activeUid = snapshot.value?.toString().trim() ?? '';

      return activeUid.isNotEmpty && activeUid == uid;
    } catch (e) {
      debugPrint('Check bottle connection error: $e');

      return false;
    }
  }

  // ============================================================
  // ฟังสถานะการเชื่อมต่อขวดแบบ Realtime
  // ============================================================

  void _listenBottleConnectionStatus() {
    pairingSubscription?.cancel();

    final uid = currentUserId;

    if (uid == null) {
      return;
    }

    final ref = getRealtimeDatabase().ref(
      'devices/$bottleDeviceId/active_user_id',
    );

    pairingSubscription = ref.onValue.listen(
      (DatabaseEvent event) async {
        final activeUid = event.snapshot.value?.toString().trim() ?? '';

        final connected = activeUid.isNotEmpty && activeUid == uid;

        final changed = connected != isBottleConnected;

        if (!mounted) {
          return;
        }

        setState(() {
          isBottleConnected = connected;

          if (!connected) {
            groupedNotifications = {};
            isLoading = false;
          }
        });

        if (!changed) {
          return;
        }

        if (!connected) {
          await historySubscription?.cancel();

          _todayConnectionStart = null;

          await _cancelTodayDrinkReminders();

          debugPrint('Bottle disconnected -> notifications disabled');

          return;
        }

        debugPrint('Bottle connected -> notifications enabled');

        _todayConnectionStart = await _loadTodayConnectionStart();

        await _scheduleFutureDrinkReminders();
        await _createReachedNotifications();
        await _checkHydrationStatus();
        _listenTodayWaterHistory();
        await _listenNotifications();
      },
      onError: (Object error) {
        debugPrint('Bottle connection listener error: $error');

        if (!mounted) {
          return;
        }

        setState(() {
          isBottleConnected = false;
          groupedNotifications = {};
          isLoading = false;
        });
      },
    );
  }

  // ============================================================
  // YYYY-MM-DD
  // ============================================================

  String _formatDateKey(DateTime dateTime) {
    final year = dateTime.year.toString().padLeft(4, '0');

    final month = dateTime.month.toString().padLeft(2, '0');

    final day = dateTime.day.toString().padLeft(2, '0');

    return '$year-$month-$day';
  }

  // ============================================================
  // HH-00
  // ============================================================

  String _formatTimeKey(int hour) {
    return '${hour.toString().padLeft(2, '0')}-00';
  }

  // ============================================================
  // HH:00 น.
  // ============================================================

  String formatTimeFromHour(int hour) {
    return '${hour.toString().padLeft(2, '0')}:00 น.';
  }

  // ============================================================
  // ไทย Date
  // ============================================================

  String formatThaiDate(String dateKey) {
    try {
      final parts = dateKey.split('-');

      if (parts.length != 3) {
        return dateKey;
      }

      final year = int.tryParse(parts[0]) ?? 0;

      final month = int.tryParse(parts[1]) ?? 0;

      final day = int.tryParse(parts[2]) ?? 0;

      const months = [
        '',
        'มกราคม',
        'กุมภาพันธ์',
        'มีนาคม',
        'เมษายน',
        'พฤษภาคม',
        'มิถุนายน',
        'กรกฎาคม',
        'สิงหาคม',
        'กันยายน',
        'ตุลาคม',
        'พฤศจิกายน',
        'ธันวาคม',
      ];

      if (month < 1 || month > 12) {
        return dateKey;
      }

      final buddhistYear = year + 543;

      return '$day ${months[month]} $buddhistYear';
    } catch (e) {
      return dateKey;
    }
  }

  // ============================================================
  // Header วันที่
  // ============================================================

  String getDateHeader(String dateKey) {
    final todayKey = _formatDateKey(DateTime.now());

    if (dateKey == todayKey) {
      return 'วันนี้';
    }

    return formatThaiDate(dateKey);
  }

  // ============================================================
  // เช็กเปลี่ยนวัน
  // ============================================================

  Future<void> _checkDayChanged() async {
    final todayKey = _formatDateKey(DateTime.now());

    if (lastCheckedDateKey.isEmpty) {
      lastCheckedDateKey = todayKey;

      return;
    }

    if (todayKey != lastCheckedDateKey) {
      debugPrint('');
      debugPrint('================================');
      debugPrint('NOTIFICATION NEW DAY');
      debugPrint('$lastCheckedDateKey -> $todayKey');
      debugPrint('================================');

      lastCheckedDateKey = todayKey;

      if (!isBottleConnected) {
        return;
      }

      // เปลี่ยน listener history เป็นวันใหม่
      _todayConnectionStart = null;

      _listenTodayWaterHistory();

      _todayConnectionStart = await _loadTodayConnectionStart();

      await _scheduleFutureDrinkReminders();

      await _createReachedNotifications();

      await _checkHydrationStatus();
    }
  }

  // ============================================================
  // สร้าง notification ตามเวลาที่มาถึงแล้ว
  // ============================================================

  Future<void> _createReachedNotifications() async {
    // ยังไม่เชื่อมขวด = ไม่สร้างแจ้งเตือนเวลาการดื่มน้ำ
    if (!isBottleConnected) {
      return;
    }

    try {
      final uid = currentUserId;

      if (uid == null) {
        return;
      }

      final now = DateTime.now();

      final todayKey = _formatDateKey(now);

      final database = getRealtimeDatabase();

      _todayConnectionStart ??= await _loadTodayConnectionStart();

      final connectionStart = _todayConnectionStart ?? now;

      for (final hour in drinkHours) {
        final notificationTime = DateTime(
          now.year,
          now.month,
          now.day,
          hour,
          0,
        );

        // ยังไม่ถึงเวลา
        if (notificationTime.isAfter(now)) {
          continue;
        }

        // เวลานี้เกิดขึ้นก่อนผู้ใช้เริ่มเชื่อมขวดวันนี้
        // ไม่สร้างแจ้งเตือนย้อนหลัง
        if (notificationTime.isBefore(connectionStart)) {
          continue;
        }

        final timeKey = _formatTimeKey(hour);

        final ref = database.ref('users/$uid/notifications/$todayKey/$timeKey');

        try {
          final snapshot = await ref.get();

          // มีแล้ว ไม่สร้างซ้ำ
          if (snapshot.exists) {
            continue;
          }

          final timestamp = notificationTime.millisecondsSinceEpoch;

          await ref.set({
            'type': 'drink_reminder',
            'title': 'ถึงเวลาดื่มน้ำ',
            'amount_ml': drinkAmountMl,
            'hour': hour,
            'minute': 0,
            'timestamp': timestamp,
            'date': todayKey,
            'time': '${hour.toString().padLeft(2, '0')}:00',
            'created_at': ServerValue.timestamp,
          });

          debugPrint('Created drink reminder: $todayKey $timeKey');
        } catch (e) {
          debugPrint('Create notification error $todayKey/$timeKey: $e');
        }
      }
    } catch (e) {
      debugPrint('_createReachedNotifications error: $e');
    }
  }

  // ============================================================
  // ฟัง water_history ของวันนี้
  //
  // เมื่อ ESP32 บันทึกข้อมูลใหม่
  // จะประเมินสถานะการดื่มทันที
  // - ครบ/เกินเป้าหมาย: แจ้งทันที
  // - ดื่มน้อย: แจ้งเฉพาะจุดตรวจทุก 30 นาที
  // ============================================================

  void _listenTodayWaterHistory() {
    historySubscription?.cancel();

    if (!isBottleConnected) {
      return;
    }

    final uid = currentUserId;

    if (uid == null) {
      return;
    }

    final todayKey = _formatDateKey(DateTime.now());

    final ref = getRealtimeDatabase().ref('users/$uid/water_history/$todayKey');

    debugPrint('');
    debugPrint('================================');
    debugPrint('LISTEN WATER HISTORY');
    debugPrint('users/$uid/water_history/$todayKey');
    debugPrint('================================');

    historySubscription = ref.onValue.listen(
      (_) {
        _checkHydrationStatus();
      },
      onError: (Object error) {
        debugPrint('Water history listener error: $error');
      },
    );
  }

  // ============================================================
  // เช็กว่าใน 2 ชั่วโมง
  // ดื่มน้ำมากกว่า 150 ml หรือไม่
  // ============================================================

  Future<void> _checkHydrationStatus() async {
    if (!isBottleConnected || _isCheckingHydrationStatus) {
      return;
    }

    _isCheckingHydrationStatus = true;

    try {
      final uid = currentUserId;
      if (uid == null || drinkAmountMl <= 0) {
        return;
      }

      final now = DateTime.now();

      // ระบบ Hydrate Smart ใช้รอบ 2 ชั่วโมง:
      // 07-09, 09-11, 11-13, 13-15, 15-17, 17-19, 19-21
      int? windowStartHour;
      for (final hour in drinkHours) {
        final start = DateTime(now.year, now.month, now.day, hour);
        final finish = start.add(const Duration(hours: 2));

        if (!now.isBefore(start) && !now.isAfter(finish)) {
          windowStartHour = hour;
        }
      }

      if (windowStartHour == null) {
        return;
      }

      final windowStart = DateTime(
        now.year,
        now.month,
        now.day,
        windowStartHour,
      );
      final windowEnd = windowStart.add(const Duration(hours: 2));

      if (now.isAfter(windowEnd)) {
        return;
      }

      // ถ้าเพิ่งเชื่อมขวดกลางรอบ ให้เริ่มนับจากเวลาที่เชื่อม
      _todayConnectionStart ??= await _loadTodayConnectionStart();
      DateTime effectiveStart = windowStart;
      if (_todayConnectionStart != null &&
          _todayConnectionStart!.isAfter(effectiveStart)) {
        effectiveStart = _todayConnectionStart!;
      }

      final todayKey = _formatDateKey(now);
      final records = await _loadWaterHistoryForDate(
        uid: uid,
        dateKey: todayKey,
      );

      if (records.length < 2) {
        return;
      }

      records.sort((a, b) => a.time.compareTo(b.time));

      // เก็บข้อมูลตั้งแต่ก่อนจุดเริ่มเล็กน้อย 1 record
      // เพื่อใช้เป็น baseline เทียบการลดของระดับน้ำ
      final usable = records.where((r) => !r.time.isAfter(now)).toList();
      if (usable.length < 2) {
        return;
      }

      int firstIndex = 0;
      for (int i = 0; i < usable.length; i++) {
        if (!usable[i].time.isBefore(effectiveStart)) {
          firstIndex = i > 0 ? i - 1 : i;
          break;
        }
      }

      int totalDrankMl = 0;
      for (int i = firstIndex + 1; i < usable.length; i++) {
        final previous = usable[i - 1];
        final current = usable[i];

        if (current.time.isBefore(effectiveStart)) {
          continue;
        }
        if (current.time.isAfter(now)) {
          continue;
        }

        final difference = previous.volumeMl - current.volumeMl;

        // น้ำลด = ดื่ม / น้ำเพิ่ม = เติมน้ำ ไม่นับ
        if (difference > 0) {
          totalDrankMl += difference;
        }
      }

      final elapsedMinutes =
          now.difference(windowStart).inSeconds / 60.0;

      // เป้าหมายสะสมแบบสัดส่วนเดียวกับ ESP32
      // 30 นาที = 25%, 60 = 50%, 90 = 75%, 120 = 100%
      final clampedMinutes = elapsedMinutes.clamp(0.0, 120.0);
      final expectedMl = drinkAmountMl * (clampedMinutes / 120.0);

      final lowerBound = expectedMl - drinkToleranceMl;
      final upperBound = expectedMl + drinkToleranceMl;

      String? status;

      if (totalDrankMl > upperBound) {
        status = 'over';
      } else if (totalDrankMl >= lowerBound &&
          totalDrankMl <= upperBound) {
        // สีเขียวแจ้งทันทีเมื่อถึงเป้าหมายสะสมของช่วงเวลาปัจจุบัน
        status = 'good';
      } else {
        // สีส้มแจ้งเฉพาะ checkpoint 30/60/90/120 นาที
        final minuteInWindow = now.difference(windowStart).inMinutes;
        final isCheckpoint =
            minuteInWindow == 30 ||
            minuteInWindow == 60 ||
            minuteInWindow == 90 ||
            minuteInWindow == 120;

        if (isCheckpoint) {
          status = 'low';
        }
      }

      if (status == null) {
        return;
      }

      final windowKey =
          '$todayKey-${windowStartHour.toString().padLeft(2, '0')}';

      // ไม่สร้างสถานะเดิมซ้ำในรอบเดียวกัน
      if (_lastHydrationWindowKey == windowKey &&
          _lastHydrationStatus == status) {
        return;
      }

      await _createHydrationStatusNotification(
        uid: uid,
        now: now,
        status: status,
        totalDrankMl: totalDrankMl,
        expectedMl: expectedMl.round(),
        windowKey: windowKey,
      );

      _lastHydrationWindowKey = windowKey;
      _lastHydrationStatus = status;
    } catch (e, stack) {
      debugPrint('_checkHydrationStatus error: $e');
      debugPrint('$stack');
    } finally {
      _isCheckingHydrationStatus = false;
    }
  }

  Future<void> _createHydrationStatusNotification({
    required String uid,
    required DateTime now,
    required String status,
    required int totalDrankMl,
    required int expectedMl,
    required String windowKey,
  }) async {
    String type;
    String title;
    String message;

    switch (status) {
      case 'low':
        type = 'drink_low';
        title = 'ดื่มน้ำน้อยกว่าที่กำหนด';
        message =
            'ดื่มแล้ว $totalDrankMl mL จากเป้าหมายช่วงนี้ประมาณ $expectedMl mL';
        break;
      case 'good':
        type = 'drink_good';
        title = 'ดื่มน้ำครบตามเป้าหมาย';
        message =
            'ดื่มแล้ว $totalDrankMl mL อยู่ในช่วงเป้าหมายประมาณ $expectedMl mL';
        break;
      default:
        type = 'drink_over';
        title = 'ดื่มน้ำมากกว่าที่กำหนด';
        message =
            'ดื่มแล้ว $totalDrankMl mL มากกว่าเป้าหมายช่วงนี้ประมาณ $expectedMl mL';
    }

    final todayKey = _formatDateKey(now);
    final timestamp = now.millisecondsSinceEpoch;
    final alertKey = '$type-$windowKey-$timestamp';

    final ref = getRealtimeDatabase().ref(
      'users/$uid/notifications/$todayKey/$alertKey',
    );

    await ref.set({
      'type': type,
      'title': title,
      'message': message,
      'amount_ml': expectedMl,
      'drank_ml': totalDrankMl,
      'hour': now.hour,
      'minute': now.minute,
      'timestamp': timestamp,
      'date': todayKey,
      'time':
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}',
      'window_key': windowKey,
      'created_at': ServerValue.timestamp,
    });

    await _showPhoneNotificationNow(
      id: timestamp.remainder(2147483647),
      title: title,
      body: message,
    );
  }

  // ============================================================
  // โหลด water_history ของวันที่กำหนด
  // ============================================================

  Future<List<WaterHistoryRecord>> _loadWaterHistoryForDate({
    required String uid,
    required String dateKey,
  }) async {
    final List<WaterHistoryRecord> records = [];

    try {
      final ref = getRealtimeDatabase().ref(
        'users/$uid/water_history/$dateKey',
      );

      final snapshot = await ref.get();

      if (!snapshot.exists || snapshot.value == null) {
        return records;
      }

      if (snapshot.value is! Map) {
        return records;
      }

      final historyMap = Map<Object?, Object?>.from(snapshot.value as Map);

      for (final entry in historyMap.entries) {
        final key = entry.key.toString();

        final rawData = entry.value;

        if (rawData is! Map) {
          continue;
        }

        final data = Map<Object?, Object?>.from(rawData);

        final volumeMl = _parseInt(data['volume_ml']);

        if (volumeMl <= 0) {
          continue;
        }

        final timestamp = _parseInt(data['timestamp']);

        DateTime? recordTime;

        // ------------------------------------------------------
        // ใช้ timestamp ก่อน
        // ------------------------------------------------------

        if (timestamp > 0) {
          recordTime = _dateTimeFromTimestamp(timestamp);
        }

        // ------------------------------------------------------
        // ถ้าไม่มี timestamp
        // ใช้เวลาจาก Firebase key
        // ------------------------------------------------------

        recordTime ??= _dateTimeFromHistoryKey(dateKey: dateKey, timeKey: key);

        if (recordTime == null) {
          continue;
        }

        records.add(
          WaterHistoryRecord(key: key, time: recordTime, volumeMl: volumeMl),
        );
      }
    } catch (e) {
      debugPrint('Load water history $dateKey error: $e');
    }

    return records;
  }

  // ============================================================
  // Timestamp -> DateTime
  //
  // ESP32 อาจส่งเป็น seconds
  // Firebase อาจเป็น milliseconds
  // ============================================================

  DateTime? _dateTimeFromTimestamp(int timestamp) {
    try {
      if (timestamp > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
      }

      return DateTime.fromMillisecondsSinceEpoch(
        timestamp * 1000,
        isUtc: true,
      ).toLocal();
    } catch (e) {
      return null;
    }
  }

  // ============================================================
  // History key -> DateTime
  //
  // รองรับ
  // 15-30
  // 15-30-10
  // 15:30
  // 15:30:10
  // ============================================================

  DateTime? _dateTimeFromHistoryKey({
    required String dateKey,
    required String timeKey,
  }) {
    try {
      final dateParts = dateKey.split('-');

      if (dateParts.length != 3) {
        return null;
      }

      final year = int.tryParse(dateParts[0]);

      final month = int.tryParse(dateParts[1]);

      final day = int.tryParse(dateParts[2]);

      if (year == null || month == null || day == null) {
        return null;
      }

      final cleanKey = timeKey.replaceAll(':', '-');

      final timeParts = cleanKey.split('-');

      if (timeParts.length < 2) {
        return null;
      }

      final hour = int.tryParse(timeParts[0]);

      final minute = int.tryParse(timeParts[1]);

      int second = 0;

      if (timeParts.length >= 3) {
        second = int.tryParse(timeParts[2]) ?? 0;
      }

      if (hour == null || minute == null) {
        return null;
      }

      if (hour < 0 ||
          hour > 23 ||
          minute < 0 ||
          minute > 59 ||
          second < 0 ||
          second > 59) {
        return null;
      }

      return DateTime(year, month, day, hour, minute, second);
    } catch (e) {
      return null;
    }
  }

  // ============================================================
  // สร้าง Over Drink Notification
  // ============================================================

  // ============================================================
  // ฟัง notification ทั้งหมด
  // ============================================================

  Future<void> _listenNotifications() async {
    try {
      final uid = currentUserId;

      if (uid == null) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }

        return;
      }

      final database = getRealtimeDatabase();

      final ref = database.ref('users/$uid/notifications');

      await notificationSubscription?.cancel();

      // --------------------------------------------------------
      // อ่านครั้งแรก
      // --------------------------------------------------------

      try {
        final snapshot = await ref.get();

        _parseNotificationData(snapshot.value);
      } catch (e) {
        debugPrint('Initial notification read error: $e');

        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }
      }

      // --------------------------------------------------------
      // Realtime
      // --------------------------------------------------------

      notificationSubscription = ref.onValue.listen(
        (DatabaseEvent event) {
          _parseNotificationData(event.snapshot.value);
        },
        onError: (Object error) {
          debugPrint('Notification realtime error: $error');

          if (mounted) {
            setState(() {
              isLoading = false;
            });
          }
        },
      );
    } catch (e) {
      debugPrint('_listenNotifications error: $e');

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // Firebase -> Model
  // ============================================================

  void _parseNotificationData(dynamic value) {
    if (!isBottleConnected) {
      if (mounted) {
        setState(() {
          groupedNotifications = {};
          isLoading = false;
        });
      }
      return;
    }

    final Map<String, List<DrinkNotificationData>> newGrouped = {};

    if (value is Map) {
      final root = Map<Object?, Object?>.from(value);

      for (final dateEntry in root.entries) {
        final dateKey = dateEntry.key.toString();

        final dateValue = dateEntry.value;

        if (dateValue is! Map) {
          continue;
        }

        final dayMap = Map<Object?, Object?>.from(dateValue);

        final List<DrinkNotificationData> dayNotifications = [];

        for (final timeEntry in dayMap.entries) {
          final timeKey = timeEntry.key.toString();

          final rawData = timeEntry.value;

          if (rawData is! Map) {
            continue;
          }

          final data = Map<Object?, Object?>.from(rawData);

          final hour = _parseInt(data['hour']);

          final minute = _parseInt(data['minute']);

          final amount = _parseInt(data['amount_ml']);

          final timestamp = _parseInt(data['timestamp']);

          final type = data['type']?.toString() ?? 'drink_reminder';

          final title = data['title']?.toString() ?? '';

          final message = data['message']?.toString() ?? '';

          // ไม่แสดงรายการเตือนดื่มน้ำของวันนี้
          // ที่เกิดก่อนเวลาเริ่มเชื่อมขวด
          if (type == 'drink_reminder' &&
              dateKey == _formatDateKey(DateTime.now()) &&
              _todayConnectionStart != null) {
            final itemTime = DateTime(
              _todayConnectionStart!.year,
              _todayConnectionStart!.month,
              _todayConnectionStart!.day,
              hour,
              minute,
            );

            if (itemTime.isBefore(_todayConnectionStart!)) {
              continue;
            }
          }

          dayNotifications.add(
            DrinkNotificationData(
              dateKey: dateKey,
              timeKey: timeKey,
              hour: hour,
              minute: minute,
              // drink_reminder ใช้เป้าหมายปัจจุบันจากหน้าหลัก
              // แม้ Firebase จะมีรายการเก่าที่เคยเก็บไว้ 150 ml
              amountMl: type == 'drink_reminder'
                  ? drinkAmountMl
                  : (amount > 0 ? amount : drinkAmountMl),
              timestamp: timestamp,
              type: type,
              title: title,
              message: message,
            ),
          );
        }

        // เวลาล่าสุดด้านบน
        dayNotifications.sort((a, b) {
          if (a.timestamp > 0 && b.timestamp > 0) {
            return b.timestamp.compareTo(a.timestamp);
          }

          return b.timeKey.compareTo(a.timeKey);
        });

        if (dayNotifications.isNotEmpty) {
          newGrouped[dateKey] = dayNotifications;
        }
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      groupedNotifications = newGrouped;

      isLoading = false;
    });
  }

  // ============================================================
  // Parse int
  // ============================================================

  int _parseInt(dynamic value) {
    if (value == null) {
      return 0;
    }

    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.round();
    }

    return int.tryParse(value.toString()) ?? 0;
  }

  // ============================================================
  // Parse double
  // ============================================================

  double _parseDouble(dynamic value) {
    if (value == null) {
      return 0;
    }

    if (value is num) {
      return value.toDouble();
    }

    return double.tryParse(value.toString()) ?? 0;
  }

  // ============================================================
  // วันที่เรียงล่าสุด -> เก่าสุด
  // ============================================================

  List<String> getSortedDateKeys() {
    final dates = groupedNotifications.keys.toList();

    dates.sort((a, b) => b.compareTo(a));

    return dates;
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final dateKeys = getSortedDateKeys();

    return Scaffold(
      backgroundColor: const Color(0xFFEAF8FE),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==================================================
            // HEADER
            // ==================================================
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 0),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(24),
                    onTap: () {
                      Navigator.pop(context);
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back,
                        color: Color(0xFF2378C9),
                        size: 30,
                      ),
                    ),
                  ),

                  const SizedBox(width: 10),

                  const Text(
                    'การแจ้งเตือน',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ==================================================
            // BODY
            // ==================================================
            Expanded(
              child: isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF2378C9),
                      ),
                    )
                  : !isBottleConnected
                  ? const BottleNotConnectedView()
                  : dateKeys.isEmpty
                  ? const EmptyNotificationView()
                  : ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 30),
                      itemCount: dateKeys.length,
                      itemBuilder: (context, dateIndex) {
                        final dateKey = dateKeys[dateIndex];

                        final notifications =
                            groupedNotifications[dateKey] ?? [];

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                              ),
                              child: Text(
                                getDateHeader(dateKey),
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black,
                                ),
                              ),
                            ),

                            const SizedBox(height: 14),

                            ...List.generate(notifications.length, (index) {
                              final notification = notifications[index];

                              return Padding(
                                padding: EdgeInsets.only(
                                  bottom: index == notifications.length - 1
                                      ? 0
                                      : 14,
                                ),
                                child: notification.isHydrationStatus
                                    ? HydrationStatusNotificationCard(
                                        notification: notification,
                                      )
                                    : DrinkNotificationCard(
                                        time: notification.formattedTime,
                                        amountMl: notification.amountMl,
                                      ),
                              );
                            }),

                            if (dateIndex != dateKeys.length - 1)
                              const SizedBox(height: 28),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// WATER HISTORY MODEL
// ============================================================

class WaterHistoryRecord {
  const WaterHistoryRecord({
    required this.key,
    required this.time,
    required this.volumeMl,
  });

  final String key;

  final DateTime time;

  final int volumeMl;
}

// ============================================================
// NOTIFICATION MODEL
// ============================================================

class DrinkNotificationData {
  const DrinkNotificationData({
    required this.dateKey,
    required this.timeKey,
    required this.hour,
    required this.minute,
    required this.amountMl,
    required this.timestamp,
    required this.type,
    required this.title,
    required this.message,
  });

  final String dateKey;

  final String timeKey;

  final int hour;

  final int minute;

  final int amountMl;

  final int timestamp;

  final String type;

  final String title;

  final String message;

  bool get isOverDrink => type == 'overdrink_2h' || type == 'drink_over';
  bool get isLowDrink => type == 'drink_low';
  bool get isGoodDrink => type == 'drink_good';
  bool get isHydrationStatus => isOverDrink || isLowDrink || isGoodDrink;

  String get formattedTime {
    final h = hour.toString().padLeft(2, '0');

    final m = minute.toString().padLeft(2, '0');

    return '$h:$m น.';
  }
}

// ============================================================
// CARD สถานะการดื่มน้ำ: ส้ม / เขียว / แดง
// ============================================================

class HydrationStatusNotificationCard extends StatelessWidget {
  const HydrationStatusNotificationCard({
    super.key,
    required this.notification,
  });

  final DrinkNotificationData notification;

  @override
  Widget build(BuildContext context) {
    final bool isLow = notification.isLowDrink;
    final bool isGood = notification.isGoodDrink;

    final Color accent = isLow
        ? const Color(0xFFF57C00)
        : isGood
            ? const Color(0xFF2E7D32)
            : const Color(0xFFE53935);

    final Color background = isLow
        ? const Color(0xFFFFF5E6)
        : isGood
            ? const Color(0xFFEAF7EC)
            : const Color(0xFFFFF3F3);

    final Color border = isLow
        ? const Color(0xFFFFCC80)
        : isGood
            ? const Color(0xFFA5D6A7)
            : const Color(0xFFFFC5C5);

    final IconData icon = isLow
        ? Icons.water_drop_outlined
        : isGood
            ? Icons.check_circle_outline
            : Icons.warning_amber_rounded;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  notification.message,
                  style: const TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  notification.formattedTime,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CARD เตือนดื่มน้ำมากกว่าที่กำหนด
// ============================================================

class OverDrinkNotificationCard extends StatelessWidget {
  const OverDrinkNotificationCard({super.key, required this.notification});

  final DrinkNotificationData notification;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3F3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFFC5C5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ====================================================
          // ไอคอนเตือน
          // ====================================================
          Container(
            width: 58,
            height: 58,
            decoration: const BoxDecoration(
              color: Color(0xFFFFC1C1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.warning_amber_rounded,
              size: 38,
              color: Color(0xFFE53935),
            ),
          ),

          const SizedBox(width: 14),

          // ====================================================
          // ข้อความ
          // ====================================================
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  notification.title.isNotEmpty
                      ? notification.title
                      : 'ดื่มน้ำมากกว่าที่กำหนด',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFE53935),
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  notification.message.isNotEmpty
                      ? notification.message
                      : 'ปริมาณน้ำที่ดื่มในช่วง 2 ชั่วโมงนี้มากกว่าปริมาณที่กำหนด',
                  style: const TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    color: Colors.black87,
                  ),
                ),

                const SizedBox(height: 7),

                Text(
                  notification.formattedTime,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CARD ถึงเวลาดื่มน้ำ
// ============================================================

class DrinkNotificationCard extends StatelessWidget {
  const DrinkNotificationCard({
    super.key,
    required this.time,
    required this.amountMl,
  });

  final String time;

  final int amountMl;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 16, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.12),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ====================================================
          // ไอคอน
          // ====================================================
          Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: Color(0xFFB7DCFF),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications,
              size: 42,
              color: Color(0xFF2378C9),
            ),
          ),

          const SizedBox(width: 16),

          // ====================================================
          // TEXT
          // ====================================================
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'ถึงเวลาดื่มน้ำ',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2378C9),
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    Text(
                      time,
                      style: const TextStyle(fontSize: 15, color: Colors.black),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                Text(
                  'ควรดื่มน้ำ $amountMl ml',
                  style: const TextStyle(fontSize: 16, color: Colors.black),
                ),

                const SizedBox(height: 3),

                const Text(
                  'เพื่อให้เป็นไปตามเป้าหมายวันนี้',
                  style: TextStyle(fontSize: 15, color: Colors.black),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ยังไม่ได้เชื่อมต่อขวด
// ============================================================

class BottleNotConnectedView extends StatelessWidget {
  const BottleNotConnectedView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 38,
                backgroundColor: Color(0xFFB7DCFF),
                child: Icon(
                  Icons.water_drop_outlined,
                  size: 44,
                  color: Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 18),

              const Text(
                'ยังไม่ได้เชื่อมต่อขวดน้ำ',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'กรุณาเชื่อมต่อขวดน้ำในหน้าโปรไฟล์ก่อน ระบบจึงจะเริ่มแสดงการแจ้งเตือนเวลาการดื่มน้ำ',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// EMPTY
// ============================================================

class EmptyNotificationView extends StatelessWidget {
  const EmptyNotificationView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 38,
                backgroundColor: Color(0xFFB7DCFF),
                child: Icon(
                  Icons.notifications,
                  size: 44,
                  color: Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 18),

              const Text(
                'ยังไม่มีการแจ้งเตือน',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'เมื่อถึงเวลาดื่มน้ำ หรือระบบตรวจพบสถานะการดื่มน้ำน้อย ครบ หรือมากกว่าที่กำหนด ระบบจะแสดงรายการไว้ที่หน้านี้',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
