import 'dart:async';



import 'package:firebase_auth/firebase_auth.dart';

import 'package:firebase_core/firebase_core.dart';

import 'package:firebase_database/firebase_database.dart';

import 'package:flutter/material.dart';



import 'firebase_options.dart';

import 'home_page.dart';

import 'register_page.dart';



Future<void> main() async {

  WidgetsFlutterBinding.ensureInitialized();



  await Firebase.initializeApp(

    options: DefaultFirebaseOptions.currentPlatform,

  );



  runApp(const MyApp());

}



class MyApp extends StatefulWidget {

  const MyApp({super.key});



  @override

  State<MyApp> createState() => _MyAppState();

}



class _MyAppState extends State<MyApp>

    with WidgetsBindingObserver {

  // =====================================================

  // DAILY BOTTLE CONNECTION CONTROL

  // =====================================================

  static const String databaseUrl =

      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';



  static const String bottleDeviceId = 'bottle_001';



  late final FirebaseDatabase realtimeDatabase;



  Timer? _dailyDisconnectTimer;

  bool _isCheckingDailyDisconnect = false;



  @override

  void initState() {

    super.initState();



    WidgetsBinding.instance.addObserver(this);



    realtimeDatabase = FirebaseDatabase.instanceFor(

      app: Firebase.app(),

      databaseURL: databaseUrl,

    );



    // ตรวจทันทีตอนเปิดแอป

    _checkDailyBottleDisconnect();



    // ตรวจเวลาเป็นระยะตลอดเวลาที่แอปกำลังทำงาน

    _dailyDisconnectTimer = Timer.periodic(

      const Duration(seconds: 30),

      (_) => _checkDailyBottleDisconnect(),

    );

  }



  @override

  void dispose() {

    _dailyDisconnectTimer?.cancel();

    WidgetsBinding.instance.removeObserver(this);

    super.dispose();

  }



  @override

  void didChangeAppLifecycleState(

    AppLifecycleState state,

  ) {

    if (state == AppLifecycleState.resumed) {

      // ถ้าผู้ใช้กลับเข้าแอปหลัง 21:00

      // ให้ตรวจสถานะขวดทันที

      _checkDailyBottleDisconnect();

    }

  }



  bool _isAfterDailyCutoff([

    DateTime? now,

  ]) {

    final current = now ?? DateTime.now();



    return current.hour >= 21;

  }



  // =====================================================

  // AUTO DISCONNECT BOTTLE AT / AFTER 21:00

  //

  // ลบเฉพาะ:

  // devices/bottle_001/active_user_id

  //

  // ไม่ลบบัญชีผู้ใช้

  // ไม่ลบ profiles

  // ไม่ลบ water_history

  // ไม่ลบ notifications

  // ไม่ลบ drink_settings

  //

  // เมื่อ active_user_id ถูกลบ

  // วันถัดไปผู้ใช้ต้องกดเชื่อมต่อขวดใหม่เอง

  // =====================================================

  Future<void> _checkDailyBottleDisconnect() async {

    if (_isCheckingDailyDisconnect) {

      return;

    }



    if (!_isAfterDailyCutoff()) {

      return;

    }



    final user = FirebaseAuth.instance.currentUser;



    if (user == null) {

      return;

    }



    _isCheckingDailyDisconnect = true;



    try {

      final activeUserRef = realtimeDatabase.ref(

        'devices/$bottleDeviceId/active_user_id',

      );



      final snapshot = await activeUserRef.get();



      final String? activeUid =

          snapshot.exists && snapshot.value != null

              ? snapshot.value.toString().trim()

              : null;



      // ป้องกันไม่ให้บัญชีนี้ไปตัดขวดของบัญชีอื่น

      // จะลบเฉพาะเมื่อขวดกำลังเชื่อมกับ UID

      // ของผู้ใช้ที่ล็อกอินอยู่เท่านั้น

      if (activeUid == user.uid) {

        await activeUserRef.remove();



        debugPrint(

          'Bottle disconnected automatically at/after 21:00',

        );

        debugPrint(

          'Removed only devices/$bottleDeviceId/active_user_id',

        );

      }

    } catch (error) {

      debugPrint(

        'Daily bottle disconnect error: $error',

      );

    } finally {

      _isCheckingDailyDisconnect = false;

    }

  }



  @override

  Widget build(BuildContext context) {

    return const MaterialApp(

      debugShowCheckedModeBanner: false,

      home: LoginPage(),

    );

  }

}



class LoginPage extends StatefulWidget {

  const LoginPage({super.key});



  @override

  State<LoginPage> createState() => _LoginPageState();

}



class _LoginPageState extends State<LoginPage> {

  final emailController = TextEditingController();

  final passwordController = TextEditingController();



  bool isLoading = false;



  @override

  void dispose() {

    emailController.dispose();

    passwordController.dispose();

    super.dispose();

  }



  Future<void> loginUser() async {

    final email = emailController.text.trim();

    final password = passwordController.text.trim();



    if (email.isEmpty || password.isEmpty) {

      ScaffoldMessenger.of(context).showSnackBar(

        const SnackBar(

          content: Text('กรุณากรอกอีเมลและรหัสผ่าน'),

        ),

      );

      return;

    }



    setState(() {

      isLoading = true;

    });



    try {

      await FirebaseAuth.instance.signInWithEmailAndPassword(

        email: email,

        password: password,

      );



      if (!mounted) return;



      Navigator.pushReplacement(

        context,

        MaterialPageRoute(

          builder: (context) => const HomePage(),

        ),

      );

    } on FirebaseAuthException catch (error) {

      if (!mounted) return;



      String message = 'เข้าสู่ระบบไม่สำเร็จ';



      if (error.code == 'user-not-found') {

        message = 'ไม่พบบัญชีผู้ใช้นี้';

      } else if (error.code == 'wrong-password') {

        message = 'รหัสผ่านไม่ถูกต้อง';

      } else if (error.code == 'invalid-email') {

        message = 'รูปแบบอีเมลไม่ถูกต้อง';

      } else if (error.code == 'invalid-credential') {

        message = 'อีเมลหรือรหัสผ่านไม่ถูกต้อง';

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
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFA9D4F5), Color(0xFFF8FFFF)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                16,
                keyboardOpen || constraints.maxHeight < 600 ? 20 : 48,
                16,
                32,
              ),
              children: [
                const Text(
                  'เข้าสู่ระบบ',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2378C7),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'เข้าสู่บัญชีเพื่อเริ่มต้นการใช้งาน',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, color: Colors.black87),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 28,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.10),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FieldLabel(text: 'อีเมล'),
                      const SizedBox(height: 9),
                      LoginTextField(
                        controller: emailController,
                        icon: Icons.email_outlined,
                        hintText: 'example@email.com',
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 22),
                      const FieldLabel(text: 'รหัสผ่าน'),
                      const SizedBox(height: 9),
                      LoginTextField(
                        controller: passwordController,
                        icon: Icons.lock_outline,
                        hintText: '123456',
                        obscureText: true,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => loginUser(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: isLoading ? null : loginUser,
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
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'ถัดไป',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'ยังไม่มีบัญชี? ',
                      style: TextStyle(
                        fontSize: 15,
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const RegisterPage(),
                          ),
                        );
                      },
                      child: const Text(
                        'สมัครสมาชิก',
                        style: TextStyle(
                          fontSize: 15,
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


class FieldLabel extends StatelessWidget {
  final String text;

  const FieldLabel({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 16,
          color: Colors.black,
          fontWeight: FontWeight.bold,
        ),
        children: const [
          TextSpan(text: ' *', style: TextStyle(color: Color(0xFFE64C3C))),
        ],
      ),
    );
  }
}

class LoginTextField extends StatefulWidget {
  final TextEditingController controller;
  final IconData icon;
  final String hintText;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;

  const LoginTextField({
    super.key,
    required this.controller,
    required this.icon,
    required this.hintText,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<LoginTextField> createState() => _LoginTextFieldState();
}

class _LoginTextFieldState extends State<LoginTextField> {
  late bool isHidden;

  @override
  void initState() {
    super.initState();
    isHidden = widget.obscureText;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xFFEAF6FD),
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon, size: 24, color: const Color(0xFF64B0D3)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 52,
            child: TextField(
              controller: widget.controller,
              keyboardType: widget.keyboardType,
              textInputAction: widget.textInputAction,
              onSubmitted: widget.onSubmitted,
              obscureText: isHidden,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: widget.hintText,
                hintStyle: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade400,
                  fontWeight: FontWeight.w600,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                suffixIcon: widget.obscureText
                    ? IconButton(
                        onPressed: () => setState(() => isHidden = !isHidden),
                        icon: Icon(
                          isHidden
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: Colors.grey.shade400,
                          size: 23,
                        ),
                      )
                    : null,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: BorderSide(color: Colors.grey.shade400),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                  borderSide: const BorderSide(
                    color: Color(0xFF8BC2F2),
                    width: 1.5,
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