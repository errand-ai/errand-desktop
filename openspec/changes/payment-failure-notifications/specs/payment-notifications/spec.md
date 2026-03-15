## ADDED Requirements

### Requirement: Notification permission request
The system SHALL request notification authorization (`UNUserNotificationCenter.requestAuthorization` with `.alert` and `.sound` options) during app startup. The system SHALL NOT attempt to deliver notifications if authorization has not been granted.

#### Scenario: Permission granted on first launch
- **WHEN** the app starts for the first time and the user approves the notification permission prompt
- **THEN** the system records authorization as granted and enables notification delivery

#### Scenario: Permission denied
- **WHEN** the app starts and the user has denied notification permission
- **THEN** the system SHALL silently skip notification delivery for all subscription alert events

#### Scenario: Permission already determined
- **WHEN** the app starts and notification permission was previously granted or denied
- **THEN** the system SHALL NOT prompt the user again and SHALL respect the existing authorization state

### Requirement: Subscription alert event parsing
The system SHALL handle incoming events of type `subscription_alert` from errand-server. The system SHALL parse the following payload fields: `alert` (string), `plan` (string), `attempt_count` (integer), `next_retry_at` (ISO 8601 string, nullable), `final_attempt` (boolean).

#### Scenario: Valid payment_failed event received
- **WHEN** an event with `type: "subscription_alert"` and `alert: "payment_failed"` is received
- **THEN** the system parses the event and routes it to the notification handler with all payload fields available

#### Scenario: Valid payment_succeeded event received
- **WHEN** an event with `type: "subscription_alert"` and `alert: "payment_succeeded"` is received
- **THEN** the system parses the event and routes it to the notification handler

#### Scenario: Malformed subscription alert event
- **WHEN** an event with `type: "subscription_alert"` is received but required fields are missing or invalid
- **THEN** the system SHALL log a warning and discard the event without delivering a notification

### Requirement: Payment failed notification with retry
The system SHALL display a native macOS notification when a non-final `payment_failed` alert is received. The notification title SHALL be "Errand Cloud". The notification body SHALL be "Payment failed for your {plan} subscription. Retrying {formatted date}." where `{plan}` is the subscription plan name and `{formatted date}` is `next_retry_at` formatted as a user-friendly date.

#### Scenario: First payment failure with upcoming retry
- **WHEN** a `payment_failed` event is received with `final_attempt: false` and `next_retry_at: "2026-03-12T14:00:00Z"` and `plan: "monthly"`
- **THEN** the system delivers a notification with title "Errand Cloud" and body "Payment failed for your monthly subscription. Retrying March 12, 2026."

### Requirement: Payment failed notification final attempt
The system SHALL display a native macOS notification when a final `payment_failed` alert is received. The notification title SHALL be "Errand Cloud". The notification body SHALL be "Payment failed. Your subscription has expired."

#### Scenario: Final payment failure
- **WHEN** a `payment_failed` event is received with `final_attempt: true`
- **THEN** the system delivers a notification with title "Errand Cloud" and body "Payment failed. Your subscription has expired."

### Requirement: Payment succeeded notification
The system SHALL display a native macOS notification when a `payment_succeeded` alert is received. The notification title SHALL be "Errand Cloud". The notification body SHALL be "Payment successful. Your {plan} subscription has been renewed." where `{plan}` is the subscription plan name.

#### Scenario: Successful renewal
- **WHEN** a `payment_succeeded` event is received with `plan: "monthly"`
- **THEN** the system delivers a notification with title "Errand Cloud" and body "Payment successful. Your monthly subscription has been renewed."

### Requirement: Notification replacement
The system SHALL use a consistent notification identifier (`errand-payment-alert`) for all subscription payment notifications. Newer notifications SHALL replace older ones rather than stacking.

#### Scenario: Second failure replaces first
- **WHEN** a `payment_failed` notification is already displayed and a new `payment_failed` event is received
- **THEN** the new notification replaces the existing one instead of creating a second notification
