import 'package:flutter/material.dart';
import '../models/peer.dart';

class SafetyNumberDialog extends StatelessWidget {
  final Peer peer;
  final String localFingerprint;
  final Function(bool) onVerificationChanged;

  const SafetyNumberDialog({
    super.key,
    required this.peer,
    required this.localFingerprint,
    required this.onVerificationChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hasError = peer.safetyNumber == null;

    return AlertDialog(
      title: const Text('Safety Number'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(hasError
              ? 'Could not work out a safety number with ${peer.username}.'
              : 'Check that ${peer.username} sees the same number on their screen.'),
          const SizedBox(height: 12),
          Center(
            child: SelectableText(
              peer.safetyNumber ?? 'Unavailable',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 20, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 12),
          Text('Your key: $localFingerprint', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          Text('Their key: ${peer.fingerprint}', style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: hasError
              ? null
              : () {
                  onVerificationChanged(!peer.isVerified);
                  Navigator.of(context).pop();
                },
          child: Text(peer.isVerified ? 'Unverify' : 'Mark Verified'),
        ),
      ],
    );
  }
}
