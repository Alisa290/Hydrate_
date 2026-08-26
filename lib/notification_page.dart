import 'dart:async';

import 'package:flutter/material.dart';

class NotificationPage extends StatefulWidget {
  const NotificationPage({super.key});

  @override
  State<NotificationPage> createState() => _NotificationPageState();
}

class _NotificationPageState extends State<NotificationPage> {
  // =====================================================
  // เวลาที่ต้องแจ้งเตือนให้ดื่มน้ำ
  // เหมือนกับ ESP32
  // =====================================================
  final List<int> drinkHours = [
    7,
    9,
    11,
    13,
    15,
    17,
    19,
    21,
  ];

  // =====================================================
  // ปริมาณน้ำที่แสดงในแต่ละการแจ้งเตือน
  // ตอนนี้กำหนดไว้ 150 ml ก่อน
  // =====================================================
  final int drinkAmountMl = 150;

  // =====================================================
  // Timer สำหรับตรวจสอบเวลา
  // =====================================================
  Timer? timer;

  // =====================================================
  // INIT
  // =====================================================
  @override
  void initState() {
    super.initState();

    // ตรวจสอบใหม่ทุก 30 วินาที
    // เพื่อให้หน้าอัปเดตเมื่อถึงเวลาแจ้งเตือน
    timer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (mounted) {
          setState(() {});
        }
      },
    );
  }

  // =====================================================
  // DISPOSE
  // =====================================================
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  // =====================================================
  // คืนรายการเวลาที่ถึงแล้วในวันนี้
  //
  // ตัวอย่าง:
  // ตอนนี้ 15:24
  //
  // จะได้
  // 15:00
  // 13:00
  // 11:00
  // 09:00
  // 07:00
  //
  // เรียงล่าสุด -> เก่าสุด
  // =====================================================
  List<DateTime> getTodayDrinkNotifications() {
    final now = DateTime.now();

    final List<DateTime> notifications = [];

    for (final hour in drinkHours) {
      final notificationTime = DateTime(
        now.year,
        now.month,
        now.day,
        hour,
        0,
      );

      // ถ้าเวลานั้นมาถึงแล้ว
      if (!notificationTime.isAfter(now)) {
        notifications.add(notificationTime);
      }
    }

    // เรียงเวลาล่าสุดไว้ด้านบน
    notifications.sort(
      (a, b) => b.compareTo(a),
    );

    return notifications;
  }

  // =====================================================
  // แปลงเวลาเป็น 07:00 น.
  // =====================================================
  String formatTime(DateTime dateTime) {
    final hour =
        dateTime.hour.toString().padLeft(2, '0');

    final minute =
        dateTime.minute.toString().padLeft(2, '0');

    return '$hour:$minute น.';
  }

  // =====================================================
  // BUILD
  // =====================================================
  @override
  Widget build(BuildContext context) {
    final notifications =
        getTodayDrinkNotifications();

    return Scaffold(
      backgroundColor: const Color(0xFFEAF8FE),

      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // =================================================
            // HEADER
            // =================================================
            Padding(
              padding: const EdgeInsets.fromLTRB(
                18,
                16,
                18,
                0,
              ),
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

            // =================================================
            // วันนี้
            // =================================================
            const Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 24,
              ),
              child: Text(
                'วันนี้',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),

            const SizedBox(height: 14),

            // =================================================
            // รายการแจ้งเตือน
            // =================================================
            Expanded(
              child: notifications.isEmpty

                  // =============================================
                  // ถ้ายังไม่ถึง 07:00
                  // =============================================
                  ? const EmptyNotificationView()

                  // =============================================
                  // ถ้ามีแจ้งเตือนแล้ว
                  // =============================================
                  : ListView.separated(
                      physics:
                          const BouncingScrollPhysics(),

                      padding:
                          const EdgeInsets.fromLTRB(
                        18,
                        0,
                        18,
                        30,
                      ),

                      itemCount:
                          notifications.length,

                      separatorBuilder:
                          (context, index) {
                        return const SizedBox(
                          height: 14,
                        );
                      },

                      itemBuilder:
                          (context, index) {
                        final notificationTime =
                            notifications[index];

                        return DrinkNotificationCard(
                          time: formatTime(
                            notificationTime,
                          ),
                          amountMl:
                              drinkAmountMl,
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

// =====================================================
// CARD แจ้งเตือนถึงเวลาดื่มน้ำ
// =====================================================
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

      padding: const EdgeInsets.fromLTRB(
        18,
        18,
        16,
        18,
      ),

      decoration: BoxDecoration(
        color: Colors.white,

        borderRadius: BorderRadius.circular(
          22,
        ),

        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(
              0.12,
            ),
            blurRadius: 12,
            offset: const Offset(
              0,
              6,
            ),
          ),
        ],
      ),

      child: Row(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          // =================================================
          // ไอคอนกระดิ่ง
          // =================================================
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

          // =================================================
          // ข้อความ
          // =================================================
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                // =============================================
                // หัวข้อ + เวลา
                // =============================================
                Row(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Expanded(
                      child: Text(
                        'ถึงเวลาดื่มน้ำ',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight:
                              FontWeight.bold,
                          color:
                              Color(0xFF2378C9),
                        ),
                      ),
                    ),

                    const SizedBox(width: 8),

                    Text(
                      time,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                // =============================================
                // ปริมาณน้ำ
                // =============================================
                Text(
                  'ควรดื่มน้ำ $amountMl ml',
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.black,
                  ),
                ),

                const SizedBox(height: 3),

                // =============================================
                // รายละเอียด
                // =============================================
                const Text(
                  'เพื่อให้เป็นไปตามเป้าหมายวันนี้',
                  style: TextStyle(
                    fontSize: 15,
                    color: Colors.black,
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

// =====================================================
// ยังไม่มีการแจ้งเตือน
// =====================================================
class EmptyNotificationView extends StatelessWidget {
  const EmptyNotificationView({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
        ),
        child: Container(
          width: double.infinity,

          padding: const EdgeInsets.symmetric(
            horizontal: 22,
            vertical: 32,
          ),

          decoration: BoxDecoration(
            color: Colors.white,

            borderRadius:
                BorderRadius.circular(
              18,
            ),

            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(
                  0.12,
                ),
                blurRadius: 12,
                offset: const Offset(
                  0,
                  6,
                ),
              ),
            ],
          ),

          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 38,
                backgroundColor:
                    Color(0xFFB7DCFF),
                child: Icon(
                  Icons.notifications,
                  size: 44,
                  color:
                      Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 18),

              const Text(
                'ยังไม่มีการแจ้งเตือน',
                textAlign:
                    TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight:
                      FontWeight.bold,
                  color:
                      Color(0xFF2378C9),
                ),
              ),

              const SizedBox(height: 8),

              Text(
                'เมื่อถึงเวลาดื่มน้ำ ระบบจะแสดงรายการไว้ที่หน้านี้',
                textAlign:
                    TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color:
                      Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}