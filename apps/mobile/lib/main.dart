import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'presentation/auth_gate.dart';
import 'presentation/design_system.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const CreovyHouseOwnerApp());
}

class CreovyHouseOwnerApp extends StatelessWidget {
  const CreovyHouseOwnerApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CREOVY House Owner',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: CreovyColors.brand),
          scaffoldBackgroundColor: CreovyColors.canvas,
          useMaterial3: true,
          inputDecorationTheme: const InputDecorationTheme(
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(14))),
          ),
        ),
        home: const AuthGate(),
      );
}
