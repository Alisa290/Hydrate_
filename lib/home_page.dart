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
  // "เหลืออีก" จาก water_history
  // =====================================================
  int latestHistoryVolumeMl = 0;

  int lastUpdatedTimestamp = 0;

  bool hasBottleData = false;
  bool hasHistoryVolumeData = false;
  bool isLoading = true;

  String nextDrinkTimeText = '07:00 น.';

  Timer? reminderTimer;

  StreamSubscription<DatabaseEvent>? bottleSubscription;
  StreamSubscription<DatabaseEvent>? historySubscription;

  // =====================================================
  // REALTIME DATABASE URL
  // =====================================================
  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  // =====================================================
  // UID ที่ ESP32 ใช้บันทึกข้อมูล
  // =====================================================
  static const String bottleUserId =
      'jE9aQG2EgtMRFLb8lKaqRpIf1QH3';

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

    // อ่านระดับน้ำในขวดจาก ESP32
    listenBottleData();

    // อ่านค่า "เหลืออีก"
    listenLatestWaterHistory();

    updateNextDrinkTime();

    reminderTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        updateNextDrinkTime();
      },
    );
  }

  // =====================================================
  // DISPOSE
  // =====================================================
  @override
  void dispose() {
    reminderTimer?.cancel();
    bottleSubscription?.cancel();
    historySubscription?.cancel();

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
  // ดื่มแล้ว ML
  //
  // สูตร:
  // เป้าหมายวันนี้ - เหลืออีก
  //
  // ตัวอย่าง:
  // 1200 - 1060 = 140 ML
  // =====================================================
  int get consumedMl {
    if (!hasHistoryVolumeData || dailyGoalMl <= 0) {
      return 0;
    }

    final value = dailyGoalMl - latestHistoryVolumeMl;

    return value.clamp(0, dailyGoalMl);
  }

  // =====================================================
  // เปอร์เซ็นต์ที่ดื่มแล้ว
  //
  // สูตร:
  // 100 - ระดับน้ำในขวด
  //
  // ตัวอย่าง:
  //
  // ระดับน้ำในขวด = 53%
  //
  // 100 - 53 = 47%
  //
  // ดังนั้น:
  // ใต้กราฟ = 47%
  // วงกลม = 47%
  //
  // ส่วน "ระดับน้ำในขวด" ยังคงเป็น 53%
  // =====================================================
  int get graphPercent {
    if (!hasBottleData) {
      return 0;
    }

    final safeBottlePercent =
        bottleLevelPercent.clamp(0, 100);

    final drankPercent =
        100 - safeBottlePercent;

    return drankPercent.clamp(0, 100);
  }

  // =====================================================
  // Progress ของกราฟวงกลม
  //
  // ถ้า graphPercent = 47
  // progress = 0.47
  // =====================================================
  double get graphProgress {
    if (!hasBottleData) {
      return 0.0;
    }

    return (graphPercent / 100.0)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  // =====================================================
  // โหลดเป้าหมายรายวันจาก Firestore
  // =====================================================
  Future<void> loadDailyGoal() async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        if (mounted) {
          setState(() {
            isLoading = false;
          });
        }

        return;
      }

      final doc = await FirebaseFirestore.instance
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
          parseIntValue(data['manual_daily_goal_ml']);

      if (manualGoal > 0) {
        if (mounted) {
          setState(() {
            dailyGoalMl = manualGoal;
            isLoading = false;
          });
        }

        return;
      }

      // =================================================
      // คำนวณเป้าหมายจากข้อมูล Profile
      // =================================================
      final gender =
          (data['gender'] ?? '').toString();

      final heightCm =
          parseIntValue(data['height_cm']);

      final kidneyStage =
          (data['kidney_stage'] ?? '').toString();

      final calculatedGoal = calculateDailyGoal(
        gender: gender,
        heightCm: heightCm,
        kidneyStage: kidneyStage,
      );

      if (mounted) {
        setState(() {
          dailyGoalMl = calculatedGoal;
          isLoading = false;
        });
      }
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
  // REALTIME DATABASE INSTANCE
  // =====================================================
  FirebaseDatabase getRealtimeDatabase() {
    return FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
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
      final database =
          getRealtimeDatabase();

      final String databasePath =
          'users/$bottleUserId/devices/$bottleDeviceId';

      final DatabaseReference ref =
          database.ref(databasePath);

      debugPrint('');
      debugPrint(
        '================================',
      );
      debugPrint(
        'LISTENING DEVICE DATA',
      );
      debugPrint(
        'Bottle UID: $bottleUserId',
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

      await bottleSubscription?.cancel();

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
                hasBottleData = false;
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
              hasBottleData = false;
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

      // =================================================
      // ตรวจสอบค่าหลังจากอัปเดต
      // =================================================
      debugPrint(
        'ระดับน้ำในขวด = $bottleLevelPercent%',
      );

      debugPrint(
        '100 - $bottleLevelPercent = $graphPercent%',
      );

      debugPrint(
        'เปอร์เซ็นต์ใต้กราฟ = $graphPercent%',
      );

      debugPrint(
        'GRAPH PROGRESS = $graphProgress',
      );
    }
  }

  // =====================================================
  // อ่าน volume_ml ล่าสุดจาก water_history
  //
  // ใช้เป็นค่า "เหลืออีก"
  // =====================================================
  Future<void> listenLatestWaterHistory() async {
    try {
      final database =
          getRealtimeDatabase();

      final String historyPath =
          'users/$bottleUserId/water_history';

      final DatabaseReference ref =
          database.ref(historyPath);

      debugPrint('');
      debugPrint(
        '================================',
      );

      debugPrint(
        'LISTENING WATER HISTORY',
      );

      debugPrint(
        'History Path: $historyPath',
      );

      debugPrint(
        '================================',
      );

      // =================================================
      // อ่านครั้งแรก
      // =================================================
      try {
        final snapshot =
            await ref.get();

        debugPrint(
          'Initial Water History: ${snapshot.value}',
        );

        if (snapshot.exists) {
          _updateLatestHistoryVolume(
            snapshot.value,
          );
        }
      } catch (e) {
        debugPrint(
          'Initial history read error: $e',
        );
      }

      await historySubscription?.cancel();

      // =================================================
      // ฟังแบบ Realtime
      // =================================================
      historySubscription =
          ref.onValue.listen(
        (DatabaseEvent event) {
          final value =
              event.snapshot.value;

          debugPrint('');

          debugPrint(
            'WATER HISTORY EVENT RECEIVED',
          );

          if (value == null) {
            debugPrint(
              'No water_history found',
            );

            if (mounted) {
              setState(() {
                hasHistoryVolumeData =
                    false;
              });
            }

            return;
          }

          _updateLatestHistoryVolume(
            value,
          );
        },
        onError: (Object error) {
          debugPrint(
            'Water History Error: $error',
          );

          if (mounted) {
            setState(() {
              hasHistoryVolumeData =
                  false;
            });
          }
        },
      );
    } catch (e) {
      debugPrint(
        'listenLatestWaterHistory Error: $e',
      );

      if (mounted) {
        setState(() {
          hasHistoryVolumeData =
              false;
        });
      }
    }
  }

  // =====================================================
  // หา volume_ml ที่ใหม่ที่สุด
  // =====================================================
  void _updateLatestHistoryVolume(
    dynamic value,
  ) {
    if (value is! Map) {
      debugPrint(
        'water_history is not Map',
      );

      return;
    }

    final historyRoot =
        Map<Object?, Object?>.from(
      value,
    );

    int latestVolume = 0;
    int latestTimestamp = -1;

    String latestDate = '';
    String latestTime = '';

    // =================================================
    // วนแต่ละวัน
    // =================================================
    for (final dateEntry
        in historyRoot.entries) {
      final dateKey =
          dateEntry.key.toString();

      final dateValue =
          dateEntry.value;

      if (dateValue is! Map) {
        continue;
      }

      final dayRecords =
          Map<Object?, Object?>.from(
        dateValue,
      );

      // =================================================
      // วนแต่ละเวลา
      // =================================================
      for (final timeEntry
          in dayRecords.entries) {
        final timeKey =
            timeEntry.key.toString();

        final rawRecord =
            timeEntry.value;

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

        final volume =
            parseIntValue(
          record['volume_ml'],
        );

        final timestamp =
            parseIntValue(
          record['timestamp'],
        );

        // รองรับ 0 ML
        if (volume < 0) {
          continue;
        }

        // =================================================
        // ถ้ามี timestamp
        // =================================================
        if (timestamp > 0) {
          if (timestamp >
              latestTimestamp) {
            latestTimestamp =
                timestamp;

            latestVolume =
                volume;

            latestDate =
                dateKey;

            latestTime =
                timeKey;
          }
        }

        // =================================================
        // ถ้าไม่มี timestamp
        // ใช้วัน + เวลาเปรียบเทียบ
        // =================================================
        else if (latestTimestamp <= 0) {
          final currentKey =
              '$dateKey/$timeKey';

          final latestKey =
              '$latestDate/$latestTime';

          if (latestDate.isEmpty ||
              currentKey.compareTo(
                    latestKey,
                  ) >
                  0) {
            latestVolume =
                volume;

            latestDate =
                dateKey;

            latestTime =
                timeKey;
          }
        }
      }
    }

    debugPrint(
      '--------------------------------',
    );

    debugPrint(
      'LATEST WATER HISTORY',
    );

    debugPrint(
      'Date: $latestDate',
    );

    debugPrint(
      'Time: $latestTime',
    );

    debugPrint(
      'เหลืออีก: $latestVolume ML',
    );

    debugPrint(
      'timestamp: $latestTimestamp',
    );

    debugPrint(
      '--------------------------------',
    );

    if (latestDate.isNotEmpty) {
      if (mounted) {
        setState(() {
          latestHistoryVolumeMl =
              latestVolume;

          hasHistoryVolumeData =
              true;
        });

        debugPrint(
          'เป้าหมาย = $dailyGoalMl ML',
        );

        debugPrint(
          'เหลืออีก = $latestHistoryVolumeMl ML',
        );

        debugPrint(
          'ดื่มแล้ว = $consumedMl ML',
        );

        debugPrint(
          'ระดับน้ำในขวด = $bottleLevelPercent%',
        );

        debugPrint(
          'เปอร์เซ็นต์ใต้กราฟ = 100 - $bottleLevelPercent = $graphPercent%',
        );
      }
    } else {
      if (mounted) {
        setState(() {
          hasHistoryVolumeData =
              false;
        });
      }
    }
  }

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

    if (mounted) {
      setState(() {
        dailyGoalMl =
            goalMl;
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
                              fontSize: 28,
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
                      mainAxisAlignment:
                          MainAxisAlignment.center,
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
                          width: 24,
                        ),

                        Text(
                          formatNumber(
                            tempGoal,
                          ),
                          style:
                              const TextStyle(
                            fontSize: 44,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        ),

                        const SizedBox(
                          width: 24,
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
                            fontSize: 26,
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
    // ดื่มแล้ว ML
    //
    // เป้าหมาย - เหลืออีก
    // =====================================================
    final int drankMl =
        consumedMl;

    // =====================================================
    // เปอร์เซ็นต์ใต้กราฟ
    //
    // 100 - ระดับน้ำในขวด
    //
    // เช่น:
    // ระดับน้ำ 53%
    // ใต้กราฟ 47%
    // =====================================================
    final int displayedGraphPercent =
        graphPercent;

    // =====================================================
    // กราฟวงกลม
    //
    // ใช้ค่าเดียวกับเปอร์เซ็นต์ใต้กราฟ
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

                            // เหลืออีก ML
                            remainingMl:
                                latestHistoryVolumeMl,

                            // ดื่มแล้ว ML
                            consumedMl:
                                drankMl,

                            // กราฟ = 100 - ระดับน้ำ
                            progress:
                                safeProgress,

                            // ใต้กราฟ = 100 - ระดับน้ำ
                            percent:
                                displayedGraphPercent,

                            hasVolumeData:
                                hasHistoryVolumeData,

                            hasBottleData:
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
                                      'ปริมาณน้ำที่ควรดื่ม 150 ml',
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

                                  // =========================
                                  // แสดงระดับน้ำจริงจากขวด
                                  // เช่น 53%
                                  // =========================
                                  value:
                                      hasBottleData
                                          ? '$bottleLevelPercent%'
                                          : '--%',

                                  bottomText:
                                      hasBottleData
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

                  Positioned(
                    right: 2,
                    top: 0,
                    child:
                        Container(
                      width:
                          9 * scale,
                      height:
                          9 * scale,
                      decoration:
                          const BoxDecoration(
                        color:
                            Colors.red,
                        shape:
                            BoxShape.circle,
                      ),
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

  // เหลืออีก
  final int remainingMl;

  // ดื่มแล้ว
  final int consumedMl;

  // กราฟ 100 - ระดับน้ำ
  final double progress;

  // % 100 - ระดับน้ำ
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
// ดื่มแล้ว ML:
// เป้าหมาย - เหลืออีก
//
// % ใต้กราฟ:
// 100 - bottle_level_percent
//
// เส้นวงกลม:
// 100 - bottle_level_percent
//
// ตัวอย่าง:
// น้ำในขวด 53%
// ใต้กราฟ 47%
// เส้นกราฟ 47%
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

  // เปอร์เซ็นต์ดื่มแล้ว
  // 100 - ระดับน้ำในขวด
  final int percent;

  // ML ที่ดื่มแล้ว
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
                        hasVolumeData
                            ? '${formatNumber(consumedMl)} ML'
                            : '-- ML',
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
        // เปอร์เซ็นต์ใต้กราฟ
        //
        // 100 - ระดับน้ำในขวด
        //
        // เช่น:
        // ระดับน้ำ = 53%
        // ตรงนี้ = 47%
        // =================================================
        Text(
          hasBottleData
              ? '$percent%'
              : '--%',
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

  // เหลืออีก
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
            hasVolumeData
                ? '${formatNumber(remainingMl)} ML'
                : '-- ML',
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
    required this.bottomText,
    required this.scale,
    required this.compact,
    this.bottomIcon,
  });

  final IconData icon;

  final String title;
  final String value;
  final String bottomText;

  final double scale;
  final bool compact;

  final IconData? bottomIcon;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      height:
          (compact
                  ? 166
                  : 180) *
              scale,
      padding:
          EdgeInsets.symmetric(
        horizontal:
            10 * scale,
        vertical:
            12 * scale,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white,
        borderRadius:
            BorderRadius.circular(
          22 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withOpacity(
              0.13,
            ),
            blurRadius:
                14,
            offset:
                const Offset(
              0,
              7,
            ),
          ),
        ],
      ),
      child:
          Column(
        mainAxisAlignment:
            MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius:
                26 * scale,
            backgroundColor:
                const Color(
              0xFFB7DCFF,
            ),
            child:
                Icon(
              icon,
              size:
                  27 * scale,
              color:
                  const Color(
                0xFF2378C9,
              ),
            ),
          ),

          SizedBox(
            height:
                9 * scale,
          ),

          Text(
            title,
            textAlign:
                TextAlign.center,
            maxLines:
                2,
            overflow:
                TextOverflow.ellipsis,
            style:
                TextStyle(
              fontSize:
                  12.5 * scale,
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
              value,
              maxLines:
                  1,
              style:
                  TextStyle(
                fontSize:
                    24 * scale,
                fontWeight:
                    FontWeight.bold,
                color:
                    const Color(
                  0xFF2378C9,
                ),
              ),
            ),
          ),

          SizedBox(
            height:
                5 * scale,
          ),

          Row(
            mainAxisAlignment:
                MainAxisAlignment.center,
            children: [
              if (bottomIcon !=
                  null) ...[
                Icon(
                  bottomIcon,
                  size:
                      12 * scale,
                  color:
                      const Color(
                    0xFF2378C9,
                  ),
                ),

                SizedBox(
                  width:
                      3 * scale,
                ),
              ],

              Flexible(
                child:
                    Text(
                  bottomText,
                  textAlign:
                      TextAlign.center,
                  maxLines:
                      2,
                  overflow:
                      TextOverflow.ellipsis,
                  style:
                      TextStyle(
                    fontSize:
                        9.5 * scale,
                    color:
                        Colors.black,
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
// BOTTOM NAVIGATION
// =====================================================
class BottomNavBar extends StatelessWidget {
  const BottomNavBar({
    super.key,
    required this.scale,
  });

  final double scale;

  @override
  Widget build(
    BuildContext context,
  ) {
    return Container(
      height:
          70 * scale,
      decoration:
          BoxDecoration(
        color:
            Colors.white,
        borderRadius:
            BorderRadius.circular(
          36 * scale,
        ),
        boxShadow: [
          BoxShadow(
            color:
                Colors.black.withOpacity(
              0.14,
            ),
            blurRadius:
                16,
            offset:
                const Offset(
              0,
              7,
            ),
          ),
        ],
      ),
      child:
          Row(
        mainAxisAlignment:
            MainAxisAlignment.spaceEvenly,
        children: [
          BottomNavItem(
            icon:
                Icons.home,
            label:
                'หน้าแรก',
            active:
                true,
            scale:
                scale,
            onTap:
                () {},
          ),

          BottomNavItem(
            icon:
                Icons.bar_chart,
            label:
                'สถิติ',
            active:
                false,
            scale:
                scale,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) =>
                          const StatisticsPage(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// =====================================================
// BOTTOM NAV ITEM
// =====================================================
class BottomNavItem extends StatelessWidget {
  const BottomNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.scale,
    required this.onTap,
  });

  final IconData icon;
  final String label;

  final bool active;

  final double scale;

  final VoidCallback onTap;

  @override
  Widget build(
    BuildContext context,
  ) {
    final color =
        active
            ? const Color(
                0xFF2378C9,
              )
            : Colors.grey;

    return InkWell(
      onTap:
          onTap,
      borderRadius:
          BorderRadius.circular(
        28,
      ),
      child:
          SizedBox(
        width:
            82 * scale,
        child:
            Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size:
                  30 * scale,
              color:
                  color,
            ),

            Text(
              label,
              style:
                  TextStyle(
                fontSize:
                    13 * scale,
                fontWeight:
                    FontWeight.bold,
                color:
                    color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================
// GOAL STEP BUTTON
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
    return CircleAvatar(
      radius:
          28,
      backgroundColor:
          const Color(
        0xFF2378C9,
      ),
      child:
          IconButton(
        onPressed:
            onTap,
        icon:
            Icon(
          icon,
          color:
              Colors.white,
          size:
              34,
        ),
      ),
    );
  }
}

// =====================================================
// PROGRESS CIRCLE PAINTER
// =====================================================
class ProgressCirclePainter extends CustomPainter {
  ProgressCirclePainter({
    required this.progress,
  });

  final double progress;

  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    const strokeWidth =
        14.0;

    final center =
        Offset(
      size.width / 2,
      size.height / 2,
    );

    final radius =
        (size.width -
                strokeWidth) /
            2;

    final backgroundPaint =
        Paint()
          ..color =
              const Color(
            0xFFB7DCFF,
          )
          ..style =
              PaintingStyle.stroke
          ..strokeWidth =
              strokeWidth
          ..strokeCap =
              StrokeCap.round;

    final progressPaint =
        Paint()
          ..color =
              const Color(
            0xFF4A7DF3,
          )
          ..style =
              PaintingStyle.stroke
          ..strokeWidth =
              strokeWidth
          ..strokeCap =
              StrokeCap.round;

    canvas.drawCircle(
      center,
      radius,
      backgroundPaint,
    );

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(
          center:
              center,
          radius:
              radius,
        ),
        -math.pi / 2,
        2 *
            math.pi *
            progress,
        false,
        progressPaint,
      );
    }
  }

  @override
  bool shouldRepaint(
    covariant ProgressCirclePainter
        oldDelegate,
  ) {
    return oldDelegate.progress !=
        progress;
  }
}

// =====================================================
// FORMAT NUMBER
// =====================================================
String formatNumber(
  int number,
) {
  return number
      .toString()
      .replaceAllMapped(
        RegExp(
          r'\B(?=(\d{3})+(?!\d))',
        ),
        (match) => ',',
      );
}