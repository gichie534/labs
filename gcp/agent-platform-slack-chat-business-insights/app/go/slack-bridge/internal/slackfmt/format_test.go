package slackfmt

import (
	"strings"
	"testing"
)

func TestToMrkdwn(t *testing.T) {
	tests := []struct{ name, in, want string }{
		{"bold", "Revenue was **$1,234**.", "Revenue was *$1,234*."},
		{"heading", "## Summary\nok", "*Summary*\nok"},
		{"link", "See [the docs](https://example.com/a).", "See <https://example.com/a|the docs>."},
		{"bullets", "* one\n  + two", "• one\n  • two"},
		{"code fence untouched", "```\n**not bold**\n```", "```\n**not bold**\n```"},
		{"inline code untouched", "`**x**` and **y**", "`**x**` and *y*"},
		{"strike", "~~old~~ new", "~old~ new"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := ToMrkdwn(tc.in); got != tc.want {
				t.Fatalf("ToMrkdwn(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

func TestToMrkdwnTruncatesAndClosesFence(t *testing.T) {
	in := "```\n" + strings.Repeat("x", MaxMessageLen*2)
	got := ToMrkdwn(in)
	if len(got) > MaxMessageLen+40 {
		t.Fatalf("not truncated: %d chars", len(got))
	}
	if strings.Count(got, "```")%2 != 0 {
		t.Fatalf("unbalanced code fence in %q", got[len(got)-30:])
	}
}

func TestStripMentions(t *testing.T) {
	if got := StripMentions("<@U012ABC> revenue last month?"); got != "revenue last month?" {
		t.Fatalf("got %q", got)
	}
}
