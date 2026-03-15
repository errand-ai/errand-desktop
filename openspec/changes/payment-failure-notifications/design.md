## Approach

### Event Reception

errand-server forwards `subscription_alert` events to errand-desktop via the existing communication channel (WebSocket events or IPC). The desktop app receives these as structured events with the same payload format:

```json
{
  "type": "subscription_alert",
  "alert": "payment_failed",
  "plan": "monthly",
  "attempt_count": 1,
  "next_retry_at": "2026-03-12T14:00:00Z",
  "final_attempt": false
}
```

### Native macOS Notifications

Use `UNUserNotificationCenter` (UserNotifications framework, macOS 10.14+) to display native notifications. This is the modern replacement for the deprecated `NSUserNotification`.

Notification content by alert type:

| Alert | Title | Body |
|-------|-------|------|
| `payment_failed` (retrying) | "Errand Cloud" | "Payment failed for your {plan} subscription. Retrying {date}." |
| `payment_failed` (final) | "Errand Cloud" | "Payment failed. Your subscription has expired." |
| `payment_succeeded` | "Errand Cloud" | "Payment successful. Your {plan} subscription has been renewed." |

### Integration Point

Add a handler in the event dispatch (where incoming events from errand-server are routed) for `subscription_alert` type events. This follows the same pattern as any other event type the desktop app handles.

Request notification permission on first launch if not already granted (standard `UNUserNotificationCenter.requestAuthorization`).
