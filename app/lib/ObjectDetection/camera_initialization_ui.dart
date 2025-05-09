import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:async';
import 'camera_screen.dart';

class MyApp extends StatefulWidget {
  const MyApp({Key? key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  Future<List<CameraDescription>>? _camerasFuture;

  @override
  void initState() {
    super.initState();

    _camerasFuture = _initializeCameras();
  }

  Future<List<CameraDescription>> _initializeCameras() async {
    try {
      return await availableCameras();
    } on CameraException catch (e) {
      print('Error finding cameras: ${e.code}, ${e.description}');
      return [];
    } catch (e) {
      print('Unexpected error finding cameras: $e');
      return [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime Object Detection',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: FutureBuilder<List<CameraDescription>>(
        future: _camerasFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else if (snapshot.hasError ||
              snapshot.data == null ||
              snapshot.data!.isEmpty) {
            return const Scaffold(
              body: Center(child: Text('사용 가능한 카메라를 찾을 수 없습니다.')),
            );
          } else {
            return RealtimeObjectDetectionScreen(cameras: snapshot.data!);
          }
        },
      ),
    );
  }
}
