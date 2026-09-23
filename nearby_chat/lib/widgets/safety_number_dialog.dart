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
    final safetyNumber = peer.safetyNumber ?? 'Unavailable';

    return Dialog(
      backgroundColor: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Color(0xFF374151), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (hasError ? const Color(0xFFEF4444) : const Color(0xFF3B82F6)).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    hasError ? Icons.error_outline : Icons.verified_user_outlined,
                    color: hasError ? const Color(0xFFEF4444) : const Color(0xFF3B82F6),
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Safety Number',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Verification with ${peer.username}',
                        style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              hasError
                  ? 'Cryptographic safety number could not be established with this peer. Ensure their device identity is valid and in range.'
                  : 'Compare this cryptographic fingerprint in person to ensure your conversation is direct, tamper-proof, and free of man-in-the-middle interception.',
              style: TextStyle(
                color: hasError ? const Color(0xFFFCA5A5) : const Color(0xFFD1D5DB),
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
              decoration: BoxDecoration(
                color: const Color(0xFF0B0F19),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasError
                      ? const Color(0xFFEF4444).withValues(alpha: 0.5)
                      : const Color(0xFF22C55E).withValues(alpha: 0.4),
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  Text(
                    hasError ? 'SESSION ERROR' : 'SHARED SAFETY NUMBER',
                    style: TextStyle(
                      color: hasError ? const Color(0xFFEF4444) : const Color(0xFF9CA3AF),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    safetyNumber,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: hasError ? const Color(0xFFEF4444) : const Color(0xFF22C55E),
                      fontSize: hasError ? 16 : 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: hasError ? 1 : 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2937),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildKeyRow('Your Key Fingerprint', localFingerprint),
                  const Divider(color: Color(0xFF374151), height: 16),
                  _buildKeyRow('${peer.username}\'s Fingerprint', peer.fingerprint),
                ],
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF9CA3AF),
                      side: const BorderSide(color: Color(0xFF4B5563)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: hasError
                          ? const Color(0xFF374151)
                          : (peer.isVerified ? const Color(0xFF374151) : const Color(0xFF10B981)),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: hasError
                        ? null
                        : () {
                            onVerificationChanged(!peer.isVerified);
                            Navigator.of(context).pop();
                          },
                    icon: Icon(
                      hasError ? Icons.block : (peer.isVerified ? Icons.close : Icons.check),
                      size: 18,
                    ),
                    label: Text(
                      hasError
                          ? 'Unavailable'
                          : (peer.isVerified ? 'Unverify' : 'Mark Verified'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeyRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
        ),
        Text(
          value,
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Color(0xFF60A5FA),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
