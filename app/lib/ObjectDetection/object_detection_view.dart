import 'dart:async';
import 'dart:io'; // Platform 사용을 위해 추가
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'mlkit_object_detection.dart';
import 'object_painter.dart';
import 'camera_screen.dart' show IsolateDataHolder; // IsolateDataHolder 경로 확인

// 객체의 가로 위치를 나타내는 열거형
enum ObjectHorizontalLocation { left, center, right, unknown }

// 객체의 크기 범주를 나타내는 열거형 (기존 위치에 이미 정의되어 있을 수 있음)
enum ObjectSizeCategory { small, medium, large, unknown }

class DetectedObjectInfo {
  final DetectedObject object;
  final ObjectSizeCategory sizeCategory;
  final ObjectHorizontalLocation horizontalLocation; // 위치 정보 필드 추가
  final Rect boundingBox;
  final String? label;

  DetectedObjectInfo({
    required this.object,
    required this.sizeCategory,
    required this.horizontalLocation, // 생성자에 추가
    required this.boundingBox,
    this.label,
  });

  String get sizeDescription {
    switch (sizeCategory) {
      case ObjectSizeCategory.small:
        return "작은";
      case ObjectSizeCategory.medium:
        return "중간";
      case ObjectSizeCategory.large:
        return "큰";
      default:
        return "";
    }
  }

  // 위치 설명을 반환하는 getter
  String get horizontalLocationDescription {
    switch (horizontalLocation) {
      case ObjectHorizontalLocation.left:
        return "좌측 전방";
      case ObjectHorizontalLocation.center:
        return "전방"; // 또는 "전방"으로 해석될 수 있음
      case ObjectHorizontalLocation.right:
        return "우측 전방";
      default:
        return "전방"; // 기본값 또는 위치 불명확 시
    }
  }
}


class ObjectDetectionView extends StatefulWidget {
  final List<CameraDescription> cameras;
  final Function(List<DetectedObjectInfo> objectsInfo)? onObjectsDetected;
  final ResolutionPreset resolutionPreset;

  const ObjectDetectionView({
    Key? key,
    required this.cameras,
    this.onObjectsDetected,
    this.resolutionPreset = ResolutionPreset.high,
  }) : super(key: key);

  @override
  _ObjectDetectionViewState createState() => _ObjectDetectionViewState();
}

class _ObjectDetectionViewState extends State<ObjectDetectionView> {
  CameraController? _cameraController;
  int _cameraIndex = 0;
  bool _isCameraInitialized = false;
  bool _isBusy = false;
  List<DetectedObjectInfo> _processedObjects = [];
  InputImageRotation? _imageRotation;
  late ObjectDetector _objectDetector;
  Size? _lastImageSize;
  Size? _screenSize; // 화면 크기를 저장할 변수

  Isolate? _objectDetectionIsolate;
  Isolate? _imageRotationIsolate;
  late ReceivePort _objectDetectionReceivePort;
  late ReceivePort _imageRotationReceivePort;
  SendPort? _objectDetectionIsolateSendPort;
  SendPort? _imageRotationIsolateSendPort;
  StreamSubscription? _objectDetectionSubscription;
  StreamSubscription? _imageRotationSubscription;

  bool _isWaitingForRotation = false;
  bool _isWaitingForDetection = false;
  InputImageRotation? _lastCalculatedRotation;
  Uint8List? _pendingImageDataBytes;
  int? _pendingImageDataWidth;
  int? _pendingImageDataHeight;
  int? _pendingImageDataFormatRaw;
  int? _pendingImageDataBytesPerRow;

  String? _initializationErrorMsg;
  Orientation? _currentDeviceOrientation;

  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _isDisposed = false;
    if (widget.cameras.isEmpty) {
      if (mounted && !_isDisposed) {
        setState(() {
          _initializationErrorMsg = "사용 가능한 카메라가 없습니다.\n앱 권한을 확인하거나 재시작해주세요.";
        });
      }
      return;
    }
    _objectDetector = initializeObjectDetector();
    print("ObjectDetectionView: Main isolate ObjectDetector initialized.");

    _spawnIsolates().then((success) {
      if (!success) {
        if (mounted && !_isDisposed) {
          setState(() {
            _initializationErrorMsg = "백그라운드 작업 초기화에 실패했습니다.";
          });
        }
        return;
      }
      if (widget.cameras.isNotEmpty) {
        _initializeCamera(widget.cameras[_cameraIndex]);
      }
    }).catchError((e, stacktrace) {
      print("****** ObjectDetectionView initState (_spawnIsolates catchError): $e\n$stacktrace");
      if (mounted && !_isDisposed) {
        setState(() {
          _initializationErrorMsg = "초기화 중 예상치 못한 오류 발생:\n$e";
        });
      }
    });
  }

  @override
  void dispose() {
    print("****** ObjectDetectionView: Dispose called.");
    _isDisposed = true;

    Future.microtask(() async {
      await _stopCameraStream();

      await _objectDetectionSubscription?.cancel();
      _objectDetectionSubscription = null;
      await _imageRotationSubscription?.cancel();
      _imageRotationSubscription = null;
      print("****** ObjectDetectionView: Subscriptions cancelled.");

      try {
        _objectDetectionReceivePort.close();
        print("****** ObjectDetectionView: Object detection receive port closed.");
      } catch (e) {
        print("****** ObjectDetectionView: Error closing object detection receive port: $e");
      }
      try {
        _imageRotationReceivePort.close();
        print("****** ObjectDetectionView: Image rotation receive port closed.");
      } catch (e) {
        print("****** ObjectDetectionView: Error closing image rotation receive port: $e");
      }

      _killIsolates();

      try {
        await _cameraController?.dispose();
        print("****** ObjectDetectionView: CameraController disposed.");
      } catch (e, stacktrace) {
        print('****** ObjectDetectionView: Error disposing CameraController: $e\n$stacktrace');
      }
      _cameraController = null;

      try {
        await _objectDetector.close();
        print("****** ObjectDetectionView: Main ObjectDetector closed.");
      } catch (e, stacktrace) {
        print('****** ObjectDetectionView: Error closing main ObjectDetector: $e\n$stacktrace');
      }
    });

    super.dispose();
    print("****** ObjectDetectionView: Dispose completed for super.");
  }

  Future<bool> _spawnIsolates() async {
    final RootIsolateToken? rootIsolateToken = RootIsolateToken.instance;
    if (rootIsolateToken == null) {
      print("****** ObjectDetectionView: RootIsolateToken is null. Cannot spawn isolates.");
      return false;
    }

    try {
      _objectDetectionReceivePort = ReceivePort();
      _objectDetectionIsolate = await Isolate.spawn(
          detectObjectsIsolateEntry,
          IsolateDataHolder(_objectDetectionReceivePort.sendPort, rootIsolateToken),
          onError: _objectDetectionReceivePort.sendPort,
          onExit: _objectDetectionReceivePort.sendPort,
          debugName: "ObjectDetectionIsolate_View");
      _objectDetectionSubscription = _objectDetectionReceivePort.listen(_handleDetectionResult);
      print("****** ObjectDetectionView: ObjectDetectionIsolate spawned.");

      _imageRotationReceivePort = ReceivePort();
      _imageRotationIsolate = await Isolate.spawn(
          getImageRotationIsolateEntry, _imageRotationReceivePort.sendPort,
          onError: _imageRotationReceivePort.sendPort,
          onExit: _imageRotationReceivePort.sendPort,
          debugName: "ImageRotationIsolate_View");
      _imageRotationSubscription = _imageRotationReceivePort.listen(_handleRotationResult);
      print("****** ObjectDetectionView: ImageRotationIsolate spawned.");
      return true;
    } catch (e, stacktrace) {
      print("****** ObjectDetectionView: Failed to spawn isolates: $e\n$stacktrace");
      _initializationErrorMsg = "백그라운드 작업 생성 실패: $e";
      if(mounted && !_isDisposed) setState(() {});
      return false;
    }
  }

  void _killIsolates() {
    if (_objectDetectionIsolateSendPort != null && !_isDisposed) {
        _objectDetectionIsolateSendPort!.send('shutdown');
        print("****** ObjectDetectionView: Sent 'shutdown' to DetectionIsolate.");
    } else {
      _objectDetectionIsolate?.kill(priority: Isolate.immediate);
      _objectDetectionIsolate = null;
      print("****** ObjectDetectionView: DetectionIsolate killed (no SendPort or already disposed).");
    }
    _objectDetectionIsolateSendPort = null;

    if (_imageRotationIsolateSendPort != null && !_isDisposed) {
        _imageRotationIsolateSendPort!.send('shutdown');
        print("****** ObjectDetectionView: Sent 'shutdown' to RotationIsolate.");
    } else {
      _imageRotationIsolate?.kill(priority: Isolate.immediate);
      _imageRotationIsolate = null;
      print("****** ObjectDetectionView: RotationIsolate killed (no SendPort or already disposed).");
    }
    _imageRotationIsolateSendPort = null;
  }

  void _handleDetectionResult(dynamic message) {
    if (_isDisposed || !mounted) return;

    if (message == 'isolate_shutdown_ack_detection') {
        print("****** ObjectDetectionView: Detection isolate acknowledged shutdown. Killing now.");
        _objectDetectionIsolate?.kill(priority: Isolate.immediate);
        _objectDetectionIsolate = null;
        return;
    }

    if (_objectDetectionIsolateSendPort == null && message is SendPort) {
      _objectDetectionIsolateSendPort = message;
      print("****** ObjectDetectionView: ObjectDetectionIsolate SendPort received.");
    } else if (message is List<DetectedObject>) {
      List<DetectedObjectInfo> newProcessedObjects = [];

      if (message.isNotEmpty && _lastImageSize != null && _screenSize != null && _imageRotation != null && _cameraController != null) {
        DetectedObject largestMlKitObject = message.reduce((curr, next) {
          final double areaCurr = curr.boundingBox.width * curr.boundingBox.height;
          final double areaNext = next.boundingBox.width * next.boundingBox.height;
          return areaCurr > areaNext ? curr : next;
        });

        final Rect displayRect = _calculateDisplayRect(
          mlKitBoundingBox: largestMlKitObject.boundingBox,
          originalImageSize: _lastImageSize!,
          canvasSize: _screenSize!,
          imageRotation: _imageRotation!,
          cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
          cameraPreviewAspectRatio: _cameraController!.value.aspectRatio,
        );

        ObjectSizeCategory sizeCategory = ObjectSizeCategory.unknown;
        if (_screenSize!.width > 0 && _screenSize!.height > 0) {
            final double screenArea = _screenSize!.width * _screenSize!.height;
            final double objectArea = displayRect.width * displayRect.height;
            if (screenArea > 0) {
                final double areaRatio = objectArea / screenArea;
                if (areaRatio > 0.20) { // 20% 이상 차지하면 large
                    sizeCategory = ObjectSizeCategory.large;
                } else if (areaRatio > 0.05) { // 5% 이상 차지하면 medium
                    sizeCategory = ObjectSizeCategory.medium;
                } else if (areaRatio > 0.005) { // 0.5% 이상 차지하면 small
                    sizeCategory = ObjectSizeCategory.small;
                }
            }
        }
        
        // 객체의 화면상 가로 위치 판단 로직 추가
        ObjectHorizontalLocation horizontalLocation = ObjectHorizontalLocation.unknown;
        if (_screenSize!.width > 0 && displayRect.width > 0 && displayRect.height > 0) {
            final double screenWidth = _screenSize!.width;
            // 카메라 프리뷰 영역을 기준으로 3등분
            // _calculateDisplayRect에서 반환된 displayRect는 이미 전체 스크린 기준의 좌표이므로,
            // _screenSize!.width를 사용해도 무방.
            // 만약 카메라 프리뷰가 화면 전체를 채우지 않는다면, 
            // 카메라 프리뷰 영역(cameraViewRect)을 기준으로 계산해야 함.
            // 여기서는 _calculateDisplayRect가 이미 cameraViewRect를 고려하여 최종 displayRect를 반환한다고 가정.

            final double leftBoundary = screenWidth / 3.0;
            final double rightBoundary = screenWidth * (2.0 / 3.0);
            final double objectCenterX = displayRect.center.dx;

            if (objectCenterX < leftBoundary) {
                horizontalLocation = ObjectHorizontalLocation.left;
            } else if (objectCenterX < rightBoundary) {
                horizontalLocation = ObjectHorizontalLocation.center;
            } else {
                horizontalLocation = ObjectHorizontalLocation.right;
            }
        }
        
        final String? mainLabel = largestMlKitObject.labels.isNotEmpty ? largestMlKitObject.labels.first.text : null;

        newProcessedObjects.add(DetectedObjectInfo(
          object: largestMlKitObject,
          sizeCategory: sizeCategory,
          horizontalLocation: horizontalLocation, // 위치 정보 전달
          boundingBox: displayRect, // 화면에 그려질 최종 바운딩 박스
          label: mainLabel,
        ));
      }

      _isWaitingForDetection = false;
      if (mounted && !_isDisposed) {
        setState(() {
          _processedObjects = newProcessedObjects;
        });
      }
      widget.onObjectsDetected?.call(newProcessedObjects);

      if (!_isWaitingForRotation && !_isWaitingForDetection && _isBusy) {
        _isBusy = false;
      }
    } else if (message is List && message.length == 2 && message[0] is String && message[0].toString().contains('Error')) {
      print('****** ObjectDetectionView: Detection Isolate Error: ${message[1]}');
      if (mounted && !_isDisposed) setState(() => _processedObjects = []);
      widget.onObjectsDetected?.call([]);
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    } else if (message == null || (message is List && message.isEmpty && message is! List<DetectedObject>)) {
      print('****** ObjectDetectionView: Detection Isolate exited or sent empty/null message ($message).');
      if (mounted && !_isDisposed) setState(() => _processedObjects = []);
      widget.onObjectsDetected?.call([]);
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    } else {
      print('****** ObjectDetectionView: Unexpected message from Detection Isolate: ${message.runtimeType} - $message');
      if (mounted && !_isDisposed) setState(() => _processedObjects = []);
      widget.onObjectsDetected?.call([]);
      _isWaitingForDetection = false;
      if (!_isWaitingForRotation && _isBusy) _isBusy = false;
    }
  }

  Rect _calculateDisplayRect({
    required Rect mlKitBoundingBox,
    required Size originalImageSize,
    required Size canvasSize, // CustomPaint가 그려지는 전체 화면 또는 영역 크기
    required InputImageRotation imageRotation,
    required CameraLensDirection cameraLensDirection,
    required double cameraPreviewAspectRatio,
  }) {
    if (originalImageSize.isEmpty || canvasSize.isEmpty || cameraPreviewAspectRatio <= 0) {
      return Rect.zero;
    }

    // 1. 카메라 프리뷰가 실제로 화면에 표시되는 영역(cameraViewRect) 계산
    Rect cameraViewRect;
    final double screenAspectRatio = canvasSize.width / canvasSize.height;

    if (screenAspectRatio > cameraPreviewAspectRatio) {
      // 화면이 프리뷰보다 넓은 경우 (위아래 레터박스 또는 프리뷰가 세로로 꽉 참)
      final double fittedHeight = canvasSize.height;
      final double fittedWidth = fittedHeight * cameraPreviewAspectRatio;
      final double offsetX = (canvasSize.width - fittedWidth) / 2; // 중앙 정렬을 위한 X 오프셋
      cameraViewRect = Rect.fromLTWH(offsetX, 0, fittedWidth, fittedHeight);
    } else {
      // 프리뷰가 화면보다 넓은 경우 (좌우 레터박스 또는 프리뷰가 가로로 꽉 참)
      final double fittedWidth = canvasSize.width;
      final double fittedHeight = fittedWidth / cameraPreviewAspectRatio;
      final double offsetY = (canvasSize.height - fittedHeight) / 2; // 중앙 정렬을 위한 Y 오프셋
      cameraViewRect = Rect.fromLTWH(0, offsetY, fittedWidth, fittedHeight);
    }

    // 2. ML Kit에서 반환된 바운딩 박스를 카메라 프리뷰 좌표계에 맞게 변환
    final bool isImageRotatedSideways =
        imageRotation == InputImageRotation.rotation90deg ||
            imageRotation == InputImageRotation.rotation270deg;

    // 회전을 고려한 ML Kit 이미지의 너비와 높이
    final double mlImageWidth = isImageRotatedSideways ? originalImageSize.height : originalImageSize.width;
    final double mlImageHeight = isImageRotatedSideways ? originalImageSize.width : originalImageSize.height;

    if (mlImageWidth == 0 || mlImageHeight == 0) return Rect.zero;

    // ML Kit 이미지 좌표를 cameraViewRect 좌표로 변환하기 위한 스케일 계산
    final double scaleX = cameraViewRect.width / mlImageWidth;
    final double scaleY = cameraViewRect.height / mlImageHeight;

    double l, t, r, b; // 변환된 좌표 (cameraViewRect 내에서의 상대 좌표)

    switch (imageRotation) {
      case InputImageRotation.rotation0deg:
        l = mlKitBoundingBox.left * scaleX;
        t = mlKitBoundingBox.top * scaleY;
        r = mlKitBoundingBox.right * scaleX;
        b = mlKitBoundingBox.bottom * scaleY;
        break;
      case InputImageRotation.rotation90deg:
        l = mlKitBoundingBox.top * scaleX;
        t = (mlImageHeight - mlKitBoundingBox.right) * scaleY; // Y축 반전 및 스케일
        r = mlKitBoundingBox.bottom * scaleX;
        b = (mlImageHeight - mlKitBoundingBox.left) * scaleY;  // Y축 반전 및 스케일
        break;
      case InputImageRotation.rotation180deg:
        l = (mlImageWidth - mlKitBoundingBox.right) * scaleX;  // X축 반전 및 스케일
        t = (mlImageHeight - mlKitBoundingBox.bottom) * scaleY; // Y축 반전 및 스케일
        r = (mlImageWidth - mlKitBoundingBox.left) * scaleX;   // X축 반전 및 스케일
        b = (mlImageHeight - mlKitBoundingBox.top) * scaleY;  // Y축 반전 및 스케일
        break;
      case InputImageRotation.rotation270deg:
        l = (mlImageWidth - mlKitBoundingBox.bottom) * scaleX; // X축 반전 및 스케일 (원래 이미지의 bottom이 화면의 left가 됨)
        t = mlKitBoundingBox.left * scaleY;
        r = (mlImageWidth - mlKitBoundingBox.top) * scaleX;    // X축 반전 및 스케일 (원래 이미지의 top이 화면의 right가 됨)
        b = mlKitBoundingBox.right * scaleY;
        break;
    }
    
    // 안드로이드 전면 카메라 미러링 처리
    if (cameraLensDirection == CameraLensDirection.front && Platform.isAndroid) {
       // 가로 미러링이 필요한 경우 (보통 0도 또는 180도 회전 시)
       if (imageRotation == InputImageRotation.rotation0deg || imageRotation == InputImageRotation.rotation180deg) {
         final double tempL = l;
         l = cameraViewRect.width - r; // cameraViewRect 내부에서의 미러링
         r = cameraViewRect.width - tempL;
       }
       // 90도, 270도 회전 시에는 미러링 방향이 달라지거나 필요 없을 수 있음 (테스트 필요)
       // 예: 90도 회전 시에는 세로 방향 미러링이 될 수 있음 (t,b 값 변경)
       // else if (imageRotation == InputImageRotation.rotation90deg || imageRotation == InputImageRotation.rotation270deg) {
       //   final double tempT = t;
       //   t = cameraViewRect.height - b;
       //   b = cameraViewRect.height - tempT;
       // }
    }


    // 3. cameraViewRect의 오프셋을 더해 최종 화면(canvas) 좌표로 변환
    Rect displayRect = Rect.fromLTRB(
        cameraViewRect.left + l,
        cameraViewRect.top + t,
        cameraViewRect.left + r,
        cameraViewRect.top + b);

    // 4. 계산된 displayRect가 cameraViewRect 범위를 벗어나지 않도록 클램핑
    return Rect.fromLTRB(
      displayRect.left.clamp(cameraViewRect.left, cameraViewRect.right),
      displayRect.top.clamp(cameraViewRect.top, cameraViewRect.bottom),
      displayRect.right.clamp(cameraViewRect.left, cameraViewRect.right),
      displayRect.bottom.clamp(cameraViewRect.top, cameraViewRect.bottom),
    );
  }


  void _handleRotationResult(dynamic message) {
    if (_isDisposed || !mounted) return;

    if (message == 'isolate_shutdown_ack_rotation') {
        print("****** ObjectDetectionView: Rotation isolate acknowledged shutdown. Killing now.");
        _imageRotationIsolate?.kill(priority: Isolate.immediate);
        _imageRotationIsolate = null;
        return;
    }

    if (_imageRotationIsolateSendPort == null && message is SendPort) {
      _imageRotationIsolateSendPort = message;
      print("****** ObjectDetectionView: ImageRotationIsolate SendPort received.");
    } else if (message is InputImageRotation?) {
      _isWaitingForRotation = false;
      _lastCalculatedRotation = message;
      _imageRotation = message;

      if (_pendingImageDataBytes != null && _objectDetectionIsolateSendPort != null && message != null) {
        _isWaitingForDetection = true;
        // _lastImageSize는 _processCameraImage에서 이미 설정됨
        final Map<String, dynamic> payload = {
          'bytes': _pendingImageDataBytes!,
          'width': _pendingImageDataWidth!,
          'height': _pendingImageDataHeight!,
          'rotation': message, // 계산된 이미지 회전 값
          'formatRaw': _pendingImageDataFormatRaw!,
          'bytesPerRow': _pendingImageDataBytesPerRow!,
        };
        if (!_isDisposed && _objectDetectionIsolateSendPort != null) {
             _objectDetectionIsolateSendPort!.send(payload);
        } else {
          print("****** ObjectDetectionView: Not sending to detection isolate (disposed or no sendPort)");
        }
        _pendingImageDataBytes = null; // 데이터 전송 후 초기화
      } else {
        // 보낼 데이터가 없거나, 보낼 곳이 없거나, 회전값이 null인 경우
        if (!_isWaitingForDetection && _isBusy) _isBusy = false;
      }
    } else if (message is List && message.length == 2 && message[0] is String && message[0].toString().contains('Error')) {
      print('****** ObjectDetectionView: Rotation Isolate Error: ${message[1]}');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null; // 오류 발생 시 보류 중인 데이터 클리어
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    } else if (message == null || (message is List && message.isEmpty && message is! InputImageRotation)) {
      // Isolate가 종료되었거나, 빈 메시지 또는 예상치 못한 null 메시지를 보낸 경우
      print('****** ObjectDetectionView: Rotation Isolate exited or sent empty/null message ($message).');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null;
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    } else {
      // 예상치 못한 타입의 메시지
      print('****** ObjectDetectionView: Unexpected message from Rotation Isolate: ${message.runtimeType} - $message');
      _isWaitingForRotation = false;
      _pendingImageDataBytes = null;
      if (!_isWaitingForDetection && _isBusy) _isBusy = false;
    }
  }

  Future<void> _initializeCamera(CameraDescription cameraDescription) async {
    if (_isDisposed) return;
    if (_cameraController != null) {
      await _stopCameraStream(); 
      await _cameraController!.dispose();
      _cameraController = null;
      print("****** ObjectDetectionView: Old CameraController disposed before new init for ${cameraDescription.name}.");
    }
    if (mounted && !_isDisposed) {
      setState(() {
        _isCameraInitialized = false;
        _initializationErrorMsg = null; // 이전 오류 메시지 초기화
      });
    }

    _cameraController = CameraController(
      cameraDescription,
      widget.resolutionPreset, // 전달받은 해상도 사용
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
    );
    try {
      await _cameraController!.initialize();
      print("****** ObjectDetectionView: New CameraController initialized for ${cameraDescription.name}.");
      await _startCameraStream(); // 스트림 시작
      if (mounted && !_isDisposed) {
        setState(() {
          _isCameraInitialized = true;
          _cameraIndex = widget.cameras.indexOf(cameraDescription);
        });
      }
    } catch (e, stacktrace) {
      print('****** ObjectDetectionView: Camera init error for ${cameraDescription.name}: $e\n$stacktrace');
      if (mounted && !_isDisposed) {
        setState(() {
          _isCameraInitialized = false;
          _initializationErrorMsg = "카메라 시작에 실패했습니다.\n권한 확인 또는 앱 재시작 필요.\n오류: ${e.toString().substring(0, (e.toString().length > 100) ? 100 : e.toString().length)}";
        });
      }
    }
  }

  Future<void> _startCameraStream() async {
    if (_isDisposed || _cameraController == null || !_cameraController!.value.isInitialized || _cameraController!.value.isStreamingImages) return;
    try {
      await _cameraController!.startImageStream(_processCameraImage);
      print("****** ObjectDetectionView: Camera stream started for ${_cameraController?.description.name}.");
    } catch (e, stacktrace) {
      print('****** ObjectDetectionView: Start stream error: $e\n$stacktrace');
      if (mounted && !_isDisposed) {
        setState(() {
          _initializationErrorMsg = "카메라 스트림 시작 실패: ${e.toString().substring(0, (e.toString().length > 100) ? 100 : e.toString().length)}";
        });
      }
    }
  }

  Future<void> _stopCameraStream() async {
    // 스트림을 멈추기 전에 _isBusy 등의 상태를 초기화할 수 있음
    if (_cameraController == null || !_cameraController!.value.isInitialized || !_cameraController!.value.isStreamingImages) {
      _isBusy = false; // 안전하게 false로 설정
      _isWaitingForRotation = false;
      _isWaitingForDetection = false;
      _pendingImageDataBytes = null;
      return;
    }
    try {
      await _cameraController!.stopImageStream();
      print("****** ObjectDetectionView: Camera stream stopped in _stopCameraStream for ${_cameraController?.description.name}.");
    } catch (e, stacktrace) {
      print('****** ObjectDetectionView: Stop stream error in _stopCameraStream: $e\n$stacktrace');
      // 오류 발생 시에도 상태는 초기화하는 것이 좋을 수 있음
    } finally {
      // 스트림 중지 후 관련 상태 초기화
      _isBusy = false;
      _isWaitingForRotation = false;
      _isWaitingForDetection = false;
      _pendingImageDataBytes = null; // 보류 중인 데이터가 있다면 클리어
    }
  }


  void _processCameraImage(CameraImage image) {
    if (_isDisposed || !mounted || _isBusy || _imageRotationIsolateSendPort == null) {
      // print("Skipping frame: disposed=$_isDisposed, mounted=$mounted, busy=$_isBusy, rotationPortNull=${_imageRotationIsolateSendPort == null}");
      if(_isBusy && !_isDisposed) {
        // print("Frame skipped (busy)");
      }
      return;
    }
    _isBusy = true; // 처리를 시작했으므로 true
    _isWaitingForRotation = true; // 회전 계산을 기다림

    try {
      // 이미지 데이터 준비 (기존 코드 유지)
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      _pendingImageDataBytes = allBytes.done().buffer.asUint8List();
      _pendingImageDataWidth = image.width;
      _pendingImageDataHeight = image.height;
      _pendingImageDataFormatRaw = image.format.raw;
      _pendingImageDataBytesPerRow = image.planes.isNotEmpty ? image.planes[0].bytesPerRow : 0;

      // 현재 이미지 크기 업데이트 (ML Kit 결과 처리 시 사용)
      _lastImageSize = Size(image.width.toDouble(), image.height.toDouble());

      // 회전 계산을 위한 정보 전달 (기존 코드 유지)
      final camera = widget.cameras[_cameraIndex];
      // _currentDeviceOrientation은 build 메소드에서 MediaQuery를 통해 업데이트되거나,
      // OrientationBuilder 등을 통해 실시간으로 가져올 수 있습니다.
      // 여기서는 build 메소드에서 업데이트된 값을 사용한다고 가정합니다.
      final orientation = _currentDeviceOrientation ?? MediaQuery.of(context).orientation; // Fallback
      
      final DeviceOrientation deviceRotation = (orientation == Orientation.landscape)
          ? (Platform.isIOS ? DeviceOrientation.landscapeRight : DeviceOrientation.landscapeLeft)
          : DeviceOrientation.portraitUp; // 기본값은 portraitUp

      final Map<String, dynamic> rotationPayload = {
        'sensorOrientation': camera.sensorOrientation,
        'deviceOrientationIndex': deviceRotation.index,
      };

      if (!_isDisposed && _imageRotationIsolateSendPort != null) { 
         _imageRotationIsolateSendPort!.send(rotationPayload);
      } else {
         print("****** ObjectDetectionView: Not sending to rotation isolate (disposed or no sendPort)");
         // 전송 실패 시 보류 중인 데이터 및 상태 초기화
         _pendingImageDataBytes = null; 
         _isWaitingForRotation = false; // 회전 계산 기다릴 필요 없음
         _isBusy = false; // 다음 프레임 처리 가능하도록 false로 설정
      }

    } catch (e, stacktrace) {
      print("****** ObjectDetectionView: Error processing image: $e\n$stacktrace");
      // 오류 발생 시 관련 상태 초기화
      _pendingImageDataBytes = null;
      _isWaitingForRotation = false;
      _isBusy = false; // 다음 프레임 처리 가능하도록
    }
  }

  void _switchCamera() {
    if (_isDisposed || widget.cameras.length < 2 || _isBusy) return;
    print("****** ObjectDetectionView: Switching camera...");
    final newIndex = (_cameraIndex + 1) % widget.cameras.length;
    // 카메라 전환은 비동기 작업이므로, Future.microtask를 사용하여 현재 빌드 사이클 이후에 실행
    Future.microtask(() async {
        await _stopCameraStream(); // 현재 스트림을 먼저 중지
        if (!_isDisposed && mounted) { // dispose되지 않았고 마운트된 상태인지 확인
            await _initializeCamera(widget.cameras[newIndex]); // 새 카메라 초기화
        }
    });
  }


  @override
  Widget build(BuildContext context) {
    // 현재 장치 방향 업데이트
    _currentDeviceOrientation = MediaQuery.of(context).orientation;

    if (_initializationErrorMsg != null) {
      return Center( child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(_initializationErrorMsg!, style: const TextStyle(color: Colors.red, fontSize: 16), textAlign: TextAlign.center),
        )
      );
    }

    if (!_isCameraInitialized || _cameraController == null || !_cameraController!.value.isInitialized) {
      return Center( child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 10),
            Text(widget.cameras.isEmpty ? '카메라 없음' : '카메라 초기화 중...'),
          ],
        ));
    }

    // 카메라 컨트롤러와 화면 비율을 가져옴
    final double cameraAspectRatio = _cameraController!.value.aspectRatio;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _screenSize = constraints.biggest; // 화면 크기 업데이트
        final Size parentSize = constraints.biggest; // LayoutBuilder로부터 실제 사용 가능한 부모 크기
        double previewWidth;
        double previewHeight;

        // 화면 비율과 카메라 프리뷰 비율을 비교하여 프리뷰 크기 계산
        if (parentSize.width / parentSize.height > cameraAspectRatio) { 
          // 부모 위젯이 카메라 프리뷰보다 가로로 넓은 경우 (세로로 꽉 채움)
          previewHeight = parentSize.height;
          previewWidth = previewHeight * cameraAspectRatio;
        } else {
          // 부모 위젯이 카메라 프리뷰보다 세로로 긴 경우 (가로로 꽉 채움)
          previewWidth = parentSize.width;
          previewHeight = previewWidth / cameraAspectRatio;
        }

        return Stack(
          fit: StackFit.expand, // Stack이 LayoutBuilder의 크기를 모두 차지하도록
          alignment: Alignment.center, // 자식들을 중앙 정렬 (CameraPreview 위젯에 영향)
          children: [
            // 카메라 프리뷰를 중앙에 배치하고 계산된 크기 적용
            Center(
              child: SizedBox(
                width: previewWidth,
                height: previewHeight,
                child: CameraPreview(_cameraController!),
              ),
            ),
            // 객체 바운딩 박스 및 정보 표시 (CustomPaint)
            if (_processedObjects.isNotEmpty && _lastImageSize != null && _imageRotation != null && _screenSize != null)
              CustomPaint(
                size: parentSize, // CustomPaint의 크기는 LayoutBuilder의 전체 크기
                painter: ObjectPainter(
                  objects: _processedObjects.map((info) => info.object).toList(), // DetectedObject 리스트 전달
                  imageSize: _lastImageSize!,
                  screenSize: _screenSize!, // CustomPaint의 캔버스 크기
                  rotation: _imageRotation!,
                  cameraLensDirection: widget.cameras[_cameraIndex].lensDirection,
                  cameraPreviewAspectRatio: cameraAspectRatio, // 카메라 프리뷰 비율 전달
                  showNameTags: false, // 요구사항에 따라 이름표는 그리지 않음
                ),
              ),
            // 여기에 다른 UI 요소들을 Positioned 위젯 등으로 추가할 수 있음
          ],
        );
      },
    );
  }
}