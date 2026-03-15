## 1. Notification Permission

- [ ] 1.1 Call `UNUserNotificationCenter.requestAuthorization(options: [.alert, .sound])` during app startup in `AppState`
- [ ] 1.2 Store authorization result and gate all notification delivery on permission being granted

## 2. Subscription Alert Event Handling

- [ ] 2.1 Define `SubscriptionAlert` model with fields: `alert` (string), `plan` (string), `attempt_count` (int), `next_retry_at` (ISO 8601 string, nullable), `final_attempt` (bool)
- [ ] 2.2 Add `subscription_alert` case to the event dispatch and parse payload into `SubscriptionAlert`
- [ ] 2.3 Log a warning and discard malformed `subscription_alert` events

## 3. Native macOS Notifications

- [ ] 3.1 Create notification helper that builds `UNNotificationRequest` from a `SubscriptionAlert`
- [ ] 3.2 `payment_failed` (not final): title "Errand Cloud", body "Payment failed for your {plan} subscription. Retrying {formatted date}."
- [ ] 3.3 `payment_failed` (final): title "Errand Cloud", body "Payment failed. Your subscription has expired."
- [ ] 3.4 `payment_succeeded`: title "Errand Cloud", body "Payment successful. Your {plan} subscription has been renewed."
- [ ] 3.5 Use consistent notification identifier `errand-payment-alert` so newer alerts replace older ones

## 4. Tests

- [ ] 4.1 Test `SubscriptionAlert` parsing for valid `payment_failed` and `payment_succeeded` events
- [ ] 4.2 Test notification content generation for each alert variant (retrying, final, succeeded)
- [ ] 4.3 Test that notification delivery is skipped when permission is denied
