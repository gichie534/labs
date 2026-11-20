package session

import (
	"regexp"
	"strings"
	"testing"
)

var validSessionID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`)

func TestID(t *testing.T) {
	tests := []struct {
		name, team, channel, ts, want string
	}{
		{"thread", "T0123ABCDEF", "C0456GHIJKL", "1700000000.123456", "s-t0123abcdef-c0456ghijkl-1700000000-123456"},
		{"dm channel", "T1", "D99", "1.2", "s-t1-d99-1-2"},
		{"odd characters", "T 1", "C#2", "3.4", "s-t-1-c-2-3-4"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ID(tc.team, tc.channel, tc.ts)
			if got != tc.want {
				t.Fatalf("ID() = %q, want %q", got, tc.want)
			}
			if !validSessionID.MatchString(got) {
				t.Fatalf("ID() = %q is not a valid session ID", got)
			}
		})
	}
}

func TestIDIsStableAndBounded(t *testing.T) {
	long := strings.Repeat("C", 80)
	a := ID("T1", long, "1700000000.000001")
	b := ID("T1", long, "1700000000.000001")
	c := ID("T1", long, "1700000000.000002")
	if a != b {
		t.Fatalf("not stable: %q vs %q", a, b)
	}
	if a == c {
		t.Fatalf("different threads collided: %q", a)
	}
	if len(a) > maxSessionIDLen || !validSessionID.MatchString(a) {
		t.Fatalf("invalid long ID %q (%d chars)", a, len(a))
	}
}

func TestUserID(t *testing.T) {
	if got, want := UserID("T0123", "U0456"), "slack-t0123-u0456"; got != want {
		t.Fatalf("UserID() = %q, want %q", got, want)
	}
}
