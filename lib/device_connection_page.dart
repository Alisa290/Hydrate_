import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class DeviceConnectionPage extends StatefulWidget {
  const DeviceConnectionPage({super.key});

  @override
  State<DeviceConnectionPage> createState() =>
      _DeviceConnectionPageState();
}

class _DeviceConnectionPageState
    extends State<DeviceConnectionPage> {
  // ============================================================
  // FIREBASE
  // ============================================================

  static const String databaseUrl =
      'https://hydrate-smart-dc6b9-default-rtdb.asia-southeast1.firebasedatabase.app';

  static const String deviceId = 'bottle_001';

  late final FirebaseDatabase database;

  // ============================================================
  // STATE
  // ============================================================

  bool isLoading = true;
  bool isConnected = false;

  String? activeUserId;
  String? currentUserId;

  // ============================================================
  // INIT
  // ============================================================

  @override
  void initState() {
    super.initState();

    database = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: databaseUrl,
    );

    _checkConnection();
  }

  // ============================================================
  // ACTIVE USER REFERENCE
  // ============================================================

  DatabaseReference get _activeUserRef {
    return database.ref(
      'devices/$deviceId/active_user_id',
    );
  }

  // ============================================================
  // DAILY CONNECTION TIME
  // ============================================================

  bool _isAfterDailyCutoff([DateTime? now]) {
    final current = now ?? DateTime.now();
    return current.hour >= 21;
  }

  // ============================================================
  // CHECK CONNECTION
  // ============================================================

  Future<void> _checkConnection() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (!mounted) return;

      setState(() {
        currentUserId = null;
        activeUserId = null;
        isConnected = false;
        isLoading = false;
      });

      return;
    }

    currentUserId = user.uid;

    try {
      // หลัง 21:00 หาก active_user_id ยังเป็น UID ของบัญชีนี้
      // ให้ลบออกเพื่อให้สถานะตรงกับกติกาตัดการเชื่อมต่อรายวัน
      if (_isAfterDailyCutoff()) {
        final cutoffSnapshot =
            await _activeUserRef.get();

        String? cutoffUid;

        if (cutoffSnapshot.exists &&
            cutoffSnapshot.value != null) {
          cutoffUid =
              cutoffSnapshot.value.toString().trim();

          if (cutoffUid.isEmpty ||
              cutoffUid == 'null') {
            cutoffUid = null;
          }
        }

        if (cutoffUid == user.uid) {
          await _activeUserRef.remove();
        }
      }

      final snapshot =
          await _activeUserRef.get();

      String? uid;

      if (snapshot.exists &&
          snapshot.value != null) {
        uid = snapshot.value.toString().trim();

        if (uid.isEmpty ||
            uid == 'null') {
          uid = null;
        }
      }

      if (!mounted) return;

      setState(() {
        activeUserId = uid;

        isConnected =
            uid != null &&
            uid == user.uid;

        isLoading = false;
      });

      debugPrint('');
      debugPrint(
        '======================================',
      );
      debugPrint(
        'DEVICE CONNECTION STATUS',
      );
      debugPrint(
        'Current Firebase Auth UID = ${user.uid}',
      );
      debugPrint(
        'Bottle active UID = $uid',
      );
      debugPrint(
        'Connected to this account = $isConnected',
      );
      debugPrint(
        '======================================',
      );
    } catch (e, stack) {
      debugPrint(
        'Check connection error: $e',
      );
      debugPrint('$stack');

      if (!mounted) return;

      setState(() {
        isLoading = false;
        isConnected = false;
      });

      _showMessage(
        'ไม่สามารถตรวจสอบสถานะขวดได้',
      );
    }
  }

  // ============================================================
  // PAIR BOTTLE
  //
  // เมื่อกดเชื่อมต่อ
  //
  // devices
  //   └── bottle_001
  //       └── active_user_id: UID ของบัญชีปัจจุบัน
  //
  // ESP32 จะอ่าน UID ตรงนี้
  // แล้วส่งข้อมูลไปยัง
  //
  // users/{UID}/devices/bottle_001
  //
  // และ
  //
  // users/{UID}/water_history/...
  // ============================================================

  Future<void> _pairBottle() async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(
        'กรุณาเข้าสู่ระบบก่อนเชื่อมต่อขวด',
      );

      return;
    }

    if (_isAfterDailyCutoff()) {
      _showMessage(
        'สิ้นสุดเวลาการติดตามวันนี้แล้ว กรุณาเชื่อมต่อขวดใหม่ในวันถัดไป',
      );
      return;
    }

    if (!mounted) return;

    setState(() {
      isLoading = true;
    });

    try {
      await _activeUserRef.set(
        user.uid,
      );

      if (!mounted) return;

      setState(() {
        currentUserId = user.uid;
        activeUserId = user.uid;

        isConnected = true;
        isLoading = false;
      });

      debugPrint('');
      debugPrint(
        '======================================',
      );
      debugPrint(
        'BOTTLE PAIRED SUCCESSFULLY',
      );
      debugPrint(
        'Device ID = $deviceId',
      );
      debugPrint(
        'Active UID = ${user.uid}',
      );
      debugPrint(
        '======================================',
      );

      _showMessage(
        'เชื่อมต่อขวดสำเร็จ',
      );
    } catch (e, stack) {
      debugPrint(
        'Pair bottle error: $e',
      );
      debugPrint('$stack');

      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      _showMessage(
        'ไม่สามารถเชื่อมต่อขวดได้',
      );
    }
  }

  // ============================================================
  // DISCONNECT
  //
  // ลบ active_user_id เฉพาะเมื่อ
  // ขวดกำลังเชื่อมกับบัญชีปัจจุบันจริง ๆ
  //
  // ป้องกันบัญชีอื่นมาลบ connection
  // ============================================================

  Future<void> _disconnectBottle() async {
    final user =
        FirebaseAuth.instance.currentUser;

    if (user == null) {
      _showMessage(
        'ไม่พบบัญชีผู้ใช้',
      );

      return;
    }

    if (!mounted) return;

    setState(() {
      isLoading = true;
    });

    try {
      final snapshot =
          await _activeUserRef.get();

      String? firebaseUid;

      if (snapshot.exists &&
          snapshot.value != null) {
        firebaseUid =
            snapshot.value.toString().trim();

        if (firebaseUid.isEmpty ||
            firebaseUid == 'null') {
          firebaseUid = null;
        }
      }

      // --------------------------------------------------------
      // ขวดเชื่อมกับบัญชีนี้อยู่
      // --------------------------------------------------------

      if (firebaseUid == user.uid) {
        await _activeUserRef.remove();

        if (!mounted) return;

        setState(() {
          activeUserId = null;
          currentUserId = user.uid;

          isConnected = false;
          isLoading = false;
        });

        debugPrint('');
        debugPrint(
          '======================================',
        );
        debugPrint(
          'BOTTLE DISCONNECTED',
        );
        debugPrint(
          'UID = ${user.uid}',
        );
        debugPrint(
          '======================================',
        );

        _showMessage(
          'ยกเลิกการเชื่อมต่อขวดแล้ว',
        );

        return;
      }

      // --------------------------------------------------------
      // ขวดไม่ได้เชื่อมกับบัญชีนี้
      // --------------------------------------------------------

      if (!mounted) return;

      setState(() {
        activeUserId = firebaseUid;
        currentUserId = user.uid;

        isConnected = false;
        isLoading = false;
      });

      _showMessage(
        'บัญชีนี้ไม่ได้เชื่อมต่อกับขวด',
      );
    } catch (e, stack) {
      debugPrint(
        'Disconnect bottle error: $e',
      );
      debugPrint('$stack');

      if (!mounted) return;

      setState(() {
        isLoading = false;
      });

      _showMessage(
        'ไม่สามารถยกเลิกการเชื่อมต่อได้',
      );
    }
  }

  // ============================================================
  // CONFIRM DISCONNECT
  // ============================================================

  Future<void>
      _showDisconnectConfirmDialog() async {
    await showDialog<void>(
      context: context,
      barrierColor:
          Colors.black.withOpacity(0.35),
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(22),
          ),
          title: const Text(
            'ยกเลิกการเชื่อมต่อ',
            textAlign:
                TextAlign.center,
          ),
          content: const Text(
            'ต้องการยกเลิกการเชื่อมต่อขวดน้ำกับบัญชีนี้หรือไม่',
            textAlign:
                TextAlign.center,
          ),
          actionsAlignment:
              MainAxisAlignment.spaceEvenly,
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  dialogContext,
                );
              },
              child: const Text(
                'ยกเลิก',
              ),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(
                  dialogContext,
                );

                await _disconnectBottle();
              },
              child: const Text(
                'ยืนยัน',
                style: TextStyle(
                  color: Colors.red,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // MESSAGE
  // ============================================================

  void _showMessage(
    String message,
  ) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
        .hideCurrentSnackBar();

    ScaffoldMessenger.of(context)
        .showSnackBar(
      SnackBar(
        content: Text(
          message,
        ),
        behavior:
            SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // REFRESH
  // ============================================================

  Future<void> _refresh() async {
    if (!mounted) return;

    setState(() {
      isLoading = true;
    });

    await _checkConnection();
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(
    BuildContext context,
  ) {
    final screenWidth =
        MediaQuery.sizeOf(context).width;

    final bool isSmall =
        screenWidth < 390;

    return Scaffold(
      backgroundColor:
          const Color(0xFFEAF8FF),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: SingleChildScrollView(
            physics:
                const AlwaysScrollableScrollPhysics(),
            padding:
                EdgeInsets.fromLTRB(
              isSmall ? 16 : 26,
              isSmall ? 18 : 26,
              isSmall ? 16 : 26,
              40,
            ),
            child: Column(
              children: [
                // =================================================
                // HEADER
                // =================================================

                Row(
                  children: [
                    InkWell(
                      onTap: () {
                        Navigator.pop(
                          context,
                        );
                      },
                      borderRadius:
                          BorderRadius.circular(
                        100,
                      ),
                      child: Container(
                        width:
                            isSmall
                                ? 52
                                : 64,
                        height:
                            isSmall
                                ? 52
                                : 64,
                        decoration:
                            const BoxDecoration(
                          color:
                              Colors.white,
                          shape:
                              BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.arrow_back,
                          size:
                              isSmall
                                  ? 32
                                  : 38,
                          color:
                              const Color(
                            0xFF2678C7,
                          ),
                        ),
                      ),
                    ),

                    Expanded(
                      child: Text(
                        'เชื่อมต่อขวดน้ำ',
                        textAlign:
                            TextAlign.center,
                        style: TextStyle(
                          fontSize:
                              isSmall
                                  ? 26
                                  : 32,
                          fontWeight:
                              FontWeight.bold,
                          color:
                              const Color(
                            0xFF16324F,
                          ),
                        ),
                      ),
                    ),

                    SizedBox(
                      width:
                          isSmall
                              ? 52
                              : 64,
                    ),
                  ],
                ),

                SizedBox(
                  height:
                      isSmall
                          ? 28
                          : 38,
                ),

                // =================================================
                // DEVICE CARD
                // =================================================

                Container(
                  width:
                      double.infinity,
                  padding:
                      EdgeInsets.all(
                    isSmall
                        ? 22
                        : 30,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.white,
                    borderRadius:
                        BorderRadius.circular(
                      28,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black
                                .withOpacity(
                          0.12,
                        ),
                        blurRadius:
                            16,
                        offset:
                            const Offset(
                          4,
                          8,
                        ),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      // -------------------------------------------
                      // BOTTLE ICON
                      // -------------------------------------------

                      Container(
                        width:
                            isSmall
                                ? 110
                                : 130,
                        height:
                            isSmall
                                ? 110
                                : 130,
                        decoration:
                            const BoxDecoration(
                          color:
                              Color(
                            0xFFD9EEFF,
                          ),
                          shape:
                              BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.water_drop,
                          size:
                              isSmall
                                  ? 60
                                  : 72,
                          color:
                              const Color(
                            0xFF2678C7,
                          ),
                        ),
                      ),

                      SizedBox(
                        height:
                            isSmall
                                ? 20
                                : 26,
                      ),

                      const Text(
                        'Hydrate Smart Bottle',
                        textAlign:
                            TextAlign.center,
                        style:
                            TextStyle(
                          fontSize:
                              23,
                          fontWeight:
                              FontWeight.bold,
                          color:
                              Color(
                            0xFF16324F,
                          ),
                        ),
                      ),

                      const SizedBox(
                        height: 8,
                      ),

                      const Text(
                        deviceId,
                        style:
                            TextStyle(
                          fontSize:
                              16,
                          color:
                              Colors.grey,
                        ),
                      ),

                      SizedBox(
                        height:
                            isSmall
                                ? 26
                                : 34,
                      ),

                      // -------------------------------------------
                      // STATE
                      // -------------------------------------------

                      if (isLoading)
                        const Padding(
                          padding:
                              EdgeInsets.symmetric(
                            vertical:
                                30,
                          ),
                          child:
                              CircularProgressIndicator(
                            color:
                                Color(
                              0xFF2678C7,
                            ),
                          ),
                        )
                      else if (isConnected)
                        _buildConnectedState(
                          isSmall,
                        )
                      else
                        _buildDisconnectedState(
                          isSmall,
                        ),
                    ],
                  ),
                ),

                SizedBox(
                  height:
                      isSmall
                          ? 20
                          : 26,
                ),

                // =================================================
                // INFORMATION
                // =================================================

                Container(
                  width:
                      double.infinity,
                  padding:
                      EdgeInsets.all(
                    isSmall
                        ? 18
                        : 24,
                  ),
                  decoration:
                      BoxDecoration(
                    color:
                        Colors.white,
                    borderRadius:
                        BorderRadius.circular(
                      22,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color:
                            Colors.black
                                .withOpacity(
                          0.08,
                        ),
                        blurRadius:
                            12,
                        offset:
                            const Offset(
                          2,
                          6,
                        ),
                      ),
                    ],
                  ),
                  child: const Row(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        color:
                            Color(
                          0xFF2678C7,
                        ),
                      ),
                      SizedBox(
                        width: 12,
                      ),
                      Expanded(
                        child: Text(
                          'เมื่อเชื่อมต่อแล้ว ข้อมูลระดับน้ำจากขวดจะถูกบันทึกไว้ในบัญชีที่กำลังเชื่อมต่ออยู่',
                          style:
                              TextStyle(
                            fontSize:
                                15,
                            height:
                                1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // CONNECTED STATE
  // ============================================================

  Widget _buildConnectedState(
    bool isSmall,
  ) {
    return Column(
      children: [
        const Icon(
          Icons.check_circle,
          size: 52,
          color: Colors.green,
        ),

        const SizedBox(
          height: 10,
        ),

        const Text(
          'เชื่อมต่อแล้ว',
          style: TextStyle(
            fontSize:
                20,
            fontWeight:
                FontWeight.bold,
            color:
                Colors.green,
          ),
        ),

        const SizedBox(
          height: 8,
        ),

        Text(
          'ขวดน้ำกำลังส่งข้อมูลให้บัญชีนี้',
          textAlign:
              TextAlign.center,
          style: TextStyle(
            fontSize:
                isSmall
                    ? 14
                    : 16,
            color:
                Colors.grey.shade600,
          ),
        ),

        const SizedBox(
          height: 26,
        ),

        SizedBox(
          width:
              double.infinity,
          height: 54,
          child:
              OutlinedButton.icon(
            onPressed:
                _showDisconnectConfirmDialog,
            icon:
                const Icon(
              Icons.link_off,
            ),
            label:
                const Text(
              'ยกเลิกการเชื่อมต่อ',
            ),
            style:
                OutlinedButton.styleFrom(
              foregroundColor:
                  Colors.red,
              side:
                  const BorderSide(
                color:
                    Colors.red,
              ),
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // DISCONNECTED STATE
  // ============================================================

  Widget _buildDisconnectedState(
    bool isSmall,
  ) {
    final bool anotherUserConnected =
        activeUserId != null &&
        activeUserId!.isNotEmpty &&
        activeUserId != currentUserId;

    return Column(
      children: [
        Icon(
          anotherUserConnected
              ? Icons.sync_alt
              : Icons.link_off,
          size: 52,
          color:
              Colors.grey.shade500,
        ),

        const SizedBox(
          height: 10,
        ),

        Text(
          anotherUserConnected
              ? 'ขวดเชื่อมต่อกับบัญชีอื่นอยู่'
              : 'ยังไม่ได้เชื่อมต่อ',
          textAlign:
              TextAlign.center,
          style:
              const TextStyle(
            fontSize:
                20,
            fontWeight:
                FontWeight.bold,
          ),
        ),

        const SizedBox(
          height: 8,
        ),

        Text(
          anotherUserConnected
              ? 'หากกดเชื่อมต่อ ขวดจะเปลี่ยนมาส่งข้อมูลให้บัญชีนี้แทน'
              : 'เชื่อมต่อบัญชีของคุณกับ Hydrate Smart Bottle',
          textAlign:
              TextAlign.center,
          style: TextStyle(
            fontSize:
                isSmall
                    ? 14
                    : 16,
            height:
                1.5,
            color:
                Colors.grey.shade600,
          ),
        ),

        const SizedBox(
          height: 26,
        ),

        SizedBox(
          width:
              double.infinity,
          height: 54,
          child:
              ElevatedButton.icon(
            onPressed:
                _isAfterDailyCutoff()
                    ? null
                    : _pairBottle,
            icon:
                const Icon(
              Icons.link,
            ),
            label: Text(
              anotherUserConnected
                  ? 'เชื่อมต่อกับบัญชีนี้'
                  : 'เชื่อมต่อขวด',
            ),
            style:
                ElevatedButton.styleFrom(
              backgroundColor:
                  const Color(
                0xFF2678C7,
              ),
              foregroundColor:
                  Colors.white,
              elevation: 0,
              shape:
                  RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(
                  15,
                ),
              ),
              textStyle:
                  const TextStyle(
                fontSize:
                    17,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ),
        ),
      ],
    );
  }
}