import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
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

  // ============================================================
  // FIREBASE REALTIME DATABASE
  // ============================================================

  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  // ============================================================
  // UID เดียวกับหน้า HOME และ ESP32
  // ============================================================

  static const String bottleUserId =
      'jE9aQG2EgtMRFLb8lKaqRpIf1QH3';

  // ============================================================
  // DEVICE ID
  // ============================================================

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

  DateTime selectedDay = _dateOnly(DateTime.now());
  DateTime selectedWeekStart = _startOfWeekSunday(DateTime.now());

  int dailyGoalMl = 1400;

  int selectedDrankMl = 0;
  int selectedPercent = 0;

  int todayDrankMl = 0;

  int bottleRemainingMl = 0;
  int bottleLevelPercent = 0;

  List<int> dailyBars = List<int>.filled(8, 0);
  List<int> weeklyBars = List<int>.filled(7, 0);

  StreamSubscription<DatabaseEvent>? bottleSubscription;
  StreamSubscription<DatabaseEvent>? historySubscription;

  // ============================================================
  // INIT
  // ============================================================

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

  // ============================================================
  // LOAD PROFILE + START
  // ============================================================

  Future<void> _loadProfileAndData() async {
    try {
      debugPrint('');
      debugPrint('================================');
      debugPrint('STATISTICS PAGE START');
      debugPrint('UID = $bottleUserId');
      debugPrint('DATABASE URL = $databaseUrl');
      debugPrint('DEVICE ID = $bottleDeviceId');
      debugPrint('================================');

      try {
        final profileDoc = await FirebaseFirestore.instance
            .collection('profiles')
            .doc(bottleUserId)
            .get()
            .timeout(
              const Duration(seconds: 8),
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
            final calculatedGoal = _calculateGoalFromProfile(data);

            if (calculatedGoal > 0) {
              dailyGoalMl = calculatedGoal;
            }
          }
        }
      } on TimeoutException {
        debugPrint('Profile loading timeout');
      } on FirebaseException catch (e) {
        debugPrint('Firestore profile error: ${e.code}');
        debugPrint('Firestore profile message: ${e.message}');
      } catch (e) {
        debugPrint('Profile error: $e');
      }

      if (dailyGoalMl <= 0) {
        dailyGoalMl = 1400;
      }

      debugPrint('FINAL DAILY GOAL = $dailyGoalMl ml');

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }

      _listenBottle();
      _listenTodayHistory();

      await _loadSelectedData();
    } catch (e, stack) {
      debugPrint('Load profile/data error: $e');
      debugPrint('$stack');

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // ============================================================
  // LISTEN DEVICE
  //
  // current_volume_ml = ปริมาณน้ำที่เหลือ
  // bottle_level_percent = % น้ำที่เหลือ
  //
  // ดื่มแล้ว = goal - น้ำที่เหลือ
  // % ดื่มแล้ว = 100 - % น้ำที่เหลือ
  // ============================================================

  void _listenBottle() {
    bottleSubscription?.cancel();

    final path =
        'users/$bottleUserId/devices/$bottleDeviceId';

    final ref = _database.ref(path);

    debugPrint('');
    debugPrint('================================');
    debugPrint('STATISTICS - LISTENING DEVICE');
    debugPrint('Path: $path');
    debugPrint('================================');

    bottleSubscription = ref.onValue.listen(
      (event) {
        try {
          final value = event.snapshot.value;

          if (value is! Map) {
            debugPrint('Bottle data is not Map');
            return;
          }

          final data = Map<dynamic, dynamic>.from(value);

          final newBottleRemainingMl = _toInt(
            data['current_volume_ml'],
            fallback: 0,
          );

          final newBottleLevelPercent = _toInt(
            data['bottle_level_percent'],
            fallback: 0,
          ).clamp(0, 100).toInt();

          final drankToday =
              (dailyGoalMl - newBottleRemainingMl)
                  .clamp(0, dailyGoalMl)
                  .toInt();

          final drankPercent =
              (100 - newBottleLevelPercent)
                  .clamp(0, 100)
                  .toInt();

          debugPrint('');
          debugPrint('========== BOTTLE UPDATE ==========');
          debugPrint(
            'Bottle remaining = $newBottleRemainingMl ml',
          );
          debugPrint(
            'Bottle level = $newBottleLevelPercent%',
          );
          debugPrint(
            'Home-style drank = $drankToday ml',
          );
          debugPrint(
            'Home-style percent = $drankPercent%',
          );
          debugPrint('===================================');

          if (!mounted) return;

          setState(() {
            hasBottleData = true;

            bottleRemainingMl = newBottleRemainingMl;
            bottleLevelPercent = newBottleLevelPercent;

            todayDrankMl = drankToday;

            if (!isWeekly &&
                _isSameDay(
                  selectedDay,
                  DateTime.now(),
                )) {
              selectedDrankMl = drankToday;
              selectedPercent = drankPercent;
            }
          });
        } catch (e, stack) {
          debugPrint('Bottle listener error: $e');
          debugPrint('$stack');
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
  // LISTEN WATER HISTORY TODAY
  // ============================================================

  void _listenTodayHistory() {
    historySubscription?.cancel();

    final todayKey = _dateKey(DateTime.now());

    final path =
        'users/$bottleUserId/water_history/$todayKey';

    final ref = _database.ref(path);

    historySubscription = ref.onValue.listen(
      (event) async {
        try {
          if (!isWeekly &&
              _isSameDay(
                selectedDay,
                DateTime.now(),
              )) {
            await _loadDailyData();
          }

          if (isWeekly) {
            final weekEnd = selectedWeekStart.add(
              const Duration(days: 6),
            );

            final today = _dateOnly(DateTime.now());

            if (!today.isBefore(selectedWeekStart) &&
                !today.isAfter(weekEnd)) {
              await _loadWeeklyData();
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

  // ============================================================
  // LOAD SELECTED DATA
  // ============================================================

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
      debugPrint('$stack');
    }
  }

  // ============================================================
  // DAILY
  //
  // วันนี้:
  // ภาพรวม = ใช้ค่าจากขวดแบบเดียวกับ Home
  // กราฟ = ใช้ history
  //
  // วันย้อนหลัง:
  // ใช้ history ทั้งหมด
  // ============================================================

  Future<void> _loadDailyData() async {
    try {
      final result = await _calculateDayHistory(
        selectedDay,
      );

      final isToday = _isSameDay(
        selectedDay,
        DateTime.now(),
      );

      int overviewDrank;
      int overviewPercent;

      if (isToday && hasBottleData) {
        overviewDrank =
            (dailyGoalMl - bottleRemainingMl)
                .clamp(0, dailyGoalMl)
                .toInt();

        overviewPercent =
            (100 - bottleLevelPercent)
                .clamp(0, 100)
                .toInt();
      } else {
        overviewDrank = result.totalDrank;

        overviewPercent = _percent(
          overviewDrank,
          dailyGoalMl,
        );
      }

      if (!mounted) return;

      setState(() {
        dailyBars = List<int>.from(result.bars);

        selectedDrankMl = overviewDrank;
        selectedPercent = overviewPercent;

        if (isToday) {
          todayDrankMl = overviewDrank;
        }
      });

      debugPrint('');
      debugPrint('================ DAILY =================');
      debugPrint('Date = ${_dateKey(selectedDay)}');
      debugPrint('Goal = $dailyGoalMl ml');
      debugPrint('Has bottle data = $hasBottleData');
      debugPrint(
        'Bottle remaining = $bottleRemainingMl ml',
      );
      debugPrint(
        'Bottle level = $bottleLevelPercent%',
      );
      debugPrint(
        'History latest = ${result.latestVolumeMl} ml',
      );
      debugPrint(
        'History total drank = ${result.totalDrank} ml',
      );
      debugPrint(
        'Overview drank = $overviewDrank ml',
      );
      debugPrint(
        'Overview percent = $overviewPercent%',
      );
      debugPrint('Bars = $dailyBars');
      debugPrint('========================================');
    } catch (e, stack) {
      debugPrint(
        'Load daily history error: $e',
      );
      debugPrint('$stack');

      if (!mounted) return;

      final isToday = _isSameDay(
        selectedDay,
        DateTime.now(),
      );

      setState(() {
        dailyBars = List<int>.filled(8, 0);

        if (isToday && hasBottleData) {
          selectedDrankMl =
              (dailyGoalMl - bottleRemainingMl)
                  .clamp(0, dailyGoalMl)
                  .toInt();

          selectedPercent =
              (100 - bottleLevelPercent)
                  .clamp(0, 100)
                  .toInt();
        } else {
          selectedDrankMl = 0;
          selectedPercent = 0;
        }
      });
    }
  }

  // ============================================================
  // CALCULATE ONE DAY
  //
  // volume_ml = ปริมาณน้ำที่เหลือในขวด
  //
  // เช่น
  // 07:10 = 1400 ml
  // 07:30 = 1300 ml
  //
  // ดื่ม = 1400 - 1300 = 100 ml
  //
  // ถ้าน้ำเพิ่ม เช่น 700 -> 1500
  // ถือว่าเติมน้ำ ไม่นับเป็นการดื่ม
  // ============================================================

  Future<_DayHistoryResult> _calculateDayHistory(
    DateTime day,
  ) async {
    final bars = List<int>.filled(8, 0);

    final dateKey = _dateKey(day);

    final path =
        'users/$bottleUserId/water_history/$dateKey';

    debugPrint('');
    debugPrint('--------------------------------');
    debugPrint('LOAD DAY HISTORY');
    debugPrint('DATE = $dateKey');
    debugPrint('Path = $path');
    debugPrint('--------------------------------');

    final DatabaseReference ref = _database.ref(path);

    DataSnapshot snapshot;

    try {
      snapshot = await ref.get();
    } catch (e) {
      debugPrint('RTDB GET ERROR = $e');

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

    final rawValue = snapshot.value;

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

    final List<_WaterHistoryRecord> records = [];

    historyMap.forEach(
      (key, value) {
        if (value is! Map) {
          return;
        }

        final data =
            Map<dynamic, dynamic>.from(
          value,
        );

        final volume = _toInt(
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

        final timestamp = _toInt(
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
          recordTime!,
          day,
        )) {
          return;
        }

        records.add(
          _WaterHistoryRecord(
            key: key.toString(),
            time: recordTime!,
            volumeMl: volume,
            timestamp: timestamp,
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
      (a, b) => a.time.compareTo(b.time),
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

    final now = DateTime.now();

    final isToday = _isSameDay(day, now);

    final List<_WaterHistoryRecord> validRecords = [];

    for (final record in records) {
      if (isToday &&
          record.time.isAfter(now)) {
        continue;
      }

      validRecords.add(record);
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

    for (int i = 1;
        i < validRecords.length;
        i++) {
      final previous = validRecords[i - 1];
      final current = validRecords[i];

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

      final drankAmount = difference;

      totalDrank += drankAmount;

      final slot = _slotIndex(current.time);

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

      bars[slot] += drankAmount;

      debugPrint(
        'BAR ${_dailyLabels()[slot]} '
        '+= $drankAmount '
        '=> ${bars[slot]} ml',
      );
    }

    final latest = validRecords.last;

    final latestVolumeMl =
        latest.volumeMl;

    debugPrint('');
    debugPrint(
      '================ RESULT ================',
    );
    debugPrint(
      'น้ำเหลือล่าสุด = $latestVolumeMl ml',
    );
    debugPrint(
      'ดื่มรวมทั้งวัน = $totalDrank ml',
    );
    debugPrint(
      'DAILY BARS = $bars',
    );
    debugPrint(
      '========================================',
    );

    return _DayHistoryResult(
      bars: List<int>.from(bars),
      totalDrank: totalDrank,
      latestVolumeMl: latestVolumeMl,
      hasRecords: true,
    );
  }

  // ============================================================
  // TIMESTAMP
  // ============================================================

  DateTime? _dateTimeFromTimestamp(
    int timestamp,
  ) {
    try {
      if (timestamp > 1000000000000) {
        return DateTime
            .fromMillisecondsSinceEpoch(
          timestamp,
        ).toLocal();
      }

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
  // TIME FROM KEY
  // ============================================================

  DateTime? _timeFromHistoryKey(
    DateTime day,
    String key,
  ) {
    try {
      String cleanKey = key.trim();

      cleanKey =
          cleanKey.replaceAll(':', '-');

      final parts =
          cleanKey.split('-');

      if (parts.length < 2) {
        return null;
      }

      final hour =
          int.tryParse(parts[0]);

      final minute =
          int.tryParse(parts[1]);

      int second = 0;

      if (parts.length >= 3) {
        second =
            int.tryParse(parts[2]) ?? 0;
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
  // WEEKLY
  // ============================================================

  Future<void> _loadWeeklyData() async {
    final newWeeklyBars =
        List<int>.filled(7, 0);

    int sum = 0;
    int dayCount = 0;

    final today =
        _dateOnly(DateTime.now());

    for (int i = 0; i < 7; i++) {
      final day =
          selectedWeekStart.add(
        Duration(days: i),
      );

      if (day.isAfter(today)) {
        newWeeklyBars[i] = 0;
        continue;
      }

      try {
        final result =
            await _calculateDayHistory(
          day,
        );

        newWeeklyBars[i] =
            result.totalDrank;

        if (result.hasData) {
          sum += result.totalDrank;
          dayCount++;
        }
      } catch (e) {
        debugPrint(
          'Weekly error ${_dateKey(day)}: $e',
        );

        newWeeklyBars[i] = 0;
      }
    }

    final average =
        dayCount > 0
            ? (sum / dayCount).round()
            : 0;

    final percent = _percent(
      average,
      dailyGoalMl,
    );

    if (!mounted) return;

    setState(() {
      weeklyBars =
          List<int>.from(newWeeklyBars);

      selectedDrankMl = average;
      selectedPercent = percent;
    });
  }

  // ============================================================
  // CALCULATE GOAL
  // ============================================================

  int _calculateGoalFromProfile(
    Map<String, dynamic> data,
  ) {
    final gender =
        '${data['gender'] ?? ''}';

    final heightCm = _toInt(
      data['height_cm'],
      fallback: 160,
    );

    final kidneyStage =
        '${data['kidney_stage'] ?? ''}';

    if (heightCm <= 0) {
      return 1400;
    }

    final heightInch =
        heightCm / 2.54;

    final isFemale =
        gender.contains('หญิง');

    double ibw;

    if (isFemale) {
      ibw =
          45.5 +
          (2.3 *
              (heightInch - 60));
    } else {
      ibw =
          50 +
          (2.3 *
              (heightInch - 60));
    }

    if (ibw <= 0) {
      return 1400;
    }

    int mlPerKg = 25;

    if (kidneyStage.contains('1') ||
        kidneyStage.contains('2')) {
      mlPerKg = 30;
    } else if (kidneyStage.contains('3')) {
      mlPerKg = 25;
    } else if (kidneyStage.contains('4')) {
      mlPerKg = 20;
    } else if (kidneyStage.contains('5')) {
      mlPerKg = 15;
    }

    final rawGoal =
        ibw * mlPerKg;

    return _roundToHundred(rawGoal);
  }

  int _roundToHundred(
    double value,
  ) {
    final base =
        (value ~/ 100) * 100;

    final remainder =
        value - base;

    return remainder >= 50
        ? base + 100
        : base;
  }

  // ============================================================
  // PREVIOUS
  // ============================================================

  void _goPrevious() {
    if (isWeekly) {
      setState(() {
        selectedWeekStart =
            selectedWeekStart.subtract(
          const Duration(days: 7),
        );
      });
    } else {
      setState(() {
        selectedDay =
            selectedDay.subtract(
          const Duration(days: 1),
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
      initialDate: selectedDay,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );

    if (picked == null) {
      return;
    }

    setState(() {
      selectedDay =
          _dateOnly(picked);
    });

    await _loadSelectedData();
  }

  // ============================================================
  // PICK WEEK
  // ============================================================

  Future<void> _showWeekPicker() async {
    DateTime tempWeek =
        selectedWeekStart;

    final weeks = List.generate(
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
                    BorderRadius.circular(18),
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
                        SizedBox(width: 8),
                        Text(
                          'เลือกช่วงสัปดาห์',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight:
                                FontWeight.bold,
                            color: blue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 300,
                      child: ListView.builder(
                        itemCount:
                            weeks.length,
                        itemBuilder:
                            (
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
                              value: week,
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
      selectedWeekStart = picked;
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
            .clamp(0.82, 1.0)
            .toDouble();

    final horizontalPadding =
        22.0 * scale;

    final chartValues =
        isWeekly
            ? List<int>.from(weeklyBars)
            : List<int>.from(dailyBars);

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

    final remaining =
        (dailyGoalMl - firstValue)
            .clamp(
              0,
              dailyGoalMl,
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
                          style: TextStyle(
                            fontSize:
                                42 * scale,
                            fontWeight:
                                FontWeight.w900,
                            color: blue,
                            height: 1.05,
                          ),
                        ),
                        SizedBox(
                          height: 20 * scale,
                        ),
                        _ModeSwitch(
                          isWeekly: isWeekly,
                          scale: scale,
                          onChanged: (value) {
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
                          height: 24 * scale,
                        ),
                        _DateSelector(
                          text: isWeekly
                              ? _thaiWeekRange(
                                  selectedWeekStart,
                                )
                              : _thaiDate(
                                  selectedDay,
                                ),
                          scale: scale,
                          onPrevious:
                              _goPrevious,
                          onTap: isWeekly
                              ? _showWeekPicker
                              : _pickDay,
                          showDownIcon:
                              isWeekly,
                        ),
                        SizedBox(
                          height: 18 * scale,
                        ),
                        _OverviewCard(
                          title:
                              overviewTitle,
                          firstTitle:
                              firstTitle,
                          firstValue:
                              firstValue,
                          goalValue:
                              dailyGoalMl,
                          percent:
                              percent,
                          remaining:
                              remaining,
                          scale: scale,
                          isWeekly:
                              isWeekly,
                        ),
                        SizedBox(
                          height: 22 * scale,
                        ),
                        _ChartCard(
                          values:
                              chartValues,
                          labels:
                              chartLabels,
                          goal:
                              dailyGoalMl,
                          scale: scale,
                          isWeekly:
                              isWeekly,
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 20 * scale,
                    child: _BottomNav(
                      scale: scale,
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
        _dateOnly(date);

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
    return '${date.year}-${_two(date.month)}-${_two(date.day)}';
  }

  static String _two(
    int value,
  ) {
    return value
        .toString()
        .padLeft(2, '0');
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
      final text = value.trim();

      final asInt =
          int.tryParse(text);

      if (asInt != null) {
        return asInt;
      }

      final asDouble =
          double.tryParse(text);

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
        .clamp(0, 100)
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
    return '${date.day} ${_thaiMonth(date.month)} ${date.year + 543}';
  }

  static String _thaiWeekRange(
    DateTime start,
  ) {
    final end = start.add(
      const Duration(days: 6),
    );

    final buddhistYear =
        end.year + 543;

    if (start.month ==
        end.month) {
      return '${start.day}-${end.day} ${_thaiMonth(end.month)} $buddhistYear';
    }

    return '${start.day} ${_thaiMonthShort(start.month)} - '
        '${end.day} ${_thaiMonthShort(end.month)} $buddhistYear';
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
    return [
      '07:00',
      '09:00',
      '11:00',
      '13:00',
      '15:00',
      '17:00',
      '19:00',
      '21:00',
    ];
  }

  static int _slotIndex(
    DateTime time,
  ) {
    final hour = time.hour;

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

    if (hour < 21) {
      return 6;
    }

    return 7;
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
        final day = start.add(
          Duration(days: index),
        );

        return '${days[index]}\n'
            '${day.day} ${_thaiMonthShort(day.month)}';
      },
    );
  }
}

// ============================================================
// MODEL
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

  bool get hasData => hasRecords;
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
      width: 255 * scale,
      height: 46 * scale,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius:
            BorderRadius.circular(
          24 * scale,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _ModeButton(
              text: 'รายวัน',
              active: !isWeekly,
              scale: scale,
              onTap: () {
                onChanged(false);
              },
            ),
          ),
          Expanded(
            child: _ModeButton(
              text: 'รายสัปดาห์',
              active: isWeekly,
              scale: scale,
              onTap: () {
                onChanged(true);
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
      onTap: onTap,
      child: AnimatedContainer(
        duration:
            const Duration(
          milliseconds: 180,
        ),
        alignment:
            Alignment.center,
        decoration: BoxDecoration(
          color: active
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
          maxLines: 1,
          style: TextStyle(
            fontSize:
                20 * scale,
            fontWeight:
                FontWeight.w900,
            color: active
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
            icon: Icon(
              Icons.chevron_left,
              size:
                  32 * scale,
              color:
                  _StatisticsPageState.blue,
            ),
          ),
          GestureDetector(
            onTap: onTap,
            child: Row(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_month,
                  size:
                      27 * scale,
                  color:
                      _StatisticsPageState.blue,
                ),
                SizedBox(
                  width: 8 * scale,
                ),
                Text(
                  text,
                  style: TextStyle(
                    fontSize:
                        19 * scale,
                    fontWeight:
                        FontWeight.w900,
                    color:
                        _StatisticsPageState.blue,
                  ),
                ),
                if (showDownIcon) ...[
                  SizedBox(
                    width: 6 * scale,
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    size:
                        24 * scale,
                    color:
                        _StatisticsPageState.blue,
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
// OVERVIEW
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
      padding:
          EdgeInsets.fromLTRB(
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
            offset:
                const Offset(
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
                size: 30 * scale,
              ),
              SizedBox(
                width: 8 * scale,
              ),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
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
            height: 20 * scale,
          ),
          Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SummaryItem(
                  icon:
                      Icons.local_drink_outlined,
                  title:
                      firstTitle,
                  value:
                      firstValue,
                  unit: 'ml',
                  scale:
                      scale,
                ),
              ),
              _DividerLine(
                scale: scale,
              ),
              Expanded(
                child: _SummaryItem(
                  icon:
                      Icons.track_changes,
                  title:
                      'เป้าหมาย',
                  value:
                      goalValue,
                  unit: 'ml',
                  scale:
                      scale,
                ),
              ),
              _DividerLine(
                scale: scale,
              ),
              Expanded(
                child: _SummaryItem(
                  icon:
                      Icons.water_drop,
                  title:
                      'เปอร์เซ็นต์',
                  value:
                      percent,
                  unit: '%',
                  scale:
                      scale,
                ),
              ),
            ],
          ),
          SizedBox(
            height: 22 * scale,
          ),
          _ProgressBar(
            percent: percent,
            scale: scale,
          ),
          SizedBox(
            height: 12 * scale,
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
                      '${_StatisticsPageState._formatNumber(firstValue)} ml '
                      'จากเป้าหมาย '
                      '${_StatisticsPageState._formatNumber(goalValue)} ml ต่อวัน'
                  : 'เหลืออีก '
                      '${_StatisticsPageState._formatNumber(remaining)} ml '
                      'เพื่อให้ถึงเป้าหมาย',
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                fontSize:
                    15 * scale,
                height: 1.25,
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
              _StatisticsPageState.softBlue,
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
          height: 12 * scale,
        ),
        SizedBox(
          height: 42 * scale,
          child: Center(
            child: Text(
              title,
              maxLines: 2,
              textAlign:
                  TextAlign.center,
              style: TextStyle(
                fontSize:
                    15.5 * scale,
                height: 1.15,
                color:
                    Colors.black87,
              ),
            ),
          ),
        ),
        SizedBox(
          height: 8 * scale,
        ),
        FittedBox(
          fit:
              BoxFit.scaleDown,
          child: Text(
            _StatisticsPageState
                ._formatNumber(
              value,
            ),
            maxLines: 1,
            style: TextStyle(
              fontSize:
                  35 * scale,
              fontWeight:
                  FontWeight.w900,
              color:
                  _StatisticsPageState.blue,
              height: 1,
            ),
          ),
        ),
        SizedBox(
          height: 5 * scale,
        ),
        Text(
          unit,
          style: TextStyle(
            fontSize:
                21 * scale,
            fontWeight:
                FontWeight.w900,
            color:
                _StatisticsPageState.blue,
            height: 1,
          ),
        ),
      ],
    );
  }
}

// ============================================================
// DIVIDER
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
      width: 1,
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
// PROGRESS
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
    return ClipRRect(
      borderRadius:
          BorderRadius.circular(99),
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
                  (percent / 100)
                      .clamp(
                        0.0,
                        1.0,
                      )
                      .toDouble(),
              child: Container(
                color:
                    const Color(
                  0xFF3B96D4,
                ),
              ),
            ),
            Center(
              child: Text(
                '$percent%',
                style: TextStyle(
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
                  'กราฟปริมาณน้ำที่ดื่ม',
                  style: TextStyle(
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
            child: CustomPaint(
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
// BAR CHART
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
    const double leftPad = 46.0;
    const double topPad = 20.0;
    const double rightPad = 8.0;
    const double bottomPad = 55.0;

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
      baseMax =
          math.max(
        dailySafeGoal(goal),
        maxData,
      );
    } else {
      baseMax =
          math.max(
        400,
        maxData,
      );
    }

    const int step = 200;

    double roundedMax =
        ((baseMax / step).ceil() *
                step)
            .toDouble();

    if (roundedMax <= 0) {
      roundedMax =
          isWeekly ? 1400 : 400;
    }

    final gridPaint =
        Paint()
          ..color =
              Colors.grey.shade300
          ..strokeWidth = 1;

    final axisPaint =
        Paint()
          ..color =
              Colors.grey.shade500
          ..strokeWidth = 1;

    final textPainter =
        TextPainter(
      textDirection:
          TextDirection.ltr,
      textAlign:
          TextAlign.center,
    );

    const int gridCount = 4;

    for (int i = 0;
        i <= gridCount;
        i++) {
      final y =
          topPad +
          (chartHeight / gridCount) *
              i;

      canvas.drawLine(
        Offset(leftPad, y),
        Offset(
          leftPad + chartWidth,
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
          fontSize: 10,
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
        topPad + chartHeight,
      ),
      Offset(
        leftPad + chartWidth,
        topPad + chartHeight,
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
        chartWidth / count;

    final barWidth =
        isWeekly
            ? math.min(
                30.0,
                groupWidth * 0.58,
              )
            : math.min(
                25.0,
                groupWidth * 0.55,
              );

    final weeklyColors = [
      const Color(0xFFFF525A),
      const Color(0xFFFFD54F),
      const Color(0xFFF38BDA),
      const Color(0xFF80D982),
      const Color(0xFFFFB74D),
      const Color(0xFF90CAF9),
      const Color(0xFF64B5F6),
    ];

    for (int i = 0;
        i < count;
        i++) {
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
        barHeight = 3;
      }

      final x =
          leftPad +
          (groupWidth * i) +
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
                                  .length]
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
          const Radius.circular(6),
        );

        canvas.drawRRect(
          barRect,
          barPaint,
        );

        textPainter.text =
            TextSpan(
          text: '$value',
          style:
              const TextStyle(
            fontSize: 9.5,
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
        text: labels[i],
        style:
            const TextStyle(
          fontSize: 9.5,
          color:
              Colors.black87,
          height: 1.15,
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
              (groupWidth * i) +
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
      text: '(ml)',
      style: TextStyle(
        fontSize: 10.5,
        color:
            Colors.black87,
      ),
    );

    textPainter.layout();

    textPainter.paint(
      canvas,
      const Offset(0, 0),
    );
  }

  static int dailySafeGoal(
    int goal,
  ) {
    if (goal <= 0) {
      return 1400;
    }

    return goal;
  }

  @override
  bool shouldRepaint(
    covariant _BarChartPainter
        oldDelegate,
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

    for (int i = 0;
        i < values.length;
        i++) {
      if (oldDelegate.values[i] !=
          values[i]) {
        return true;
      }
    }

    return false;
  }
}

// ============================================================
// BOTTOM NAV
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
            Expanded(
              child: InkWell(
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