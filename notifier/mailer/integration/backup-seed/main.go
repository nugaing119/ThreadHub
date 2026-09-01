// Command backup-seed inserts one pending delivery into the real notifier
// SQLite store for the isolated backup/restore integration test.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/nugaing119/ThreadHub/notifier/mailer/internal/store"
	"github.com/nugaing119/ThreadHub/notifier/protocol"
)

const integrationDomain = "threadhub.integration.test"

func main() {
	queuePath, queueOK := os.LookupEnv("NOTIFIER_QUEUE_PATH")
	secretHex, secretOK := os.LookupEnv("NOTIFIER_HMAC_SECRET")
	if !queueOK || !secretOK || queuePath == "" || secretHex == "" {
		fail()
	}
	secret, err := protocol.DecodeSecretHex(secretHex)
	if err != nil {
		fail()
	}
	queue, err := store.Open(queuePath, secret)
	if err != nil {
		fail()
	}
	defer queue.Close()

	now := time.Now().UTC()
	postID := strings.Repeat("b", 26)
	event := protocol.Event{
		EventID:    postID,
		PostID:     postID,
		Permalink:  "https://" + integrationDomain + "/_redirect/pl/" + postID,
		OccurredAt: now.Add(-time.Hour).UnixMilli(),
		Recipients: []protocol.Recipient{{
			UserID: strings.Repeat("c", 26),
			Email:  "queue@integration.invalid",
		}},
	}
	if err := event.Validate(integrationDomain); err != nil {
		fail()
	}
	result, err := queue.Accept(
		context.Background(),
		protocol.HashIdentifier(secret, "nonce", "backup-seed"),
		event,
		now,
	)
	if err != nil || result.Inserted != 1 || result.Duplicate != 0 {
		fail()
	}
	fmt.Println("seeded=1")
}

func fail() {
	fmt.Fprintln(os.Stderr, "backup-seed failed")
	os.Exit(1)
}
