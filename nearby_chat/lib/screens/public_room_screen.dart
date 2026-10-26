import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../models/mesh_packet.dart';

/// The public #nearby room: signed (Ed25519) but not encrypted, flooded to everyone in the mesh.
class PublicRoomScreen extends StatefulWidget {
  final ChatController controller;

  const PublicRoomScreen({super.key, required this.controller});

  @override
  State<PublicRoomScreen> createState() => _PublicRoomScreenState();
}

class _PublicRoomScreenState extends State<PublicRoomScreen> {
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _text.clear();
    await widget.controller.sendPublicMessage(t);
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.controller.publicMessages;
    final reachable = widget.controller.peers.where((p) => p.isConnected).length;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('#nearby'),
            Text('Public room, $reachable connected. Signed, not encrypted.',
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Messages here go to everyone in the mesh. Use a private chat for anything secret.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (_, i) => _bubble(messages[i]),
                  ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: 'Message everyone'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(onPressed: _send, child: const Text('Send')),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(PublicMessage m) {
    final time = '${m.sentAt.hour.toString().padLeft(2, '0')}:${m.sentAt.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: m.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
        decoration: BoxDecoration(
          color: m.isMine ? Colors.blue.shade50 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!m.isMine)
              Text('${m.senderName} (${m.senderFingerprint})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            Text(m.text, style: const TextStyle(fontSize: 15)),
            Text(m.isMine ? time : '$time, ${m.hops} hop${m.hops == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
      ),
    );
  }
}
