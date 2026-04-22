import 'package:flutter/material.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  static const logoAssetPath = 'assets/pdf-images/drySpotLogoBlue.png';
  static const brandBlue = Color(0xFF2A4F9A);

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFF7FAFF),
              Colors.white,
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 32),
                child: Image(
                  image: AssetImage(logoAssetPath),
                  width: 220,
                  semanticLabel: 'DrySpot logo',
                ),
              ),
              SizedBox(height: 28),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: brandBlue,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
