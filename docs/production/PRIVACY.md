# Privacy and data inventory

The prepared production target browses an immutable local Archive and requests no Bluetooth, local-network, location, camera, microphone, notification, or background-radio capability. Android backup is disabled. The iOS privacy manifest declares no tracking or collected data for this target.

Potential future sensitive data—identity keys, contacts, trust, messages, acknowledgments, prompts, history, diagnostics, location, media, and radio metadata—is not authorized for production because the corresponding features are disabled. Any reintroduction requires retention, backup, deletion, export, diagnostics, and privacy-manifest review.
