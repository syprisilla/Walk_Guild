import 'package:flutter/material.dart';
import 'package:walk_guide/step_counter_page.dart';
import 'package:walk_guide/description_page.dart';
import 'package:walk_guide/login_page.dart';
import 'package:walk_guide/analytics_dashboard_page.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  double Function()? _getSpeed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('오늘도 즐거운 하루 되세요!'),
          centerTitle: true,
          backgroundColor: Colors.amber,
          actions: [
            IconButton(
              icon: const Icon(Icons.info_outline, size: 28),
              tooltip: '설명 보기',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => DescriptionPage(),
                  ),
                );
              },
            ),
          ],
        ),
        body: Container(
          width: double.infinity,
          height: double.infinity,
          color: Colors.grey[300],
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('지도', style: TextStyle(fontSize: 24)),
              const SizedBox(height: 20),
            ],
          ),
        ),
        bottomNavigationBar: BottomNavigationBar(
          selectedFontSize: 16,
          unselectedFontSize: 14,
          iconSize: 32,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.directions_walk),
              label: '보행시작하기',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bar_chart),
              label: '분석',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.settings),
              label: '설정',
            ),
          ],
          onTap: (index) {
            if (index == 0) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => StepCounterPage(
                    onInitialized: (double Function() fn) {
                      _getSpeed = fn;
                    },
                  ),
                ),
              );
            } else if (index == 1) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AnalyticsDashboardPage(
                    onGetSpeed: _getSpeed ?? () => 0.0,
                  ),
                ),
              );
            } else if (index == 2) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('설정 페이지는 준비 중입니다')),
              );
            }
          },
        ),
      ),
    );
  }
}
