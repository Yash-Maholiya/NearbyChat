import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../models/peer.dart';
import 'conversation_screen.dart';

class NearbyPeopleScreen extends StatefulWidget {
  final ChatController controller;

  const NearbyPeopleScreen({super.key, required this.controller});

  @override
  State<NearbyPeopleScreen> createState() => _NearbyPeopleScreenState();
}

class _NearbyPeopleScreenState extends State<NearbyPeopleScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onStateChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onStateChange);
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) setState(() {});
  }

  void _showMyIdentity() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.badge_outlined, color: Color(0xFF3B82F6), size: 24),
                  const SizedBox(width: 10),
                  Text(
                    'Your Identity: ${widget.controller.username}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Other peers within BLE range discover you under this handle. Your identity is authenticated through your hardware-backed public key.',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B0F19),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF374151)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'KEY FINGERPRINT',
                      style: TextStyle(color: Color(0xFF6B7280), fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      widget.controller.localFingerprint,
                      style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF60A5FA), fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.controller.peers;
    final isScanning = widget.controller.isScanning;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NearbyChat',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
            ),
            Text(
              'Advertising as NC-${widget.controller.username ?? 'User'}',
              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_pin, color: Color(0xFF60A5FA)),
            tooltip: 'View Identity',
            onPressed: _showMyIdentity,
          ),
          IconButton(
            icon: Icon(
              isScanning ? Icons.stop_circle_outlined : Icons.radar,
              color: isScanning ? const Color(0xFFEF4444) : const Color(0xFF10B981),
            ),
            tooltip: isScanning ? 'Stop Discovery' : 'Start Discovery',
            onPressed: () {
              if (isScanning) {
                widget.controller.stopDiscovery();
              } else {
                widget.controller.startDiscovery();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Scanning status indicator
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            color: const Color(0xFF0F172A),
            child: Row(
              children: [
                if (isScanning)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF3B82F6)),
                  )
                else
                  const Icon(Icons.bluetooth_disabled, size: 16, color: Color(0xFF6B7280)),
                const SizedBox(width: 10),
                Text(
                  isScanning ? 'Actively scanning for peers via BLE...' : 'Scanning paused.',
                  style: TextStyle(
                    color: isScanning ? const Color(0xFF93C5FD) : const Color(0xFF9CA3AF),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const Spacer(),
                Text(
                  '${peers.length} found',
                  style: const TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                ),
              ],
            ),
          ),
          // Peers list or empty state
          Expanded(
            child: peers.isEmpty ? _buildEmptyState(isScanning) : _buildPeerList(peers),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isScanning) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF111827),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF1F2937), width: 2),
              ),
              child: Icon(
                isScanning ? Icons.radar : Icons.bluetooth_searching,
                color: const Color(0xFF3B82F6),
                size: 54,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Peers in Range',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ensure Bluetooth is turned on on nearby devices running NearbyChat. Devices within 10–30 meters will appear here automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPeerList(List<Peer> peers) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12),
      itemCount: peers.length,
      separatorBuilder: (_, __) => const Divider(color: Color(0xFF1F2937), height: 1),
      itemBuilder: (context, index) {
        final peer = peers[index];
        final initial = peer.username.isNotEmpty ? peer.username[0].toUpperCase() : '?';

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: const Color(0xFF1E40AF),
                child: Text(
                  initial,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              if (peer.isVerified)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: const BoxDecoration(
                      color: Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.check, size: 10, color: Colors.white),
                  ),
                ),
            ],
          ),
          title: Row(
            children: [
              Text(
                peer.username,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
              ),
              if (peer.isVerified) ...[
                const SizedBox(width: 6),
                const Icon(Icons.verified, size: 16, color: Color(0xFF10B981)),
              ],
            ],
          ),
          subtitle: Row(
            children: [
              Text(
                'Key: ${peer.fingerprint}',
                style: const TextStyle(fontFamily: 'monospace', color: Color(0xFF9CA3AF), fontSize: 12),
              ),
              if (peer.rssi != null) ...[
                const SizedBox(width: 8),
                Text(
                  '•  ${peer.rssi} dBm',
                  style: TextStyle(color: _getRssiColor(peer.rssi!), fontSize: 11),
                ),
              ],
            ],
          ),
          trailing: const Icon(Icons.chevron_right, color: Color(0xFF6B7280)),
          onTap: () {
            widget.controller.selectPeer(peer);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConversationScreen(controller: widget.controller, peer: peer),
              ),
            );
          },
        );
      },
    );
  }

  Color _getRssiColor(int rssi) {
    if (rssi > -60) return const Color(0xFF10B981);
    if (rssi > -80) return const Color(0xFFF59E0B);
    return const Color(0xFFEF4444);
  }
}
