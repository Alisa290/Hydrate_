import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'main.dart';
import 'device_connection_page.dart';

// =====================================================
// PROFILE PAGE
// =====================================================
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage>
    with WidgetsBindingObserver {
  bool isLoading = true;

  String fullName = '-';
  String email = '-';
  String phone = '-';
  String gender = '-';
  String kidneyStage = '-';
  int heightCm = 0;

  // =====================================================
  // BOTTLE AUTO DISCONNECT AFTER 21:00
  // =====================================================
  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  static const String bottleDeviceId = 'bottle_001';

  late final FirebaseDatabase realtimeDatabase;

  Timer? _dailyDisconnectTimer;
  bool _isAutoDisconnecting = false;

  bool _isAfterDailyCutoff([DateTime? now]) {
    final current = now ?? DateTime.now();
    return current.hour >= 21;
  }


  // =====================================================
  // INIT
  // =====================================================
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    realtimeDatabase = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
    );

    loadProfile();

    // ตรวจทันทีเมื่อเข้าหน้าโปรไฟล์
    _enforceDailyBottleDisconnect();

    // ตรวจซ้ำทุก 30 วินาที ขณะที่หน้านี้ยังเปิดอยู่
    _dailyDisconnectTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _enforceDailyBottleDisconnect(),
    );
  }

  @override
  void dispose() {
    _dailyDisconnectTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // ถ้ากลับเข้าแอปหลัง 21:00 ให้ตรวจและตัดทันที
      _enforceDailyBottleDisconnect();
    }
  }

  // =====================================================
  // AUTO DISCONNECT BOTTLE AT / AFTER 21:00
  //
  // Firebase:
  // devices/bottle_001/active_user_id
  //
  // ลบเฉพาะกรณีที่ UID ในขวดตรงกับผู้ใช้ที่ล็อกอินอยู่
  // วันถัดไปจะไม่เชื่อมให้อัตโนมัติ
  // ผู้ใช้ต้องกด "เชื่อมต่อขวดน้ำ" ใหม่เอง
  // =====================================================
  Future<void> _enforceDailyBottleDisconnect() async {
    if (_isAutoDisconnecting) {
      return;
    }

    if (!_isAfterDailyCutoff()) {
      return;
    }

    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      return;
    }

    _isAutoDisconnecting = true;

    try {
      final ref = realtimeDatabase.ref(
        'devices/$bottleDeviceId/active_user_id',
      );

      final snapshot = await ref.get();

      final String? activeUid =
          snapshot.exists && snapshot.value != null
              ? snapshot.value.toString().trim()
              : null;

      if (activeUid == user.uid) {
        await ref.remove();

        debugPrint(
          'Bottle auto disconnected after 21:00',
        );

        if (!mounted) {
          return;
        }

        ScaffoldMessenger.of(context)
            .hideCurrentSnackBar();

        ScaffoldMessenger.of(context)
            .showSnackBar(
          const SnackBar(
            content: Text(
              'สิ้นสุดการติดตามวันนี้แล้ว กรุณาเชื่อมต่อขวดใหม่ในวันถัดไป',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      debugPrint(
        'Auto disconnect bottle error: $error',
      );
    } finally {
      _isAutoDisconnecting = false;
    }
  }

  // =====================================================
  // LOAD PROFILE
  // =====================================================
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

      if (!mounted) return;

      setState(() {
        fullName = data['full_name']?.toString() ?? '-';

        email =
            data['email']?.toString() ??
            user.email ??
            '-';

        phone = data['phone']?.toString() ?? '-';

        gender = data['gender']?.toString() ?? '-';

        kidneyStage =
            data['kidney_stage']?.toString() ?? '-';

        heightCm =
            int.tryParse(
              data['height_cm'].toString(),
            ) ??
            0;

        isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        email =
            FirebaseAuth.instance.currentUser?.email ??
            '-';

        isLoading = false;
      });

      debugPrint(
        'loadProfile error: $error',
      );
    }
  }

  // =====================================================
  // NORMALIZE HEALTH VALUES
  // =====================================================
  String normalizeGender(String value) {
    if (value.contains('หญิง')) {
      return 'หญิง';
    }

    if (value.contains('ชาย')) {
      return 'ชาย';
    }

    return 'หญิง';
  }

  String normalizeKidneyStage(String value) {
    if (value.contains('3')) {
      return 'stage 3';
    }

    if (value.contains('4')) {
      return 'stage 4';
    }

    if (value.contains('5')) {
      return 'stage 5';
    }

    return 'stage 3';
  }

  // =====================================================
  // SAVE HEALTH DATA -> FIRESTORE
  // profiles/{uid}
  // =====================================================
  Future<void> saveHealthData({
    required String newGender,
    required String newKidneyStage,
    required int newHeightCm,
  }) async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      throw Exception('ยังไม่มีผู้ใช้ล็อกอิน');
    }

    await FirebaseFirestore.instance
        .collection('profiles')
        .doc(user.uid)
        .set(
      {
        'gender': newGender,
        'kidney_stage': newKidneyStage,
        'height_cm': newHeightCm,
        'updated_at': FieldValue.serverTimestamp(),
      },
      SetOptions(
        merge: true,
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      gender = newGender;
      kidneyStage = newKidneyStage;
      heightCm = newHeightCm;
    });
  }

  // =====================================================
  // EDIT HEALTH DIALOG
  // =====================================================
  Future<void> showEditHealthDialog() async {
    String selectedGender =
        normalizeGender(
      gender,
    );

    String selectedKidneyStage =
        normalizeKidneyStage(
      kidneyStage,
    );

    final heightController =
        TextEditingController(
      text: heightCm > 0
          ? heightCm.toString()
          : '',
    );

    final formKey =
        GlobalKey<FormState>();

    bool isSaving = false;

    await showDialog(
      context: context,
      barrierDismissible: !isSaving,
      barrierColor:
          Colors.black.withOpacity(
        0.35,
      ),
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (
            context,
            setDialogState,
          ) {
            final screenWidth =
                MediaQuery.sizeOf(
              context,
            ).width;

            final isSmall =
                screenWidth < 390;

            return Dialog(
              insetPadding:
                  EdgeInsets.symmetric(
                horizontal:
                    isSmall ? 16 : 24,
              ),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  24,
                ),
              ),
              child:
                  SingleChildScrollView(
                padding:
                    EdgeInsets.fromLTRB(
                  isSmall ? 18 : 24,
                  22,
                  isSmall ? 18 : 24,
                  20,
                ),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize:
                        MainAxisSize.min,
                    crossAxisAlignment:
                        CrossAxisAlignment
                            .start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons
                                .monitor_heart,
                            color:
                                Color(
                              0xFF2678C7,
                            ),
                            size: 30,
                          ),

                          const SizedBox(
                            width: 10,
                          ),

                          const Expanded(
                            child: Text(
                              'แก้ไขข้อมูลสุขภาพ',
                              style:
                                  TextStyle(
                                fontSize:
                                    22,
                                fontWeight:
                                    FontWeight
                                        .bold,
                              ),
                            ),
                          ),

                          IconButton(
                            onPressed:
                                isSaving
                                    ? null
                                    : () {
                                        Navigator.pop(
                                          dialogContext,
                                        );
                                      },
                            icon:
                                const Icon(
                              Icons.close,
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(
                        height: 20,
                      ),

                      const Text(
                        'ระยะโรคไต',
                        style:
                            TextStyle(
                          fontSize: 16,
                          fontWeight:
                              FontWeight
                                  .w600,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      DropdownButtonFormField<
                          String>(
                        value:
                            selectedKidneyStage,
                        isExpanded: true,
                        decoration:
                            editHealthInputDecoration(),
                        items:
                            const [
                          'stage 3',
                          'stage 4',
                          'stage 5',
                        ].map(
                          (stage) {
                            return DropdownMenuItem<
                                String>(
                              value:
                                  stage,
                              child:
                                  Text(
                                stage,
                              ),
                            );
                          },
                        ).toList(),
                        onChanged:
                            isSaving
                                ? null
                                : (value) {
                                    if (value ==
                                        null) {
                                      return;
                                    }

                                    setDialogState(
                                      () {
                                        selectedKidneyStage =
                                            value;
                                      },
                                    );
                                  },
                      ),

                      const SizedBox(
                        height: 16,
                      ),

                      const Text(
                        'เพศ',
                        style:
                            TextStyle(
                          fontSize: 16,
                          fontWeight:
                              FontWeight
                                  .w600,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      DropdownButtonFormField<
                          String>(
                        value:
                            selectedGender,
                        isExpanded: true,
                        decoration:
                            editHealthInputDecoration(),
                        items:
                            const [
                          'ชาย',
                          'หญิง',
                        ].map(
                          (item) {
                            return DropdownMenuItem<
                                String>(
                              value:
                                  item,
                              child:
                                  Text(
                                item,
                              ),
                            );
                          },
                        ).toList(),
                        onChanged:
                            isSaving
                                ? null
                                : (value) {
                                    if (value ==
                                        null) {
                                      return;
                                    }

                                    setDialogState(
                                      () {
                                        selectedGender =
                                            value;
                                      },
                                    );
                                  },
                      ),

                      const SizedBox(
                        height: 16,
                      ),

                      const Text(
                        'ส่วนสูง (ซม.)',
                        style:
                            TextStyle(
                          fontSize: 16,
                          fontWeight:
                              FontWeight
                                  .w600,
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      TextFormField(
                        controller:
                            heightController,
                        enabled:
                            !isSaving,
                        keyboardType:
                            TextInputType
                                .number,
                        decoration:
                            editHealthInputDecoration(
                          hintText:
                              'เช่น 165',
                        ),
                        validator:
                            (value) {
                          final parsed =
                              int.tryParse(
                            value
                                    ?.trim() ??
                                '',
                          );

                          if (parsed ==
                              null) {
                            return 'กรุณากรอกส่วนสูงเป็นตัวเลข';
                          }

                          if (parsed <
                                  100 ||
                              parsed >
                                  250) {
                            return 'กรุณากรอกส่วนสูงระหว่าง 100-250 ซม.';
                          }

                          return null;
                        },
                      ),

                      const SizedBox(
                        height: 24,
                      ),

                      SizedBox(
                        width:
                            double.infinity,
                        height: 52,
                        child:
                            ElevatedButton(
                          onPressed:
                              isSaving
                                  ? null
                                  : () async {
                                      if (!(formKey
                                              .currentState
                                              ?.validate() ??
                                          false)) {
                                        return;
                                      }

                                      final newHeightCm =
                                          int.parse(
                                        heightController
                                            .text
                                            .trim(),
                                      );

                                      setDialogState(
                                        () {
                                          isSaving =
                                              true;
                                        },
                                      );

                                      try {
                                        await saveHealthData(
                                          newGender:
                                              selectedGender,
                                          newKidneyStage:
                                              selectedKidneyStage,
                                          newHeightCm:
                                              newHeightCm,
                                        );

                                        if (!mounted) {
                                          return;
                                        }

                                        if (Navigator.of(
                                          dialogContext,
                                        ).canPop()) {
                                          Navigator.pop(
                                            dialogContext,
                                          );
                                        }

                                        ScaffoldMessenger.of(
                                          this.context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content:
                                                Text(
                                              'อัปเดตข้อมูลสุขภาพเรียบร้อยแล้ว',
                                            ),
                                          ),
                                        );
                                      } catch (error) {
                                        debugPrint(
                                          'saveHealthData error: $error',
                                        );

                                        if (!mounted) {
                                          return;
                                        }

                                        setDialogState(
                                          () {
                                            isSaving =
                                                false;
                                          },
                                        );

                                        ScaffoldMessenger.of(
                                          this.context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content:
                                                Text(
                                              'บันทึกข้อมูลไม่สำเร็จ: $error',
                                            ),
                                          ),
                                        );
                                      }
                                    },
                          style:
                              ElevatedButton
                                  .styleFrom(
                            backgroundColor:
                                const Color(
                              0xFF2678C7,
                            ),
                            foregroundColor:
                                Colors.white,
                            shape:
                                RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius
                                      .circular(
                                16,
                              ),
                            ),
                          ),
                          child:
                              isSaving
                                  ? const SizedBox(
                                      width:
                                          22,
                                      height:
                                          22,
                                      child:
                                          CircularProgressIndicator(
                                        strokeWidth:
                                            2.5,
                                        color:
                                            Colors
                                                .white,
                                      ),
                                    )
                                  : const Text(
                                      'บันทึกข้อมูล',
                                      style:
                                          TextStyle(
                                        fontSize:
                                            17,
                                        fontWeight:
                                            FontWeight
                                                .bold,
                                      ),
                                    ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    heightController.dispose();
  }

  // =====================================================
  // LOGOUT
  // =====================================================
  Future<void> logout() async {
    await FirebaseAuth.instance.signOut();

    if (!mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(
        builder: (context) => const LoginPage(),
      ),
      (route) => false,
    );
  }

  // =====================================================
  // LOGOUT CONFIRM DIALOG
  // =====================================================
  void showLogoutConfirmDialog() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.35),
      builder: (dialogContext) {
        final isSmall =
            MediaQuery.sizeOf(context).width < 390;

        return Dialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: isSmall ? 18 : 26,
          ),
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
                      // ===============================
                      // CANCEL
                      // ===============================
                      Expanded(
                        child: TextButton(
                          onPressed: () {
                            Navigator.pop(
                              dialogContext,
                            );
                          },
                          child: Text(
                            'ยกเลิก',
                            style: TextStyle(
                              fontSize:
                                  isSmall ? 20 : 24,
                              fontWeight:
                                  FontWeight.bold,
                              color: const Color(
                                0xFF5E9BFF,
                              ),
                            ),
                          ),
                        ),
                      ),

                      Container(
                        width: 1,
                        height: isSmall ? 46 : 54,
                        color: Colors.grey.shade300,
                      ),

                      // ===============================
                      // LOGOUT
                      // ===============================
                      Expanded(
                        child: TextButton(
                          onPressed: () async {
                            Navigator.pop(
                              dialogContext,
                            );

                            await logout();
                          },
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'ออกจากระบบ',
                              style: TextStyle(
                                fontSize:
                                    isSmall ? 20 : 24,
                                fontWeight:
                                    FontWeight.bold,
                                color: const Color(
                                  0xFFC62828,
                                ),
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

  // =====================================================
  // DISPLAY KIDNEY STAGE
  // =====================================================
  String displayKidneyStage(String value) {
    if (value.contains('3')) {
      return 'stage 3';
    }

    if (value.contains('4')) {
      return 'stage 4';
    }

    if (value.contains('5')) {
      return 'stage 5';
    }

    return 'stage 3';
  }

  // =====================================================
  // GENDER ICON
  // =====================================================
  IconData genderIcon() {
    if (gender.contains('หญิง')) {
      return Icons.female;
    }

    return Icons.male;
  }

  // =====================================================
  // BUILD
  // =====================================================
  @override
  Widget build(BuildContext context) {
    final screenWidth =
        MediaQuery.sizeOf(context).width;

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
                    // =================================
                    // HEADER
                    // =================================
                    Row(
                      children: [
                        CircleButton(
                          icon: Icons.arrow_back,
                          size: isSmall ? 52 : 64,
                          iconSize: isSmall ? 34 : 42,
                          onTap: () {
                            Navigator.pop(context);
                          },
                        ),

                        Expanded(
                          child: Text(
                            'โปรไฟล์',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize:
                                  isSmall ? 28 : 34,
                              fontWeight:
                                  FontWeight.bold,
                            ),
                          ),
                        ),

                        SizedBox(
                          width: isSmall ? 52 : 64,
                        ),
                      ],
                    ),

                    SizedBox(
                      height: isSmall ? 24 : 34,
                    ),

                    // =================================
                    // PROFILE USER CARD
                    // =================================
                    ProfileUserCard(
                      fullName: fullName,
                      email: email,
                      phone: phone,
                    ),

                    SizedBox(
                      height: isSmall ? 22 : 28,
                    ),

                    // =================================
                    // HEALTH CARD
                    // =================================
                    HealthCard(
                      kidneyStage:
                          displayKidneyStage(
                        kidneyStage,
                      ),
                      gender: gender,
                      genderIcon: genderIcon(),
                      heightCm: heightCm,
                      onEdit:
                          showEditHealthDialog,
                    ),

                    SizedBox(
                      height: isSmall ? 26 : 34,
                    ),

                    // =================================
                    // DEVICE CONNECTION
                    // =================================
                    DeviceConnectionCard(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) =>
                                const DeviceConnectionPage(),
                          ),
                        );
                      },
                    ),

                    SizedBox(
                      height: isSmall ? 16 : 20,
                    ),

                    // =================================
                    // LOGOUT
                    // =================================
                    LogoutCard(
                      onTap:
                          showLogoutConfirmDialog,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

// =====================================================
// PROFILE USER CARD
// =====================================================
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
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(
        isSmall ? 18 : 26,
      ),
      decoration: profileCardDecoration(),
      child: Row(
        children: [
          CircleAvatar(
            radius: isSmall ? 44 : 58,
            backgroundColor:
                const Color(0xFFB5D8FF),
            child: Icon(
              Icons.person,
              size: isSmall ? 70 : 92,
              color: const Color(
                0xFF2678C7,
              ),
            ),
          ),

          SizedBox(
            width: isSmall ? 16 : 24,
          ),

          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(
                  fullName,
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize:
                        isSmall ? 20 : 24,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  email,
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize:
                        isSmall ? 15 : 18,
                  ),
                ),

                SizedBox(
                  height: isSmall ? 8 : 12,
                ),

                Row(
                  children: [
                    Icon(
                      Icons
                          .phone_in_talk_outlined,
                      color: const Color(
                        0xFF2678C7,
                      ),
                      size:
                          isSmall ? 20 : 24,
                    ),

                    const SizedBox(width: 8),

                    Flexible(
                      child: Text(
                        phone,
                        maxLines: 1,
                        overflow:
                            TextOverflow
                                .ellipsis,
                        style: TextStyle(
                          fontSize:
                              isSmall
                                  ? 15
                                  : 18,
                        ),
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

// =====================================================
// HEALTH CARD
// =====================================================
class HealthCard extends StatelessWidget {
  final String kidneyStage;
  final String gender;
  final IconData genderIcon;
  final int heightCm;
  final VoidCallback onEdit;

  const HealthCard({
    super.key,
    required this.kidneyStage,
    required this.gender,
    required this.genderIcon,
    required this.heightCm,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

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
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.monitor_heart,
                color: const Color(
                  0xFF2678C7,
                ),
                size: isSmall ? 34 : 42,
              ),

              const SizedBox(width: 10),

              Expanded(
                child: Text(
                  'ข้อมูลสุขภาพ',
                  style: TextStyle(
                    fontSize:
                        isSmall ? 22 : 26,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),

              TextButton.icon(
                onPressed: onEdit,
                style: TextButton.styleFrom(
                  foregroundColor:
                      const Color(
                    0xFF2678C7,
                  ),
                  padding:
                      const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                ),
                icon: const Icon(
                  Icons.edit_outlined,
                  size: 20,
                ),
                label: Text(
                  'แก้ไข',
                  style: TextStyle(
                    fontSize:
                        isSmall ? 14 : 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(
            height: isSmall ? 28 : 34,
          ),

          Row(
            children: [
              Expanded(
                child: HealthInfoItem(
                  icon: Icons
                      .medical_services_outlined,
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
                  value: heightCm == 0
                      ? '-'
                      : '$heightCm',
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
// DEVICE CONNECTION CARD
// =====================================================
class DeviceConnectionCard
    extends StatelessWidget {
  final VoidCallback onTap;

  const DeviceConnectionCard({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(22),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal:
              isSmall ? 20 : 26,
          vertical:
              isSmall ? 18 : 22,
        ),
        decoration:
            profileCardDecoration(
          radius: 22,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius:
                  isSmall ? 30 : 34,
              backgroundColor:
                  const Color(
                0xFFD9EEFF,
              ),
              child: Icon(
                Icons.water_drop_outlined,
                color: const Color(
                  0xFF2678C7,
                ),
                size:
                    isSmall ? 30 : 34,
              ),
            ),

            SizedBox(
              width: isSmall ? 18 : 22,
            ),

            Expanded(
              child: Text(
                'เชื่อมต่อขวดน้ำ',
                style: TextStyle(
                  fontSize:
                      isSmall ? 20 : 22,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),

            const Icon(
              Icons.arrow_forward_ios,
              color: Color(
                0xFF2678C7,
              ),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

// =====================================================
// LOGOUT CARD
// =====================================================
class LogoutCard extends StatelessWidget {
  final VoidCallback onTap;

  const LogoutCard({
    super.key,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

    return InkWell(
      onTap: onTap,
      borderRadius:
          BorderRadius.circular(22),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal:
              isSmall ? 20 : 26,
          vertical:
              isSmall ? 18 : 22,
        ),
        decoration:
            profileCardDecoration(
          radius: 22,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius:
                  isSmall ? 30 : 34,
              backgroundColor:
                  const Color(
                0xFFFF8B99,
              ),
              child: Icon(
                Icons.logout,
                color: const Color(
                  0xFFC62828,
                ),
                size:
                    isSmall ? 30 : 34,
              ),
            ),

            SizedBox(
              width: isSmall ? 18 : 22,
            ),

            Expanded(
              child: Text(
                'ออกจากระบบ',
                style: TextStyle(
                  fontSize:
                      isSmall ? 20 : 22,
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

// =====================================================
// CIRCLE BUTTON
// =====================================================
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
      borderRadius:
          BorderRadius.circular(
        size / 2,
      ),
      child: Container(
        width: size,
        height: size,
        decoration:
            const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: iconSize,
          color: const Color(
            0xFF2678C7,
          ),
        ),
      ),
    );
  }
}

// =====================================================
// HEALTH INFO ITEM
// =====================================================
class HealthInfoItem
    extends StatelessWidget {
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
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

    return Column(
      children: [
        Icon(
          icon,
          size: isSmall ? 42 : 70,
          color: const Color(
            0xFF2678C7,
          ),
        ),

        SizedBox(
          height: isSmall ? 10 : 14,
        ),

        Text(
          label,
          maxLines: 1,
          overflow:
              TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize:
                isSmall ? 14 : 19,
          ),
        ),

        SizedBox(
          height: isSmall ? 6 : 10,
        ),

        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            textAlign:
                TextAlign.center,
            style: TextStyle(
              fontSize:
                  isSmall ? 15 : 19,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================
// VERTICAL DIVIDER
// =====================================================
class VerticalDividerLine
    extends StatelessWidget {
  const VerticalDividerLine({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final isSmall =
        MediaQuery.sizeOf(context).width < 390;

    return Container(
      width: 1,
      height: isSmall ? 104 : 150,
      color: Colors.grey.shade300,
    );
  }
}

// =====================================================
// EDIT HEALTH INPUT DECORATION
// =====================================================
InputDecoration editHealthInputDecoration({
  String? hintText,
}) {
  return InputDecoration(
    hintText: hintText,
    filled: true,
    fillColor: const Color(
      0xFFF7FBFF,
    ),
    contentPadding:
        const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 14,
    ),
    border: OutlineInputBorder(
      borderRadius:
          BorderRadius.circular(
        14,
      ),
      borderSide: BorderSide(
        color:
            Colors.grey.shade300,
      ),
    ),
    enabledBorder:
        OutlineInputBorder(
      borderRadius:
          BorderRadius.circular(
        14,
      ),
      borderSide: BorderSide(
        color:
            Colors.grey.shade300,
      ),
    ),
    focusedBorder:
        OutlineInputBorder(
      borderRadius:
          BorderRadius.circular(
        14,
      ),
      borderSide:
          const BorderSide(
        color:
            Color(
          0xFF2678C7,
        ),
        width: 1.5,
      ),
    ),
  );
}

// =====================================================
// PROFILE CARD DECORATION
// =====================================================
BoxDecoration profileCardDecoration({
  double radius = 26,
}) {
  return BoxDecoration(
    color: Colors.white,
    borderRadius:
        BorderRadius.circular(radius),
    boxShadow: [
      BoxShadow(
        color:
            Colors.black.withOpacity(0.14),
        blurRadius: 16,
        offset:
            const Offset(4, 8),
      ),
    ],
  );
}