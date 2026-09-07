import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'notification_page.dart';
import 'profile_page.dart';
import 'statistics_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // =====================================================
  // เป้าหมายรายวัน
  // =====================================================
  int dailyGoalMl = 1200;

  // =====================================================
  // ข้อมูลล่าสุดจาก ESP32
  // =====================================================
  int currentBottleMl = 0;

  // เปอร์เซ็นต์ "น้ำที่เหลืออยู่ในขวด"
  int bottleLevelPercent = 0;

  // =====================================================
  // ข้อมูลการดื่ม "เฉพาะวันนี้"
  // =====================================================
  int todayConsumedMl = 0;

  int lastUpdatedTimestamp = 0;

  bool hasBottleData = false;
  bool isBottleConnected = false;
  bool hasHistoryVolumeData = true;
  bool isLoading = true;

  // วันที่ที่หน้า Home กำลังฟัง water_history อยู่
  String listeningHistoryDateKey = '';

  String nextDrinkTimeText = '07:00 น.';

  Timer? reminderTimer;

  StreamSubscription<DatabaseEvent>? bottleSubscription;
  StreamSubscription<DatabaseEvent>? pairingSubscription;
  StreamSubscription<DatabaseEvent>? historySubscription;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? healthProfileSubscription;
  String? _lastHealthSignature;

  // =====================================================
  // REALTIME DATABASE URL
  // =====================================================
  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  // =====================================================
  // ใช้ UID ของบัญชีที่กำลัง Login
  // ไม่ใช้ UID แบบตายตัว
  // =====================================================
  String? get currentUserId =>
      FirebaseAuth.instance.currentUser?.uid;

  // =====================================================
  // เป้าหมายการดื่มต่อ 2 ชั่วโมงของผู้ใช้ปัจจุบัน
  // ช่วงดื่ม 07:00-21:00 คิดเป็น 15 ชั่วโมงตามกติกาโปรเจกต์
  // =====================================================
  int get twoHourDrinkTargetMl {
    if (dailyGoalMl <= 0) {
      return 0;
    }

    return ((dailyGoalMl / 15.0) * 2.0).round();
  }

  // =====================================================
  // DEVICE ID
  // =====================================================
  static const String bottleDeviceId = 'bottle_001';

  // =====================================================
  // INIT
  // =====================================================
  @override
  void initState() {
    super.initState();

    loadDailyGoal();

    // ฟังการเปลี่ยนข้อมูลสุขภาพ เพื่อคำนวณเป้าหมายใหม่ทันที
    listenHealthProfileChanges();

    // ตรวจสอบก่อนว่าผู้ใช้คนนี้เชื่อมต่อกับขวดหรือยัง
    listenBottleConnectionStatus();

    // อ่านข้อมูลการดื่มของวันนี้
    listenLatestWaterHistory();

    updateNextDrinkTime();

    reminderTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        updateNextDrinkTime();

        // เช็กว่าเปลี่ยนวันหรือยัง
        _checkNewDay();
      },
    );
  }

  // =====================================================
  // วันที่วันนี้ในรูปแบบ YYYY-MM-DD
  // =====================================================
  String _getTodayDateKey() {
    final now = DateTime.now();

    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  // =====================================================
  // เช็กการเปลี่ยนวัน
  //
  // เมื่อขึ้นวันใหม่:
  // - ดื่มแล้ว = 0 ML
  // - เหลืออีก = เป้าหมายเต็ม
  // - กราฟ = 0%
  // - เปลี่ยน listener ไปอ่าน water_history ของวันใหม่
  // =====================================================
  void _checkNewDay() {
    final todayKey = _getTodayDateKey();

    if (listeningHistoryDateKey.isEmpty) {
      return;
    }

    if (todayKey == listeningHistoryDateKey) {
      return;
    }

    debugPrint('');
    debugPrint('================================');
    debugPrint('NEW DAY DETECTED');
    debugPrint(
      '$listeningHistoryDateKey -> $todayKey',
    );
    debugPrint('RESET DAILY DRINK DATA');
    debugPrint('================================');

    if (mounted) {
      setState(() {
        todayConsumedMl = 0;
        hasHistoryVolumeData = true;
      });
    }

    historySubscription?.cancel();
    healthProfileSubscription?.cancel();

    listenLatestWaterHistory();
  }

  // =====================================================
  // DISPOSE
  // =====================================================
  @override
  void dispose() {
    reminderTimer?.cancel();
    bottleSubscription?.cancel();
    pairingSubscription?.cancel();
    historySubscription?.cancel();
    healthProfileSubscription?.cancel();

    super.dispose();
  }

  // =====================================================
  // แปลงค่าต่าง ๆ เป็น int
  // =====================================================
  int parseIntValue(dynamic value) {
    if (value == null) {
      return 0;
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

    final text = value.toString().trim();

    final asInt = int.tryParse(text);

    if (asInt != null) {
      return asInt;
    }

    final asDouble = double.tryParse(text);

    if (asDouble != null) {
      return asDouble.round();
    }

    return 0;
  }

  // =====================================================
  // ดื่มแล้ววันนี้
  // =====================================================
  int get consumedMl {
    if (dailyGoalMl <= 0) {
      return 0;
    }

    return todayConsumedMl.clamp(
      0,
      dailyGoalMl,
    );
  }

  // =====================================================
  // เหลืออีกวันนี้
  //
  // สูตร:
  // เป้าหมายวันนี้ - ดื่มแล้ววันนี้
  // =====================================================
  int get remainingMl {
    if (dailyGoalMl <= 0) {
      return 0;
    }

    final value =
        dailyGoalMl - consumedMl;

    return value.clamp(
      0,
      dailyGoalMl,
    );
  }

  // =====================================================
  // เปอร์เซ็นต์ที่ดื่มแล้ว "วันนี้"
  //
  // ตัวอย่าง:
  // เป้าหมาย 1300 ML
  // ดื่มแล้ว 650 ML
  // = 50%
  //
  // เมื่อขึ้นวันใหม่ todayConsumedMl = 0
  // กราฟจึงกลับเป็น 0%
  // =====================================================
  int get graphPercent {
    if (dailyGoalMl <= 0) {
      return 0;
    }

    final percent =
        ((consumedMl / dailyGoalMl) * 100)
            .round();

    return percent.clamp(
      0,
      100,
    );
  }

  // =====================================================
  // Progress ของกราฟวงกลม 0.0 - 1.0
  // =====================================================
  double get graphProgress {
    return (graphPercent / 100.0)
        .clamp(
          0.0,
          1.0,
        )
        .toDouble();
  }

  // =====================================================
  // ส่งเป้าหมายรายวันไป Realtime Database ให้ ESP32 อ่านได้
  // users/{uid}/drink_settings/daily_goal_ml
  // =====================================================
  Future<void> syncDailyGoalToRealtimeDatabase(
    int goalMl,
  ) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null || goalMl <= 0) {
      return;
    }

    try {
      final database = getRealtimeDatabase();

      final ref = database.ref(
        'users/${user.uid}/drink_settings',
      );

      await ref.update({
        'daily_goal_ml': goalMl,
        'hourly_target_ml': dailyGoalMl > 0
            ? (goalMl / 15.0)
            : 0,
        'two_hour_target_ml': (goalMl / 15.0) * 2.0,
        'updated_at': ServerValue.timestamp,
      });

      debugPrint(
        'RTDB drink goal synced: $goalMl ML/day | '
        '${(goalMl / 15.0).toStringAsFixed(2)} ML/hour | '
        '${((goalMl / 15.0) * 2.0).toStringAsFixed(2)} ML/2h',
      );
    } catch (e) {
      debugPrint('Sync daily goal to RTDB error: $e');
    }
  }

  // =====================================================
  // โหลดเป้าหมายรายวันจาก Firestore
  // =====================================================
  Future<void> loadDailyGoal() async {
    try {
      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }

        return;
      }

      final doc =
          await FirebaseFirestore.instance
              .collection('profiles')
              .doc(user.uid)
              .get();

      if (!doc.exists) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }

        return;
      }

      final data = doc.data()!;

      // =================================================
      // เป้าหมายที่ผู้ใช้ตั้งเอง
      // =================================================
      final manualGoal =
          parseIntValue(
        data['manual_daily_goal_ml'],
      );

      if (manualGoal > 0) {
        if (mounted) {
          setState(() {
            dailyGoalMl = manualGoal;
            isLoading = false;
          });
        }

        // ส่งเป้าหมายของผู้ใช้คนนี้ให้ ESP32 ผ่าน RTDB
        await syncDailyGoalToRealtimeDatabase(manualGoal);

        return;
      }

      // =================================================
      // คำนวณเป้าหมายจากข้อมูล Profile
      // =================================================
      final gender =
          (data['gender'] ?? '').toString();

      final heightCm =
          parseIntValue(
        data['height_cm'],
      );

      final kidneyStage =
          (data['kidney_stage'] ?? '')
              .toString();

      final calculatedGoal =
          calculateDailyGoal(
        gender: gender,
        heightCm: heightCm,
        kidneyStage: kidneyStage,
      );

      if (mounted) {
        setState(() {
          dailyGoalMl =
              calculatedGoal;

          isLoading = false;
        });
      }

      // ส่งเป้าหมายที่คำนวณได้ของผู้ใช้คนนี้ให้ ESP32 ผ่าน RTDB
      await syncDailyGoalToRealtimeDatabase(calculatedGoal);
    } catch (e) {
      debugPrint(
        'Load daily goal error: $e',
      );

      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  // =====================================================
  // ฟังข้อมูลสุขภาพของผู้ใช้แบบ Realtime
  // เมื่อเพศ / ส่วนสูง / ระยะโรคไตเปลี่ยน จะคำนวณเป้าหมายใหม่ทันที
  // =====================================================
  void listenHealthProfileChanges() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    healthProfileSubscription?.cancel();
    healthProfileSubscription = FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .snapshots()
        .listen((doc) async {
      // ถ้าบัญชีถูก logout/เปลี่ยนระหว่างที่ listener กำลังทำงาน
      // ให้หยุด callback ทันที ไม่อ่าน/เขียนข้อมูลของ UID เดิมต่อ
      final currentAuthUser = FirebaseAuth.instance.currentUser;
      if (!mounted ||
          currentAuthUser == null ||
          currentAuthUser.uid != user.uid) {
        return;
      }

      if (!doc.exists) return;

      final data = doc.data();
      if (data == null) return;

      final gender = (data['gender'] ?? '').toString();
      final heightCm = parseIntValue(data['height_cm']);
      final kidneyStage = (data['kidney_stage'] ?? '').toString();
      final signature = '$gender|$heightCm|$kidneyStage';

      // ครั้งแรกเก็บค่าไว้เฉย ๆ เพื่อไม่รบกวน logic เดิมของ loadDailyGoal()
      if (_lastHealthSignature == null) {
        _lastHealthSignature = signature;
        return;
      }

      // ถ้าข้อมูลสุขภาพไม่ได้เปลี่ยน ไม่ต้องทำอะไร
      if (_lastHealthSignature == signature) return;
      _lastHealthSignature = signature;

      final calculatedGoal = calculateDailyGoal(
        gender: gender,
        heightCm: heightCm,
        kidneyStage: kidneyStage,
      );

      // ระหว่าง callback อาจมีการกดออกจากระบบได้
      // ตรวจ UID อีกครั้งก่อนเขียน Firestore
      final authBeforeUpdate = FirebaseAuth.instance.currentUser;
      if (!mounted ||
          authBeforeUpdate == null ||
          authBeforeUpdate.uid != user.uid) {
        return;
      }

      // ข้อมูลสุขภาพเปลี่ยน = ยกเลิกเป้าหมายที่เคยตั้งเอง
      // เพื่อให้ระบบใช้ค่าที่คำนวณจากสุขภาพล่าสุด
      await FirebaseFirestore.instance
          .collection('profiles')
          .doc(user.uid)
          .update({
        'manual_daily_goal_ml': FieldValue.delete(),
      });

      if (mounted) {
        setState(() {
          dailyGoalMl = calculatedGoal;
        });
      }

      // ส่งค่าใหม่ให้ ESP32 ทันที
      await syncDailyGoalToRealtimeDatabase(calculatedGoal);

      debugPrint(
        'Health profile changed -> recalculated daily goal: $calculatedGoal ML/day',
      );
    }, onError: (Object error) {
      // ระหว่าง logout listener อาจได้รับ permission-denied ก่อนถูก dispose
      // จึงรับ error ไว้และไม่ปล่อยให้กระทบ UI
      debugPrint('Health profile listener stopped/error: $error');
    });
  }

  // =====================================================
  // REALTIME DATABASE INSTANCE
  // =====================================================
  FirebaseDatabase getRealtimeDatabase() {
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
    );
  }

  // =====================================================
  // ตรวจสอบสถานะการเชื่อมต่อขวด
  // devices/bottle_001/active_user_id
  // =====================================================
  Future<void> listenBottleConnectionStatus() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (mounted) {
        setState(() {
          isBottleConnected = false;
          hasBottleData = false;
          currentBottleMl = 0;
          bottleLevelPercent = 0;
          lastUpdatedTimestamp = 0;
        });
      }
      return;
    }

    final database = getRealtimeDatabase();
    final ref = database.ref(
      'devices/$bottleDeviceId/active_user_id',
    );

    await pairingSubscription?.cancel();

    pairingSubscription = ref.onValue.listen(
      (event) {
        final activeUid =
            event.snapshot.value?.toString().trim() ?? '';

        final connected =
            activeUid.isNotEmpty &&
            activeUid == user.uid;

        if (!mounted) return;

        if (!connected) {
          bottleSubscription?.cancel();
          setState(() {
            isBottleConnected = false;
            hasBottleData = false;
            currentBottleMl = 0;
            bottleLevelPercent = 0;
            lastUpdatedTimestamp = 0;
          });
          return;
        }

        final wasConnected = isBottleConnected;

        setState(() {
          isBottleConnected = true;
        });

        if (!wasConnected || bottleSubscription == null) {
          listenBottleData();
        }
      },
      onError: (error) {
        if (!mounted) return;
        setState(() {
          isBottleConnected = false;
          hasBottleData = false;
          currentBottleMl = 0;
          bottleLevelPercent = 0;
          lastUpdatedTimestamp = 0;
        });
      },
    );
  }

  // =====================================================
  // อ่านข้อมูลจาก devices
  //
  // users
  //   UID
  //     devices
  //       bottle_001
  //         bottle_level_percent
  //         current_volume_ml
  //         raw_distance_cm
  //         updated_at
  // =====================================================
  Future<void> listenBottleData() async {
    try {
      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) {
        debugPrint(
          'listenBottleData: no logged-in user',
        );

        if (mounted) {
          setState(() {
            hasBottleData = false;
            currentBottleMl = 0;
            bottleLevelPercent = 0;
            lastUpdatedTimestamp = 0;
          });
        }

        return;
      }

      final String uid =
          user.uid;

      if (!isBottleConnected) {
        if (mounted) {
          setState(() {
            hasBottleData = false;
            currentBottleMl = 0;
            bottleLevelPercent = 0;
            lastUpdatedTimestamp = 0;
          });
        }
        return;
      }

      final database =
          getRealtimeDatabase();

      final String databasePath =
          'users/$uid/devices/$bottleDeviceId';

      final DatabaseReference ref =
          database.ref(
        databasePath,
      );

      debugPrint('');
      debugPrint(
        '================================',
      );
      debugPrint(
        'LISTENING DEVICE DATA',
      );
      debugPrint(
        'Logged-in UID: $uid',
      );
      debugPrint(
        'Device ID: $bottleDeviceId',
      );
      debugPrint(
        'Database Path: $databasePath',
      );
      debugPrint(
        'Database URL: $databaseUrl',
      );
      debugPrint(
        '================================',
      );

      // =================================================
      // อ่านข้อมูลครั้งแรก
      // =================================================
      try {
        final snapshot =
            await ref.get();

        debugPrint(
          'Initial Device Data: ${snapshot.value}',
        );

        if (snapshot.exists &&
            snapshot.value is Map) {
          _updateBottleData(
            snapshot.value,
          );
        }
      } catch (e) {
        debugPrint(
          'Initial device read error: $e',
        );
      }

      await bottleSubscription
          ?.cancel();

      // =================================================
      // ฟังข้อมูลแบบ Realtime
      // =================================================
      bottleSubscription =
          ref.onValue.listen(
        (DatabaseEvent event) {
          final value =
              event.snapshot.value;

          debugPrint('');
          debugPrint(
            'DEVICE EVENT RECEIVED',
          );

          debugPrint(
            'Firebase Bottle Data: $value',
          );

          if (value == null) {
            debugPrint(
              'No device data found at $databasePath',
            );

            if (mounted) {
              setState(() {
                hasBottleData =
                    false;
              });
            }

            return;
          }

          _updateBottleData(
            value,
          );
        },
        onError: (Object error) {
          debugPrint(
            'Realtime Device Error: $error',
          );

          if (mounted) {
            setState(() {
              hasBottleData =
                  false;
            });
          }
        },
      );
    } catch (e) {
      debugPrint(
        'listenBottleData Error: $e',
      );

      if (mounted) {
        setState(() {
          hasBottleData = false;
        });
      }
    }
  }

  // =====================================================
  // จัดการข้อมูลจาก devices
  // =====================================================
  void _updateBottleData(
    dynamic value,
  ) {
    if (!isBottleConnected) {
      if (mounted) {
        setState(() {
          hasBottleData = false;
          currentBottleMl = 0;
          bottleLevelPercent = 0;
          lastUpdatedTimestamp = 0;
        });
      }
      return;
    }

    if (value is! Map) {
      debugPrint(
        'Device data is not Map',
      );

      return;
    }

    final data =
        Map<Object?, Object?>.from(
      value,
    );

    // =================================================
    // current_volume_ml
    // =================================================
    final int volume =
        parseIntValue(
      data['current_volume_ml'],
    );

    // =================================================
    // bottle_level_percent
    // =================================================
    final int levelPercent =
        parseIntValue(
      data['bottle_level_percent'],
    );

    // =================================================
    // updated_at
    // =================================================
    final int updatedAt =
        parseIntValue(
      data['updated_at'],
    );

    debugPrint(
      '--------------------------------',
    );

    debugPrint(
      'DEVICE DATA PARSED',
    );

    debugPrint(
      'current_volume_ml = $volume ML',
    );

    debugPrint(
      'ระดับน้ำในขวด = $levelPercent%',
    );

    debugPrint(
      'updated_at = $updatedAt',
    );

    debugPrint(
      '--------------------------------',
    );

    if (mounted) {
      setState(() {
        currentBottleMl =
            volume;

        bottleLevelPercent =
            levelPercent.clamp(
          0,
          100,
        );

        lastUpdatedTimestamp =
            updatedAt;

        hasBottleData =
            true;
      });

      debugPrint(
        'ระดับน้ำในขวด = $bottleLevelPercent%',
      );

      debugPrint(
        'ดื่มแล้ววันนี้ = $consumedMl ML',
      );

      debugPrint(
        'เหลืออีกวันนี้ = $remainingMl ML',
      );

      debugPrint(
        'เปอร์เซ็นต์วันนี้ = $graphPercent%',
      );

      debugPrint(
        'GRAPH PROGRESS = $graphProgress',
      );
    }
  }

  // =====================================================
  // อ่าน water_history เฉพาะ "วันนี้"
  //
  // users/{uid}/water_history/YYYY-MM-DD
  //
  // เมื่อขึ้นวันใหม่ path จะเปลี่ยนเป็นวันใหม่
  // ดื่มแล้ว / เหลืออีก / กราฟ จึงเริ่มใหม่
  // =====================================================
    Future<void> listenLatestWaterHistory() async {
    try {
      final user =
          FirebaseAuth.instance.currentUser;

      if (user == null) {
        debugPrint(
          'listenLatestWaterHistory: no logged-in user',
        );

        if (mounted) {
          setState(() {
            todayConsumedMl = 0;
            hasHistoryVolumeData = false;
          });
        }

        return;
      }

      final String uid =
          user.uid;

      final String todayKey =
          _getTodayDateKey();

      listeningHistoryDateKey =
          todayKey;

      final database =
          getRealtimeDatabase();

      // =================================================
      // อ่านเฉพาะข้อมูลของ "วันนี้"
      // =================================================
      final String historyPath =
          'users/$uid/water_history/$todayKey';

      final DatabaseReference ref =
          database.ref(
        historyPath,
      );

      debugPrint('');
      debugPrint(
        '================================',
      );
      debugPrint(
        'LISTENING TODAY WATER HISTORY',
      );
      debugPrint(
        'Logged-in UID: $uid',
      );
      debugPrint(
        'Today: $todayKey',
      );
      debugPrint(
        'History Path: $historyPath',
      );
      debugPrint(
        '================================',
      );

      // ยกเลิก listener เดิมก่อน
      await historySubscription?.cancel();

      // =================================================
      // อ่านครั้งแรก
      // =================================================
      try {
        final snapshot =
            await ref.get();

        debugPrint(
          'Initial Today History: ${snapshot.value}',
        );

        if (snapshot.exists &&
            snapshot.value != null) {
          _updateTodayDrinkData(
            snapshot.value,
          );
        } else {
          _resetTodayDrinkData();
        }
      } catch (e) {
        debugPrint(
          'Initial today history error: $e',
        );

        _resetTodayDrinkData();
      }

      // =================================================
      // ฟังแบบ Realtime เฉพาะวันนี้
      // =================================================
      historySubscription =
          ref.onValue.listen(
        (DatabaseEvent event) {
          final value =
              event.snapshot.value;

          debugPrint('');
          debugPrint(
            'TODAY WATER HISTORY EVENT',
          );

          if (value == null) {
            debugPrint(
              'No history for today',
            );

            _resetTodayDrinkData();

            return;
          }

          _updateTodayDrinkData(
            value,
          );
        },
        onError: (Object error) {
          debugPrint(
            'Today Water History Error: $error',
          );
        },
      );
    } catch (e) {
      debugPrint(
        'listenLatestWaterHistory Error: $e',
      );

      _resetTodayDrinkData();
    }
  }

  // =====================================================
  // RESET DAILY DATA
  //
  // วันนี้ยังไม่มีประวัติ
  // ดื่มแล้ว = 0
  // เหลืออีก = เป้าหมายเต็ม
  // กราฟ = 0%
  // =====================================================
  void _resetTodayDrinkData() {
    if (!mounted) {
      return;
    }

    setState(() {
      todayConsumedMl = 0;

      // ให้ UI แสดง 0 ML ได้
      // แทนที่จะขึ้น -- ML
      hasHistoryVolumeData = true;
    });

    debugPrint('');
    debugPrint(
      '================================',
    );
    debugPrint(
      'TODAY DRINK DATA RESET',
    );
    debugPrint(
      'ดื่มแล้ว = 0 ML',
    );
    debugPrint(
      'เหลืออีก = $dailyGoalMl ML',
    );
    debugPrint(
      'กราฟ = 0%',
    );
    debugPrint(
      '================================',
    );
  }

  // =====================================================
  // คำนวณการดื่มของ "วันนี้"
  //
  // หลักการ:
  //
  // 1500 -> 1400 = ดื่ม 100 ML
  // 1400 -> 1200 = ดื่ม 200 ML
  //
  // รวม = 300 ML
  //
  // แต่ถ้า:
  // 1200 -> 1800
  //
  // คือเติมน้ำ
  // ไม่ถือว่าเป็นการดื่ม
  // =====================================================
  void _updateTodayDrinkData(
    dynamic value,
  ) {
    if (value is! Map) {
      debugPrint(
        'Today water_history is not Map',
      );

      _resetTodayDrinkData();

      return;
    }

    final dayRecords =
        Map<Object?, Object?>.from(
      value,
    );

    final List<_HomeWaterRecord> records =
        [];

    // =================================================
    // แปลง Firebase records เป็น List
    // =================================================
    for (final entry
        in dayRecords.entries) {
      final String timeKey =
          entry.key.toString();

      final rawRecord =
          entry.value;

      if (rawRecord is! Map) {
        continue;
      }

      final record =
          Map<Object?, Object?>.from(
        rawRecord,
      );

      if (!record.containsKey(
        'volume_ml',
      )) {
        continue;
      }

      final int volume =
          parseIntValue(
        record['volume_ml'],
      );

      final int timestamp =
          parseIntValue(
        record['timestamp'],
      );

      if (volume < 0) {
        continue;
      }

      records.add(
        _HomeWaterRecord(
          key: timeKey,
          volumeMl: volume,
          timestamp: timestamp,
        ),
      );
    }

    // =================================================
    // วันนี้ยังไม่มีข้อมูล
    // =================================================
    if (records.isEmpty) {
      _resetTodayDrinkData();

      return;
    }

    // =================================================
    // เรียงข้อมูลจากเก่า -> ใหม่
    // =================================================
    records.sort(
      (
        a,
        b,
      ) {
        // ถ้ามี timestamp ทั้งคู่
        if (a.timestamp > 0 &&
            b.timestamp > 0) {
          return a.timestamp.compareTo(
            b.timestamp,
          );
        }

        // ถ้าไม่มี timestamp
        // ใช้ key เวลา HH-MM-SS
        return a.key.compareTo(
          b.key,
        );
      },
    );

    int totalConsumed = 0;

    // record แรกเป็นค่าตั้งต้น
    int previousVolume =
        records.first.volumeMl;

    debugPrint('');
    debugPrint(
      '================================',
    );
    debugPrint(
      'CALCULATE TODAY DRINK',
    );
    debugPrint(
      'Records: ${records.length}',
    );
    debugPrint(
      'First volume: $previousVolume ML',
    );

    // =================================================
    // เปรียบเทียบแต่ละ record
    // =================================================
    for (
      int i = 1;
      i < records.length;
      i++
    ) {
      final int currentVolume =
          records[i].volumeMl;

      debugPrint(
        '${records[i - 1].key}: $previousVolume ML'
        ' -> '
        '${records[i].key}: $currentVolume ML',
      );

      // =================================================
      // น้ำลด = ดื่มน้ำ
      // =================================================
      if (previousVolume >
          currentVolume) {
        final int drank =
            previousVolume -
                currentVolume;

        totalConsumed +=
            drank;

        debugPrint(
          'DRINK: +$drank ML',
        );
      }

      // =================================================
      // น้ำเพิ่ม = เติมน้ำ
      // ไม่บวกเป็นการดื่ม
      // =================================================
      else if (currentVolume >
          previousVolume) {
        debugPrint(
          'REFILL: not counted',
        );
      }

      // =================================================
      // น้ำเท่าเดิม
      // =================================================
      else {
        debugPrint(
          'UNCHANGED',
        );
      }

      previousVolume =
          currentVolume;
    }

    // =================================================
    // จำกัดไม่ให้เกินเป้าหมายรายวัน
    // =================================================
    totalConsumed =
        totalConsumed.clamp(
      0,
      dailyGoalMl,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      todayConsumedMl =
          totalConsumed;

      hasHistoryVolumeData =
          true;
    });

    debugPrint(
      '--------------------------------',
    );
    debugPrint(
      'TODAY DRINK SUMMARY',
    );
    debugPrint(
      'ดื่มแล้ววันนี้ = $todayConsumedMl ML',
    );
    debugPrint(
      'เป้าหมาย = $dailyGoalMl ML',
    );
    debugPrint(
      'เหลืออีก = $remainingMl ML',
    );
    debugPrint(
      'เปอร์เซ็นต์ = $graphPercent%',
    );
    debugPrint(
      '================================',
    );
  }

  // =====================================================
  // MODEL สำหรับข้อมูล water_history ในหน้า Home
  // =====================================================
  // หมายเหตุ:
  // class จริงจะใส่หลังปิด _HomePageState ในท่อนถัดไป
  // =====================================================

  // =====================================================
  // คำนวณเป้าหมายรายวัน
  // =====================================================
  int calculateDailyGoal({
    required String gender,
    required int heightCm,
    required String kidneyStage,
  }) {
    if (heightCm <= 0) {
      return 1200;
    }

    final heightInch =
        heightCm / 2.54;

    final isFemale =
        gender.contains('หญิง');

    final ibw = isFemale
        ? 45.5 +
            (2.3 *
                (heightInch - 60))
        : 50 +
            (2.3 *
                (heightInch - 60));

    final stageNumber =
        int.tryParse(
          kidneyStage.replaceAll(
            RegExp(r'[^0-9]'),
            '',
          ),
        ) ??
        3;

    int coefficient;

    if (stageNumber <= 2) {
      coefficient = 30;
    } else if (stageNumber == 3) {
      coefficient = 25;
    } else if (stageNumber == 4) {
      coefficient = 20;
    } else {
      coefficient = 15;
    }

    return roundToNearestHundred(
      ibw * coefficient,
    );
  }

  // =====================================================
  // ปัดหลักร้อย
  // =====================================================
  int roundToNearestHundred(
    double value,
  ) {
    final lower =
        (value ~/ 100) * 100;

    final remainder =
        value - lower;

    return remainder >= 50
        ? lower + 100
        : lower;
  }

  // =====================================================
  // เวลาดื่มครั้งถัดไป
  // =====================================================
  void updateNextDrinkTime() {
    final now =
        DateTime.now();

    final drinkHours = [
      7,
      9,
      11,
      13,
      15,
      17,
      19,
      21,
    ];

    int nextHour = 7;
    bool found = false;

    for (final hour in drinkHours) {
      if (now.hour < hour) {
        nextHour = hour;
        found = true;
        break;
      }
    }

    // หลัง 21:00
    // ให้รอ 07:00 ของวันถัดไป
    if (!found) {
      nextHour = 7;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      nextDrinkTimeText =
          '${nextHour.toString().padLeft(2, '0')}:00 น.';
    });
  }

  // =====================================================
  // บันทึกเป้าหมายเอง
  // =====================================================
  Future<void> saveManualGoal(
    int goalMl,
  ) async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      return;
    }

    await FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .update({
      'manual_daily_goal_ml':
          goalMl,
      'updated_at':
          FieldValue.serverTimestamp(),
    });

    // เมื่อผู้ใช้แก้เป้าหมาย ให้ RTDB/ESP32 ได้ค่าใหม่ทันที
    await syncDailyGoalToRealtimeDatabase(goalMl);

    if (mounted) {
      setState(() {
        dailyGoalMl =
            goalMl;

        // หลังแก้เป้าหมาย
        // ค่าเหลืออีกและ % จะคำนวณใหม่อัตโนมัติ
      });
    }
  }
    // =====================================================
  // DIALOG แก้เป้าหมาย
  // =====================================================
  void showEditGoalDialog() {
    int tempGoal =
        dailyGoalMl;

    showDialog(
      context: context,
      barrierColor:
          Colors.black.withOpacity(
        0.35,
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            return Dialog(
              insetPadding:
                  const EdgeInsets.symmetric(
                horizontal: 24,
              ),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  26,
                ),
              ),
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(
                  22,
                  20,
                  22,
                  22,
                ),
                child: Column(
                  mainAxisSize:
                      MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () {
                            Navigator.pop(
                              context,
                            );
                          },
                          icon:
                              const Icon(
                            Icons.arrow_back,
                            color:
                                Color(
                              0xFF2378C9,
                            ),
                            size: 34,
                          ),
                        ),
                        const Expanded(
                          child: Text(
                            'เป้าหมายการดื่มน้ำ',
                            textAlign:
                                TextAlign.center,
                            style:
                                TextStyle(
                              fontSize:
                                  28,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: 48,
                        ),
                      ],
                    ),

                    const SizedBox(
                      height: 28,
                    ),

                    Row(
                      children: [
                        GoalStepButton(
                          icon:
                              Icons.remove,
                          onTap: () {
                            if (tempGoal >
                                100) {
                              setDialogState(
                                () {
                                  tempGoal -=
                                      100;
                                },
                              );
                            }
                          },
                        ),

                        const SizedBox(
                          width: 12,
                        ),

                        Expanded(
                          child: FittedBox(
                            fit:
                                BoxFit.scaleDown,
                            child: Text(
                              formatNumber(
                                tempGoal,
                              ),
                              maxLines: 1,
                              style:
                                  const TextStyle(
                                fontSize:
                                    44,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(
                          width: 12,
                        ),

                        GoalStepButton(
                          icon:
                              Icons.add,
                          onTap: () {
                            setDialogState(
                              () {
                                tempGoal +=
                                    100;
                              },
                            );
                          },
                        ),
                      ],
                    ),

                    const SizedBox(
                      height: 8,
                    ),

                    const Text(
                      'ml/วัน',
                      style:
                          TextStyle(
                        fontSize: 28,
                      ),
                    ),

                    const SizedBox(
                      height: 24,
                    ),

                    SizedBox(
                      width:
                          double.infinity,
                      height: 54,
                      child:
                          ElevatedButton(
                        onPressed:
                            () async {
                          await saveManualGoal(
                            tempGoal,
                          );

                          if (!mounted) {
                            return;
                          }

                          Navigator.pop(
                            context,
                          );
                        },
                        style:
                            ElevatedButton.styleFrom(
                          backgroundColor:
                              const Color(
                            0xFF3D9ADC,
                          ),
                          foregroundColor:
                              Colors.white,
                          shape:
                              RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(
                              24,
                            ),
                          ),
                        ),
                        child:
                            const Text(
                          'เปลี่ยนเป้าหมาย',
                          style:
                              TextStyle(
                            fontSize:
                                26,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // =====================================================
  // BUILD
  // =====================================================
  @override
  Widget build(
    BuildContext context,
  ) {
    final media =
        MediaQuery.of(
      context,
    );

    final screenWidth =
        media.size.width;

    final screenHeight =
        media.size.height;

    final scale =
        (screenWidth / 430)
            .clamp(
              0.80,
              1.0,
            )
            .toDouble();

    final compact =
        screenHeight < 720;

    // =====================================================
    // ดื่มแล้วของวันนี้
    // =====================================================
    final int drankMl =
        consumedMl;

    // =====================================================
    // เปอร์เซ็นต์ของวันนี้
    // =====================================================
    final int displayedGraphPercent =
        graphPercent;

    // =====================================================
    // Progress ของกราฟวงกลมวันนี้
    // =====================================================
    final double safeProgress =
        graphProgress;

    return MediaQuery(
      data:
          media.copyWith(
        textScaler:
            TextScaler.noScaling,
      ),
      child: Scaffold(
        backgroundColor:
            const Color(
          0xFFEAF8FE,
        ),
        body: SafeArea(
          child:
              LayoutBuilder(
            builder: (
              context,
              constraints,
            ) {
              return Stack(
                children: [
                  // =====================================
                  // BACKGROUND
                  // =====================================
                  Container(
                    decoration:
                        const BoxDecoration(
                      gradient:
                          LinearGradient(
                        begin:
                            Alignment.topCenter,
                        end:
                            Alignment.bottomCenter,
                        colors: [
                          Color(
                            0xFFDFF4FF,
                          ),
                          Color(
                            0xFFEAF8FE,
                          ),
                          Color(
                            0xFFF5FCFF,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // =====================================
                  // CONTENT
                  // =====================================
                  SingleChildScrollView(
                    physics:
                        const BouncingScrollPhysics(),
                    padding:
                        EdgeInsets.fromLTRB(
                      20 * scale,
                      compact
                          ? 12 * scale
                          : 18 * scale,
                      20 * scale,
                      112 * scale,
                    ),
                    child:
                        ConstrainedBox(
                      constraints:
                          BoxConstraints(
                        minHeight:
                            constraints
                                    .maxHeight -
                                (110 * scale),
                      ),
                      child:
                          Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          HeaderSection(
                            scale:
                                scale,
                          ),

                          SizedBox(
                            height:
                                compact
                                    ? 14 *
                                        scale
                                    : 20 *
                                        scale,
                          ),

                          // =============================
                          // GOAL CARD
                          // =============================
                          GoalCard(
                            dailyGoalMl:
                                dailyGoalMl,

                            // เหลืออีกของวันนี้
                            remainingMl:
                                remainingMl,

                            // ดื่มแล้วของวันนี้
                            consumedMl:
                                drankMl,

                            // กราฟของวันนี้
                            progress:
                                safeProgress,

                            // เปอร์เซ็นต์ของวันนี้
                            percent:
                                displayedGraphPercent,

                            // วันนี้ไม่มีข้อมูล
                            // ก็ยังแสดง 0 ML ได้
                            hasVolumeData:
                                true,

                            // ระดับน้ำในขวดยังใช้ข้อมูลจริงจาก ESP32
                            hasBottleData:
                                isBottleConnected &&
                                    hasBottleData,

                            isLoading:
                                isLoading,

                            scale:
                                scale,

                            compact:
                                compact,

                            onEditGoal:
                                showEditGoalDialog,
                          ),

                          SizedBox(
                            height:
                                compact
                                    ? 16 *
                                        scale
                                    : 22 *
                                        scale,
                          ),

                          // =============================
                          // SUMMARY
                          // =============================
                          Row(
                            children: [
                              Expanded(
                                child:
                                    SummaryCard(
                                  icon:
                                      Icons.notifications,
                                  title:
                                      'เวลาดื่มน้ำครั้งถัดไป',
                                  value:
                                      nextDrinkTimeText,
                                  bottomIcon:
                                      Icons.access_time,
                                  bottomText:
                                      'ปริมาณน้ำที่ควรดื่ม ${formatNumber(twoHourDrinkTargetMl)} ml / 2 ชม.',
                                  scale:
                                      scale,
                                  compact:
                                      compact,
                                ),
                              ),

                              SizedBox(
                                width:
                                    14 *
                                        scale,
                              ),

                              Expanded(
                                child:
                                    SummaryCard(
                                  icon:
                                      Icons.water_drop,

                                  title:
                                      'ระดับน้ำในขวด',

                                  // ระดับน้ำจริงจากขวด
                                  value:
                                      isBottleConnected &&
                                              hasBottleData
                                          ? '$bottleLevelPercent%'
                                          : '0%',

                                  bottomText:
                                      !isBottleConnected
                                          ? 'ยังไม่ได้เชื่อมต่อกับขวด'
                                          : hasBottleData
                                              ? 'ข้อมูลล่าสุดจากขวด'
                                              : 'กำลังรอข้อมูลจากขวด',

                                  scale:
                                      scale,

                                  compact:
                                      compact,
                                ),
                              ),
                            ],
                          ),

                          SizedBox(
                            height:
                                compact
                                    ? 18 *
                                        scale
                                    : 28 *
                                        scale,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // =====================================
                  // BOTTOM NAVIGATION
                  // =====================================
                  Positioned(
                    left:
                        50 * scale,
                    right:
                        50 * scale,
                    bottom:
                        18 * scale,
                    child:
                        BottomNavBar(
                      scale:
                          scale,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// =====================================================
// MODEL สำหรับ water_history ของหน้า Home
// =====================================================
class _HomeWaterRecord {
  const _HomeWaterRecord({
    required this.key,
    required this.volumeMl,
    required this.timestamp,
  });

  final String key;
  final int volumeMl;
  final int timestamp;
}

// =====================================================
// HEADER
// =====================================================
class HeaderSection extends StatelessWidget {
  const HeaderSection({
    super.key,
    required this.scale,
  });

  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Padding(
      padding:
          EdgeInsets.symmetric(
        horizontal:
            2 * scale,
      ),
      child: Row(
        children: [
          Icon(
            Icons.water_drop_outlined,
            size:
                58 * scale,
            color:
                const Color(
              0xFF2378C9,
            ),
          ),

          SizedBox(
            width:
                10 * scale,
          ),

          Expanded(
            child:
                Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit:
                      BoxFit.scaleDown,
                  alignment:
                      Alignment.centerLeft,
                  child:
                      Text(
                    'Hydrate Smart',
                    style:
                        TextStyle(
                      fontSize:
                          30 * scale,
                      fontWeight:
                          FontWeight.bold,
                      color:
                          const Color(
                        0xFF2378C9,
                      ),
                    ),
                  ),
                ),

                Text(
                  'ดื่มน้ำดี เพื่อสุขภาพดี',
                  style:
                      TextStyle(
                    fontSize:
                        15 * scale,
                    color:
                        Colors.black,
                  ),
                ),
              ],
            ),
          ),

          InkWell(
            borderRadius:
                BorderRadius.circular(
              28,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) =>
                          const NotificationPage(),
                ),
              );
            },
            child:
                Padding(
              padding:
                  EdgeInsets.all(
                4 * scale,
              ),
              child:
                  Stack(
                clipBehavior:
                    Clip.none,
                children: [
                  Icon(
                    Icons.notifications_none,
                    size:
                        34 * scale,
                    color:
                        const Color(
                      0xFF2378C9,
                    ),
                  ),

                ],
              ),
            ),
          ),

          SizedBox(
            width:
                8 * scale,
          ),

          InkWell(
            borderRadius:
                BorderRadius.circular(
              28,
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) =>
                          const ProfilePage(),
                ),
              );
            },
            child:
                Padding(
              padding:
                  EdgeInsets.all(
                4 * scale,
              ),
              child:
                  Icon(
                Icons.account_circle_outlined,
                size:
                    36 * scale,
                color:
                    const Color(
                  0xFF2378C9,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
// =====================================================
// GOAL CARD
// =====================================================
class GoalCard extends StatelessWidget {
  const GoalCard({
    super.key,
    required this.dailyGoalMl,
    required this.remainingMl,
    required this.consumedMl,
    required this.progress,
    required this.percent,
    required this.hasVolumeData,
    required this.hasBottleData,
    required this.isLoading,
    required this.scale,
    required this.compact,
    required this.onEditGoal,
  });

  final int dailyGoalMl;

  // เหลืออีกวันนี้
  final int remainingMl;

  // ดื่มแล้ววันนี้
  final int consumedMl;

  // progress ของกราฟวงกลม 0.0 - 1.0
  final double progress;

  // เปอร์เซ็นต์ที่ดื่มแล้ววันนี้
  final int percent;

  final bool hasVolumeData;
  final bool hasBottleData;

  final bool isLoading;

  final double scale;
  final bool compact;

  final VoidCallback onEditGoal;

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
        16 * scale,
        18 * scale,
        compact
            ? 18 * scale
            : 22 * scale,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white,
        borderRadius:
            BorderRadius.circular(
          26 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withOpacity(
              0.15,
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
      child:
          Column(
        children: [
          Align(
            alignment:
                Alignment.topRight,
            child:
                EditGoalButton(
              onTap:
                  onEditGoal,
              scale:
                  scale,
            ),
          ),

          SizedBox(
            height:
                compact
                    ? 8 * scale
                    : 14 * scale,
          ),

          Row(
            children: [
              Expanded(
                child:
                    GoalProgressCircle(
                  progress:
                      progress,

                  percent:
                      percent,

                  consumedMl:
                      consumedMl,

                  hasVolumeData:
                      hasVolumeData,

                  hasBottleData:
                      hasBottleData,

                  scale:
                      scale,

                  compact:
                      compact,
                ),
              ),

              SizedBox(
                width:
                    16 * scale,
              ),

              Expanded(
                child:
                    GoalDetail(
                  dailyGoalMl:
                      dailyGoalMl,

                  remainingMl:
                      remainingMl,

                  hasVolumeData:
                      hasVolumeData,

                  isLoading:
                      isLoading,

                  scale:
                      scale,

                  compact:
                      compact,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =====================================================
// EDIT GOAL BUTTON
// =====================================================
class EditGoalButton extends StatelessWidget {
  const EditGoalButton({
    super.key,
    required this.onTap,
    required this.scale,
  });

  final VoidCallback onTap;
  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return InkWell(
      onTap:
          onTap,
      borderRadius:
          BorderRadius.circular(
        18,
      ),
      child:
          Container(
        padding:
            EdgeInsets.symmetric(
          horizontal:
              14 * scale,
          vertical:
              7 * scale,
        ),
        decoration:
            BoxDecoration(
          color:
              const Color(
            0xFFD8ECFF,
          ),
          borderRadius:
              BorderRadius.circular(
            18,
          ),
        ),
        child:
            Text(
          'แก้ไขเป้าหมาย',
          style:
              TextStyle(
            fontSize:
                12 * scale,
            fontWeight:
                FontWeight.bold,
            color:
                const Color(
              0xFF2378C9,
            ),
          ),
        ),
      ),
    );
  }
}

// =====================================================
// PROGRESS CIRCLE
//
// ตอนนี้กราฟใช้ข้อมูล "เฉพาะวันนี้"
//
// สูตร:
// ดื่มแล้ววันนี้ / เป้าหมายวันนี้
//
// ตัวอย่าง:
// เป้าหมาย 1300 ML
// ดื่มแล้ว 650 ML
// = 50%
//
// เมื่อขึ้นวันใหม่:
// ดื่มแล้ว = 0 ML
// กราฟ = 0%
// =====================================================
class GoalProgressCircle extends StatelessWidget {
  const GoalProgressCircle({
    super.key,
    required this.progress,
    required this.percent,
    required this.consumedMl,
    required this.hasVolumeData,
    required this.hasBottleData,
    required this.scale,
    required this.compact,
  });

  final double progress;

  // เปอร์เซ็นต์ที่ดื่มแล้ววันนี้
  final int percent;

  // ML ที่ดื่มแล้ววันนี้
  final int consumedMl;

  final bool hasVolumeData;
  final bool hasBottleData;

  final double scale;
  final bool compact;

  @override
  Widget build(
    BuildContext context,
  ) {
    final circleSize =
        (compact
                ? 140
                : 158) *
            scale;

    return Column(
      children: [
        SizedBox(
          width:
              circleSize,
          height:
              circleSize,
          child:
              CustomPaint(
            painter:
                ProgressCirclePainter(
              progress:
                  progress,
            ),
            child:
                Center(
              child:
                  Padding(
                padding:
                    EdgeInsets.symmetric(
                  horizontal:
                      20 * scale,
                ),
                child:
                    Column(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    Text(
                      'ดื่มแล้ว',
                      textAlign:
                          TextAlign.center,
                      style:
                          TextStyle(
                        fontSize:
                            18 * scale,
                        color:
                            Colors.black,
                      ),
                    ),

                    SizedBox(
                      height:
                          6 * scale,
                    ),

                    FittedBox(
                      fit:
                          BoxFit.scaleDown,
                      child:
                          Text(
                        // วันใหม่ก็แสดง 0 ML ได้เลย
                        '${formatNumber(consumedMl)} ML',
                        style:
                            TextStyle(
                          fontSize:
                              28 * scale,
                          fontWeight:
                              FontWeight.bold,
                          color:
                              const Color(
                            0xFF2378C9,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        SizedBox(
          height:
              9 * scale,
        ),

        // =================================================
        // เปอร์เซ็นต์วันนี้
        //
        // ไม่ใช้ bottleLevelPercent แล้ว
        // วันใหม่จะเป็น 0%
        // =================================================
        Text(
          '$percent%',
          style:
              TextStyle(
            fontSize:
                19 * scale,
            fontWeight:
                FontWeight.bold,
            color:
                const Color(
              0xFF2378C9,
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================
// GOAL DETAIL
// =====================================================
class GoalDetail extends StatelessWidget {
  const GoalDetail({
    super.key,
    required this.dailyGoalMl,
    required this.remainingMl,
    required this.hasVolumeData,
    required this.isLoading,
    required this.scale,
    required this.compact,
  });

  final int dailyGoalMl;

  // เหลืออีกของวันนี้
  final int remainingMl;

  final bool hasVolumeData;
  final bool isLoading;

  final double scale;
  final bool compact;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Text(
          'เป้าหมายวันนี้',
          style:
              TextStyle(
            fontSize:
                19 * scale,
            color:
                Colors.black,
          ),
        ),

        SizedBox(
          height:
              9 * scale,
        ),

        FittedBox(
          fit:
              BoxFit.scaleDown,
          alignment:
              Alignment.centerLeft,
          child:
              Text(
            isLoading
                ? '...'
                : '${formatNumber(dailyGoalMl)} ML',
            style:
                TextStyle(
              fontSize:
                  36 * scale,
              fontWeight:
                  FontWeight.bold,
              color:
                  const Color(
                0xFF2378C9,
              ),
            ),
          ),
        ),

        Divider(
          height:
              compact
                  ? 24 * scale
                  : 30 * scale,
          thickness:
              1,
          color:
              const Color(
            0xFF8BC2F2,
          ),
        ),

        Text(
          'เหลืออีก',
          style:
              TextStyle(
            fontSize:
                18 * scale,
            color:
                Colors.black,
          ),
        ),

        SizedBox(
          height:
              7 * scale,
        ),

        FittedBox(
          fit:
              BoxFit.scaleDown,
          alignment:
              Alignment.centerLeft,
          child:
              Text(
            // วันใหม่จะเท่ากับเป้าหมายเต็ม
            '${formatNumber(remainingMl)} ML',
            style:
                TextStyle(
              fontSize:
                  33 * scale,
              fontWeight:
                  FontWeight.bold,
              color:
                  const Color(
                0xFF2378C9,
              ),
            ),
          ),
        ),

        Text(
          'เพื่อให้ถึงเป้าหมาย',
          style:
              TextStyle(
            fontSize:
                15 * scale,
            color:
                Colors.black,
          ),
        ),
      ],
    );
  }
}
// =====================================================
// SUMMARY CARD
// =====================================================
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.bottomIcon,
    required this.bottomText,
    required this.scale,
    required this.compact,
  });

  final IconData icon;
  final String title;
  final String value;

  final IconData? bottomIcon;
  final String bottomText;

  final double scale;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: (compact ? 160 : 176) * scale,
      padding: EdgeInsets.all(
        16 * scale,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(
          22 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              0.12,
            ),
            blurRadius: 14,
            offset: const Offset(
              0,
              7,
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 26 * scale,
                color: const Color(
                  0xFF2378C9,
                ),
              ),
              SizedBox(
                width: 8 * scale,
              ),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow:
                      TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15 * scale,
                    fontWeight:
                        FontWeight.bold,
                    color: const Color(
                      0xFF16324F,
                    ),
                  ),
                ),
              ),
            ],
          ),

          const Spacer(),

          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 27 * scale,
                  fontWeight:
                      FontWeight.bold,
                  color: const Color(
                    0xFF2378C9,
                  ),
                ),
              ),
            ),
          ),

          const Spacer(),

          Row(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              if (bottomIcon != null) ...[
                Icon(
                  bottomIcon,
                  size: 16 * scale,
                  color:
                      Colors.grey.shade600,
                ),
                SizedBox(
                  width: 5 * scale,
                ),
              ],

              Expanded(
                child: Text(
                  bottomText,
                  maxLines: 2,
                  overflow:
                      TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5 * scale,
                    height: 1.25,
                    color:
                        Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =====================================================
// BOTTOM NAVIGATION BAR
// =====================================================
class BottomNavBar extends StatelessWidget {
  const BottomNavBar({
    super.key,
    required this.scale,
  });

  final double scale;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70 * scale,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(
          40 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              0.16,
            ),
            blurRadius: 16,
            offset: const Offset(
              0,
              8,
            ),
          ),
        ],
      ),
      child: Row(
        children: [
          // =================================================
          // HOME
          // =================================================
          Expanded(
            child: Column(
              mainAxisAlignment:
                  MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.home,
                  size: 31 * scale,
                  color: const Color(
                    0xFF2378C9,
                  ),
                ),
                Text(
                  'หน้าแรก',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight:
                        FontWeight.bold,
                    color: const Color(
                      0xFF2378C9,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // =================================================
          // STATISTICS
          // =================================================
          Expanded(
            child: InkWell(
              borderRadius:
                  BorderRadius.circular(
                40 * scale,
              ),
              onTap: () {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        const StatisticsPage(),
                  ),
                );
              },
              child: Column(
                mainAxisAlignment:
                    MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bar_chart,
                    size: 31 * scale,
                    color:
                        Colors.grey.shade500,
                  ),
                  Text(
                    'สถิติ',
                    style: TextStyle(
                      fontSize: 12 * scale,
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
        ],
      ),
    );
  }
}

// =====================================================
// PROGRESS CIRCLE PAINTER
//
// progress:
// 0.0 = 0%
// 0.5 = 50%
// 1.0 = 100%
//
// เมื่อขึ้นวันใหม่ progress = 0.0
// กราฟจะกลับไปเริ่มต้นใหม่
// =====================================================
class ProgressCirclePainter
    extends CustomPainter {
  ProgressCirclePainter({
    required this.progress,
  });

  final double progress;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final center = Offset(
      size.width / 2,
      size.height / 2,
    );

    final radius =
        math.min(
          size.width,
          size.height,
        ) /
            2 -
        10;

    // =================================================
    // วงพื้นหลัง
    // =================================================
    final backgroundPaint = Paint()
      ..color = const Color(
        0xFFDDEEFF,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(
      center,
      radius,
      backgroundPaint,
    );

    // =================================================
    // วง Progress
    // =================================================
    final progressPaint = Paint()
      ..color = const Color(
        0xFF3D9ADC,
      )
      ..style = PaintingStyle.stroke
      ..strokeWidth = 13
      ..strokeCap = StrokeCap.round;

    final safeProgress =
        progress.clamp(
      0.0,
      1.0,
    );

    final sweepAngle =
        2 *
        math.pi *
        safeProgress;

    // เริ่มจากด้านบน
    const startAngle =
        -math.pi / 2;

    final rect =
        Rect.fromCircle(
      center: center,
      radius: radius,
    );

    // ถ้าเป็น 0%
    // ไม่ต้องวาดส่วน Progress
    if (safeProgress > 0) {
      canvas.drawArc(
        rect,
        startAngle,
        sweepAngle,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant ProgressCirclePainter oldDelegate,
  ) {
    return oldDelegate.progress !=
        progress;
  }
}

// =====================================================
// ปุ่ม + / - ใน Dialog เป้าหมาย
// =====================================================
class GoalStepButton extends StatelessWidget {
  const GoalStepButton({
    super.key,
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(
    BuildContext context,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(
        100,
      ),
      child: Container(
        width: 54,
        height: 54,
        decoration:
            const BoxDecoration(
          color: Color(
            0xFFD8ECFF,
          ),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 32,
          color: const Color(
            0xFF2378C9,
          ),
        ),
      ),
    );
  }
}

// =====================================================
// FORMAT NUMBER
//
// 1200 -> 1,200
// 1500 -> 1,500
// =====================================================
String formatNumber(
  int number,
) {
  final text =
      number.toString();

  final buffer =
      StringBuffer();

  for (
    int i = 0;
    i < text.length;
    i++
  ) {
    final position =
        text.length - i;

    buffer.write(
      text[i],
    );

    if (position > 1 &&
        position % 3 == 1) {
      buffer.write(',');
    }
  }

  return buffer.toString();
}