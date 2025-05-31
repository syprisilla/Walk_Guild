import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // SystemChrome 사용을 위해 추가
import 'package:pedometer/pedometer.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hive/hive.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:camera/camera.dart';

import 'walk_session.dart';
import 'package:walk_guide/real_time_speed_service.dart';
import 'package:walk_guide/voice_guide_service.dart';

import './ObjectDetection/object_detection_view.dart';

import 'package:walk_guide/user_profile.dart';

class StepCounterPage extends StatefulWidget {
  final void Function(double Function())? onInitialized;
  final List<CameraDescription> cameras;

  const StepCounterPage({
    super.key,
    this.onInitialized,
    required this.cameras,
  });

  @override
  State<StepCounterPage> createState() => _StepCounterPageState();
}

// WidgetsBindingObserver를 mixin으로 추가
class _StepCounterPageState extends State<StepCounterPage> with WidgetsBindingObserver {
  late UserProfile _userProfile;
  late Stream<StepCount> _stepCountStream;
  StreamSubscription<StepCount>? _stepCountSubscription;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  Timer? _checkTimer;
  late FlutterTts flutterTts;

  int _steps = 0;
  int? _initialSteps;
  int? _previousSteps;
  DateTime? _startTime;
  DateTime? _lastMovementTime;
  DateTime? _lastGuidanceTime;

  bool _isMoving = false;
  List<WalkSession> _sessionHistory = [];

  static const double movementThreshold = 1.5;
  bool _isDisposed = false;

  // 카메라 관련 상태 변수 (ObjectDetectionView가 내부적으로 관리하지만, 여기서도 필요할 수 있음)
  CameraController? _cameraController; // StepCounterPage에서 직접 제어하지 않는다면 ObjectDetectionView 내부 것으로 충분
  bool _isCameraInitialized = false; // ObjectDetectionView의 초기화 상태를 알기 어려우므로 일단 가정

  @override
  void initState() {
    super.initState();
    _isDisposed = false;
    WidgetsBinding.instance.addObserver(this); // 생명주기 옵저버 등록

    _setLandscapeMode(); // 화면을 가로 모드로 설정

    flutterTts = FlutterTts();
    flutterTts.setSpeechRate(0.5);
    flutterTts.setLanguage("ko-KR");

    requestPermission(); // 권한 요청 및 관련 스트림 시작
    loadSessions();

    final box = Hive.box<WalkSession>('walk_sessions');
    final sessions = box.values.toList();
    _userProfile = UserProfile.fromSessions(sessions);

    widget.onInitialized?.call(() => RealTimeSpeedService.getSpeed());

    // StepCounterPage가 활성화될 때 _isCameraInitialized는 ObjectDetectionView의 상태를 따르지만,
    // didChangeAppLifecycleState에서 카메라 재시작 등을 위해 이 페이지 레벨에서도 카메라 상태를 추적하는 것이 좋을 수 있습니다.
    // 다만, 현재 ObjectDetectionView가 자체적으로 카메라를 관리하므로,
    // 여기서는 주로 화면 방향과 앱 생명주기에 따른 최상위 로직만 처리합니다.
    // ObjectDetectionView 내부의 _isCameraInitialized 상태를 가져올 수 있다면 더 정확한 제어가 가능합니다.
    // 지금은 ObjectDetectionView가 정상적으로 카메라를 초기화한다고 가정합니다.
    if (widget.cameras.isNotEmpty) {
        _isCameraInitialized = true; // 일단 카메라가 있다고 가정하고 시작
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this); // 생명주기 옵저버 제거

    _setPortraitMode(); // 화면 방향을 세로 모드(또는 앱 기본값)로 복구

    _stepCountSubscription?.cancel();
    _accelerometerSubscription?.cancel();
    _checkTimer?.cancel();
    flutterTts.stop();
    // _cameraController?.dispose(); // 만약 이 페이지에서 직접 카메라 컨트롤러를 생성했다면 해제
    super.dispose();
    print("StepCounterPage disposed");
  }

  // 앱 생명주기 변경 감지
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (_isDisposed) return;

    // ObjectDetectionView의 카메라 컨트롤러에 직접 접근할 수 없으므로,
    // 화면 방향 설정과 같은 최상위 레벨의 동작만 수행합니다.
    // ObjectDetectionView는 자체적으로 카메라 스트림을 재시작하거나 중지해야 합니다.
    // (CameraController의 생명주기에 따라 자동으로 처리될 수도 있음)

    switch (state) {
      case AppLifecycleState.resumed:
        // 앱이 다시 활성화될 때
        print("StepCounterPage: App Resumed");
        _setLandscapeMode(); // 화면 방향을 다시 가로로 설정
        // ObjectDetectionView가 카메라 스트림을 자동으로 재개하지 않는다면,
        // 여기서 ObjectDetectionView에 재개 신호를 보내는 로직이 필요할 수 있습니다.
        // 또는 ObjectDetectionView 내부에서 AppLifecycleState를 감지하여 처리하도록 합니다.
        // 현재로서는 화면 방향만 재설정합니다.
        // 만약 카메라가 멈췄다면, 사용자가 카메라 관련 기능을 다시 시도해야 할 수 있습니다.
        // 더 나은 방법은 ObjectDetectionView가 controller를 통해 노출하여 여기서 제어하거나,
        // ObjectDetectionView 내부에서 생명주기를 처리하는 것입니다.
        // 일단 _initializeCamera 로직을 호출하는 것으로 가정 (ObjectDetectionView가 아니라 여기서 제어한다면)
        if (_isCameraInitialized && widget.cameras.isNotEmpty) {
             // 여기서 카메라를 직접 재시작해야 한다면 관련 로직 추가
             // 예: _objectDetectionViewStateKey.currentState?.restartCameraStream(); (만약 GlobalKey 사용 시)
             // 지금은 ObjectDetectionView가 스스로 처리하거나, CameraController가 resume시 자동 처리되길 기대
             print("StepCounterPage: Resumed - Ensuring landscape and hoping camera is active.");
        }
        break;
      case AppLifecycleState.inactive:
        // 앱이 비활성화될 때 (예: 전화 수신 등)
        print("StepCounterPage: App Inactive");
        // ObjectDetectionView가 카메라 스트림을 자동으로 일시 중지하지 않는다면 신호 필요
        // _cameraController?.stopImageStream(); // 직접 제어 시
        break;
      case AppLifecycleState.paused:
        // 앱이 백그라운드로 전환될 때
        print("StepCounterPage: App Paused");
        // ObjectDetectionView가 카메라 스트림을 자동으로 중지하지 않는다면 신호 필요
        // _cameraController?.stopImageStream(); // 직접 제어 시
        // 화면 방향은 그대로 유지하거나, 필요시 여기서도 _setPortraitMode() 호출 고려 (dispose와 중복될 수 있음)
        break;
      case AppLifecycleState.detached:
        // Flutter 엔진은 아직 실행 중이지만, View가 없는 상태
        print("StepCounterPage: App Detached");
        break;
      default:
        break;
    }
  }

  // 화면을 가로 모드로 설정하는 함수
  void _setLandscapeMode() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    print("StepCounterPage: Set to Landscape Mode");
  }

  // 화면을 세로 모드(또는 앱 기본 설정)로 복구하는 함수
  void _setPortraitMode() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    // 또는 모든 방향 허용:
    // SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    print("StepCounterPage: Set to Portrait Mode");
  }


  void _handleDetectedObjects(List<DetectedObjectInfo> objectsInfo) {
    if (!mounted || _isDisposed) return;
    if (objectsInfo.isNotEmpty) {
      final DetectedObjectInfo firstObjectInfo = objectsInfo.first;
      guideWhenObjectDetected(firstObjectInfo);
    }
  }

  Future<void> requestPermission() async {
    var status = await Permission.activityRecognition.status;
    if (!status.isGranted) {
      status = await Permission.activityRecognition.request();
    }

    if (status.isGranted) {
      if (!Hive.isBoxOpen('recent_steps')) {
        await Hive.openBox<DateTime>('recent_steps');
        debugPrint(" Hive 'recent_steps' 박스 열림 완료");
      }
      startPedometer();
      startAccelerometer();
      startCheckingMovement();
    } else {
      if (context.mounted && !_isDisposed) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('권한 필요'),
            content: const Text('걸음 측정을 위해 활동 인식 권한을 허용해 주세요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    }
  }

  void startPedometer() {
    if (_isDisposed) return;
    _stepCountSubscription?.cancel();
    _stepCountStream = Pedometer.stepCountStream;
    _stepCountSubscription = _stepCountStream.listen(
      onStepCount,
      onError: onStepCountError,
      cancelOnError: true,
    );
  }

  void startAccelerometer() {
    if (_isDisposed) return;
    _accelerometerSubscription?.cancel();
    _accelerometerSubscription = accelerometerEvents.listen((event) {
      if (_isDisposed || !mounted) return;
      double totalAcceleration =
          sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      double movement = (totalAcceleration - 9.8).abs();

      if (movement > movementThreshold) {
        _lastMovementTime = DateTime.now();
        if (!_isMoving) {
          if (mounted && !_isDisposed) {
            setState(() {
              _isMoving = true;
            });
          }
          debugPrint("움직임 감지!");
        }
      }
    });
  }

  Duration getGuidanceDelay(double avgSpeed) {
    if (avgSpeed < 0.5) {
      return const Duration(seconds: 2);
    } else if (avgSpeed < 1.2) {
      return const Duration(milliseconds: 1500);
    } else {
      return const Duration(seconds: 1);
    }
  }

  void guideWhenObjectDetected(DetectedObjectInfo objectInfo) async {
    if (_isDisposed) return;
    final now = DateTime.now();
    if (_lastGuidanceTime != null &&
        now.difference(_lastGuidanceTime!).inSeconds < 3) {
      debugPrint("⏳ 쿨다운 중 - 음성 안내 생략 (마지막 안내: $_lastGuidanceTime)");
      return;
    }

    bool voiceEnabled = await isVoiceGuideEnabled();
    if (!voiceEnabled) {
      debugPrint("🔇 음성 안내 비활성화됨 - 안내 생략");
      return;
    }

    final delay = getGuidanceDelay(_userProfile.avgSpeed);

    String locationDesc = objectInfo.horizontalLocationDescription;
    String sizeDesc = objectInfo.sizeDescription;

    String message = "$locationDesc 에";
    if (sizeDesc.isNotEmpty) {
      message += " $sizeDesc 크기의";
    }
    message += " 장애물이 있습니다. 주의하세요.";

    debugPrint("🕒 ${delay.inMilliseconds}ms 후 안내 예정... TTS 메시지: $message");

    await Future.delayed(delay);
    if (_isDisposed) return;

    await flutterTts.speak(message);
    debugPrint("🔊 안내 완료: $message");
    _lastGuidanceTime = DateTime.now();
  }

  void onStepCount(StepCount event) async {
    if (!mounted || _isDisposed) return;

    debugPrint(
        "걸음 수 이벤트 발생: ${event.steps}, 현재 _steps: $_steps, _initialSteps: $_initialSteps, _previousSteps: $_previousSteps");

    if (_initialSteps == null) {
      _initialSteps = event.steps;
      _previousSteps = event.steps;
      _startTime = DateTime.now();
      _lastMovementTime = DateTime.now();
      RealTimeSpeedService.clear(delay: true);
      _steps = 0;
      if (mounted && !_isDisposed) {
        setState(() {});
      }
      debugPrint("세션 시작: _initialSteps = $_initialSteps, _steps = $_steps");
      return;
    }

    int currentPedometerSteps = event.steps;
    int stepDelta =
        currentPedometerSteps - (_previousSteps ?? currentPedometerSteps);

    if (stepDelta > 0) {
      _steps += stepDelta;
      final baseTime = DateTime.now();
      for (int i = 0; i < stepDelta; i++) {
        await RealTimeSpeedService.recordStep(
          baseTime.add(Duration(milliseconds: i * 100)),
        );
      }
      _lastMovementTime = DateTime.now();
      if (mounted && !_isDisposed) {
        setState(() {});
      }
    }
    _previousSteps = currentPedometerSteps;
    debugPrint(
        "걸음 업데이트: stepDelta = $stepDelta, _steps = $_steps, _previousSteps = $_previousSteps");
  }

  void onStepCountError(error) {
    if (_isDisposed) return;
    debugPrint('걸음 수 측정 오류: $error');
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted && !_isDisposed) {
        debugPrint('걸음 측정 재시도...');
        startPedometer();
      }
    });
  }

  double getAverageSpeed() {
    if (_startTime == null || _steps == 0) return 0;
    final durationInSeconds = DateTime.now().difference(_startTime!).inSeconds;
    if (durationInSeconds == 0) return 0;
    double stepLength = 0.7;
    double distanceInMeters = _steps * stepLength;
    return distanceInMeters / durationInSeconds;
  }

  double getRealTimeSpeed() {
    return RealTimeSpeedService.getSpeed();
  }

  void _saveSessionData() {
    if (_isDisposed) return;
    if (_startTime == null || _steps == 0) {
      debugPrint("세션 저장 스킵: 시작 시간이 없거나 걸음 수가 0입니다.");
      _initialSteps = null;
      _previousSteps = null;
      _steps = 0;
      _startTime = null;
      RealTimeSpeedService.clear(delay: true);
      if (mounted && !_isDisposed) setState(() {});
      return;
    }

    final endTime = DateTime.now();
    final session = WalkSession(
      startTime: _startTime!,
      endTime: endTime,
      stepCount: _steps,
      averageSpeed: getAverageSpeed(),
    );

    _sessionHistory.insert(0, session);
    if (_sessionHistory.length > 20) {
      _sessionHistory.removeLast();
    }

    final box = Hive.box<WalkSession>('walk_sessions');
    box.add(session);

    debugPrint("🟢 저장된 세션: $session");
    debugPrint("💾 Hive에 저장된 세션 수: ${box.length}");

    analyzeWalkingPattern();

    _steps = 0;
    _initialSteps = null;
    _previousSteps = null;
    _startTime = null;
    RealTimeSpeedService.clear(delay: true);
    if (mounted && !_isDisposed) setState(() {});
  }

  void startCheckingMovement() {
    if (_isDisposed) return;
    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || _isDisposed) {
        timer.cancel();
        return;
      }
      if (_lastMovementTime != null && _isMoving) {
        final diff =
            DateTime.now().difference(_lastMovementTime!).inMilliseconds;
        if (diff >= 2000) {
          if (mounted && !_isDisposed) {
            setState(() {
              _isMoving = false;
            });
          }
          debugPrint("정지 감지 (2초 이상 움직임 없음)!");
          _saveSessionData();
        }
      } else if (_lastMovementTime == null && _isMoving) {
        if (mounted && !_isDisposed) {
          setState(() {
            _isMoving = false;
          });
        }
      } else if (_isMoving && _startTime == null) {
        if (mounted && !_isDisposed) {
          setState(() {
            _isMoving = false;
          });
        }
      }
    });
  }

  void loadSessions() {
    if (_isDisposed) return;
    final box = Hive.box<WalkSession>('walk_sessions');
    final loadedSessions = box.values.toList();
    loadedSessions.sort((a, b) => b.startTime.compareTo(a.startTime));

    if (mounted && !_isDisposed) {
      setState(() {
        _sessionHistory = loadedSessions;
      });
    } else if (!_isDisposed) {
      _sessionHistory = loadedSessions;
    }
    debugPrint("📦 불러온 세션 수: ${_sessionHistory.length}");
    analyzeWalkingPattern();
  }

  void analyzeWalkingPattern() {
    if (_isDisposed || _sessionHistory.isEmpty) {
      debugPrint("⚠️ 보행 데이터가 없어 패턴 분석을 건너뜁니다.");
      return;
    }

    double totalSpeed = 0;
    int totalSteps = 0;
    int totalDurationSeconds = 0;

    for (var session in _sessionHistory) {
      totalSpeed += session.averageSpeed;
      totalSteps += session.stepCount;
      totalDurationSeconds +=
          session.endTime.difference(session.startTime).inSeconds;
    }

    int sessionCount = _sessionHistory.length;
    double overallAvgSpeed = sessionCount > 0 ? totalSpeed / sessionCount : 0;
    double avgStepsPerSession =
        sessionCount > 0 ? totalSteps / sessionCount.toDouble() : 0;
    double avgDurationPerSessionSeconds =
        sessionCount > 0 ? totalDurationSeconds / sessionCount.toDouble() : 0;

    debugPrint("📊 보행 패턴 분석 결과:");
    debugPrint("- 전체 평균 속도: ${overallAvgSpeed.toStringAsFixed(2)} m/s");
    debugPrint("- 세션 당 평균 걸음 수: ${avgStepsPerSession.toStringAsFixed(1)} 걸음");
    debugPrint(
        "- 세션 당 평균 시간: ${(avgDurationPerSessionSeconds / 60).toStringAsFixed(1)} 분 (${avgDurationPerSessionSeconds.toStringAsFixed(1)} 초)");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('보행 중'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_isMoving && _startTime != null && _steps > 0) {
              _saveSessionData();
            } else {
              _initialSteps = null;
              _previousSteps = null;
              _steps = 0;
              _startTime = null;
              RealTimeSpeedService.clear(delay: false);
            }
            // dispose에서 화면 방향 복구가 호출될 것이므로 여기서 별도 처리 안 함
            Navigator.of(context).pop();
          },
        ),
      ),
      body: PopScope(
        canPop: false,
        onPopInvoked: (didPop) {
          if (didPop) return;
          if (_isMoving && _startTime != null && _steps > 0) {
            _saveSessionData();
          } else {
            _initialSteps = null;
            _previousSteps = null;
            _steps = 0;
            _startTime = null;
            RealTimeSpeedService.clear(delay: false);
          }
          // dispose에서 화면 방향 복구가 호출될 것이므로 여기서 별도 처리 안 함
          Navigator.of(context).pop();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: (widget.cameras.isNotEmpty)
                  ? ObjectDetectionView(
                      cameras: widget.cameras,
                      onObjectsDetected: _handleDetectedObjects,
                      resolutionPreset: ResolutionPreset.high,
                    )
                  : Container(
                      width: double.infinity,
                      height: double.infinity,
                      color: Colors.grey[200],
                      alignment: Alignment.center,
                      child: const Text(
                        '카메라를 사용할 수 없습니다.\n앱 권한을 확인해주세요.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 16, color: Colors.redAccent),
                      ),
                    ),
            ),
            Positioned(
                top: 20,
                left: 0,
                right: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: 8.0, horizontal: 12.0),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.25),
                          spreadRadius: 2,
                          blurRadius: 5,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                _isMoving ? '🚶 보행 중' : '🛑 정지 상태',
                                style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '$_steps 걸음',
                                style: const TextStyle(
                                    fontSize: 20,
                                    color: Colors.amberAccent,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 50,
                          width: 1,
                          color: Colors.white30,
                          margin: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text('평균 속도',
                                  style: TextStyle(
                                      fontSize: 14, color: Colors.white70)),
                              const SizedBox(height: 2),
                              Text(
                                '${getAverageSpeed().toStringAsFixed(2)} m/s',
                                style: const TextStyle(
                                    fontSize: 18,
                                    color: Colors.lightGreenAccent,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 6),
                              const Text('실시간 속도',
                                  style: TextStyle(
                                      fontSize: 14, color: Colors.white70)),
                              const SizedBox(height: 2),
                              Text(
                                '${getRealTimeSpeed().toStringAsFixed(2)} m/s',
                                style: const TextStyle(
                                    fontSize: 18,
                                    color: Colors.cyanAccent,
                                    fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                )),
            if (_sessionHistory.isNotEmpty)
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Opacity(
                  opacity: 0.9,
                  child: Container(
                    height: 160,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Colors.blueGrey[800],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.black38)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            "최근 보행 기록",
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Colors.white),
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _sessionHistory.length > 5
                                ? 5
                                : _sessionHistory.length,
                            itemBuilder: (context, index) {
                              final session = _sessionHistory[index];
                              return Card(
                                color: Colors.blueGrey[700],
                                margin: const EdgeInsets.symmetric(vertical: 3.0),
                                child: Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Text(
                                    '${index + 1}) ${session.stepCount}걸음, 평균 ${session.averageSpeed.toStringAsFixed(2)} m/s (${(session.endTime.difference(session.startTime).inSeconds / 60).toStringAsFixed(1)}분)',
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.white),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              Positioned(
                  bottom: 20,
                  left: 20,
                  right: 20,
                  child: Opacity(
                    opacity: 0.9,
                    child: Container(
                      height: 80,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                          color: Colors.blueGrey[800],
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.black38)),
                      alignment: Alignment.center,
                      child: const Text(
                        "아직 보행 기록이 없습니다.",
                        style: TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}