import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'profile_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int dailyGoalMl = 1200;

  int drankMl = 0;
  int lastDrinkMl = 0;
  int todayDrinkCount = 0;
  int bottleLevelPercent = 0;

  bool isLoading = true;
  String nextDrinkTimeText = '07:00 น.';
  Timer? reminderTimer;

  @override
  void initState() {
    super.initState();
    loadDailyGoal();
    updateNextDrinkTime();

    reminderTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      updateNextDrinkTime();
    });
  }

  @override
  void dispose() {
    reminderTimer?.cancel();
    super.dispose();
  }

  Future<void> loadDailyGoal() async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        setState(() {
          isLoading = false;
        });
        return;
      }

      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(user.uid)
          .get();

      if (!doc.exists || doc.data() == null) {
        setState(() {
          isLoading = false;
        });
        return;
      }

      final data = doc.data()!;

      final manualGoal = data['manual_daily_goal_ml'];
      if (manualGoal != null) {
        setState(() {
          dailyGoalMl = int.tryParse(manualGoal.toString()) ?? 1200;
          isLoading = false;
        });
        return;
      }

      final gender = data['gender']?.toString() ?? '';
      final heightCm = int.tryParse(data['height_cm'].toString()) ?? 0;
      final kidneyStage = data['kidney_stage']?.toString() ?? '';

      final calculatedGoal = calculateDailyGoal(
        gender: gender,
        heightCm: heightCm,
        kidneyStage: kidneyStage,
      );

      setState(() {
        dailyGoalMl = calculatedGoal;
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
      });
    }
  }

  int calculateDailyGoal({
    required String gender,
    required int heightCm,
    required String kidneyStage,
  }) {
    if (heightCm <= 0) return 1200;

    final heightInch = heightCm / 2.54;

    final ibw = gender == 'หญิง'
        ? 45.5 + (2.3 * (heightInch - 60))
        : 50 + (2.3 * (heightInch - 60));

    final stageNumber =
        int.tryParse(kidneyStage.replaceAll(RegExp(r'[^0-9]'), '')) ?? 3;

    double mlPerKg;

    if (stageNumber == 1 || stageNumber == 2) {
      mlPerKg = 30;
    } else if (stageNumber == 3) {
      mlPerKg = 25;
    } else if (stageNumber == 4) {
      mlPerKg = 20;
    } else {
      mlPerKg = 15;
    }

    final rawGoal = ibw * mlPerKg;
    return (rawGoal / 100).round() * 100;
  }

  void updateNextDrinkTime() {
    final now = DateTime.now();
    final drinkHours = [7, 9, 11, 13, 15, 17, 19, 21];

    DateTime? nextTime;

    for (final hour in drinkHours) {
      final scheduleTime = DateTime(now.year, now.month, now.day, hour);

      if (scheduleTime.isAfter(now)) {
        nextTime = scheduleTime;
        break;
      }
    }

    nextTime ??= DateTime(now.year, now.month, now.day + 1, 7);

    final hourText = nextTime.hour.toString().padLeft(2, '0');
    final minuteText = nextTime.minute.toString().padLeft(2, '0');

    if (!mounted) return;

    setState(() {
      nextDrinkTimeText = '$hourText:$minuteText น.';
    });
  }

  Future<void> saveManualGoal(int newGoal) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance.collection('profiles').doc(user.uid).set({
      'manual_daily_goal_ml': newGoal,
    }, SetOptions(merge: true));

    setState(() {
      dailyGoalMl = newGoal;
    });
  }

  void showEditGoalDialog() {
    int tempGoal = dailyGoalMl;

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(
                            Icons.arrow_back,
                            size: 34,
                            color: Color(0xFF2678C7),
                          ),
                        ),
                        const Expanded(
                          child: Text(
                            'เป้าหมายการดื่มน้ำ',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 44),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        GoalStepButton(
                          icon: Icons.remove,
                          onTap: () {
                            if (tempGoal > 100) {
                              setDialogState(() {
                                tempGoal -= 100;
                              });
                            }
                          },
                        ),
                        const SizedBox(width: 20),
                        Text(
                          formatNumber(tempGoal),
                          style: const TextStyle(
                            fontSize: 38,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 20),
                        GoalStepButton(
                          icon: Icons.add,
                          onTap: () {
                            setDialogState(() {
                              tempGoal += 100;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'ml/วัน',
                      style: TextStyle(fontSize: 26),
                    ),
                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () async {
                          await saveManualGoal(tempGoal);
                          if (!mounted) return;
                          Navigator.pop(dialogContext);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3796D4),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                          elevation: 8,
                          shadowColor: Colors.black26,
                        ),
                        child: const Text(
                          'เปลี่ยนเป้าหมาย',
                          style: TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
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

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screenWidth = media.size.width;
    final scale = (screenWidth / 430).clamp(0.78, 1.0);
    final horizontalPadding = 22.0 * scale;

    final remainingMl = math.max(dailyGoalMl - drankMl, 0);
    final progress = dailyGoalMl == 0 ? 0.0 : drankMl / dailyGoalMl;
    final safeProgress = progress.clamp(0.0, 1.0);
    final percent = (safeProgress * 100).round();

    return MediaQuery(
      data: media.copyWith(textScaleFactor: 1.0),
      child: Scaffold(
        backgroundColor: const Color(0xFFEAF8FF),
        body: SafeArea(
          child: isLoading
              ? const Center(
                  child: CircularProgressIndicator(
                    color: Color(0xFF2678C7),
                  ),
                )
              : Stack(
                  children: [
                    SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        14 * scale,
                        horizontalPadding,
                        112,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          HeaderSection(scale: scale),
                          SizedBox(height: 20 * scale),
                          GoalCard(
                            dailyGoalMl: dailyGoalMl,
                            drankMl: drankMl,
                            remainingMl: remainingMl,
                            progress: safeProgress,
                            percent: percent,
                            onEditGoal: showEditGoalDialog,
                            scale: scale,
                          ),
                          SizedBox(height: 16 * scale),
                          Row(
                            children: [
                              Expanded(
                                child: SummaryCard(
                                  icon: Icons.local_drink_outlined,
                                  title: 'ดื่มครั้งล่าสุด',
                                  value: '$lastDrinkMl ML',
                                  bottomIcon: Icons.access_time,
                                  bottomText: '--:-- น.',
                                  scale: scale,
                                ),
                              ),
                              SizedBox(width: 8 * scale),
                              Expanded(
                                child: SummaryCard(
                                  icon: Icons.calendar_month_outlined,
                                  title: 'จำนวนครั้งวันนี้',
                                  value: '$todayDrinkCount ครั้ง',
                                  bottomText: 'จากเป้าหมาย 8 ครั้ง',
                                  scale: scale,
                                ),
                              ),
                              SizedBox(width: 8 * scale),
                              Expanded(
                                child: SummaryCard(
                                  icon: Icons.water_drop,
                                  title: 'ระดับน้ำในขวด',
                                  value: '$bottleLevelPercent%',
                                  bottomText: 'เหลือในขวด',
                                  scale: scale,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 18 * scale),
                          ReminderCard(
                            nextDrinkTimeText: nextDrinkTimeText,
                            scale: scale,
                          ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: BottomNavBar(scale: scale),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class HeaderSection extends StatelessWidget {
  final double scale;

  const HeaderSection({
    super.key,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.water_drop_outlined,
          size: 62 * scale,
          color: const Color(0xFF2678C7),
        ),
        SizedBox(width: 10 * scale),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'Hydrate Smart',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 31 * scale,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF2678C7),
                  ),
                ),
              ),
              Text(
                'ดื่มน้ำดี เพื่อสุขภาพดี',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18 * scale,
                  color: Colors.black,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: 8 * scale),
        Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tight(
                Size(38 * scale, 38 * scale),
              ),
              onPressed: () {},
              icon: Icon(
                Icons.notifications_none,
                size: 34 * scale,
                color: const Color(0xFF2678C7),
              ),
            ),
            Positioned(
              right: 2 * scale,
              top: 2 * scale,
              child: Container(
                width: 11 * scale,
                height: 11 * scale,
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
        SizedBox(width: 8 * scale),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tight(
            Size(38 * scale, 38 * scale),
          ),
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const ProfilePage()),
            );
          },
          icon: Icon(
            Icons.account_circle_outlined,
            size: 36 * scale,
            color: const Color(0xFF2678C7),
          ),
        ),
      ],
    );
  }
}

class GoalCard extends StatelessWidget {
  final int dailyGoalMl;
  final int drankMl;
  final int remainingMl;
  final double progress;
  final int percent;
  final VoidCallback onEditGoal;
  final double scale;

  const GoalCard({
    super.key,
    required this.dailyGoalMl,
    required this.drankMl,
    required this.remainingMl,
    required this.progress,
    required this.percent,
    required this.onEditGoal,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        14 * scale,
        14 * scale,
        14 * scale,
        18 * scale,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(26 * scale),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: EditGoalButton(
              onTap: onEditGoal,
              scale: scale,
            ),
          ),
          SizedBox(height: 8 * scale),
          Row(
            children: [
              Expanded(
                flex: 10,
                child: Center(
                  child: GoalProgressCircle(
                    drankMl: drankMl,
                    progress: progress,
                    percent: percent,
                    size: 166 * scale,
                    scale: scale,
                  ),
                ),
              ),
              SizedBox(width: 12 * scale),
              Expanded(
                flex: 11,
                child: GoalDetail(
                  dailyGoalMl: dailyGoalMl,
                  remainingMl: remainingMl,
                  scale: scale,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class EditGoalButton extends StatelessWidget {
  final VoidCallback onTap;
  final double scale;

  const EditGoalButton({
    super.key,
    required this.onTap,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 15 * scale,
          vertical: 6 * scale,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFFD8EBFF),
          borderRadius: BorderRadius.circular(18 * scale),
        ),
        child: Text(
          'แก้ไขเป้าหมาย',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: const Color(0xFF2678C7),
            fontWeight: FontWeight.bold,
            fontSize: 14 * scale,
          ),
        ),
      ),
    );
  }
}

class GoalProgressCircle extends StatelessWidget {
  final int drankMl;
  final double progress;
  final int percent;
  final double size;
  final double scale;

  const GoalProgressCircle({
    super.key,
    required this.drankMl,
    required this.progress,
    required this.percent,
    required this.size,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: Size(size, size),
                painter: ProgressCirclePainter(
                  progress: progress,
                  strokeWidth: 15 * scale,
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10 * scale),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'ดื่มแล้ว',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 23 * scale,
                        color: Colors.black,
                      ),
                    ),
                    SizedBox(height: 6 * scale),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${formatNumber(drankMl)} ML',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 36 * scale,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF2678C7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: 10 * scale),
        Text(
          '$percent%',
          style: TextStyle(
            fontSize: 23 * scale,
            fontWeight: FontWeight.bold,
            color: const Color(0xFF2678C7),
          ),
        ),
      ],
    );
  }
}

class GoalDetail extends StatelessWidget {
  final int dailyGoalMl;
  final int remainingMl;
  final double scale;

  const GoalDetail({
    super.key,
    required this.dailyGoalMl,
    required this.remainingMl,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'เป้าหมายวันนี้',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 21 * scale,
            color: Colors.black,
          ),
        ),
        SizedBox(height: 8 * scale),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '${formatNumber(dailyGoalMl)} ML',
            maxLines: 1,
            style: TextStyle(
              fontSize: 38 * scale,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF2678C7),
            ),
          ),
        ),
        SizedBox(height: 12 * scale),
        Container(
          height: 1,
          color: const Color(0xFF8BC2F2),
        ),
        SizedBox(height: 12 * scale),
        Text(
          'เหลืออีก',
          maxLines: 1,
          style: TextStyle(
            fontSize: 20 * scale,
            color: Colors.black,
          ),
        ),
        SizedBox(height: 6 * scale),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '${formatNumber(remainingMl)} ML',
            maxLines: 1,
            style: TextStyle(
              fontSize: 35 * scale,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF2678C7),
            ),
          ),
        ),
        Text(
          'เพื่อให้ถึงเป้าหมาย',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 17 * scale,
            color: Colors.black,
          ),
        ),
      ],
    );
  }
}

class SummaryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final IconData? bottomIcon;
  final String bottomText;
  final double scale;

  const SummaryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.bottomIcon,
    required this.bottomText,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 188 * scale,
      padding: EdgeInsets.symmetric(
        horizontal: 7 * scale,
        vertical: 9 * scale,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22 * scale),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 12,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          CircleAvatar(
            radius: 28 * scale,
            backgroundColor: const Color(0xFFB8DCFF),
            child: Icon(
              icon,
              size: 31 * scale,
              color: const Color(0xFF0A86D7),
            ),
          ),
          SizedBox(height: 7 * scale),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13 * scale),
          ),
          SizedBox(height: 3 * scale),
          Expanded(
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  value,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 27 * scale,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF2678C7),
                  ),
                ),
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (bottomIcon != null)
                Icon(
                  bottomIcon,
                  size: 13 * scale,
                  color: const Color(0xFF0A86D7),
                ),
              if (bottomIcon != null) SizedBox(width: 3 * scale),
              Flexible(
                child: Text(
                  bottomText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10.5 * scale),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ReminderCard extends StatelessWidget {
  final String nextDrinkTimeText;
  final double scale;

  const ReminderCard({
    super.key,
    required this.nextDrinkTimeText,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(18 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24 * scale),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 12,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 42 * scale,
            backgroundColor: const Color(0xFFB8DCFF),
            child: Icon(
              Icons.notifications,
              size: 40 * scale,
              color: const Color(0xFF2678C7),
            ),
          ),
          SizedBox(width: 14 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'การแจ้งเตือน',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 21 * scale),
                ),
                Text(
                  'เวลาดื่มน้ำในครั้งถัดไป',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20 * scale,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF2678C7),
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  'ปริมาณน้ำที่ควรดื่ม 150 ml',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14 * scale),
                ),
              ],
            ),
          ),
          SizedBox(width: 6 * scale),
          Text(
            nextDrinkTimeText,
            maxLines: 1,
            style: TextStyle(fontSize: 15 * scale),
          ),
        ],
      ),
    );
  }
}

class BottomNavBar extends StatelessWidget {
  final double scale;

  const BottomNavBar({
    super.key,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final width = math.min(screenWidth - 86, 310.0);

    return Container(
      margin: EdgeInsets.only(bottom: 14 * scale),
      width: width,
      height: 78 * scale,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(42 * scale),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 15,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          BottomNavItem(
            icon: Icons.home,
            label: 'หน้าแรก',
            isActive: true,
            scale: scale,
          ),
          BottomNavItem(
            icon: Icons.bar_chart,
            label: 'สถิติ',
            isActive: false,
            scale: scale,
          ),
        ],
      ),
    );
  }
}

class BottomNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final double scale;

  const BottomNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.isActive,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? const Color(0xFF2678C7) : Colors.grey;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 30 * scale, color: color),
        Text(
          label,
          style: TextStyle(
            fontSize: 14 * scale,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class GoalStepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const GoalStepButton({
    super.key,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 24,
      backgroundColor: const Color(0xFF2678C7),
      child: IconButton(
        onPressed: onTap,
        icon: const Icon(
          Icons.remove,
          color: Colors.transparent,
          size: 0,
        ),
      ),
    );
  }
}

class ProgressCirclePainter extends CustomPainter {
  final double progress;
  final double strokeWidth;

  ProgressCirclePainter({
    required this.progress,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - strokeWidth;

    final backgroundPaint = Paint()
      ..color = const Color(0xFFB8DCFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final progressPaint = Paint()
      ..color = const Color(0xFF4C7DFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant ProgressCirclePainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

String formatNumber(int number) {
  return number.toString().replaceAllMapped(
        RegExp(r'\B(?=(\d{3})+(?!\d))'),
        (match) => ',',
      );
}