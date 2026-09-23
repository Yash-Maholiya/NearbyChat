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
    final safetyNumber = currentPeer.safetyNumber ?? 'Deriving...';

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF1E40AF),
              child: Text(
                currentPeer.username.isNotEmpty ? currentPeer.username[0].toUpperCase() : '?',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    currentPeer.username,
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: currentPeer.isConnected ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        currentPeer.isConnected ? 'Connected' : 'Offline / Scanning',
                        style: TextStyle(
                          color: currentPeer.isConnected ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              currentPeer.isVerified ? Icons.verified : Icons.verified_user_outlined,
              color: currentPeer.isVerified ? const Color(0xFF10B981) : const Color(0xFF9CA3AF),
            ),
            tooltip: 'Safety Number',
            onPressed: () => _showSafetyNumberModal(currentPeer),
          ),
        ],
      ),
      body: Column(
        children: [
          // In-chat Safety Number Banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                Icon(
                  currentPeer.safetyNumber == null
                      ? Icons.warning_amber_rounded
                      : (currentPeer.isVerified ? Icons.lock : Icons.lock_clock),
                  color: currentPeer.safetyNumber == null
                      ? const Color(0xFFEF4444)
                      : (currentPeer.isVerified ? const Color(0xFF10B981) : const Color(0xFFF59E0B)),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentPeer.safetyNumber == null
                        ? 'Safety Number: Unavailable'
                        : (currentPeer.isVerified
                            ? 'Verified E2EE Session ($safetyNumber)'
                            : 'Safety No: $safetyNumber'),
                    style: TextStyle(
                      fontFamily: 'monospace',
                      color: currentPeer.safetyNumber == null ? const Color(0xFFFCA5A5) : const Color(0xFFCBD5E1),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _showSafetyNumberModal(currentPeer),
                  child: Text(
                    currentPeer.isVerified ? 'Details' : 'Verify',
                    style: TextStyle(
                      color: currentPeer.safetyNumber == null
                          ? const Color(0xFFEF4444)
                          : (currentPeer.isVerified ? const Color(0xFF60A5FA) : const Color(0xFFF59E0B)),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Messages list
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.lock_outline, size: 40, color: Color(0xFF374151)),
                          const SizedBox(height: 12),
                          Text(
                            'Start of Encrypted Chat with ${currentPeer.username}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Messages are encrypted with AES-GCM-256 and sent over BLE.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF6B7280), fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (_, index) => ChatBubble(message: messages[index]),
                  ),
          ),

          // Chat Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF111827),
              border: Border(top: BorderSide(color: Color(0xFF1F2937), width: 1)),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      maxLines: 4,
                      minLines: 1,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Type an encrypted message...',
                        hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 14),
                        filled: true,
                        fillColor: const Color(0xFF0B0F19),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: Color(0xFF374151)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: Color(0xFF374151)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: Color(0xFF3B82F6)),
                        ),
                      ),
                      onSubmitted: (_) => _handleSend(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Color(0xFF3B82F6),
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send, color: Colors.white, size: 20),
                      onPressed: _isSending ? null : _handleSend,
                    ),
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
