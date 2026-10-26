import 'package:flutter/material.dart';
import '../controllers/chat_controller.dart';
import '../models/peer.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/safety_number_dialog.dart';

class ConversationScreen extends StatefulWidget {
  final ChatController controller;
  final Peer peer;

  const ConversationScreen({
    super.key,
    required this.controller,
    required this.peer,
  });

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onStateChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onStateChange);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (mounted) {
      setState(() {});
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        final currentScroll = _scrollController.offset;
        // Only auto-scroll if user is already near the bottom (within 150px)
        if (maxScroll - currentScroll < 150) {
          _scrollController.animateTo(
            maxScroll,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isSending) return;

    _textController.clear();
    setState(() => _isSending = true);

    await widget.controller.sendMessage(text);

    if (mounted) {
      setState(() => _isSending = false);
      _scrollToBottom();
    }
  }

  void _showSafetyNumberModal(Peer peer) {
    showDialog(
      context: context,
      builder: (_) => SafetyNumberDialog(
        peer: peer,
        localFingerprint: widget.controller.localFingerprint,
        onVerificationChanged: (verified) {
          widget.controller.togglePeerVerification(peer, verified);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentPeer = widget.controller.activePeer ?? widget.peer;
    final messages = widget.controller.activeMessages;

    final String status;
    if (currentPeer.safetyNumber == null) {
      status = 'Safety number not available';
    } else if (currentPeer.isVerified) {
      status = 'Verified, safety no. ${currentPeer.safetyNumber}';
    } else {
      status = 'Not verified, safety no. ${currentPeer.safetyNumber}';
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(currentPeer.username),
            Text(
              currentPeer.isConnected ? 'Connected' : 'Not connected',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _showSafetyNumberModal(currentPeer),
            child: Text(currentPeer.isVerified ? 'Details' : 'Verify'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(status, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
          ),
          if (currentPeer.hasNameCollision)
            Container(
              width: double.infinity,
              color: Colors.red.shade50,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Text(
                'Warning: another device nearby uses this name with a different key. Check the safety number.',
                style: TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
          Expanded(
            child: messages.isEmpty
                ? const Center(
                    child: Text('No messages yet', style: TextStyle(color: Colors.black54)),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (_, index) {
                      final message = messages[index];
                      return ChatBubble(
                        message: message,
                        onRetry: () => widget.controller.resendMessage(message.id),
                      );
                    },
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
                      controller: _textController,
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(hintText: 'Message'),
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isSending ? null : _handleSend,
                    child: const Text('Send'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
