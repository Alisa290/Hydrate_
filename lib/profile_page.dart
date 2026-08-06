import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'main.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool isLoading = true;

  String fullName = '-';
  String email = '-';
  String phone = '-';
  String gender = '-';
  String kidneyStage = '-';
  int heightCm = 0;

  @override
  void initState() {
    super.initState();
    loadProfile();
  }

  Future<void> loadProfile() async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      if (user == null) {
        throw Exception('ยังไม่มีผู้ใช้ล็อกอิน');
      }

      final doc = await FirebaseFirestore.instance
          .collection('profiles')
          .doc(user.uid)
          .get();

      final data = doc.data();

      if (!doc.exists || data == null) {
        throw Exception('ไม่พบข้อมูลโปรไฟล์');
      }

      setState(() {
        fullName = data['full_name']?.toString() ?? '-';
        email = data['email']?.toString() ?? user.email ?? '-';
        phone = data['phone']?.toString() ?? '-';
        gender = data['gender']?.toString() ?? '-';
        kidneyStage = data['kidney_stage']?.toString() ?? '-';
        heightCm = int.tryParse(data['height_cm'].toString()) ?? 0;
        isLoading = false;
      });
    } catch (error) {
      setState(() {
        email = FirebaseAuth.instance.currentUser?.email ?? '-';
        isLoading = false;
      });

      debugPrint('loadProfile error: $error');
    }
  }

  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
      (route) => false,
    );
  }

  void showLogoutConfirmDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (dialogContext) {
        final isSmall = MediaQuery.sizeOf(context).width < 390;

        return Dialog(
          insetPadding: EdgeInsets.symmetric(horizontal: isSmall ? 18 : 26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              isSmall ? 14 : 20,
              30,
              isSmall ? 14 : 20,
              0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ออกจากระบบบัญชีของคุณใช่หรือไม่',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: isSmall ? 20 : 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 30),
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.grey.shade300,
                ),
                SizedBox(
                  height: isSmall ? 64 : 74,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                          },
                          child: Text(
                            'ยกเลิก',
                            style: TextStyle(
                              fontSize: isSmall ? 20 : 24,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFF5E9BFF),
                            ),
                          ),
                        ),
                      ),
                      Container(
                        width: 1,
                        height: isSmall ? 46 : 54,
                        color: Colors.grey.shade300,
                      ),
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            Navigator.pop(dialogContext);
                            await logout();
                          },
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'ออกจากระบบ',
                              style: TextStyle(
                                fontSize: isSmall ? 20 : 24,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFFC62828),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String displayKidneyStage(String value) {
    if (value.contains('1')) return 'stage 1';
    if (value.contains('2')) return 'stage 2';
    if (value.contains('3')) return 'stage 3';
    if (value.contains('4')) return 'stage 4';
    if (value.contains('5')) return 'stage 5';
    return value;
  }

  IconData genderIcon() {
    if (gender.contains('หญิง')) {
      return Icons.female;
    }

    return Icons.male;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isSmall = screenWidth < 390;

    return Scaffold(
      backgroundColor: const Color(0xFFEAF8FF),
      body: SafeArea(
        child: isLoading
            ? const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF2678C7),
                ),
              )
            : SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  isSmall ? 16 : 26,
                  isSmall ? 18 : 26,
                  isSmall ? 16 : 26,
                  40,
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        CircleButton(
                          icon: Icons.arrow_back,
                          size: isSmall ? 52 : 64,
                          iconSize: isSmall ? 34 : 42,
                          onTap: () => Navigator.pop(context),
                        ),
                        Expanded(
                          child: Text(
                            'โปรไฟล์',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: isSmall ? 28 : 34,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        SizedBox(width: isSmall ? 52 : 64),
                      ],
                    ),
                    SizedBox(height: isSmall ? 24 : 34),

                    ProfileUserCard(
                      fullName: fullName,
                      email: email,
                      phone: phone,
                    ),

                    SizedBox(height: isSmall ? 22 : 28),

                    HealthCard(
                      kidneyStage: displayKidneyStage(kidneyStage),
                      gender: gender,
                      genderIcon: genderIcon(),
                      heightCm: heightCm,
                    ),

                    SizedBox(height: isSmall ? 26 : 34),

                    LogoutCard(
                      onTap: showLogoutConfirmDialog,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class ProfileUserCard extends StatelessWidget {
  final String fullName;
  final String email;
  final String phone;

  const ProfileUserCard({
    super.key,
    required this.fullName,
    required this.email,
    required this.phone,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.sizeOf(context).width < 390;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(isSmall ? 18 : 26),
      decoration: profileCardDecoration(),
      child: Row(
        children: [
          CircleAvatar(
            radius: isSmall ? 44 : 58,
            backgroundColor: const Color(0xFFB5D8FF),
            child: Icon(
              Icons.person,
              size: isSmall ? 70 : 92,
              color: const Color(0xFF2678C7),
            ),
          ),
          SizedBox(width: isSmall ? 16 : 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isSmall ? 20 : 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: isSmall ? 15 : 18),
                ),
                SizedBox(height: isSmall ? 8 : 12),
                Row(
                  children: [
                    Icon(
                      Icons.phone_in_talk_outlined,
                      color: const Color(0xFF2678C7),
                      size: isSmall ? 20 : 24,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        phone,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: isSmall ? 15 : 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class HealthCard extends StatelessWidget {
  final String kidneyStage;
  final String gender;
  final IconData genderIcon;
  final int heightCm;

  const HealthCard({
    super.key,
    required this.kidneyStage,
    required this.gender,
    required this.genderIcon,
    required this.heightCm,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.sizeOf(context).width < 390;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        isSmall ? 18 : 26,
        isSmall ? 22 : 28,
        isSmall ? 18 : 26,
        isSmall ? 26 : 34,
      ),
      decoration: profileCardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.monitor_heart,
                color: const Color(0xFF2678C7),
                size: isSmall ? 34 : 42,
              ),
              const SizedBox(width: 10),
              Text(
                'ข้อมูลสุขภาพ',
                style: TextStyle(
                  fontSize: isSmall ? 22 : 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          SizedBox(height: isSmall ? 28 : 34),
          Row(
            children: [
              Expanded(
                child: HealthInfoItem(
                  icon: Icons.medical_services_outlined,
                  label: 'ระยะโรคไต',
                  value: kidneyStage,
                ),
              ),
              const VerticalDividerLine(),
              Expanded(
                child: HealthInfoItem(
                  icon: genderIcon,
                  label: 'เพศ',
                  value: gender,
                ),
              ),
              const VerticalDividerLine(),
              Expanded(
                child: HealthInfoItem(
                  icon: Icons.height,
                  label: 'ส่วนสูง',
                  value: heightCm == 0 ? '-' : '$heightCm',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class LogoutCard extends StatelessWidget {
  final VoidCallback onTap;

  const LogoutCard({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.sizeOf(context).width < 390;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: isSmall ? 20 : 26,
          vertical: isSmall ? 18 : 22,
        ),
        decoration: profileCardDecoration(radius: 22),
        child: Row(
          children: [
            CircleAvatar(
              radius: isSmall ? 30 : 34,
              backgroundColor: const Color(0xFFFF8B99),
              child: Icon(
                Icons.logout,
                color: const Color(0xFFC62828),
                size: isSmall ? 30 : 34,
              ),
            ),
            SizedBox(width: isSmall ? 18 : 22),
            Text(
              'ออกจากระบบ',
              style: TextStyle(
                fontSize: isSmall ? 20 : 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CircleButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback onTap;

  const CircleButton({
    super.key,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: const Color(0xFF2678C7),
        ),
      ),
    );
  }
}

class HealthInfoItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const HealthInfoItem({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.sizeOf(context).width < 390;

    return Column(
      children: [
        Icon(
          icon,
          size: isSmall ? 42 : 70,
          color: const Color(0xFF2678C7),
        ),
        SizedBox(height: isSmall ? 10 : 14),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: isSmall ? 14 : 19),
        ),
        SizedBox(height: isSmall ? 6 : 10),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: isSmall ? 15 : 19,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class VerticalDividerLine extends StatelessWidget {
  const VerticalDividerLine({super.key});

  @override
  Widget build(BuildContext context) {
    final isSmall = MediaQuery.sizeOf(context).width < 390;

    return Container(
      width: 1,
      height: isSmall ? 104 : 150,
      color: Colors.grey.shade300,
    );
  }
}

BoxDecoration profileCardDecoration({double radius = 26}) {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(radius),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.14),
        blurRadius: 16,
        offset: const Offset(4, 8),
      ),
    ],
  );
}