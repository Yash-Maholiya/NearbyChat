import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../models/peer.dart';
import 'conversation_screen.dart';
import 'public_room_screen.dart';

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
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('You: ${widget.controller.username}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Key fingerprint'),
            const SizedBox(height: 4),
            SelectableText(
              widget.controller.localFingerprint,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peers = widget.controller.peers;
    final isScanning = widget.controller.isScanning;

    return Scaffold(
      appBar: AppBar(
        title: Text('NearbyChat (${widget.controller.username ?? 'User'})'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            tooltip: 'My key',
            onPressed: _showMyIdentity,
          ),
          IconButton(
            icon: Icon(isScanning ? Icons.stop : Icons.bluetooth_searching),
            tooltip: isScanning ? 'Stop scan' : 'Start scan',
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
          Container(
            width: double.infinity,
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
            child: Text(
              '${isScanning ? 'Scanning' : 'Scan stopped'}  |  ${peers.length} found  |  ${widget.controller.relayedPackets} relayed',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          _buildPublicRoomTile(),
          const Divider(height: 1),
          Expanded(
            child: peers.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No one found yet. Turn on Bluetooth on the other devices.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : _buildPeerList(peers),
          ),
        ],
      ),
    );
  }

  Widget _buildPublicRoomTile() {
    final msgs = widget.controller.publicMessages;
    final last = msgs.isEmpty ? 'Public room' : '${msgs.last.senderName}: ${msgs.last.text}';
    return ListTile(
      leading: const CircleAvatar(child: Text('#')),
      title: const Text('#nearby'),
      subtitle: Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => PublicRoomScreen(controller: widget.controller)),
      ),
    );
  }

  Widget _buildPeerList(List<Peer> peers) {
    return ListView.separated(
      itemCount: peers.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final peer = peers[index];
        final initial = peer.username.isNotEmpty ? peer.username[0].toUpperCase() : '?';

        final info = <String>['Key ${peer.fingerprint}'];
        if (peer.isMeshOnly) {
          info.add('${peer.hops} hop${peer.hops == 1 ? '' : 's'}');
        } else if (peer.isReverseLink) {
          info.add('linked');
        }
        if (peer.rssi != null) info.add('${peer.rssi} dBm');

        var name = peer.username;
        if (peer.isVerified) name += ' (verified)';

        return ListTile(
          leading: CircleAvatar(child: Text(initial)),
          title: Text(name),
          subtitle: Text(
            info.join(', ') + (peer.hasNameCollision ? '\nSame name as another device!' : ''),
            style: TextStyle(color: peer.hasNameCollision ? Colors.red : null),
          ),
          isThreeLine: peer.hasNameCollision,
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
}
