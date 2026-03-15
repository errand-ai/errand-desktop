## Why

errand-cloud is integrating Stripe for paid subscriptions. When a renewal payment fails, the errand-server forwards a `subscription_alert` event to errand-desktop. The desktop app needs to display native macOS notifications so the user is immediately aware of payment issues that could affect their service access.

## What Changes

- Handle `subscription_alert` events received from errand-server
- Display native macOS notifications for payment failures and resolutions
- Notification content varies by alert type:
  - `payment_failed` (retrying): "Payment failed for {plan} subscription. Retrying {date}."
  - `payment_failed` (final): "Payment failed for {plan} subscription. Your subscription has expired."
  - `payment_succeeded`: "Payment successful. Your {plan} subscription has been renewed."

## Capabilities

### New Capabilities

- `payment-notifications`: Native macOS notifications for subscription payment events

### Modified Capabilities

- Extend existing event handling to process `subscription_alert` events from errand-server

## Impact

- **macOS notifications**: Uses existing notification infrastructure (NSUserNotificationCenter or UNUserNotificationCenter)
- **Event handler**: New case in the event dispatch for `subscription_alert` type
- **No new dependencies expected**
