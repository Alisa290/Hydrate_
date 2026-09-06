import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'home_page.dart';

class StatisticsPage extends StatefulWidget {
  const StatisticsPage({super.key});

  @override
  State<StatisticsPage> createState() => _StatisticsPageState();
}

class _StatisticsPageState extends State<StatisticsPage> {
  static const Color blue = Color(0xFF2878C9);
  static const Color softBlue = Color(0xFFA8D2FF);
  static const Color bg = Color(0xFFEAF8FF);

  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  static const String bottleDeviceId = 'bottle_001';

  FirebaseDatabase get _database {
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
    );
  }

  bool isWeekly = false;
  bool isLoading = true;
  bool hasBottleData = false;

  // กันโหลด daily ซ้อนกันหลายรอบจนแอปค้าง
  bool _isLoadingDaily = false;

  // กันโหลด weekly ซ้อนกัน
  bool _isLoadingWeekly = false;

  DateTime selectedDay = _dateOnly(DateTime.now());

  DateTime selectedWeekStart = _startOfWeekSunday(
    DateTime.now(),
  );

  int dailyGoalMl = 1400;

  // เป้าหมายรวมทั้งสัปดาห์ = เป้าหมายรายวัน x 7
  int get weeklyGoalMl => dailyGoalMl * 7;

  int selectedDrankMl = 0;
  int selectedPercent = 0;

  int todayDrankMl = 0;

  // ค่าจากขวด
  // ใช้แสดงสถานะขวดเท่านั้น
  int bottleRemainingMl = 0;
  int bottleLevelPercent = 0;

  List<int> dailyBars = List<int>.filled(
    7,
    0,
  );

  List<int> weeklyBars = List<int>.filled(
    7,
    0,
  );

  StreamSubscription<DatabaseEvent>? bottleSubscription;
  StreamSubscription<DatabaseEvent>? historySubscription;

  @override
  void initState() {
    super.initState();
    _loadProfileAndData();
  }

  @override
  void dispose() {
    bottleSubscription?.cancel();
    historySubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadProfileAndData() async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        debugPrint(
          'STATISTICS PAGE: no logged-in user',
        );

        if (mounted) {
          setState(() {
            isLoading = false;
            hasBottleData = false;
          });
        }

        return;
      }

      final uid = user.uid;

      debugPrint('');
      debugPrint('================================');
      debugPrint('STATISTICS PAGE START');
      debugPrint('LOGGED-IN UID = $uid');
      debugPrint('DATABASE URL = $databaseUrl');
      debugPrint('DEVICE ID = $bottleDeviceId');
      debugPrint('================================');

      try {
        final profileDoc = await FirebaseFirestore.instance
            .collection('profiles')
            .doc(uid)
            .get()
            .timeout(
              const Duration(
                seconds: 8,
              ),
            );

        if (profileDoc.exists) {
          final data = profileDoc.data() ?? {};

          final manualGoal = _toInt(
            data['manual_daily_goal_ml'],
            fallback: 0,
          );

          if (manualGoal > 0) {
            dailyGoalMl = manualGoal;
          } else {
            final calculatedGoal = _calculateGoalFromProfile(
              data,
            );

            if (calculatedGoal > 0) {
              dailyGoalMl = calculatedGoal;
            }
          }
        }
      } on TimeoutException {
        debugPrint(
          'Profile loading timeout',
        );
      } on FirebaseException catch (e) {
        debugPrint(
          'Firestore profile error: ${e.code}',
        );
        debugPrint(
          'Firestore profile message: ${e.message}',
        );
      } catch (e) {
        debugPrint(
          'Profile error: $e',
        );
      }

      if (dailyGoalMl <= 0) {
        dailyGoalMl = 1400;
      }

      debugPrint(
        'FINAL DAILY GOAL = $dailyGoalMl ml',
      );

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }

      _listenBottle();
      _listenTodayHistory();

      await _loadSelectedData();
    } catch (e, stack) {
      debugPrint(
        'Load profile/data error: $e',
      );
      debugPrint(
        '$stack',
      );

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // LISTEN BOTTLE
  //
  // สำคัญ:
  // current_volume_ml = น้ำที่อยู่ในขวด
  // bottle_level_percent = % น้ำในขวด
  //
  // ห้ามนำไปคำนวณว่า "ดื่มแล้ววันนี้"
  // ============================================================

  void _listenBottle() {
    bottleSubscription?.cancel();

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() {
          hasBottleData = false;
          bottleRemainingMl = 0;
          bottleLevelPercent = 0;
        });
      }

      return;
    }

    final uid = user.uid;

    final path =
        'users/$uid/devices/$bottleDeviceId';

    final ref = _database.ref(
      path,
    );

    debugPrint('');
    debugPrint('================================');
    debugPrint('STATISTICS - LISTENING DEVICE');
    debugPrint('UID = $uid');
    debugPrint('Path = $path');
    debugPrint('================================');

    bottleSubscription = ref.onValue.listen(
      (event) {
        try {
          final value = event.snapshot.value;

          if (value is! Map) {
            if (!mounted) return;

            setState(() {
              hasBottleData = false;
            });

            return;
          }

          final data = Map<dynamic, dynamic>.from(
            value,
          );

          final newBottleRemainingMl = _toInt(
            data['current_volume_ml'],
            fallback: 0,
          );

          final newBottleLevelPercent = _toInt(
            data['bottle_level_percent'],
            fallback: 0,
          ).clamp(0, 100).toInt();

          debugPrint('');
          debugPrint('========== BOTTLE UPDATE ==========');
          debugPrint(
            'Bottle remaining = $newBottleRemainingMl ml',
          );
          debugPrint(
            'Bottle level = $newBottleLevelPercent%',
          );
          debugPrint(
            '===================================',
          );

          if (!mounted) return;

          setState(() {
            hasBottleData = true;
            bottleRemainingMl = newBottleRemainingMl;
            bottleLevelPercent = newBottleLevelPercent;
          });
        } catch (e, stack) {
          debugPrint(
            'Bottle listener error: $e',
          );
          debugPrint(
            '$stack',
          );
        }
      },
      onError: (error) {
        debugPrint(
          'Realtime Database bottle error: $error',
        );
      },
    );
  }

  // ============================================================
  // LISTEN TODAY HISTORY
  //
  // มีตัวกันโหลดซ้ำแล้ว
  // ============================================================

  void _listenTodayHistory() {
    historySubscription?.cancel();

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      debugPrint(
        'STATISTICS _listenTodayHistory: no logged-in user',
      );
      return;
    }

    final uid = user.uid;

    final todayKey = _dateKey(
      DateTime.now(),
    );

    final path =
        'users/$uid/water_history/$todayKey';

    final ref = _database.ref(
      path,
    );

    debugPrint('');
    debugPrint('STATISTICS - LISTENING HISTORY');
    debugPrint('UID = $uid');
    debugPrint('Path = $path');

    historySubscription = ref.onValue.listen(
      (event) {
        try {
          if (!mounted) return;

          if (!isWeekly &&
              _isSameDay(
                selectedDay,
                DateTime.now(),
              )) {
            _loadDailyData();
          }

          if (isWeekly) {
            final weekEnd = selectedWeekStart.add(
              const Duration(
                days: 6,
              ),
            );

            final today = _dateOnly(
              DateTime.now(),
            );

            if (!today.isBefore(
                  selectedWeekStart,
                ) &&
                !today.isAfter(
                  weekEnd,
                )) {
              _loadWeeklyData();
            }
          }
        } catch (e) {
          debugPrint(
            'History listener error: $e',
          );
        }
      },
      onError: (error) {
        debugPrint(
          'History realtime error: $error',
        );
      },
    );
  }

  Future<void> _loadSelectedData() async {
    try {
      if (isWeekly) {
        await _loadWeeklyData();
      } else {
        await _loadDailyData();
      }
    } catch (e, stack) {
      debugPrint(
        'Load selected data error: $e',
      );
      debugPrint(
        '$stack',
      );
    }
  }
    // ============================================================
  // LOAD DAILY DATA
  //
  // กันโหลดซ้อนด้วย _isLoadingDaily
  // และใช้ water_history เป็นแหล่งข้อมูล "ดื่มแล้ว"
  // ============================================================

  Future<void> _loadDailyData() async {
    if (_isLoadingDaily) {
      return;
    }

    _isLoadingDaily = true;

    try {
      final result = await _calculateDayHistory(
        selectedDay,
      );

      final isToday = _isSameDay(
        selectedDay,
        DateTime.now(),
      );

      final overviewDrank = result.totalDrank
          .clamp(
            0,
            dailyGoalMl,
          )
          .toInt();

      final overviewPercent = _percent(
        overviewDrank,
        dailyGoalMl,
      );

      if (!mounted) return;

      setState(() {
        dailyBars = List<int>.from(
          result.bars,
        );

        selectedDrankMl =
            overviewDrank;

        selectedPercent =
            overviewPercent;

        if (isToday) {
          todayDrankMl =
              overviewDrank;
        }
      });

      debugPrint('');
      debugPrint(
        '================ DAILY =================',
      );
      debugPrint(
        'Date = ${_dateKey(selectedDay)}',
      );
      debugPrint(
        'Goal = $dailyGoalMl ml',
      );
      debugPrint(
        'History latest volume = '
        '${result.latestVolumeMl} ml',
      );
      debugPrint(
        'History total drank = '
        '${result.totalDrank} ml',
      );
      debugPrint(
        'Overview drank = '
        '$overviewDrank ml',
      );
      debugPrint(
        'Overview percent = '
        '$overviewPercent%',
      );
      debugPrint(
        'Bars = $dailyBars',
      );
      debugPrint(
        '========================================',
      );
    } catch (e, stack) {
      debugPrint(
        'Load daily history error: $e',
      );

      debugPrint(
        '$stack',
      );

      if (!mounted) return;

      final isToday = _isSameDay(
        selectedDay,
        DateTime.now(),
      );

      setState(() {
        dailyBars = List<int>.filled(
          7,
          0,
        );

        selectedDrankMl = 0;
        selectedPercent = 0;

        if (isToday) {
          todayDrankMl = 0;
        }
      });
    } finally {
      _isLoadingDaily = false;
    }
  }

  // ============================================================
  // CALCULATE DAY HISTORY
  //
  // แนวคิด:
  //
  // 1060 -> 1020 = ดื่ม 40 ml
  //
  // 700 -> 1500 = เติมน้ำ
  // ไม่นับเป็นการดื่ม
  // ============================================================

  Future<_DayHistoryResult> _calculateDayHistory(
    DateTime day,
  ) async {
    final bars = List<int>.filled(
      7,
      0,
    );

    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    final uid = user.uid;

    final dateKey =
        _dateKey(
      day,
    );

    final path =
        'users/$uid/water_history/$dateKey';

    debugPrint('');
    debugPrint(
      '--------------------------------',
    );
    debugPrint(
      'LOAD DAY HISTORY',
    );
    debugPrint(
      'UID = $uid',
    );
    debugPrint(
      'DATE = $dateKey',
    );
    debugPrint(
      'Path = $path',
    );
    debugPrint(
      '--------------------------------',
    );

    final ref =
        _database.ref(
      path,
    );

    DataSnapshot snapshot;

    try {
      snapshot =
          await ref.get();
    } catch (e) {
      debugPrint(
        'RTDB GET ERROR = $e',
      );

      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    if (!snapshot.exists ||
        snapshot.value == null) {
      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    final rawValue =
        snapshot.value;

    if (rawValue is! Map) {
      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    final historyMap =
        Map<dynamic, dynamic>.from(
      rawValue,
    );

    final List<_WaterHistoryRecord>
        records = [];

    historyMap.forEach(
      (key, value) {
        if (value is! Map) {
          return;
        }

        final data =
            Map<dynamic, dynamic>.from(
          value,
        );

        final volume =
            _toInt(
          data['volume_ml'],
          fallback: -1,
        );

        if (volume < 0) {
          return;
        }

        DateTime? recordTime =
            _timeFromHistoryKey(
          day,
          key.toString(),
        );

        final timestamp =
            _toInt(
          data['timestamp'],
          fallback: 0,
        );

        if (recordTime == null &&
            timestamp > 0) {
          recordTime =
              _dateTimeFromTimestamp(
            timestamp,
          );
        }

        if (recordTime == null) {
          return;
        }

        if (!_isSameDay(
          recordTime,
          day,
        )) {
          return;
        }

        records.add(
          _WaterHistoryRecord(
            key:
                key.toString(),
            time:
                recordTime,
            volumeMl:
                volume,
            timestamp:
                timestamp,
          ),
        );
      },
    );

    if (records.isEmpty) {
      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    records.sort(
      (a, b) =>
          a.time.compareTo(
        b.time,
      ),
    );

    debugPrint('');
    debugPrint(
      '========== RECORDS $dateKey ==========',
    );

    for (final record in records) {
      debugPrint(
        '${record.key} '
        '${_two(record.time.hour)}:'
        '${_two(record.time.minute)}:'
        '${_two(record.time.second)} '
        '= ${record.volumeMl} ml',
      );
    }

    final now =
        DateTime.now();

    final isToday =
        _isSameDay(
      day,
      now,
    );

    final List<_WaterHistoryRecord>
        validRecords = [];

    for (final record in records) {
      if (isToday &&
          record.time.isAfter(
            now,
          )) {
        continue;
      }

      validRecords.add(
        record,
      );
    }

    if (validRecords.isEmpty) {
      return _DayHistoryResult(
        bars: bars,
        totalDrank: 0,
        latestVolumeMl: 0,
        hasRecords: false,
      );
    }

    int totalDrank = 0;

    for (
      int i = 1;
      i < validRecords.length;
      i++
    ) {
      final previous =
          validRecords[i - 1];

      final current =
          validRecords[i];

      final difference =
          previous.volumeMl -
          current.volumeMl;

      debugPrint('');
      debugPrint(
        '${previous.volumeMl} -> '
        '${current.volumeMl} ml',
      );

      if (difference <= 0) {
        if (difference < 0) {
          debugPrint(
            'เติมน้ำ +${difference.abs()} ml '
            'ไม่นับเป็นการดื่ม',
          );
        }

        continue;
      }

      final drankAmount =
          difference;

      totalDrank +=
          drankAmount;

      final slot =
          _slotIndex(
        current.time,
      );

      debugPrint(
        'ดื่ม $drankAmount ml '
        'เวลา '
        '${_two(current.time.hour)}:'
        '${_two(current.time.minute)}',
      );

      if (slot < 0 ||
          slot >= bars.length) {
        continue;
      }

      bars[slot] +=
          drankAmount;

      debugPrint(
        'BAR ${_dailyLabels()[slot]} '
        '+= $drankAmount '
        '=> ${bars[slot]} ml',
      );
    }

    final latest =
        validRecords.last;

    final latestVolumeMl =
        latest.volumeMl;

    debugPrint('');
    debugPrint(
      '================ RESULT ================',
    );
    debugPrint(
      'น้ำในขวดล่าสุด = '
      '$latestVolumeMl ml',
    );
    debugPrint(
      'ดื่มรวมทั้งวัน = '
      '$totalDrank ml',
    );
    debugPrint(
      'DAILY BARS = '
      '$bars',
    );
    debugPrint(
      '========================================',
    );

    return _DayHistoryResult(
      bars:
          List<int>.from(
        bars,
      ),
      totalDrank:
          totalDrank,
      latestVolumeMl:
          latestVolumeMl,
      hasRecords:
          true,
    );
  }
    // ============================================================
  // TIMESTAMP -> DATETIME
  // ============================================================

  DateTime? _dateTimeFromTimestamp(
    int timestamp,
  ) {
    try {
      // กรณี timestamp เป็น milliseconds
      if (timestamp > 1000000000000) {
        return DateTime
            .fromMillisecondsSinceEpoch(
          timestamp,
        ).toLocal();
      }

      // กรณี timestamp เป็น seconds
      return DateTime
          .fromMillisecondsSinceEpoch(
        timestamp * 1000,
        isUtc: true,
      ).toLocal();
    } catch (e) {
      debugPrint(
        'Timestamp convert error: $e',
      );

      return null;
    }
  }

  // ============================================================
  // PARSE TIME FROM HISTORY KEY
  //
  // รองรับ key เช่น
  // 15-30
  // 15-30-10
  // 15:30
  // 15:30:10
  // ============================================================

  DateTime? _timeFromHistoryKey(
    DateTime day,
    String key,
  ) {
    try {
      String cleanKey =
          key.trim();

      cleanKey =
          cleanKey.replaceAll(
        ':',
        '-',
      );

      final parts =
          cleanKey.split('-');

      if (parts.length < 2) {
        return null;
      }

      final hour =
          int.tryParse(
        parts[0],
      );

      final minute =
          int.tryParse(
        parts[1],
      );

      int second = 0;

      if (parts.length >= 3) {
        second =
            int.tryParse(
              parts[2],
            ) ??
            0;
      }

      if (hour == null ||
          minute == null) {
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

      return DateTime(
        day.year,
        day.month,
        day.day,
        hour,
        minute,
        second,
      );
    } catch (e) {
      debugPrint(
        'Parse history key error $key : $e',
      );

      return null;
    }
  }

  // ============================================================
  // LOAD WEEKLY DATA
  //
  // กันโหลด weekly ซ้อนกันด้วย _isLoadingWeekly
  // ============================================================

  Future<void> _loadWeeklyData() async {
    if (_isLoadingWeekly) {
      return;
    }

    _isLoadingWeekly = true;

    try {
      final newWeeklyBars =
          List<int>.filled(
        7,
        0,
      );

      int sum = 0;
      int dayCount = 0;

      final today =
          _dateOnly(
        DateTime.now(),
      );

      for (
        int i = 0;
        i < 7;
        i++
      ) {
        final day =
            selectedWeekStart.add(
          Duration(
            days: i,
          ),
        );

        // วันในอนาคต
        if (day.isAfter(
          today,
        )) {
          newWeeklyBars[i] = 0;
          continue;
        }

        try {
          final result =
              await _calculateDayHistory(
            day,
          );

          final drank =
              result.totalDrank
                  .clamp(
                    0,
                    dailyGoalMl,
                  )
                  .toInt();

          newWeeklyBars[i] =
              drank;

          if (result.hasData) {
            sum += drank;
            dayCount++;
          }
        } catch (e) {
          debugPrint(
            'Weekly day error '
            '${_dateKey(day)}: $e',
          );

          newWeeklyBars[i] = 0;
        }
      }

      // ========================================================
      // ค่าเฉลี่ยต่อวัน
      // ========================================================

      final average =
          dayCount > 0
              ? (sum / dayCount)
                  .round()
              : 0;

      // ========================================================
      // เป้าหมายรวมรายสัปดาห์
      // dailyGoalMl x 7
      // ========================================================

      final weekGoal =
          weeklyGoalMl;

      // ========================================================
      // เปอร์เซ็นต์ของน้ำที่ดื่มรวมทั้งสัปดาห์
      // เทียบกับเป้าหมายรวมทั้งสัปดาห์
      // ========================================================

      final percent =
          _percent(
        sum,
        weekGoal,
      );

      if (!mounted) return;

      setState(() {
        weeklyBars =
            List<int>.from(
          newWeeklyBars,
        );

        // ช่องแรกยังแสดงค่าเฉลี่ยต่อวัน
        selectedDrankMl =
            average;

        // เปอร์เซ็นต์ใช้ยอดรวมทั้งสัปดาห์ / เป้าหมายรวมทั้งสัปดาห์
        selectedPercent =
            percent;
      });

      debugPrint('');
      debugPrint(
        '================ WEEKLY ================',
      );

      debugPrint(
        'Weekly bars = $weeklyBars',
      );

      debugPrint(
        'Average drank = '
        '$average ml/day',
      );

      debugPrint(
        'Daily goal = '
        '$dailyGoalMl ml',
      );

      debugPrint(
        'Weekly goal = '
        '$weeklyGoalMl ml',
      );

      debugPrint(
        'Weekly total drank = '
        '$sum ml',
      );

      debugPrint(
        'Average percent = '
        '$percent%',
      );

      debugPrint(
        '========================================',
      );
    } catch (e, stack) {
      debugPrint(
        'Load weekly error: $e',
      );

      debugPrint(
        '$stack',
      );

      if (!mounted) return;

      setState(() {
        weeklyBars =
            List<int>.filled(
          7,
          0,
        );

        selectedDrankMl = 0;
        selectedPercent = 0;
      });
    } finally {
      _isLoadingWeekly = false;
    }
  }

  // ============================================================
  // CALCULATE DAILY GOAL FROM PROFILE
  // ============================================================

  int _calculateGoalFromProfile(
    Map<String, dynamic> data,
  ) {
    final gender =
        '${data['gender'] ?? ''}';

    final heightCm =
        _toInt(
      data['height_cm'],
      fallback: 160,
    );

    final kidneyStage =
        '${data['kidney_stage'] ?? ''}';

    if (heightCm <= 0) {
      return 1400;
    }

    // cm -> inch
    final heightInch =
        heightCm / 2.54;

    final isFemale =
        gender.contains(
      'หญิง',
    );

    double ibw;

    if (isFemale) {
      ibw =
          45.5 +
          (
            2.3 *
            (heightInch - 60)
          );
    } else {
      ibw =
          50 +
          (
            2.3 *
            (heightInch - 60)
          );
    }

    if (ibw <= 0) {
      return 1400;
    }

    int mlPerKg = 25;

    if (kidneyStage.contains('1') ||
        kidneyStage.contains('2')) {
      mlPerKg = 30;
    } else if (
        kidneyStage.contains('3')) {
      mlPerKg = 25;
    } else if (
        kidneyStage.contains('4')) {
      mlPerKg = 20;
    } else if (
        kidneyStage.contains('5')) {
      mlPerKg = 15;
    }

    final rawGoal =
        ibw * mlPerKg;

    return _roundToHundred(
      rawGoal,
    );
  }

  // ============================================================
  // ROUND TO HUNDRED
  // ============================================================

  int _roundToHundred(
    double value,
  ) {
    final base =
        (value ~/ 100) *
        100;

    final remainder =
        value - base;

    return remainder >= 50
        ? base + 100
        : base;
  }

  // ============================================================
  // GO PREVIOUS
  // ============================================================

  void _goPrevious() {
    if (isWeekly) {
      setState(() {
        selectedWeekStart =
            selectedWeekStart
                .subtract(
          const Duration(
            days: 7,
          ),
        );
      });
    } else {
      setState(() {
        selectedDay =
            selectedDay
                .subtract(
          const Duration(
            days: 1,
          ),
        );
      });
    }

    _loadSelectedData();
  }

  // ============================================================
  // PICK DAY
  // ============================================================

  Future<void> _pickDay() async {
    final picked =
        await showDatePicker(
      context: context,
      initialDate:
          selectedDay,
      firstDate:
          DateTime(2024),
      lastDate:
          DateTime.now(),
    );

    if (picked == null) {
      return;
    }

    setState(() {
      selectedDay =
          _dateOnly(
        picked,
      );
    });

    await _loadSelectedData();
  }

  // ============================================================
  // PICK WEEK
  // ============================================================

  Future<void> _showWeekPicker() async {
    DateTime tempWeek =
        selectedWeekStart;

    final weeks =
        List.generate(
      12,
      (index) =>
          _startOfWeekSunday(
        DateTime.now(),
      ).subtract(
        Duration(
          days: index * 7,
        ),
      ),
    );

    final picked =
        await showDialog<DateTime>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (
            context,
            setModalState,
          ) {
            return Dialog(
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  18,
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(
                  18,
                  18,
                  18,
                  12,
                ),
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    const Row(
                      children: [
                        Icon(
                          Icons.calendar_month,
                          color: blue,
                          size: 28,
                        ),
                        SizedBox(
                          width: 8,
                        ),
                        Text(
                          'เลือกช่วงสัปดาห์',
                          style:
                              TextStyle(
                            fontSize: 22,
                            fontWeight:
                                FontWeight.bold,
                            color: blue,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(
                      height: 12,
                    ),

                    SizedBox(
                      height: 300,
                      child:
                          ListView.builder(
                        itemCount:
                            weeks.length,
                        itemBuilder: (
                          context,
                          index,
                        ) {
                          final week =
                              weeks[index];

                          final isSelected =
                              _isSameDay(
                            tempWeek,
                            week,
                          );

                          return ListTile(
                            dense: true,

                            contentPadding:
                                EdgeInsets.zero,

                            title: Text(
                              _thaiWeekRange(
                                week,
                              ),
                              style:
                                  const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),

                            trailing:
                                Radio<DateTime>(
                              value:
                                  week,

                              groupValue:
                                  tempWeek,

                              onChanged:
                                  (value) {
                                if (value ==
                                    null) {
                                  return;
                                }

                                setModalState(
                                  () {
                                    tempWeek =
                                        value;
                                  },
                                );
                              },
                            ),

                            selected:
                                isSelected,

                            selectedTileColor:
                                const Color(
                              0xFFD7ECFF,
                            ),

                            shape:
                                RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(
                                8,
                              ),
                            ),

                            onTap: () {
                              setModalState(
                                () {
                                  tempWeek =
                                      week;
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),

                    Row(
                      children: [
                        Expanded(
                          child:
                              OutlinedButton(
                            onPressed: () {
                              Navigator.pop(
                                context,
                              );
                            },
                            child:
                                const Text(
                              'ยกเลิก',
                            ),
                          ),
                        ),

                        const SizedBox(
                          width: 10,
                        ),

                        Expanded(
                          child:
                              ElevatedButton(
                            onPressed: () {
                              Navigator.pop(
                                context,
                                tempWeek,
                              );
                            },
                            style:
                                ElevatedButton.styleFrom(
                              backgroundColor:
                                  const Color(
                                0xFF4D7EF2,
                              ),
                              foregroundColor:
                                  Colors.white,
                            ),
                            child:
                                const Text(
                              'ยืนยัน',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (picked == null) {
      return;
    }

    setState(() {
      selectedWeekStart =
          picked;
    });

    await _loadSelectedData();
  }
    // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final size =
        MediaQuery.of(context).size;

    final scale =
        (size.width / 390)
            .clamp(
              0.82,
              1.0,
            )
            .toDouble();

    final horizontalPadding =
        22.0 * scale;

    final chartValues =
        isWeekly
            ? List<int>.from(
                weeklyBars,
              )
            : List<int>.from(
                dailyBars,
              );

    final chartLabels =
        isWeekly
            ? _weeklyLabels(
                selectedWeekStart,
              )
            : _dailyLabels();

    final overviewTitle =
        isWeekly
            ? 'ภาพรวมสัปดาห์'
            : 'ภาพรวมวันนี้';

    final firstTitle =
        isWeekly
            ? 'ค่าเฉลี่ยต่อวัน'
            : 'ดื่มแล้ว';

    final firstValue =
        selectedDrankMl;

    final percent =
        selectedPercent;

    // เป้าหมายที่ใช้แสดง:
    // รายวัน = dailyGoalMl
    // รายสัปดาห์ = dailyGoalMl x 7
    final displayGoal =
        isWeekly
            ? weeklyGoalMl
            : dailyGoalMl;

    // ยอดรวมรายสัปดาห์จากแท่งทั้ง 7 วัน
    final weeklyTotalDrank =
        weeklyBars.fold<int>(
      0,
      (sum, value) => sum + value,
    );

    final remaining =
        (displayGoal -
                (isWeekly
                    ? weeklyTotalDrank
                    : firstValue))
            .clamp(
              0,
              displayGoal,
            )
            .toInt();

    return Scaffold(
      backgroundColor: bg,

      body: SafeArea(
        child: isLoading
            ? const Center(
                child:
                    CircularProgressIndicator(
                  color: blue,
                ),
              )
            : Stack(
                children: [
                  SingleChildScrollView(
                    padding:
                        EdgeInsets.fromLTRB(
                      horizontalPadding,
                      24 * scale,
                      horizontalPadding,
                      135 * scale,
                    ),

                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,

                      children: [
                        Text(
                          'สถิติการดื่มน้ำ',

                          style:
                              TextStyle(
                            fontSize:
                                42 * scale,

                            fontWeight:
                                FontWeight.w900,

                            color:
                                blue,

                            height:
                                1.05,
                          ),
                        ),

                        SizedBox(
                          height:
                              20 * scale,
                        ),

                        _ModeSwitch(
                          isWeekly:
                              isWeekly,

                          scale:
                              scale,

                          onChanged:
                              (value) {
                            if (value ==
                                isWeekly) {
                              return;
                            }

                            setState(() {
                              isWeekly =
                                  value;
                            });

                            _loadSelectedData();
                          },
                        ),

                        SizedBox(
                          height:
                              24 * scale,
                        ),

                        _DateSelector(
                          text:
                              isWeekly
                                  ? _thaiWeekRange(
                                      selectedWeekStart,
                                    )
                                  : _thaiDate(
                                      selectedDay,
                                    ),

                          scale:
                              scale,

                          onPrevious:
                              _goPrevious,

                          onTap:
                              isWeekly
                                  ? _showWeekPicker
                                  : _pickDay,

                          showDownIcon:
                              isWeekly,
                        ),

                        SizedBox(
                          height:
                              18 * scale,
                        ),

                        _OverviewCard(
                          title:
                              overviewTitle,

                          firstTitle:
                              firstTitle,

                          firstValue:
                              firstValue,

                          goalValue:
                              displayGoal,

                          percent:
                              percent,

                          remaining:
                              remaining,

                          scale:
                              scale,

                          isWeekly:
                              isWeekly,
                        ),

                        SizedBox(
                          height:
                              22 * scale,
                        ),

                        _ChartCard(
                          values:
                              chartValues,

                          labels:
                              chartLabels,

                          goal:
                              isWeekly
                                  ? weeklyGoalMl
                                  : dailyGoalMl,

                          scale:
                              scale,

                          isWeekly:
                              isWeekly,
                        ),
                      ],
                    ),
                  ),

                  Positioned(
                    left: 0,
                    right: 0,
                    bottom:
                        20 * scale,

                    child:
                        _BottomNav(
                      scale:
                          scale,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ============================================================
  // HELPERS
  // ============================================================

  static DateTime _dateOnly(
    DateTime date,
  ) {
    return DateTime(
      date.year,
      date.month,
      date.day,
    );
  }

  static DateTime _startOfWeekSunday(
    DateTime date,
  ) {
    final cleanDate =
        _dateOnly(
      date,
    );

    return cleanDate.subtract(
      Duration(
        days:
            cleanDate.weekday % 7,
      ),
    );
  }

  static bool _isSameDay(
    DateTime a,
    DateTime b,
  ) {
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day;
  }

  static String _dateKey(
    DateTime date,
  ) {
    return '${date.year}-'
        '${_two(date.month)}-'
        '${_two(date.day)}';
  }

  static String _two(
    int value,
  ) {
    return value
        .toString()
        .padLeft(
          2,
          '0',
        );
  }

  static int _toInt(
    dynamic value, {
    int fallback = 0,
  }) {
    if (value == null) {
      return fallback;
    }

    if (value is int) {
      return value;
    }

    if (value is double) {
      return value.round();
    }

    if (value is num) {
      return value.round();
    }

    if (value is String) {
      final text =
          value.trim();

      final asInt =
          int.tryParse(
        text,
      );

      if (asInt != null) {
        return asInt;
      }

      final asDouble =
          double.tryParse(
        text,
      );

      if (asDouble != null) {
        return asDouble.round();
      }
    }

    return fallback;
  }

  static int _percent(
    int drank,
    int goal,
  ) {
    if (goal <= 0) {
      return 0;
    }

    return ((drank / goal) * 100)
        .round()
        .clamp(
          0,
          100,
        )
        .toInt();
  }

  static String _formatNumber(
    int value,
  ) {
    return value
        .toString()
        .replaceAllMapped(
      RegExp(
        r'(\d{1,3})(?=(\d{3})+(?!\d))',
      ),
      (match) =>
          '${match[1]},',
    );
  }

  static String _thaiDate(
    DateTime date,
  ) {
    return '${date.day} '
        '${_thaiMonth(date.month)} '
        '${date.year + 543}';
  }

  static String _thaiWeekRange(
    DateTime start,
  ) {
    final end =
        start.add(
      const Duration(
        days: 6,
      ),
    );

    final buddhistYear =
        end.year + 543;

    if (start.month ==
        end.month) {
      return '${start.day}-${end.day} '
          '${_thaiMonth(end.month)} '
          '$buddhistYear';
    }

    return '${start.day} '
        '${_thaiMonthShort(start.month)} - '
        '${end.day} '
        '${_thaiMonthShort(end.month)} '
        '$buddhistYear';
  }

  static String _thaiMonth(
    int month,
  ) {
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

    return months[month];
  }

  static String _thaiMonthShort(
    int month,
  ) {
    const months = [
      '',
      'ม.ค.',
      'ก.พ.',
      'มี.ค.',
      'เม.ย.',
      'พ.ค.',
      'มิ.ย.',
      'ก.ค.',
      'ส.ค.',
      'ก.ย.',
      'ต.ค.',
      'พ.ย.',
      'ธ.ค.',
    ];

    return months[month];
  }

  static List<String> _dailyLabels() {
    // 21:00 เป็นเวลาสิ้นสุดของรอบ 19:00-21:00
    // จึงไม่สร้างแท่งแยกที่ 21:00
    return [
      '07:00',
      '09:00',
      '11:00',
      '13:00',
      '15:00',
      '17:00',
      '19:00',
    ];
  }

  static int _slotIndex(
    DateTime time,
  ) {
    final hour =
        time.hour;

    if (hour < 7) {
      return -1;
    }

    if (hour < 9) {
      return 0;
    }

    if (hour < 11) {
      return 1;
    }

    if (hour < 13) {
      return 2;
    }

    if (hour < 15) {
      return 3;
    }

    if (hour < 17) {
      return 4;
    }

    if (hour < 19) {
      return 5;
    }

    // รอบสุดท้ายคือ 19:00-21:00
    // ข้อมูลก่อน 21:00 อยู่ในแท่ง 19:00
    if (hour < 21) {
      return 6;
    }

    // หลัง 21:00 ไม่แสดงเป็นแท่งรายวัน
    return -1;
  }

  static List<String> _weeklyLabels(
    DateTime start,
  ) {
    const days = [
      'อา.',
      'จ.',
      'อ.',
      'พ.',
      'พฤ.',
      'ศ.',
      'ส.',
    ];

    return List.generate(
      7,
      (index) {
        final day =
            start.add(
          Duration(
            days: index,
          ),
        );

        return '${days[index]}\n'
            '${day.day} '
            '${_thaiMonthShort(day.month)}';
      },
    );
  }
}

// ============================================================
// MODELS
// ============================================================

class _WaterHistoryRecord {
  const _WaterHistoryRecord({
    required this.key,
    required this.time,
    required this.volumeMl,
    required this.timestamp,
  });

  final String key;
  final DateTime time;
  final int volumeMl;
  final int timestamp;
}

class _DayHistoryResult {
  const _DayHistoryResult({
    required this.bars,
    required this.totalDrank,
    required this.latestVolumeMl,
    required this.hasRecords,
  });

  final List<int> bars;
  final int totalDrank;
  final int latestVolumeMl;
  final bool hasRecords;

  bool get hasData =>
      hasRecords;
}

// ============================================================
// MODE SWITCH
// ============================================================

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.isWeekly,
    required this.scale,
    required this.onChanged,
  });

  final bool isWeekly;
  final double scale;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      width:
          255 * scale,

      height:
          46 * scale,

      decoration:
          BoxDecoration(
        color:
            Colors.white,

        borderRadius:
            BorderRadius.circular(
          24 * scale,
        ),
      ),

      child: Row(
        children: [
          Expanded(
            child:
                _ModeButton(
              text:
                  'รายวัน',

              active:
                  !isWeekly,

              scale:
                  scale,

              onTap: () {
                onChanged(
                  false,
                );
              },
            ),
          ),

          Expanded(
            child:
                _ModeButton(
              text:
                  'รายสัปดาห์',

              active:
                  isWeekly,

              scale:
                  scale,

              onTap: () {
                onChanged(
                  true,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.text,
    required this.active,
    required this.scale,
    required this.onTap,
  });

  final String text;
  final bool active;
  final double scale;
  final VoidCallback onTap;

  @override
  Widget build(
    BuildContext context,
  ) {
    return GestureDetector(
      onTap:
          onTap,

      child:
          AnimatedContainer(
        duration:
            const Duration(
          milliseconds:
              180,
        ),

        alignment:
            Alignment.center,

        decoration:
            BoxDecoration(
          color:
              active
                  ? const Color(
                      0xFF4D7EF2,
                    )
                  : Colors.white,

          borderRadius:
              BorderRadius.circular(
            24 * scale,
          ),
        ),

        child: Text(
          text,

          maxLines:
              1,

          style:
              TextStyle(
            fontSize:
                20 * scale,

            fontWeight:
                FontWeight.w900,

            color:
                active
                    ? Colors.white
                    : Colors.black,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// DATE SELECTOR
// ============================================================

class _DateSelector extends StatelessWidget {
  const _DateSelector({
    required this.text,
    required this.scale,
    required this.onPrevious,
    required this.onTap,
    required this.showDownIcon,
  });

  final String text;
  final double scale;
  final VoidCallback onPrevious;
  final VoidCallback onTap;
  final bool showDownIcon;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Center(
      child: Row(
        mainAxisSize:
            MainAxisSize.min,

        children: [
          IconButton(
            visualDensity:
                VisualDensity.compact,

            onPressed:
                onPrevious,

            icon:
                Icon(
              Icons.chevron_left,

              size:
                  32 * scale,

              color:
                  _StatisticsPageState
                      .blue,
            ),
          ),

          GestureDetector(
            onTap:
                onTap,

            child: Row(
              mainAxisSize:
                  MainAxisSize.min,

              children: [
                Icon(
                  Icons.calendar_month,

                  size:
                      27 * scale,

                  color:
                      _StatisticsPageState
                          .blue,
                ),

                SizedBox(
                  width:
                      8 * scale,
                ),

                Text(
                  text,

                  style:
                      TextStyle(
                    fontSize:
                        19 * scale,

                    fontWeight:
                        FontWeight.w900,

                    color:
                        _StatisticsPageState
                            .blue,
                  ),
                ),

                if (showDownIcon) ...[
                  SizedBox(
                    width:
                        6 * scale,
                  ),

                  Icon(
                    Icons
                        .keyboard_arrow_down,

                    size:
                        24 * scale,

                    color:
                        _StatisticsPageState
                            .blue,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
// ============================================================
// OVERVIEW CARD
// ============================================================

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.title,
    required this.firstTitle,
    required this.firstValue,
    required this.goalValue,
    required this.percent,
    required this.remaining,
    required this.scale,
    required this.isWeekly,
  });

  final String title;
  final String firstTitle;
  final int firstValue;
  final int goalValue;
  final int percent;
  final int remaining;
  final double scale;
  final bool isWeekly;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      width: double.infinity,

      padding: EdgeInsets.fromLTRB(
        18 * scale,
        18 * scale,
        18 * scale,
        24 * scale,
      ),

      decoration: BoxDecoration(
        color: Colors.white,

        borderRadius:
            BorderRadius.circular(
          24 * scale,
        ),

        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withOpacity(
              0.12,
            ),
            blurRadius: 14,
            offset: const Offset(
              0,
              8,
            ),
          ),
        ],
      ),

      child: Column(
        mainAxisSize:
            MainAxisSize.min,

        children: [
          Row(
            children: [
              Icon(
                Icons.water_drop,

                color:
                    const Color(
                  0xFF008DD8,
                ),

                size:
                    30 * scale,
              ),

              SizedBox(
                width:
                    8 * scale,
              ),

              Expanded(
                child: Text(
                  title,

                  style:
                      TextStyle(
                    fontSize:
                        23 * scale,

                    fontWeight:
                        FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(
            height:
                20 * scale,
          ),

          Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,

            children: [
              Expanded(
                child:
                    _SummaryItem(
                  icon:
                      Icons.local_drink_outlined,

                  title:
                      firstTitle,

                  value:
                      firstValue,

                  unit:
                      'ml',

                  scale:
                      scale,
                ),
              ),

              _DividerLine(
                scale:
                    scale,
              ),

              Expanded(
                child:
                    _SummaryItem(
                  icon:
                      Icons.track_changes,

                  title:
                      'เป้าหมาย',

                  value:
                      goalValue,

                  unit:
                      'ml',

                  scale:
                      scale,
                ),
              ),

              _DividerLine(
                scale:
                    scale,
              ),

              Expanded(
                child:
                    _SummaryItem(
                  icon:
                      Icons.water_drop,

                  title:
                      'เปอร์เซ็นต์',

                  value:
                      percent,

                  unit:
                      '%',

                  scale:
                      scale,
                ),
              ),
            ],
          ),

          SizedBox(
            height:
                22 * scale,
          ),

          _ProgressBar(
            percent:
                percent,

            scale:
                scale,
          ),

          SizedBox(
            height:
                12 * scale,
          ),

          Padding(
            padding:
                EdgeInsets.symmetric(
              horizontal:
                  6 * scale,
            ),

            child: Text(
              isWeekly
                  ? 'ดื่มได้เฉลี่ย '
                      '${_StatisticsPageState._formatNumber(firstValue)} ml ต่อวัน '
                      'จากเป้าหมายรวม '
                      '${_StatisticsPageState._formatNumber(goalValue)} ml ต่อสัปดาห์'
                  : 'เหลืออีก '
                      '${_StatisticsPageState._formatNumber(remaining)} ml '
                      'เพื่อให้ถึงเป้าหมาย',

              textAlign:
                  TextAlign.center,

              style:
                  TextStyle(
                fontSize:
                    15 * scale,

                height:
                    1.25,

                color:
                    Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SUMMARY ITEM
// ============================================================

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.icon,
    required this.title,
    required this.value,
    required this.unit,
    required this.scale,
  });

  final IconData icon;
  final String title;
  final int value;
  final String unit;
  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Column(
      children: [
        CircleAvatar(
          radius:
              38 * scale,

          backgroundColor:
              _StatisticsPageState
                  .softBlue,

          child: Icon(
            icon,

            size:
                42 * scale,

            color:
                const Color(
              0xFF078BD2,
            ),
          ),
        ),

        SizedBox(
          height:
              12 * scale,
        ),

        SizedBox(
          height:
              42 * scale,

          child: Center(
            child: Text(
              title,

              maxLines:
                  2,

              textAlign:
                  TextAlign.center,

              style:
                  TextStyle(
                fontSize:
                    15.5 * scale,

                height:
                    1.15,

                color:
                    Colors.black87,
              ),
            ),
          ),
        ),

        SizedBox(
          height:
              8 * scale,
        ),

        FittedBox(
          fit:
              BoxFit.scaleDown,

          child: Text(
            _StatisticsPageState
                ._formatNumber(
              value,
            ),

            maxLines:
                1,

            style:
                TextStyle(
              fontSize:
                  35 * scale,

              fontWeight:
                  FontWeight.w900,

              color:
                  _StatisticsPageState
                      .blue,

              height:
                  1,
            ),
          ),
        ),

        SizedBox(
          height:
              5 * scale,
        ),

        Text(
          unit,

          style:
              TextStyle(
            fontSize:
                21 * scale,

            fontWeight:
                FontWeight.w900,

            color:
                _StatisticsPageState
                    .blue,

            height:
                1,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// DIVIDER LINE
// ============================================================

class _DividerLine extends StatelessWidget {
  const _DividerLine({
    required this.scale,
  });

  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      width:
          1,

      height:
          155 * scale,

      margin:
          EdgeInsets.symmetric(
        horizontal:
            4 * scale,
      ),

      color:
          const Color(
        0xFF9EAABD,
      ),
    );
  }
}

// ============================================================
// PROGRESS BAR
// ============================================================

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.percent,
    required this.scale,
  });

  final int percent;
  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    final safePercent =
        percent.clamp(
      0,
      100,
    );

    return ClipRRect(
      borderRadius:
          BorderRadius.circular(
        99,
      ),

      child: SizedBox(
        height:
            18 * scale,

        child: Stack(
          children: [
            Container(
              color:
                  const Color(
                0xFFA7B1BF,
              ),
            ),

            FractionallySizedBox(
              widthFactor:
                  safePercent / 100,

              child: Container(
                color:
                    const Color(
                  0xFF3B96D4,
                ),
              ),
            ),

            Center(
              child: Text(
                '$safePercent%',

                style:
                    TextStyle(
                  color:
                      Colors.white,

                  fontSize:
                      12 * scale,

                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// CHART CARD
// ============================================================

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.values,
    required this.labels,
    required this.goal,
    required this.scale,
    required this.isWeekly,
  });

  final List<int> values;
  final List<String> labels;
  final int goal;
  final double scale;
  final bool isWeekly;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      width:
          double.infinity,

      padding:
          EdgeInsets.fromLTRB(
        18 * scale,
        18 * scale,
        18 * scale,
        22 * scale,
      ),

      decoration:
          BoxDecoration(
        color:
            Colors.white,

        borderRadius:
            BorderRadius.circular(
          24 * scale,
        ),

        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withOpacity(
              0.12,
            ),

            blurRadius:
                14,

            offset:
                const Offset(
              0,
              8,
            ),
          ),
        ],
      ),

      child: Column(
        children: [
          Row(
            children: [
              Icon(
                Icons.water_drop,

                color:
                    const Color(
                  0xFF008DD8,
                ),

                size:
                    30 * scale,
              ),

              SizedBox(
                width:
                    8 * scale,
              ),

              Expanded(
                child: Text(
                  isWeekly
                      ? 'กราฟปริมาณน้ำที่ดื่มรายวันในสัปดาห์'
                      : 'กราฟปริมาณน้ำที่ดื่ม',

                  style:
                      TextStyle(
                    fontSize:
                        22 * scale,

                    fontWeight:
                        FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(
            height:
                20 * scale,
          ),

          SizedBox(
            height:
                280 * scale,

            width:
                double.infinity,

            child:
                CustomPaint(
              key: ValueKey(
                '${isWeekly ? "week" : "day"}-${values.join("-")}',
              ),

              painter:
                  _BarChartPainter(
                values:
                    List<int>.from(
                  values,
                ),

                labels:
                    List<String>.from(
                  labels,
                ),

                goal:
                    goal,

                isWeekly:
                    isWeekly,
              ),
            ),
          ),

          SizedBox(
            height:
                10 * scale,
          ),

          Row(
            mainAxisAlignment:
                MainAxisAlignment.center,

            children: [
              Container(
                width:
                    14 * scale,

                height:
                    14 * scale,

                decoration:
                    BoxDecoration(
                  color:
                      const Color(
                    0xFF3B96D4,
                  ),

                  borderRadius:
                      BorderRadius.circular(
                    4,
                  ),
                ),
              ),

              SizedBox(
                width:
                    8 * scale,
              ),

              Text(
                'ปริมาณน้ำที่ดื่ม (ml)',

                style:
                    TextStyle(
                  fontSize:
                      14 * scale,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// BAR CHART PAINTER
// ============================================================

class _BarChartPainter extends CustomPainter {
  _BarChartPainter({
    required this.values,
    required this.labels,
    required this.goal,
    required this.isWeekly,
  });

  final List<int> values;
  final List<String> labels;
  final int goal;
  final bool isWeekly;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    const double leftPad =
        46.0;

    const double topPad =
        20.0;

    const double rightPad =
        8.0;

    const double bottomPad =
        55.0;

    final chartWidth =
        math.max(
      1.0,
      size.width -
          leftPad -
          rightPad,
    ).toDouble();

    final chartHeight =
        math.max(
      1.0,
      size.height -
          topPad -
          bottomPad,
    ).toDouble();

    int maxData = 0;

    for (final value in values) {
      if (value > maxData) {
        maxData = value;
      }
    }

    int baseMax;

    if (isWeekly) {
      // แต่ละแท่งของกราฟรายสัปดาห์คือปริมาณที่ดื่ม "ต่อวัน"
      // จึงใช้สเกลต่อวัน ไม่ใช้เป้าหมายรวม 7 วัน
      baseMax =
          math.max(
        2000,
        maxData,
      );
    } else {
      // กราฟรายวันกำหนดแกน Y คงที่ 0-2000 mL
      baseMax = 2000;
    }

    const int step =
        200;

    double roundedMax =
        ((baseMax / step).ceil() * step)
            .toDouble();

    if (roundedMax <= 0) {
      roundedMax =
          isWeekly
              ? 1400
              : 2000;
    }

    final gridPaint =
        Paint()
          ..color =
              Colors.grey.shade300
          ..strokeWidth =
              1;

    final axisPaint =
        Paint()
          ..color =
              Colors.grey.shade500
          ..strokeWidth =
              1;

    final textPainter =
        TextPainter(
      textDirection:
          TextDirection.ltr,

      textAlign:
          TextAlign.center,
    );

    // ทั้งรายวันและรายสัปดาห์:
    // ถ้าสเกลสูงสุด 2000 จะได้ 0, 200, 400, ... 2000 mL
    const int gridCount =
        10;

    for (
      int i = 0;
      i <= gridCount;
      i++
    ) {
      final y =
          topPad +
          (chartHeight /
                  gridCount) *
              i;

      canvas.drawLine(
        Offset(
          leftPad,
          y,
        ),
        Offset(
          leftPad +
              chartWidth,
          y,
        ),
        gridPaint,
      );

      final labelValue =
          (roundedMax -
                  ((roundedMax /
                          gridCount) *
                      i))
              .round();

      textPainter.text =
          TextSpan(
        text:
            '$labelValue',

        style:
            const TextStyle(
          fontSize:
              10,

          color:
              Colors.black87,
        ),
      );

      textPainter.layout();

      textPainter.paint(
        canvas,
        Offset(
          leftPad -
              textPainter.width -
              7,
          y -
              textPainter.height /
                  2,
        ),
      );
    }

    canvas.drawLine(
      Offset(
        leftPad,
        topPad +
            chartHeight,
      ),
      Offset(
        leftPad +
            chartWidth,
        topPad +
            chartHeight,
      ),
      axisPaint,
    );

    final count =
        math.min(
      values.length,
      labels.length,
    );

    if (count <= 0) {
      return;
    }

    final groupWidth =
        chartWidth /
        count;

    final barWidth =
        isWeekly
            ? math.min(
                30.0,
                groupWidth *
                    0.58,
              )
            : math.min(
                25.0,
                groupWidth *
                    0.55,
              );

    final weeklyColors = [
      const Color(
        0xFFFF525A,
      ),
      const Color(
        0xFFFFD54F,
      ),
      const Color(
        0xFFF38BDA,
      ),
      const Color(
        0xFF80D982,
      ),
      const Color(
        0xFFFFB74D,
      ),
      const Color(
        0xFF90CAF9,
      ),
      const Color(
        0xFF64B5F6,
      ),
    ];

    for (
      int i = 0;
      i < count;
      i++
    ) {
      int value =
          values[i];

      if (value < 0) {
        value = 0;
      }

      final safeValue =
          value.clamp(
        0,
        roundedMax.toInt(),
      );

      double barHeight =
          roundedMax <= 0
              ? 0
              : (safeValue /
                      roundedMax) *
                  chartHeight;

      if (value > 0 &&
          barHeight < 3) {
        barHeight =
            3;
      }

      final x =
          leftPad +
          (groupWidth *
              i) +
          ((groupWidth -
                  barWidth) /
              2);

      final y =
          topPad +
          chartHeight -
          barHeight;

      if (value > 0) {
        final barPaint =
            Paint()
              ..color =
                  isWeekly
                      ? weeklyColors[
                          i %
                              weeklyColors
                                  .length
                        ]
                      : const Color(
                          0xFF3B96D4,
                        );

        final barRect =
            RRect.fromRectAndRadius(
          Rect.fromLTWH(
            x,
            y,
            barWidth,
            barHeight,
          ),
          const Radius.circular(
            6,
          ),
        );

        canvas.drawRRect(
          barRect,
          barPaint,
        );

        textPainter.text =
            TextSpan(
          text:
              '$value',

          style:
              const TextStyle(
            fontSize:
                9.5,

            fontWeight:
                FontWeight.bold,

            color:
                Color(
              0xFF2878C9,
            ),
          ),
        );

        textPainter.layout();

        final numberY =
            math.max(
          0.0,
          y -
              textPainter.height -
              4,
        ).toDouble();

        textPainter.paint(
          canvas,
          Offset(
            x +
                ((barWidth -
                        textPainter.width) /
                    2),
            numberY,
          ),
        );
      }

      textPainter.text =
          TextSpan(
        text:
            labels[i],

        style:
            const TextStyle(
          fontSize:
              9.5,

          color:
              Colors.black87,

          height:
              1.15,
        ),
      );

      textPainter.layout(
        maxWidth:
            groupWidth + 6,
      );

      textPainter.paint(
        canvas,
        Offset(
          leftPad +
              (groupWidth *
                  i) +
              ((groupWidth -
                      textPainter.width) /
                  2),
          topPad +
              chartHeight +
              8,
        ),
      );
    }

    textPainter.text =
        const TextSpan(
      text:
          '(ml)',

      style:
          TextStyle(
        fontSize:
            10.5,

        color:
            Colors.black87,
      ),
    );

    textPainter.layout();

    textPainter.paint(
      canvas,
      const Offset(
        0,
        0,
      ),
    );
  }

  
    // ============================================================
  // SHOULD REPAINT   
  // ============================================================

  @override
  bool shouldRepaint(
    covariant _BarChartPainter oldDelegate,
  ) {
    if (oldDelegate.goal != goal) {
      return true;
    }

    if (oldDelegate.isWeekly !=
        isWeekly) {
      return true;
    }

    if (oldDelegate.values.length !=
        values.length) {
      return true;
    }

    for (
      int i = 0;
      i < values.length;
      i++
    ) {
      if (oldDelegate.values[i] !=
          values[i]) {
        return true;
      }
    }

    if (oldDelegate.labels.length !=
        labels.length) {
      return true;
    }

    for (
      int i = 0;
      i < labels.length;
      i++
    ) {
      if (oldDelegate.labels[i] !=
          labels[i]) {
        return true;
      }
    }

    return false;
  }
}

// ============================================================
// BOTTOM NAVIGATION
// ============================================================

class _BottomNav extends StatelessWidget {
  const _BottomNav({
    required this.scale,
  });

  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Center(
      child: Container(
        width:
            255 * scale,

        height:
            72 * scale,

        decoration:
            BoxDecoration(
          color:
              Colors.white,

          borderRadius:
              BorderRadius.circular(
            42 * scale,
          ),

          boxShadow: [
            BoxShadow(
              color:
                  Colors.black.withOpacity(
                0.16,
              ),

              blurRadius:
                  16,

              offset:
                  const Offset(
                0,
                8,
              ),
            ),
          ],
        ),

        child: Row(
          children: [
            // ==================================================
            // HOME
            // ==================================================

            Expanded(
              child:
                  InkWell(
                borderRadius:
                    BorderRadius.circular(
                  42 * scale,
                ),

                onTap: () {
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const HomePage(),
                    ),
                  );
                },

                child: Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,

                  children: [
                    Icon(
                      Icons.home,

                      size:
                          32 * scale,

                      color:
                          Colors.grey.shade500,
                    ),

                    Text(
                      'หน้าแรก',

                      style:
                          TextStyle(
                        fontSize:
                            14 * scale,

                        fontWeight:
                            FontWeight.bold,

                        color:
                            Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ==================================================
            // STATISTICS
            // ==================================================

            Expanded(
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,

                children: [
                  Icon(
                    Icons.bar_chart,

                    size:
                        36 * scale,

                    color:
                        _StatisticsPageState.blue,
                  ),

                  Text(
                    'สถิติ',

                    style:
                        TextStyle(
                      fontSize:
                          14 * scale,

                      fontWeight:
                          FontWeight.bold,

                      color:
                          _StatisticsPageState.blue,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}