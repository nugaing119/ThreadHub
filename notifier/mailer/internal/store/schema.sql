CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS events (
    event_hash TEXT PRIMARY KEY CHECK(length(event_hash) = 64),
    post_id TEXT,
    permalink TEXT,
    occurred_at_ms INTEGER NOT NULL,
    accepted_at_ms INTEGER NOT NULL,
    terminal_at_ms INTEGER
);

CREATE TABLE IF NOT EXISTS deliveries (
    event_hash TEXT NOT NULL REFERENCES events(event_hash) ON DELETE CASCADE,
    recipient_hash TEXT NOT NULL CHECK(length(recipient_hash) = 64),
    email TEXT,
    status TEXT NOT NULL CHECK(status IN (
        'pending', 'sending', 'sent', 'failed_permanent',
        'failed_exhausted', 'cancelled'
    )),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    next_attempt_at_ms INTEGER NOT NULL,
    lease_until_ms INTEGER,
    last_error_class TEXT,
    last_smtp_code INTEGER,
    sent_at_ms INTEGER,
    updated_at_ms INTEGER NOT NULL,
    PRIMARY KEY (event_hash, recipient_hash)
);

CREATE INDEX IF NOT EXISTS deliveries_due_idx
    ON deliveries(status, next_attempt_at_ms);

CREATE TABLE IF NOT EXISTS nonces (
    nonce_hash TEXT PRIMARY KEY CHECK(length(nonce_hash) = 64),
    expires_at_ms INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS service_state (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
