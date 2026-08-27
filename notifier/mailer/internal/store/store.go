// Package store persists the notifier's replay claims and delivery queue.
package store

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/protocol"
	_ "modernc.org/sqlite"
)

const (
	nonceLifetime     = 10 * time.Minute
	exhaustedLifetime = 24 * time.Hour
	terminalLifetime  = 7 * 24 * time.Hour
	maximumAttempts   = 8
)

var (
	ErrReplay       = errors.New("nonce replay")
	ErrConflict     = errors.New("event conflict")
	ErrNotFound     = errors.New("delivery not found in required state")
	ErrInvalidLease = errors.New("invalid delivery lease")
	ErrUnsafePath   = errors.New("unsafe sqlite path")
	ErrInvalidStore = errors.New("invalid sqlite store configuration")
)

//go:embed schema.sql
var schemaV1 string

type DeliveryKey struct {
	EventHash     string
	RecipientHash string
}

type Delivery struct {
	Key                    DeliveryKey
	Email, Permalink       string
	AttemptCount           int
	AcceptedAt, OccurredAt time.Time
}

type AcceptResult struct {
	Inserted  int
	Duplicate int
}

type PruneResult struct {
	Nonces     int64
	Deliveries int64
	Events     int64
}

type Status struct {
	Pending, Sending, Sent, FailedPermanent, FailedExhausted, Cancelled int64
	OldestPendingSeconds                                                int64
	LastSuccessAt                                                       int64
	LastErrorClass                                                      string
	LastSMTPCode                                                        int
}

type Store interface {
	Accept(ctx context.Context, nonceHash string, event protocol.Event, now time.Time) (AcceptResult, error)
	ClaimDue(ctx context.Context, now time.Time, lease time.Duration) (*Delivery, error)
	MarkSent(ctx context.Context, key DeliveryKey, now time.Time) error
	MarkTemporary(ctx context.Context, key DeliveryKey, class string, code int, next time.Time) error
	MarkPermanent(ctx context.Context, key DeliveryKey, class string, code int, now time.Time) error
	ResetExpiredLeases(ctx context.Context, now time.Time) (int64, error)
	RetryExhausted(ctx context.Context, now time.Time) (int64, error)
	CancelExhausted(ctx context.Context, now time.Time) (int64, error)
	Prune(ctx context.Context, now time.Time) (PruneResult, error)
	Status(ctx context.Context, now time.Time) (Status, error)
}

type SQLiteStore struct {
	db     *sql.DB
	secret []byte
}

func Open(path string, secret []byte) (*SQLiteStore, error) {
	if len(secret) != 32 || !filepath.IsAbs(path) {
		return nil, ErrInvalidStore
	}
	if err := prepareDatabaseFile(path); err != nil {
		return nil, err
	}

	query := url.Values{}
	query.Add("_pragma", "foreign_keys(1)")
	query.Add("_pragma", "secure_delete(1)")
	query.Add("_pragma", "busy_timeout(5000)")
	query.Set("_txlock", "immediate")
	dsn := (&url.URL{Scheme: "file", Path: path, RawQuery: query.Encode()}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	store := &SQLiteStore{db: db, secret: append([]byte(nil), secret...)}
	if err := store.initialize(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return store, nil
}

func prepareDatabaseFile(path string) error {
	parentInfo, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		return fmt.Errorf("inspect sqlite parent: %w", err)
	}
	if parentInfo.Mode()&os.ModeSymlink != 0 || !parentInfo.IsDir() {
		return ErrUnsafePath
	}
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return ErrUnsafePath
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect sqlite file: %w", err)
	}

	fd, err := syscall.Open(path, syscall.O_CREAT|syscall.O_RDWR|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return fmt.Errorf("prepare sqlite file: %w", err)
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return errors.New("prepare sqlite file handle")
	}
	defer file.Close()
	if err := file.Chmod(0o600); err != nil {
		return fmt.Errorf("set sqlite file mode: %w", err)
	}
	info, err := file.Stat()
	if err != nil {
		return fmt.Errorf("verify sqlite file: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return ErrUnsafePath
	}
	return nil
}

func (s *SQLiteStore) initialize(ctx context.Context) error {
	if err := s.db.PingContext(ctx); err != nil {
		return fmt.Errorf("ping sqlite: %w", err)
	}
	var journalMode string
	if err := s.db.QueryRowContext(ctx, "PRAGMA journal_mode=WAL").Scan(&journalMode); err != nil || journalMode != "wal" {
		return fmt.Errorf("enable sqlite WAL: mode=%q: %w", journalMode, err)
	}
	for _, statement := range []string{
		"PRAGMA foreign_keys=ON",
		"PRAGMA secure_delete=ON",
		"PRAGMA busy_timeout=5000",
	} {
		if _, err := s.db.ExecContext(ctx, statement); err != nil {
			return fmt.Errorf("configure sqlite: %w", err)
		}
	}
	if _, err := s.db.ExecContext(ctx, schemaV1); err != nil {
		return fmt.Errorf("create sqlite schema: %w", err)
	}
	var count, version int
	if err := s.db.QueryRowContext(ctx, "SELECT count(*), COALESCE(max(version), 0) FROM schema_version").Scan(&count, &version); err != nil {
		return fmt.Errorf("read sqlite schema version: %w", err)
	}
	if count != 1 || version != 1 {
		return fmt.Errorf("unsupported sqlite schema version")
	}
	return s.verifyPragmas(ctx)
}

func (s *SQLiteStore) verifyPragmas(ctx context.Context) error {
	checks := []struct {
		name string
		want int
	}{
		{"foreign_keys", 1},
		{"secure_delete", 1},
		{"busy_timeout", 5000},
	}
	for _, check := range checks {
		var got int
		if err := s.db.QueryRowContext(ctx, "PRAGMA "+check.name).Scan(&got); err != nil {
			return fmt.Errorf("verify sqlite pragma %s: %w", check.name, err)
		}
		if got != check.want {
			return fmt.Errorf("verify sqlite pragma %s", check.name)
		}
	}
	return nil
}

func (s *SQLiteStore) Close() error {
	return s.db.Close()
}

func (s *SQLiteStore) Accept(ctx context.Context, nonceHash string, event protocol.Event, now time.Time) (AcceptResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return AcceptResult{}, err
	}
	defer tx.Rollback()

	result, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO nonces(nonce_hash, expires_at_ms) VALUES(?, ?)", nonceHash, now.Add(nonceLifetime).UnixMilli())
	if err != nil {
		return AcceptResult{}, err
	}
	inserted, err := result.RowsAffected()
	if err != nil {
		return AcceptResult{}, err
	}
	if inserted == 0 {
		return AcceptResult{}, ErrReplay
	}

	eventHash := protocol.HashIdentifier(s.secret, "event", event.EventID)
	result, err = tx.ExecContext(ctx, `INSERT OR IGNORE INTO events(
		event_hash, post_id, permalink, occurred_at_ms, accepted_at_ms
	) VALUES(?, ?, ?, ?, ?)`, eventHash, event.PostID, event.Permalink, event.OccurredAt, now.UnixMilli())
	if err != nil {
		return AcceptResult{}, err
	}
	eventInserted, err := result.RowsAffected()
	if err != nil {
		return AcceptResult{}, err
	}
	if eventInserted == 0 {
		var postID, permalink sql.NullString
		var occurredAt int64
		if err := tx.QueryRowContext(ctx, `SELECT post_id, permalink, occurred_at_ms
			FROM events WHERE event_hash = ?`, eventHash).Scan(&postID, &permalink, &occurredAt); err != nil {
			return AcceptResult{}, err
		}
		if occurredAt != event.OccurredAt || postID.Valid && postID.String != event.PostID || permalink.Valid && permalink.String != event.Permalink {
			return AcceptResult{}, ErrConflict
		}
		if err := tx.Commit(); err != nil {
			return AcceptResult{}, err
		}
		return AcceptResult{Duplicate: len(event.Recipients)}, nil
	}

	for _, recipient := range event.Recipients {
		recipientHash := protocol.HashIdentifier(s.secret, "recipient", recipient.UserID)
		if _, err := tx.ExecContext(ctx, `INSERT INTO deliveries(
			event_hash, recipient_hash, email, status, next_attempt_at_ms, updated_at_ms
		) VALUES(?, ?, ?, 'pending', ?, ?)`, eventHash, recipientHash, recipient.Email, now.UnixMilli(), now.UnixMilli()); err != nil {
			return AcceptResult{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return AcceptResult{}, err
	}
	return AcceptResult{Inserted: len(event.Recipients)}, nil
}

func (s *SQLiteStore) ClaimDue(ctx context.Context, now time.Time, lease time.Duration) (*Delivery, error) {
	if lease <= 0 {
		return nil, ErrInvalidLease
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var delivery Delivery
	var acceptedAt, occurredAt int64
	err = tx.QueryRowContext(ctx, `SELECT d.event_hash, d.recipient_hash, d.email, e.permalink,
		d.attempt_count, e.accepted_at_ms, e.occurred_at_ms
		FROM deliveries d JOIN events e USING(event_hash)
		WHERE d.status = 'pending' AND d.next_attempt_at_ms <= ?
		  AND d.email IS NOT NULL AND e.permalink IS NOT NULL
		ORDER BY d.next_attempt_at_ms, e.accepted_at_ms, d.event_hash, d.recipient_hash
		LIMIT 1`, now.UnixMilli()).Scan(
		&delivery.Key.EventHash, &delivery.Key.RecipientHash, &delivery.Email, &delivery.Permalink,
		&delivery.AttemptCount, &acceptedAt, &occurredAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		if err := tx.Commit(); err != nil {
			return nil, err
		}
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	result, err := tx.ExecContext(ctx, `UPDATE deliveries
		SET status = 'sending', attempt_count = attempt_count + 1,
			lease_until_ms = ?, updated_at_ms = ?
		WHERE event_hash = ? AND recipient_hash = ? AND status = 'pending'`,
		now.Add(lease).UnixMilli(), now.UnixMilli(), delivery.Key.EventHash, delivery.Key.RecipientHash)
	if err != nil {
		return nil, err
	}
	if changed, err := result.RowsAffected(); err != nil || changed != 1 {
		if err != nil {
			return nil, err
		}
		return nil, ErrNotFound
	}
	delivery.AttemptCount++
	delivery.AcceptedAt = time.UnixMilli(acceptedAt)
	delivery.OccurredAt = time.UnixMilli(occurredAt)
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &delivery, nil
}

func (s *SQLiteStore) MarkSent(ctx context.Context, key DeliveryKey, now time.Time) error {
	return s.markTerminal(ctx, key, "sent", "", 0, now)
}

func (s *SQLiteStore) MarkPermanent(ctx context.Context, key DeliveryKey, class string, code int, now time.Time) error {
	return s.markTerminal(ctx, key, "failed_permanent", class, code, now)
}

func (s *SQLiteStore) markTerminal(ctx context.Context, key DeliveryKey, status, class string, code int, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()

	var result sql.Result
	if status == "sent" {
		result, err = tx.ExecContext(ctx, `UPDATE deliveries SET
			status = 'sent', email = NULL, lease_until_ms = NULL,
			last_error_class = NULL, last_smtp_code = NULL,
			sent_at_ms = ?, updated_at_ms = ?
			WHERE event_hash = ? AND recipient_hash = ? AND status = 'sending'`,
			now.UnixMilli(), now.UnixMilli(), key.EventHash, key.RecipientHash)
	} else {
		result, err = tx.ExecContext(ctx, `UPDATE deliveries SET
			status = 'failed_permanent', email = NULL, lease_until_ms = NULL,
			last_error_class = ?, last_smtp_code = ?, updated_at_ms = ?
			WHERE event_hash = ? AND recipient_hash = ? AND status = 'sending'`,
			class, code, now.UnixMilli(), key.EventHash, key.RecipientHash)
	}
	if err != nil {
		return err
	}
	if err := requireOneRow(result); err != nil {
		return err
	}
	if status == "sent" {
		if err := setState(ctx, tx, "last_success_at", strconv.FormatInt(now.UnixMilli(), 10)); err != nil {
			return err
		}
	} else if err := setLastError(ctx, tx, class, code); err != nil {
		return err
	}
	if err := scrubEventIfComplete(ctx, tx, key.EventHash, now.UnixMilli()); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *SQLiteStore) MarkTemporary(ctx context.Context, key DeliveryKey, class string, code int, next time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE deliveries SET
		status = CASE WHEN attempt_count >= ? THEN 'failed_exhausted' ELSE 'pending' END,
		next_attempt_at_ms = ?, lease_until_ms = NULL,
		last_error_class = ?, last_smtp_code = ?,
		updated_at_ms = CASE WHEN attempt_count >= ? THEN updated_at_ms ELSE ? END
		WHERE event_hash = ? AND recipient_hash = ? AND status = 'sending'`,
		maximumAttempts, next.UnixMilli(), class, code, maximumAttempts, next.UnixMilli(), key.EventHash, key.RecipientHash)
	if err != nil {
		return err
	}
	if err := requireOneRow(result); err != nil {
		return err
	}
	if err := setLastError(ctx, tx, class, code); err != nil {
		return err
	}
	return tx.Commit()
}

func (s *SQLiteStore) ResetExpiredLeases(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `UPDATE deliveries SET
		status = CASE WHEN attempt_count >= ? THEN 'failed_exhausted' ELSE 'pending' END,
		lease_until_ms = NULL,
		updated_at_ms = CASE WHEN attempt_count >= ? THEN updated_at_ms ELSE ? END
		WHERE status = 'sending' AND lease_until_ms IS NOT NULL AND lease_until_ms <= ?`,
		maximumAttempts, maximumAttempts, now.UnixMilli(), now.UnixMilli())
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *SQLiteStore) RetryExhausted(ctx context.Context, now time.Time) (int64, error) {
	result, err := s.db.ExecContext(ctx, `UPDATE deliveries SET
		status = 'pending', attempt_count = 0, next_attempt_at_ms = ?,
		lease_until_ms = NULL, updated_at_ms = ?
		WHERE status = 'failed_exhausted' AND updated_at_ms > ? AND updated_at_ms <= ?`,
		now.UnixMilli(), now.UnixMilli(), now.Add(-exhaustedLifetime).UnixMilli(), now.UnixMilli())
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (s *SQLiteStore) CancelExhausted(ctx context.Context, now time.Time) (int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `UPDATE deliveries SET
		status = 'cancelled', email = NULL, lease_until_ms = NULL, updated_at_ms = ?
		WHERE status = 'failed_exhausted'`, now.UnixMilli())
	if err != nil {
		return 0, err
	}
	changed, err := result.RowsAffected()
	if err != nil {
		return 0, err
	}
	if err := scrubAllCompleteEvents(ctx, tx, now.UnixMilli()); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return changed, nil
}

func (s *SQLiteStore) Prune(ctx context.Context, now time.Time) (PruneResult, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return PruneResult{}, err
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `UPDATE deliveries SET
		status = 'cancelled', email = NULL, lease_until_ms = NULL, updated_at_ms = ?
		WHERE status = 'failed_exhausted' AND updated_at_ms <= ?`,
		now.UnixMilli(), now.Add(-exhaustedLifetime).UnixMilli()); err != nil {
		return PruneResult{}, err
	}
	if err := scrubAllCompleteEvents(ctx, tx, now.UnixMilli()); err != nil {
		return PruneResult{}, err
	}

	var pruned PruneResult
	result, err := tx.ExecContext(ctx, "DELETE FROM nonces WHERE expires_at_ms <= ?", now.UnixMilli())
	if err != nil {
		return PruneResult{}, err
	}
	if pruned.Nonces, err = result.RowsAffected(); err != nil {
		return PruneResult{}, err
	}
	terminalCutoff := now.Add(-terminalLifetime).UnixMilli()
	if err := tx.QueryRowContext(ctx, `SELECT count(*) FROM deliveries
		WHERE event_hash IN (SELECT event_hash FROM events WHERE terminal_at_ms <= ?)`, terminalCutoff).Scan(&pruned.Deliveries); err != nil {
		return PruneResult{}, err
	}
	result, err = tx.ExecContext(ctx, "DELETE FROM events WHERE terminal_at_ms <= ?", terminalCutoff)
	if err != nil {
		return PruneResult{}, err
	}
	if pruned.Events, err = result.RowsAffected(); err != nil {
		return PruneResult{}, err
	}
	if err := tx.Commit(); err != nil {
		return PruneResult{}, err
	}
	if err := s.maintainOncePerDay(ctx, now); err != nil {
		return PruneResult{}, err
	}
	return pruned, nil
}

func (s *SQLiteStore) Status(ctx context.Context, now time.Time) (Status, error) {
	var status Status
	rows, err := s.db.QueryContext(ctx, "SELECT status, count(*) FROM deliveries GROUP BY status")
	if err != nil {
		return Status{}, err
	}
	for rows.Next() {
		var name string
		var count int64
		if err := rows.Scan(&name, &count); err != nil {
			rows.Close()
			return Status{}, err
		}
		switch name {
		case "pending":
			status.Pending = count
		case "sending":
			status.Sending = count
		case "sent":
			status.Sent = count
		case "failed_permanent":
			status.FailedPermanent = count
		case "failed_exhausted":
			status.FailedExhausted = count
		case "cancelled":
			status.Cancelled = count
		}
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return Status{}, err
	}
	if err := rows.Close(); err != nil {
		return Status{}, err
	}

	var oldest sql.NullInt64
	if err := s.db.QueryRowContext(ctx, `SELECT min(e.accepted_at_ms) FROM deliveries d
		JOIN events e USING(event_hash) WHERE d.status = 'pending'`).Scan(&oldest); err != nil {
		return Status{}, err
	}
	if oldest.Valid && now.UnixMilli() > oldest.Int64 {
		status.OldestPendingSeconds = (now.UnixMilli() - oldest.Int64) / int64(time.Second/time.Millisecond)
	}
	states, err := readStates(ctx, s.db, "last_success_at", "last_error_class", "last_smtp_code")
	if err != nil {
		return Status{}, err
	}
	status.LastSuccessAt, _ = strconv.ParseInt(states["last_success_at"], 10, 64)
	status.LastErrorClass = states["last_error_class"]
	status.LastSMTPCode, _ = strconv.Atoi(states["last_smtp_code"])
	return status, nil
}

func requireOneRow(result sql.Result) error {
	changed, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if changed != 1 {
		return ErrNotFound
	}
	return nil
}

func scrubEventIfComplete(ctx context.Context, tx *sql.Tx, eventHash string, nowMS int64) error {
	_, err := tx.ExecContext(ctx, `UPDATE events SET
		post_id = NULL, permalink = NULL, terminal_at_ms = COALESCE(terminal_at_ms, ?)
		WHERE event_hash = ? AND NOT EXISTS (
			SELECT 1 FROM deliveries WHERE event_hash = ? AND email IS NOT NULL
		)`, nowMS, eventHash, eventHash)
	return err
}

func scrubAllCompleteEvents(ctx context.Context, tx *sql.Tx, nowMS int64) error {
	_, err := tx.ExecContext(ctx, `UPDATE events SET
		post_id = NULL, permalink = NULL, terminal_at_ms = COALESCE(terminal_at_ms, ?)
		WHERE terminal_at_ms IS NULL AND NOT EXISTS (
			SELECT 1 FROM deliveries WHERE deliveries.event_hash = events.event_hash AND email IS NOT NULL
		)`, nowMS)
	return err
}

func setLastError(ctx context.Context, tx *sql.Tx, class string, code int) error {
	if err := setState(ctx, tx, "last_error_class", class); err != nil {
		return err
	}
	return setState(ctx, tx, "last_smtp_code", strconv.Itoa(code))
}

func setState(ctx context.Context, tx *sql.Tx, key, value string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO service_state(key, value) VALUES(?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
	return err
}

type stateReader interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func readStates(ctx context.Context, db stateReader, keys ...string) (map[string]string, error) {
	values := make(map[string]string, len(keys))
	for _, key := range keys {
		var value string
		err := db.QueryRowContext(ctx, "SELECT value FROM service_state WHERE key = ?", key).Scan(&value)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, err
		}
		values[key] = value
	}
	return values, nil
}

func (s *SQLiteStore) maintainOncePerDay(ctx context.Context, now time.Time) error {
	day := now.UTC().Format(time.DateOnly)
	states, err := readStates(ctx, s.db, "last_maintenance_day")
	if err != nil {
		return err
	}
	if states["last_maintenance_day"] == day {
		return nil
	}
	var busy, logFrames, checkpointed int
	if err := s.db.QueryRowContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)").Scan(&busy, &logFrames, &checkpointed); err != nil {
		return err
	}
	if busy != 0 {
		return errors.New("sqlite checkpoint busy")
	}
	if _, err := s.db.ExecContext(ctx, "PRAGMA optimize"); err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `INSERT INTO service_state(key, value) VALUES('last_maintenance_day', ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, day)
	return err
}
