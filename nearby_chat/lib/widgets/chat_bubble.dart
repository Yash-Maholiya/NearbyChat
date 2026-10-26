import 'package:flutter/material.dart';
import '../models/chat_message.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  /// Called when the user taps a failed outgoing message.
  final VoidCallback? onRetry;

  const ChatBubble({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isMine = message.isMine;
    final timeStr = '${message.sentAt.hour.toString().padLeft(2, '0')}:${message.sentAt.minute.toString().padLeft(2, '0')}';
    final canRetry = isMine && message.status == MessageStatus.failed && onRetry != null;

    var info = timeStr;
    if (isMine) info += ', ${_statusText()}';
    if (canRetry) info += '. Tap to retry';

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: canRetry ? onRetry : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          decoration: BoxDecoration(
            color: isMine ? Colors.blue.shade50 : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message.body, style: const TextStyle(fontSize: 15)),
              Text(
                info,
                style: TextStyle(fontSize: 11, color: canRetry ? Colors.red : Colors.black54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText() {
    switch (message.status) {
      case MessageStatus.sending:
        return 'sending';
      case MessageStatus.sent:
        return 'sent';
      case MessageStatus.delivered:
        return 'delivered';
      case MessageStatus.failed:
        return 'failed';
    }
  }
}
