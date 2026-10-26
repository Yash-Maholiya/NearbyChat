import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import 'nearby_people_screen.dart';

class SetupScreen extends StatefulWidget {
  final ChatController controller;

  const SetupScreen({super.key, required this.controller});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _nameController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _handleStart() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorMessage = 'Enter a name first.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await widget.controller.registerUser(name);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => NearbyPeopleScreen(controller: widget.controller),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('NearbyChat')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Choose Your Display Name', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              hintText: 'Name',
              errorText: _errorMessage,
            ),
            onSubmitted: (_) => _handleStart(),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _isLoading ? null : _handleStart,
            child: _isLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Generate Keys & Continue'),
          ),
          const SizedBox(height: 24),
          const Text(
            'A key pair is generated on this phone. Chat works over Bluetooth only, no internet or account needed.',
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }
}
