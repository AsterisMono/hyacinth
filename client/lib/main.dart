import 'package:flutter/material.dart';

import 'display/display_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HyacinthApp());
}

class HyacinthApp extends StatelessWidget {
  const HyacinthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Hyacinth',
      debugShowCheckedModeBanner: false,
      home: DisplayPage(),
    );
  }
}
