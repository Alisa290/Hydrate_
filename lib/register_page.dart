import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final fullNameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();
  final heightController = TextEditingController();

  bool isLoading = false;
  String gender = 'ชาย';
  String kidneyStage = 'เลือกระยะของโรคไต';

  @override
  void dispose() {
    fullNameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    heightController.dispose();
    super.dispose();
  }

  Future<void> registerUser() async {
    final fullName = fullNameController.text.trim();
    final email = emailController.text.trim();
    final phone = phoneController.text.trim();
    final password = passwordController.text.trim();
    final confirmPassword = confirmPasswordController.text.trim();
    final height = int.tryParse(heightController.text.trim());

    if (fullName.isEmpty ||
        email.isEmpty ||
        phone.isEmpty ||
        password.isEmpty ||
        confirmPassword.isEmpty ||
        heightController.text.trim().isEmpty ||
        kidneyStage == 'เลือกระยะของโรคไต') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอกข้อมูลให้ครบ')),
      );
      return;
    }

    if (password.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('รหัสผ่านต้องมีอย่างน้อย 6 ตัวอักษร')),
      );
      return;
    }

    if (password != confirmPassword) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('รหัสผ่านไม่ตรงกัน')),
      );
      return;
    }

    if (height == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('กรุณากรอกส่วนสูงเป็นตัวเลข')),
      );
      return;
    }

    setState(() {
      isLoading = true;
    });

    try {
      final credential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      final user = credential.user;

      if (user == null) {
        throw Exception('สมัครสมาชิกไม่สำเร็จ');
      }

      await FirebaseFirestore.instance.collection('profiles').doc(user.uid).set({
        'uid': user.uid,
        'full_name': fullName,
        'email': email,
        'phone': phone,
        'gender': gender,
        'height_cm': height,
        'kidney_stage': kidneyStage,
        'created_at': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('สมัครสมาชิกสำเร็จ')),
      );

      Navigator.pop(context);
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;

      String message = 'สมัครสมาชิกไม่สำเร็จ';

      if (error.code == 'email-already-in-use') {
        message = 'อีเมลนี้ถูกใช้สมัครแล้ว';
      } else if (error.code == 'invalid-email') {
        message = 'รูปแบบอีเมลไม่ถูกต้อง';
      } else if (error.code == 'weak-password') {
        message = 'รหัสผ่านง่ายเกินไป';
      } else if (error.message != null) {
        message = error.message!;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (error) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('เกิดข้อผิดพลาด: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;

    final pagePadding = screenWidth < 380 ? 16.0 : 24.0;
    final cardPadding = screenWidth < 380 ? 18.0 : 26.0;
    final titleSize = screenWidth < 380 ? 34.0 : 40.0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFA9D4F5),
              Color(0xFFF8FFFF),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(pagePadding, 24, pagePadding, 40),
            child: Column(
              children: [
                Text(
                  'สมัครสมาชิก',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: titleSize,
                    fontWeight: FontWeight.bold,
                    color: const Color(0xFF2378C7),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'สร้างบัญชีเพื่อเริ่มต้นการใช้งาน',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.black87),
                ),
                const SizedBox(height: 24),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(cardPadding),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.16),
                        blurRadius: 14,
                        offset: const Offset(4, 7),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionTitle(number: '1', title: 'ข้อมูลบัญชีผู้ใช้'),
                      const SizedBox(height: 24),
                      const RegisterLabel(text: 'ชื่อ - นามสกุล'),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: fullNameController,
                        icon: Icons.person_outline,
                        hintText: 'กรอกชื่อ - นามสกุล',
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 18),
                      const RegisterLabel(text: 'อีเมล'),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: emailController,
                        icon: Icons.email_outlined,
                        hintText: 'example@email.com',
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 18),
                      const RegisterLabel(text: 'เบอร์โทรศัพท์'),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: phoneController,
                        icon: Icons.phone_outlined,
                        hintText: '08X-XXX-XXXX',
                        keyboardType: TextInputType.phone,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 18),
                      const RegisterLabel(text: 'รหัสผ่าน'),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: passwordController,
                        icon: Icons.lock_outline,
                        hintText: 'อย่างน้อย 6 ตัวอักษร',
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 18),
                      const RegisterLabel(text: 'ยืนยันรหัสผ่าน'),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: confirmPasswordController,
                        icon: Icons.lock_outline,
                        hintText: 'กรอกรหัสผ่านอีกครั้ง',
                        obscureText: true,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 34),
                      const SectionTitle(number: '2', title: 'ข้อมูลสุขภาพ'),
                      const SizedBox(height: 24),
                      const RegisterLabel(text: 'เพศ'),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: GenderButton(
                              text: 'ชาย',
                              icon: Icons.male,
                              color: const Color(0xFF2378C7),
                              selected: gender == 'ชาย',
                              onTap: () {
                                setState(() {
                                  gender = 'ชาย';
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GenderButton(
                              text: 'หญิง',
                              icon: Icons.female,
                              color: const Color(0xFFE75A94),
                              selected: gender == 'หญิง',
                              onTap: () {
                                setState(() {
                                  gender = 'หญิง';
                                });
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const RegisterLabel(
                        text: 'ส่วนสูง',
                        suffix: ' (เซนติเมตร)',
                      ),
                      const SizedBox(height: 8),
                      RegisterTextField(
                        controller: heightController,
                        icon: Icons.straighten,
                        hintText: 'เช่น 170',
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                      ),
                      const SizedBox(height: 18),
                      const RegisterLabel(text: 'ระยะของโรคไต'),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const CircleIcon(
                            icon: Icons.medical_services_outlined,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Container(
                              height: 50,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 14),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(25),
                                border: Border.all(color: Colors.grey.shade400),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: kidneyStage,
                                  isExpanded: true,
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down,
                                    color: Color(0xFF9AA6B2),
                                  ),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Color(0xFF6F7C88),
                                    fontWeight: FontWeight.bold,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'เลือกระยะของโรคไต',
                                      child: Text(
                                        'เลือกระยะของโรคไต',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'ระยะที่ 3',
                                      child: Text('ระยะที่ 3'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'ระยะที่ 4',
                                      child: Text('ระยะที่ 4'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'ระยะที่ 5',
                                      child: Text('ระยะที่ 5'),
                                    ),
                                  ],
                                  onChanged: (value) {
                                    if (value == null) return;

                                    setState(() {
                                      kidneyStage = value;
                                    });
                                  },
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 58,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : registerUser,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4D7DF3),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: Colors.grey.shade400,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: isLoading
                        ? const SizedBox(
                            width: 25,
                            height: 25,
                            child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'ยืนยัน',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    Text(
                      'มีบัญชีอยู่แล้ว?',
                      style: TextStyle(
                        fontSize: 17,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(context);
                      },
                      child: const Text(
                        'เข้าสู่ระบบ',
                        style: TextStyle(
                          fontSize: 17,
                          color: Color(0xFF2378C7),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String number;
  final String title;

  const SectionTitle({
    super.key,
    required this.number,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 50,
          height: 50,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Color(0xFF2378C7),
            shape: BoxShape.circle,
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 23,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF2378C7),
              fontSize: 23,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class RegisterLabel extends StatelessWidget {
  final String text;
  final String? suffix;

  const RegisterLabel({
    super.key,
    required this.text,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 17,
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
        children: [
          const TextSpan(
            text: ' *',
            style: TextStyle(color: Colors.red),
          ),
          if (suffix != null)
            TextSpan(
              text: suffix,
              style: TextStyle(
                color: Colors.grey.shade500,
                fontWeight: FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}

class RegisterTextField extends StatefulWidget {
  final IconData icon;
  final String hintText;
  final bool obscureText;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;

  const RegisterTextField({
    super.key,
    required this.icon,
    required this.hintText,
    required this.controller,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
  });

  @override
  State<RegisterTextField> createState() => _RegisterTextFieldState();
}

class _RegisterTextFieldState extends State<RegisterTextField> {
  late bool isHidden;

  @override
  void initState() {
    super.initState();
    isHidden = widget.obscureText;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleIcon(icon: widget.icon),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 50,
            child: TextField(
              controller: widget.controller,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              obscureText: isHidden,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white,
                hintText: widget.hintText,
                hintMaxLines: 1,
                hintStyle: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade400,
                  fontWeight: FontWeight.bold,
                ),
                suffixIcon: widget.obscureText
                    ? IconButton(
                        onPressed: () {
                          setState(() {
                            isHidden = !isHidden;
                          });
                        },
                        icon: Icon(
                          isHidden
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.grey.shade400,
                          size: 22,
                        ),
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide(color: Colors.grey.shade400),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: const BorderSide(
                    color: Color(0xFF8BC2F2),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class CircleIcon extends StatelessWidget {
  final IconData icon;

  const CircleIcon({
    super.key,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 46,
      height: 46,
      decoration: const BoxDecoration(
        color: Color(0xFFEAF5FF),
        shape: BoxShape.circle,
      ),
      child: Icon(
        icon,
        color: Color(0xFF5AA9D1),
        size: 25,
      ),
    );
  }
}

class GenderButton extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const GenderButton({
    super.key,
    required this.text,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 62,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? color.withOpacity(0.06) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? color : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Icon(icon, color: color, size: 34),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    text,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}