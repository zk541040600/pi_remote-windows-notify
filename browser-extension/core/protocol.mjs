/**
 * Shared protocol constants for PiNotify browser adapters.
 * Mirrors windows/route-host ProtocolConstants (fail-closed, no raw session/URL in logs).
 */

export const PROTOCOL_VERSION = 1;
export const ROUTE_VERSION = 1;
export const ROUTING_KEY_DOMAIN = 'pi-web-route-v1';

/** Native Messaging host name registered for Chrome/Edge. */
export const NATIVE_HOST_NAME = 'io.pi.notify.route';

/** Alternate host name used by the .NET Route Host binary (com.*). Prefer NATIVE_HOST_NAME. */
export const NATIVE_HOST_NAME_ALT = 'com.pi.notify.route_host';

export const MAX_MESSAGE_BYTES = 32 * 1024;
export const DEFAULT_LEASE_TTL_MS = 30_000;
export const MAX_LEASE_TTL_MS = 120_000;
export const MIN_LEASE_TTL_MS = 1_000;
export const DEFAULT_REQUEST_TTL_MS = 5_000;
export const MAX_REQUEST_TTL_MS = 30_000;
export const MAX_OPAQUE_FIELD_LENGTH = 128;
export const MAX_LABEL_LENGTH = 32;

/** How often the service worker polls Route Host for pending activate commands (ms). */
export const DEFAULT_POLL_INTERVAL_MS = 1_000;
/** Hard floor / ceiling for poll interval. */
export const MIN_POLL_INTERVAL_MS = 250;
export const MAX_POLL_INTERVAL_MS = 10_000;
/** Bound concurrent in-flight poll+activate work (single-flight). */
export const POLL_SINGLE_FLIGHT = true;

export const MessageTypes = Object.freeze({
  Health: 'health',
  RegisterAdapter: 'register-adapter',
  UnregisterAdapter: 'unregister-adapter',
  RegisterOwner: 'register-owner',
  UnregisterOwner: 'unregister-owner',
  Heartbeat: 'heartbeat',
  Freeze: 'freeze',
  Activate: 'activate',
  ActivateResult: 'activate-result',
  PollActivation: 'poll-activation',
  ActivationStatus: 'activation-status',
  Ping: 'ping',
  Result: 'result',
});

export const RouteResults = Object.freeze({
  Ready: 'ready',
  Miss: 'miss',
  Ambiguous: 'ambiguous',
  Stale: 'stale',
  AdapterUnavailable: 'adapter-unavailable',
  OwnerUnresolved: 'owner-unresolved',
  Accepted: 'accepted',
  Pending: 'pending',
  SessionUrlConfirmed: 'session-url-confirmed',
  SessionConfirmed: 'session-confirmed',
  AlreadyActive: 'already-active',
  Timeout: 'timeout',
  Replay: 'replay',
  Rejected: 'rejected',
  ProtocolMismatch: 'protocol-mismatch',
  Oversized: 'oversized',
  Expired: 'expired',
  ForegroundDenied: 'foreground-denied',
  SelectFailed: 'select-failed',
  Ok: 'ok',
});

export const RejectReasons = Object.freeze({
  MissingField: 'missing-field',
  InvalidField: 'invalid-field',
  ProtocolMismatch: 'protocol-mismatch',
  Oversized: 'oversized',
  Expired: 'expired',
  Replay: 'replay',
  Capacity: 'capacity',
  UnknownType: 'unknown-type',
  CallerRejected: 'caller-rejected',
  AdapterUnknown: 'adapter-unknown',
  SnapshotUnknown: 'snapshot-unknown',
  SnapshotMismatch: 'snapshot-mismatch',
  OwnerChanged: 'owner-changed',
  LeaseExpired: 'lease-expired',
  OriginRejected: 'origin-rejected',
  SessionUnresolved: 'session-unresolved',
  TabMissing: 'tab-missing',
  PageKeyMismatch: 'page-key-mismatch',
  RoutingKeyMismatch: 'routing-key-mismatch',
  WindowMissing: 'window-missing',
  NoPending: 'no-pending',
  ActivationUnknown: 'activation-unknown',
  PendingAdapterDelivery: 'pending-adapter-delivery',
  WrongAdapter: 'wrong-adapter',
});

export const AllowedAdapterKinds = Object.freeze(['chrome', 'edge']);

/**
 * Session ID character rules for Pi Web `?session=`.
 * Accept non-empty opaque tokens without control characters.
 */
export const SESSION_ID_MAX_LENGTH = 256;
export const SESSION_ID_MIN_LENGTH = 1;
