package store

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const (
	testPostID    = "0123456789abcdefghijklmnop"
	testPostIDTwo = "ponmlkjihgfedcba9876543210"
)

var (
	testSecret = bytes.Repeat([]byte{0x2a}, 32)
	testNow    = time.Date(2026, 8, 27, 4, 5, 6, 0, time.UTC)
)

func TestOpenCreatesSchemaV2WithRequiredPragmasAndIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	store := openTestStore(t, path)

	if got := queryInt64(t, store, "SELECT version FROM schema_version"); got != 2 {
		t.Fatalf("schema version = %d, want 2", got)
	}
	for pragma, want := range map[string]string{
		"journal_mode":  "wal",
		"foreign_keys":  "1",
		"secure_delete": "1",
		"busy_timeout":  "5000",
	} {
		var got string
		if err := store.db.QueryRow("PRAGMA " + pragma).Scan(&got); err != nil {
			t.Fatalf("read PRAGMA %s: %v", pragma, err)
		}
		if got != want {
			t.Errorf("PRAGMA %s = %q, want %q", pragma, got, want)
		}
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	store, err := Open(path, testSecret)
	if err != nil {
		t.Fatalf("second Open() error = %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	if got := queryInt64(t, store, "SELECT count(*) FROM schema_version"); got != 1 {
		t.Fatalf("schema version rows after second open = %d, want 1", got)
	}
}

func TestOpenMigratesExistingSchemaV1WithoutDroppingQueuedData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	if _, err := db.Exec(schemaBootstrap); err != nil {
		t.Fatalf("bootstrap v1 schema: %v", err)
	}
	if _, err := db.Exec("INSERT INTO schema_version(version) VALUES (1)"); err != nil {
		t.Fatalf("record v1 schema: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO events(event_hash, post_id, permalink, occurred_at_ms, accepted_at_ms)
		VALUES(?, ?, ?, ?, ?)`, strings.Repeat("a", 64), testPostID,
		"https://threadhub.example.test/_redirect/pl/"+testPostID, testNow.UnixMilli(), testNow.UnixMilli()); err != nil {
		t.Fatalf("seed v1 event: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close v1 database: %v", err)
	}

	store := openTestStore(t, path)
	if got := queryInt64(t, store, "SELECT version FROM schema_version"); got != 2 {
		t.Fatalf("schema version = %d, want 2", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE post_id IS NOT NULL"); got != 1 {
		t.Fatalf("queued v1 events = %d, want 1 preserved", got)
	}
	for _, column := range []string{"team_name", "channel_name", "event_type"} {
		var count int64
		if err := store.db.QueryRow("SELECT count(*) FROM pragma_table_info('events') WHERE name = ?", column).Scan(&count); err != nil || count != 1 {
			t.Fatalf("migrated column %s count = %d, error = %v", column, count, err)
		}
	}
}

func TestInspectReportsSchemaV1WithoutMigrating(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	if _, err := db.Exec(schemaBootstrap); err != nil {
		t.Fatalf("bootstrap v1 schema: %v", err)
	}
	if _, err := db.Exec("INSERT INTO schema_version(version) VALUES (1)"); err != nil {
		t.Fatalf("record v1 schema: %v", err)
	}
	eventHash := strings.Repeat("a", 64)
	if _, err := db.Exec(`INSERT INTO events(event_hash, occurred_at_ms, accepted_at_ms)
		VALUES(?, 1, 1)`, eventHash); err != nil {
		t.Fatalf("seed v1 event: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO deliveries(
		event_hash, recipient_hash, status, next_attempt_at_ms, updated_at_ms)
		VALUES(?, ?, 'pending', 1, 1)`, eventHash, strings.Repeat("b", 64)); err != nil {
		t.Fatalf("seed v1 delivery: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close v1 database: %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatalf("chmod v1 database: %v", err)
	}

	got, err := Inspect(path)
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if got.SchemaVersion != 1 || got.Events != 1 || got.Pending != 1 {
		t.Fatalf("Inspect() = %+v, want schema=1 events=1 pending=1", got)
	}

	db, err = sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("reopen v1 database: %v", err)
	}
	defer db.Close()
	var version int
	if err := db.QueryRow("SELECT version FROM schema_version").Scan(&version); err != nil {
		t.Fatalf("read schema version after inspection: %v", err)
	}
	if version != 1 {
		t.Fatalf("inspection migrated schema to %d, want 1", version)
	}
}

func TestInspectOfflineReadsClosedWALDatabaseFromReadOnlyDirectory(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "queue.db")
	store := openTestStore(t, path)
	if err := store.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	for _, sidecar := range []string{path + "-wal", path + "-shm"} {
		if err := os.Remove(sidecar); err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("remove closed WAL sidecar %s: %v", filepath.Base(sidecar), err)
		}
	}
	if err := os.Chmod(dir, 0o500); err != nil {
		t.Fatalf("Chmod(read-only directory) error = %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o700) })

	inspection, err := InspectOffline(path)
	if err != nil {
		t.Fatalf("InspectOffline(closed WAL database in read-only directory) error = %v", err)
	}
	if inspection.SchemaVersion != 2 {
		t.Fatalf("InspectOffline() schema version = %d, want 2", inspection.SchemaVersion)
	}
}

func TestInspectReportsOnlySafeAggregatesForSchemaV2(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	store := openTestStore(t, path)
	if err := store.Close(); err != nil {
		t.Fatalf("close schema v2 store: %v", err)
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	eventHash := strings.Repeat("c", 64)
	if _, err := db.Exec(`INSERT INTO events(event_hash, occurred_at_ms, accepted_at_ms)
		VALUES(?, 1, 1)`, eventHash); err != nil {
		t.Fatalf("seed event: %v", err)
	}
	statuses := []string{"pending", "sending", "sent", "failed_permanent", "failed_exhausted", "cancelled"}
	for index, status := range statuses {
		recipientHash := strings.Repeat(string(rune('d'+index)), 64)
		if _, err := db.Exec(`INSERT INTO deliveries(
			event_hash, recipient_hash, status, next_attempt_at_ms, updated_at_ms)
			VALUES(?, ?, ?, 1, 1)`, eventHash, recipientHash, status); err != nil {
			t.Fatalf("seed %s delivery: %v", status, err)
		}
	}
	if _, err := db.Exec("INSERT INTO nonces(nonce_hash, expires_at_ms) VALUES(?, 1)", strings.Repeat("f", 64)); err != nil {
		t.Fatalf("seed nonce: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close seeded database: %v", err)
	}

	got, err := Inspect(path)
	if err != nil {
		t.Fatalf("Inspect() error = %v", err)
	}
	if got.SchemaVersion != 2 || got.Events != 1 || got.Nonces != 1 ||
		got.Pending != 1 || got.Sending != 1 || got.Sent != 1 ||
		got.Failed != 2 || got.Cancelled != 1 {
		t.Fatalf("Inspect() = %+v, want schema=2 events=1 nonces=1 and fixed delivery aggregates", got)
	}
}

func TestInspectRejectsUnsafeDatabasePathsAndModes(t *testing.T) {
	t.Run("relative path", func(t *testing.T) {
		if _, err := Inspect("queue.db"); !errors.Is(err, ErrInvalidStore) {
			t.Fatalf("Inspect(relative) error = %v, want ErrInvalidStore", err)
		}
	})

	t.Run("mode other than 0600", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "queue.db")
		store := openTestStore(t, path)
		if err := store.Close(); err != nil {
			t.Fatalf("Close() error = %v", err)
		}
		if err := os.Chmod(path, 0o640); err != nil {
			t.Fatalf("Chmod() error = %v", err)
		}
		if _, err := Inspect(path); !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("Inspect(mode 0640) error = %v, want ErrUnsafePath", err)
		}
	})

	t.Run("symlink file", func(t *testing.T) {
		dir := t.TempDir()
		realPath := filepath.Join(dir, "real.db")
		store := openTestStore(t, realPath)
		if err := store.Close(); err != nil {
			t.Fatalf("Close() error = %v", err)
		}
		linkedPath := filepath.Join(dir, "linked.db")
		if err := os.Symlink(realPath, linkedPath); err != nil {
			t.Fatalf("Symlink() error = %v", err)
		}
		if _, err := Inspect(linkedPath); !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("Inspect(symlink file) error = %v, want ErrUnsafePath", err)
		}
	})

	t.Run("symlink parent", func(t *testing.T) {
		dir := t.TempDir()
		realParent := filepath.Join(dir, "real")
		if err := os.Mkdir(realParent, 0o700); err != nil {
			t.Fatalf("Mkdir() error = %v", err)
		}
		realPath := filepath.Join(realParent, "queue.db")
		store := openTestStore(t, realPath)
		if err := store.Close(); err != nil {
			t.Fatalf("Close() error = %v", err)
		}
		linkedParent := filepath.Join(dir, "linked")
		if err := os.Symlink(realParent, linkedParent); err != nil {
			t.Fatalf("Symlink() error = %v", err)
		}
		if _, err := Inspect(filepath.Join(linkedParent, "queue.db")); !errors.Is(err, ErrUnsafePath) {
			t.Fatalf("Inspect(symlink parent) error = %v, want ErrUnsafePath", err)
		}
	})
}

func TestInspectRejectsUnexpectedDeliveryStatus(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("sql.Open() error = %v", err)
	}
	for _, statement := range []string{
		"CREATE TABLE schema_version (version INTEGER PRIMARY KEY)",
		"INSERT INTO schema_version(version) VALUES (2)",
		"CREATE TABLE events (event_hash TEXT PRIMARY KEY)",
		"CREATE TABLE nonces (nonce_hash TEXT PRIMARY KEY)",
		"CREATE TABLE deliveries (status TEXT NOT NULL)",
		"INSERT INTO deliveries(status) VALUES ('unexpected')",
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("Exec(%q) error = %v", statement, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatalf("Chmod() error = %v", err)
	}

	if _, err := Inspect(path); err == nil {
		t.Fatal("Inspect(unexpected delivery status) error = nil")
	}
}

func TestInspectRejectsUnsupportedCorruptOrAmbiguousSchema(t *testing.T) {
	t.Run("unsupported version", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "queue.db")
		store := openTestStore(t, path)
		if _, err := store.db.Exec("UPDATE schema_version SET version = 3"); err != nil {
			t.Fatalf("set unsupported version: %v", err)
		}
		if err := store.Close(); err != nil {
			t.Fatalf("Close() error = %v", err)
		}
		if _, err := Inspect(path); err == nil {
			t.Fatal("Inspect(unsupported version) error = nil")
		}
	})

	t.Run("multiple version rows", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "queue.db")
		store := openTestStore(t, path)
		if _, err := store.db.Exec("INSERT INTO schema_version(version) VALUES (1)"); err != nil {
			t.Fatalf("insert second schema version: %v", err)
		}
		if err := store.Close(); err != nil {
			t.Fatalf("Close() error = %v", err)
		}
		if _, err := Inspect(path); err == nil {
			t.Fatal("Inspect(multiple versions) error = nil")
		}
	})

	t.Run("corrupt schema", func(t *testing.T) {
		path := filepath.Join(t.TempDir(), "queue.db")
		file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			t.Fatalf("create corrupt database: %v", err)
		}
		if err := file.Close(); err != nil {
			t.Fatalf("close corrupt database: %v", err)
		}
		if _, err := Inspect(path); err == nil {
			t.Fatal("Inspect(corrupt schema) error = nil")
		}
	})
}

func TestOpenEnforcesPrivateRegularFileAndRejectsSymlinks(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "queue.db")
	store := openTestStore(t, path)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat(queue): %v", err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("queue mode = %04o, want 0600", got)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	realParent := filepath.Join(dir, "real")
	if err := os.Mkdir(realParent, 0o700); err != nil {
		t.Fatalf("Mkdir(real parent): %v", err)
	}
	linkedParent := filepath.Join(dir, "linked")
	if err := os.Symlink(realParent, linkedParent); err != nil {
		t.Fatalf("Symlink(parent): %v", err)
	}
	if linkedStore, err := Open(filepath.Join(linkedParent, "queue.db"), testSecret); err == nil {
		_ = linkedStore.Close()
		t.Fatal("Open() accepted a symlink parent directory")
	}

	realFile := filepath.Join(dir, "real.db")
	file, err := os.OpenFile(realFile, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("create real DB target: %v", err)
	}
	_ = file.Close()
	if err := os.Symlink(realFile, filepath.Join(dir, "linked.db")); err != nil {
		t.Fatalf("Symlink(DB): %v", err)
	}
	if linkedStore, err := Open(filepath.Join(dir, "linked.db"), testSecret); err == nil {
		_ = linkedStore.Close()
		t.Fatal("Open() accepted a symlink database file")
	}
}

func TestCloseReleasesDatabaseCleanly(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	if err := store.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if err := store.db.Ping(); err == nil {
		t.Fatal("Ping() after Close() error = nil")
	}
}

func TestAcceptCommitsNonceEventAndDeliveriesAtomically(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	if _, err := store.db.Exec(`CREATE TRIGGER fixture_reject_delivery BEFORE INSERT ON deliveries
		BEGIN SELECT RAISE(ABORT, 'fixture delivery failure'); END`); err != nil {
		t.Fatalf("create failure trigger: %v", err)
	}

	if _, err := store.Accept(context.Background(), hashFixture("nonce", "atomic"), eventWithRecipients(2), testNow); err == nil {
		t.Fatal("Accept() error = nil, want injected delivery failure")
	}
	for _, table := range []string{"nonces", "events", "deliveries"} {
		if got := queryInt64(t, store, "SELECT count(*) FROM "+table); got != 0 {
			t.Errorf("%s rows after failed Accept() = %d, want 0", table, got)
		}
	}
}

func TestAcceptRejectsReplayAndFreezesFirstDeliverySet(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	event := eventWithRecipients(2)
	nonce := hashFixture("nonce", "first")

	got, err := store.Accept(ctx, nonce, event, testNow)
	if err != nil {
		t.Fatalf("first Accept() error = %v", err)
	}
	if got != (AcceptResult{Inserted: 2}) {
		t.Fatalf("first Accept() = %+v, want 2 inserted", got)
	}
	if _, err := store.Accept(ctx, nonce, event, testNow.Add(time.Second)); !errors.Is(err, ErrReplay) {
		t.Fatalf("replayed Accept() error = %v, want ErrReplay", err)
	}

	got, err = store.Accept(ctx, hashFixture("nonce", "second"), event, testNow.Add(2*time.Second))
	if err != nil {
		t.Fatalf("duplicate event Accept() error = %v", err)
	}
	if got != (AcceptResult{Duplicate: 2}) {
		t.Fatalf("duplicate event Accept() = %+v, want 2 duplicates", got)
	}

	changedRecipients := event
	changedRecipients.Recipients = append(changedRecipients.Recipients, protocol.Recipient{
		UserID: "zzzzzzzzzzzzzzzzzzzzzzzzzz",
		Email:  "late-recipient@example.test",
	})
	got, err = store.Accept(ctx, hashFixture("nonce", "third"), changedRecipients, testNow.Add(3*time.Second))
	if err != nil {
		t.Fatalf("changed recipient set Accept() error = %v", err)
	}
	if got != (AcceptResult{Duplicate: 3}) {
		t.Fatalf("changed recipient set Accept() = %+v, want frozen duplicate result", got)
	}
	if rows := queryInt64(t, store, "SELECT count(*) FROM deliveries"); rows != 2 {
		t.Fatalf("delivery rows = %d, want frozen set of 2", rows)
	}
}

func TestAcceptRejectsConflictingEventMetadata(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	event := eventWithRecipients(1)
	if _, err := store.Accept(ctx, hashFixture("nonce", "base"), event, testNow); err != nil {
		t.Fatalf("Accept(base) error = %v", err)
	}

	for _, test := range []struct {
		name   string
		mutate func(*protocol.Event)
	}{
		{"permalink", func(e *protocol.Event) { e.Permalink = "https://other.example.test/_redirect/pl/" + e.PostID }},
		{"occurred_at", func(e *protocol.Event) { e.OccurredAt++ }},
		{"team_name", func(e *protocol.Event) { e.TeamName = "Other team" }},
		{"channel_name", func(e *protocol.Event) { e.ChannelName = "Other channel" }},
		{"event_type", func(e *protocol.Event) { e.EventType = protocol.EventTypeThreadReply }},
	} {
		t.Run(test.name, func(t *testing.T) {
			changed := event
			test.mutate(&changed)
			_, err := store.Accept(ctx, hashFixture("nonce", test.name), changed, testNow.Add(time.Minute))
			if !errors.Is(err, ErrConflict) {
				t.Fatalf("Accept(conflict) error = %v, want ErrConflict", err)
			}
		})
	}
}

func TestClaimDueAtomicallyAcquiresLeaseAndOnlyExpiredLeaseResets(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	if _, err := store.Accept(ctx, hashFixture("nonce", "claim"), eventWithRecipients(1), testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}

	const lease = 2 * time.Minute
	start := make(chan struct{})
	claimed := make(chan *Delivery, 2)
	errs := make(chan error, 2)
	var group sync.WaitGroup
	for range 2 {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			delivery, err := store.ClaimDue(ctx, testNow, lease)
			claimed <- delivery
			errs <- err
		}()
	}
	close(start)
	group.Wait()
	close(claimed)
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("ClaimDue() error = %v", err)
		}
	}
	claimCount := 0
	for delivery := range claimed {
		if delivery != nil {
			claimCount++
			if delivery.AttemptCount != 1 || delivery.Email == "" || delivery.Permalink == "" ||
				delivery.TeamName != "All" || delivery.ChannelName != "Mentor & Mentee" || delivery.EventType != protocol.EventTypeNewPost {
				t.Errorf("claimed delivery = %+v, want first complete attempt", delivery)
			}
		}
	}
	if claimCount != 1 {
		t.Fatalf("concurrent claim count = %d, want 1", claimCount)
	}

	if reset, err := store.ResetExpiredLeases(ctx, testNow.Add(lease-time.Millisecond)); err != nil || reset != 0 {
		t.Fatalf("ResetExpiredLeases(before expiry) = %d, %v; want 0, nil", reset, err)
	}
	if reset, err := store.ResetExpiredLeases(ctx, testNow.Add(lease)); err != nil || reset != 1 {
		t.Fatalf("ResetExpiredLeases(at expiry) = %d, %v; want 1, nil", reset, err)
	}
	delivery, err := store.ClaimDue(ctx, testNow.Add(lease), lease)
	if err != nil || delivery == nil || delivery.AttemptCount != 2 {
		t.Fatalf("ClaimDue(after reset) = %+v, %v; want attempt 2", delivery, err)
	}
}

func TestExpiredEighthAttemptCannotBeClaimedNinthTime(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	if _, err := store.Accept(ctx, hashFixture("nonce", "eighth-attempt-crash"), eventWithRecipients(1), testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}

	for attempt := 1; attempt <= 7; attempt++ {
		delivery, err := store.ClaimDue(ctx, testNow, 2*time.Minute)
		if err != nil || delivery == nil || delivery.AttemptCount != attempt {
			t.Fatalf("ClaimDue(attempt %d) = %+v, %v", attempt, delivery, err)
		}
		if err := store.MarkTemporary(ctx, delivery.Key, "smtp_4xx", 421, testNow); err != nil {
			t.Fatalf("MarkTemporary(attempt %d) error = %v", attempt, err)
		}
	}

	eighthClaimAt := testNow.Add(time.Hour)
	eighth, err := store.ClaimDue(ctx, eighthClaimAt, 2*time.Minute)
	if err != nil || eighth == nil || eighth.AttemptCount != 8 {
		t.Fatalf("ClaimDue(attempt 8) = %+v, %v", eighth, err)
	}
	leaseExpiry := eighthClaimAt.Add(2 * time.Minute)
	if recovered, err := store.ResetExpiredLeases(ctx, leaseExpiry); err != nil || recovered != 1 {
		t.Fatalf("ResetExpiredLeases() = %d, %v; want 1, nil", recovered, err)
	}
	if ninth, err := store.ClaimDue(ctx, leaseExpiry, 2*time.Minute); err != nil || ninth != nil {
		t.Fatalf("ClaimDue(after crashed attempt 8) = %+v, %v; want no ninth attempt", ninth, err)
	}

	var status string
	var attempts, updatedAt int64
	var email string
	var lease any
	if err := store.db.QueryRow(`SELECT status, attempt_count, email, lease_until_ms, updated_at_ms
		FROM deliveries`).Scan(&status, &attempts, &email, &lease, &updatedAt); err != nil {
		t.Fatalf("read recovered delivery: %v", err)
	}
	if status != "failed_exhausted" || attempts != 8 || email == "" || lease != nil || updatedAt != eighthClaimAt.UnixMilli() {
		t.Fatalf("recovered delivery = status %q attempts %d email_present %t lease %v updated_at %d; want exhausted attempt 8 anchored at %d",
			status, attempts, email != "", lease, updatedAt, eighthClaimAt.UnixMilli())
	}

	if _, err := store.Prune(ctx, eighthClaimAt.Add(24*time.Hour-time.Millisecond)); err != nil {
		t.Fatalf("Prune(before exhausted retention) error = %v", err)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE status = 'failed_exhausted' AND email IS NOT NULL`); got != 1 {
		t.Fatalf("retryable exhausted deliveries before 24 hours = %d, want 1", got)
	}
	if _, err := store.Prune(ctx, eighthClaimAt.Add(24*time.Hour)); err != nil {
		t.Fatalf("Prune(at exhausted retention) error = %v", err)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE status = 'cancelled' AND email IS NULL`); got != 1 {
		t.Fatalf("cancelled scrubbed deliveries at 24 hours = %d, want 1", got)
	}
}

func TestTerminalMarksScrubEmailAndEventIdentifiers(t *testing.T) {
	path := filepath.Join(t.TempDir(), "queue.db")
	store := openTestStore(t, path)
	ctx := context.Background()
	event := eventWithRecipients(2)
	if _, err := store.Accept(ctx, hashFixture("nonce", "scrub"), event, testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}

	first, err := store.ClaimDue(ctx, testNow, 2*time.Minute)
	if err != nil || first == nil {
		t.Fatalf("first ClaimDue() = %+v, %v", first, err)
	}
	if err := store.MarkSent(ctx, first.Key, testNow.Add(time.Second)); err != nil {
		t.Fatalf("MarkSent() error = %v", err)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM deliveries WHERE email IS NULL"); got != 1 {
		t.Fatalf("scrubbed delivery count after success = %d, want 1", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE permalink IS NOT NULL"); got != 1 {
		t.Fatal("event permalink scrubbed while another recipient remained pending")
	}

	second, err := store.ClaimDue(ctx, testNow.Add(2*time.Second), 2*time.Minute)
	if err != nil || second == nil {
		t.Fatalf("second ClaimDue() = %+v, %v", second, err)
	}
	if err := store.MarkPermanent(ctx, second.Key, "smtp_5xx", 550, testNow.Add(3*time.Second)); err != nil {
		t.Fatalf("MarkPermanent() error = %v", err)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM deliveries WHERE email IS NOT NULL"); got != 0 {
		t.Fatalf("deliveries retaining email = %d, want 0", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE post_id IS NOT NULL OR permalink IS NOT NULL"); got != 0 {
		t.Fatalf("events retaining identifiers = %d, want 0", got)
	}

	if _, err := store.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)"); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}
	if _, err := store.db.Exec("VACUUM"); err != nil {
		t.Fatalf("VACUUM: %v", err)
	}
	for _, dbPath := range []string{path, path + "-wal", path + "-shm"} {
		contents, err := os.ReadFile(dbPath)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			t.Fatalf("read SQLite file: %v", err)
		}
		for _, forbidden := range []string{event.PostID, event.Permalink, event.Recipients[0].Email, event.Recipients[1].Email} {
			if bytes.Contains(contents, []byte(forbidden)) {
				t.Fatalf("SQLite file %s retained a scrubbed fixture value", filepath.Base(dbPath))
			}
		}
	}
}

func TestExhaustedDeliveryRetryAndRetentionBoundaries(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()

	retryEvent := eventWithRecipients(1)
	if _, err := store.Accept(ctx, hashFixture("nonce", "retryable"), retryEvent, testNow); err != nil {
		t.Fatalf("Accept(retryable) error = %v", err)
	}
	exhaustOne(t, store, testNow)
	if retried, err := store.RetryExhausted(ctx, testNow.Add(24*time.Hour-time.Millisecond)); err != nil || retried != 1 {
		t.Fatalf("RetryExhausted(within window) = %d, %v; want 1, nil", retried, err)
	}
	retriedDelivery, err := store.ClaimDue(ctx, testNow.Add(24*time.Hour-time.Millisecond), 2*time.Minute)
	if err != nil || retriedDelivery == nil || retriedDelivery.AttemptCount != 1 {
		t.Fatalf("ClaimDue(manual retry) = %+v, %v; want reset attempt 1", retriedDelivery, err)
	}
	if err := store.MarkSent(ctx, retriedDelivery.Key, testNow.Add(24*time.Hour)); err != nil {
		t.Fatalf("MarkSent(retried) error = %v", err)
	}

	cancelEvent := eventWithID(testPostIDTwo)
	cancelStart := testNow.Add(48 * time.Hour)
	if _, err := store.Accept(ctx, hashFixture("nonce", "expiry"), cancelEvent, cancelStart); err != nil {
		t.Fatalf("Accept(expiry) error = %v", err)
	}
	exhaustOne(t, store, cancelStart)
	if retried, err := store.RetryExhausted(ctx, cancelStart.Add(24*time.Hour)); err != nil || retried != 0 {
		t.Fatalf("RetryExhausted(at expiry) = %d, %v; want 0, nil", retried, err)
	}
	pruned, err := store.Prune(ctx, cancelStart.Add(24*time.Hour))
	if err != nil {
		t.Fatalf("Prune(exhausted expiry) error = %v", err)
	}
	if pruned.Nonces == 0 {
		t.Fatal("Prune() did not remove expired nonces")
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM deliveries WHERE status = 'cancelled' AND email IS NULL"); got != 1 {
		t.Fatalf("cancelled scrubbed deliveries = %d, want 1", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE event_hash = ? AND post_id IS NULL AND permalink IS NULL AND team_name IS NULL AND channel_name IS NULL AND event_type IS NULL", protocol.HashIdentifier(testSecret, "event", cancelEvent.EventID)); got != 1 {
		t.Fatalf("scrubbed exhausted event rows = %d, want 1", got)
	}

	pruned, err = store.Prune(ctx, cancelStart.Add(24*time.Hour+7*24*time.Hour-time.Millisecond))
	if err != nil {
		t.Fatalf("Prune(before terminal retention) error = %v", err)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE event_hash = ?", protocol.HashIdentifier(testSecret, "event", cancelEvent.EventID)); got != 1 {
		t.Fatalf("cancelled event rows before 7 days = %d, want 1 (earlier prune result: %+v)", got, pruned)
	}
	pruned, err = store.Prune(ctx, cancelStart.Add(24*time.Hour+7*24*time.Hour))
	if err != nil {
		t.Fatalf("Prune(at terminal retention) error = %v", err)
	}
	if pruned.Events != 1 || pruned.Deliveries != 1 {
		t.Fatalf("Prune(at 7 days) = %+v, want one event and delivery", pruned)
	}
}

func TestCancelFailedAtomicallyCancelsBothFailureStatesOnly(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()

	permanentEvent := eventWithID("11111111111111111111111111")
	permanentEvent.Recipients[0] = protocol.Recipient{UserID: "11111111111111111111111111", Email: "permanent-recipient@example.test"}
	if _, err := store.Accept(ctx, hashFixture("nonce", "permanent-cancel"), permanentEvent, testNow); err != nil {
		t.Fatalf("Accept(permanent) error = %v", err)
	}
	permanentDelivery, err := store.ClaimDue(ctx, testNow, 2*time.Minute)
	if err != nil || permanentDelivery == nil {
		t.Fatalf("ClaimDue(permanent) = %+v, %v", permanentDelivery, err)
	}
	if err := store.MarkPermanent(ctx, permanentDelivery.Key, "smtp_5xx", 550, testNow); err != nil {
		t.Fatalf("MarkPermanent() error = %v", err)
	}

	exhaustedAt := testNow.Add(time.Hour)
	exhaustedEvent := eventWithID("22222222222222222222222222")
	exhaustedEvent.Recipients[0] = protocol.Recipient{UserID: "22222222222222222222222222", Email: "exhausted-recipient@example.test"}
	if _, err := store.Accept(ctx, hashFixture("nonce", "exhausted-cancel"), exhaustedEvent, exhaustedAt); err != nil {
		t.Fatalf("Accept(exhausted) error = %v", err)
	}
	exhaustOne(t, store, exhaustedAt)

	sendingAt := testNow.Add(2 * time.Hour)
	sendingEvent := eventWithID("33333333333333333333333333")
	sendingEvent.Recipients[0] = protocol.Recipient{UserID: "33333333333333333333333333", Email: "sending-recipient@example.test"}
	if _, err := store.Accept(ctx, hashFixture("nonce", "sending-preserved"), sendingEvent, sendingAt); err != nil {
		t.Fatalf("Accept(sending) error = %v", err)
	}
	sendingDelivery, err := store.ClaimDue(ctx, sendingAt, 24*time.Hour)
	if err != nil || sendingDelivery == nil {
		t.Fatalf("ClaimDue(sending) = %+v, %v", sendingDelivery, err)
	}

	pendingAt := testNow.Add(3 * time.Hour)
	pendingEvent := eventWithID("44444444444444444444444444")
	pendingEvent.Recipients[0] = protocol.Recipient{UserID: "44444444444444444444444444", Email: "pending-recipient@example.test"}
	if _, err := store.Accept(ctx, hashFixture("nonce", "pending-preserved"), pendingEvent, pendingAt); err != nil {
		t.Fatalf("Accept(pending) error = %v", err)
	}

	cancelledAt := testNow.Add(4 * time.Hour)
	cancelled, err := store.CancelFailed(ctx, cancelledAt)
	if err != nil || cancelled != 2 {
		t.Fatalf("CancelFailed() = %d, %v; want 2, nil", cancelled, err)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE status = 'cancelled' AND email IS NULL AND lease_until_ms IS NULL AND updated_at_ms = ?`, cancelledAt.UnixMilli()); got != 2 {
		t.Fatalf("scrubbed failed cancellations = %d, want 2", got)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE event_hash = ? AND status = 'pending' AND email = ? AND lease_until_ms IS NULL`,
		protocol.HashIdentifier(testSecret, "event", pendingEvent.EventID), pendingEvent.Recipients[0].Email); got != 1 {
		t.Fatalf("intact pending deliveries = %d, want 1", got)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE event_hash = ? AND status = 'sending' AND email = ? AND lease_until_ms IS NOT NULL`,
		protocol.HashIdentifier(testSecret, "event", sendingEvent.EventID), sendingEvent.Recipients[0].Email); got != 1 {
		t.Fatalf("intact sending deliveries = %d, want 1", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE post_id IS NULL AND permalink IS NULL AND team_name IS NULL AND channel_name IS NULL AND event_type IS NULL"); got != 2 {
		t.Fatalf("scrubbed completed failed events = %d, want 2", got)
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM events WHERE post_id IS NOT NULL AND permalink IS NOT NULL"); got != 2 {
		t.Fatalf("intact nonterminal events = %d, want 2", got)
	}
	status, err := store.Status(ctx, cancelledAt)
	if err != nil {
		t.Fatalf("Status() error = %v", err)
	}
	if status.FailedPermanent+status.FailedExhausted != 0 || status.Pending != 1 || status.Sending != 1 || status.Cancelled != 2 {
		t.Fatalf("Status() = %+v, want exact failed=0 pending=1 sending=1 cancelled=2", status)
	}
}

func TestCancelFailedRollsBackCancellationWhenCompletedEventScrubFails(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	if _, err := store.Accept(ctx, hashFixture("nonce", "cancel-rollback"), eventWithRecipients(1), testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}
	exhaustOne(t, store, testNow)
	if _, err := store.db.Exec(`CREATE TRIGGER fail_completed_event_scrub BEFORE UPDATE OF post_id ON events
		WHEN NEW.post_id IS NULL BEGIN SELECT RAISE(ABORT, 'synthetic scrub failure'); END`); err != nil {
		t.Fatalf("create scrub failure trigger: %v", err)
	}

	if cancelled, err := store.CancelFailed(ctx, testNow.Add(time.Hour)); err == nil || cancelled != 0 {
		t.Fatalf("CancelFailed() = %d, %v; want 0 and scrub failure", cancelled, err)
	}
	if got := queryInt64(t, store, `SELECT count(*) FROM deliveries
		WHERE status = 'failed_exhausted' AND email = 'first-recipient@example.test'`); got != 1 {
		t.Fatalf("failed delivery after rollback = %d, want 1 with address intact", got)
	}
}

func TestPruneExpiresNonceAtTenMinuteBoundary(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	if _, err := store.Accept(ctx, hashFixture("nonce", "ten-minute-boundary"), eventWithRecipients(1), testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}
	if result, err := store.Prune(ctx, testNow.Add(10*time.Minute-time.Millisecond)); err != nil || result.Nonces != 0 {
		t.Fatalf("Prune(before nonce expiry) = %+v, %v; want nonce retained", result, err)
	}
	if result, err := store.Prune(ctx, testNow.Add(10*time.Minute)); err != nil || result.Nonces != 1 {
		t.Fatalf("Prune(at nonce expiry) = %+v, %v; want one nonce removed", result, err)
	}
}

func TestStatusReportsAggregateQueueStateWithoutIdentifiers(t *testing.T) {
	store := openTestStore(t, filepath.Join(t.TempDir(), "queue.db"))
	ctx := context.Background()
	event := eventWithRecipients(2)
	event.Recipients = append(event.Recipients, protocol.Recipient{
		UserID: "dddddddddddddddddddddddddd",
		Email:  "pending-recipient@example.test",
	})
	if _, err := store.Accept(ctx, hashFixture("nonce", "status"), event, testNow); err != nil {
		t.Fatalf("Accept() error = %v", err)
	}
	delivery, err := store.ClaimDue(ctx, testNow.Add(5*time.Second), 2*time.Minute)
	if err != nil || delivery == nil {
		t.Fatalf("ClaimDue() = %+v, %v", delivery, err)
	}
	if err := store.MarkPermanent(ctx, delivery.Key, "smtp_5xx", 550, testNow.Add(6*time.Second)); err != nil {
		t.Fatalf("MarkPermanent() error = %v", err)
	}
	delivery, err = store.ClaimDue(ctx, testNow.Add(7*time.Second), 2*time.Minute)
	if err != nil || delivery == nil {
		t.Fatalf("second ClaimDue() = %+v, %v", delivery, err)
	}
	if err := store.MarkSent(ctx, delivery.Key, testNow.Add(8*time.Second)); err != nil {
		t.Fatalf("MarkSent() error = %v", err)
	}

	status, err := store.Status(ctx, testNow.Add(10*time.Second))
	if err != nil {
		t.Fatalf("Status() error = %v", err)
	}
	if status.Sent != 1 || status.FailedPermanent != 1 || status.Pending != 1 ||
		status.OldestPendingSeconds != 10 || status.LastSuccessAt != testNow.Add(8*time.Second).UnixMilli() ||
		status.LastErrorClass != "smtp_5xx" || status.LastSMTPCode != 550 {
		t.Fatalf("Status() = %+v, want aggregate sent/pending state", status)
	}
}

func openTestStore(t *testing.T, path string) *SQLiteStore {
	t.Helper()
	store, err := Open(path, testSecret)
	if err != nil {
		t.Fatalf("Open() error = %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func eventWithRecipients(count int) protocol.Event {
	event := eventWithID(testPostID)
	event.Recipients = []protocol.Recipient{
		{UserID: "aaaaaaaaaaaaaaaaaaaaaaaaaa", Email: "first-recipient@example.test"},
		{UserID: "bbbbbbbbbbbbbbbbbbbbbbbbbb", Email: "second-recipient@example.test"},
	}[:count]
	return event
}

func eventWithID(id string) protocol.Event {
	return protocol.Event{
		EventID:     id,
		PostID:      id,
		Permalink:   "https://threadhub.example.test/_redirect/pl/" + id,
		OccurredAt:  testNow.Add(-time.Minute).UnixMilli(),
		TeamName:    "All",
		ChannelName: "Mentor & Mentee",
		EventType:   protocol.EventTypeNewPost,
		Recipients: []protocol.Recipient{{
			UserID: "cccccccccccccccccccccccccc",
			Email:  "expiry-recipient@example.test",
		}},
	}
}

func exhaustOne(t *testing.T, store *SQLiteStore, now time.Time) {
	t.Helper()
	for attempt := 1; attempt <= 8; attempt++ {
		delivery, err := store.ClaimDue(context.Background(), now, 2*time.Minute)
		if err != nil || delivery == nil {
			t.Fatalf("ClaimDue(attempt %d) = %+v, %v", attempt, delivery, err)
		}
		next := now
		if attempt == 8 {
			// Exhaustion retention starts when the final claim was made; a caller's
			// unused next-attempt value must not extend raw-email retention.
			next = now.Add(7 * 24 * time.Hour)
		}
		if err := store.MarkTemporary(context.Background(), delivery.Key, "smtp_4xx", 421, next); err != nil {
			t.Fatalf("MarkTemporary(attempt %d) error = %v", attempt, err)
		}
	}
	if got := queryInt64(t, store, "SELECT count(*) FROM deliveries WHERE status = 'failed_exhausted' AND email IS NOT NULL"); got != 1 {
		t.Fatalf("exhausted deliveries retaining email = %d, want 1", got)
	}
}

func hashFixture(purpose, value string) string {
	return protocol.HashIdentifier(testSecret, purpose, value)
}

func queryInt64(t *testing.T, store *SQLiteStore, query string, args ...any) int64 {
	t.Helper()
	var value int64
	if err := store.db.QueryRow(query, args...).Scan(&value); err != nil {
		t.Fatalf("query scalar: %v", err)
	}
	return value
}
