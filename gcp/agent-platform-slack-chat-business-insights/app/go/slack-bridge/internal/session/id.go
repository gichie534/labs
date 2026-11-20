// Package session maps Slack identities onto Agent Platform session and user IDs.
//
// One Slack thread is one Agent Platform session, so follow-up questions in a thread keep their context. One
// Slack user is one Agent Platform user ID, which is also the scope Memory Bank stores long-term memories under —
// so preferences follow the person across threads.
package session

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// maxSessionIDLen is the Sessions API limit: up to 63 characters of [a-z0-9-], starting with a letter and
// ending with a letter or digit.
const maxSessionIDLen = 63

// maxUserIDLen is the Agent Runtime limit for user_id.
const maxUserIDLen = 128

// ID returns the session ID for a Slack thread, e.g. "s-t0123-c0456-1700000000-123456".
func ID(team, channel, threadTS string) string {
	raw := "s-" + sanitize(team) + "-" + sanitize(channel) + "-" + sanitize(threadTS)
	return fit(raw, maxSessionIDLen)
}

// UserID returns the Agent Platform user ID for a Slack user, e.g. "slack-t0123-u0456".
func UserID(team, user string) string {
	return fit("slack-"+sanitize(team)+"-"+sanitize(user), maxUserIDLen)
}

// sanitize lowercases and replaces anything outside [a-z0-9] with '-'.
func sanitize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
		} else {
			b.WriteRune('-')
		}
	}
	return strings.Trim(b.String(), "-")
}

// fit keeps IDs within the limit by replacing the tail with a short hash of the full value, and makes sure the
// result ends with an alphanumeric character.
func fit(s string, max int) string {
	s = strings.TrimRight(s, "-")
	if len(s) <= max {
		return s
	}
	sum := sha256.Sum256([]byte(s))
	suffix := hex.EncodeToString(sum[:])[:12]
	return strings.TrimRight(s[:max-len(suffix)-1], "-") + "-" + suffix
}
