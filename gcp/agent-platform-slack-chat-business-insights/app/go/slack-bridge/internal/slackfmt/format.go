// Package slackfmt converts the Markdown a model writes into Slack mrkdwn and strips bot mentions.
package slackfmt

import (
	"regexp"
	"strings"
)

// MaxMessageLen keeps replies well under Slack's 40,000 character limit for chat.postMessage text.
const MaxMessageLen = 3900

var (
	boldStars   = regexp.MustCompile(`\*\*(.+?)\*\*`)
	boldUnder   = regexp.MustCompile(`__(.+?)__`)
	heading     = regexp.MustCompile(`(?m)^#{1,6}\s+(.+?)\s*#*\s*$`)
	link        = regexp.MustCompile(`\[([^\]]+)\]\((https?://[^)\s]+)\)`)
	mention     = regexp.MustCompile(`<@[A-Z0-9]+>`)
	strike      = regexp.MustCompile(`~~(.+?)~~`)
	bulletStars = regexp.MustCompile(`(?m)^(\s*)[*+]\s+`)
)

// ToMrkdwn converts common Markdown to Slack mrkdwn, leaving fenced and inline code untouched, and truncates the
// result to MaxMessageLen.
func ToMrkdwn(md string) string {
	parts := strings.Split(md, "```")
	for i := range parts {
		if i%2 == 1 {
			continue // inside a code fence
		}
		parts[i] = convertOutsideInlineCode(parts[i])
	}
	return truncate(strings.Join(parts, "```"))
}

func convertOutsideInlineCode(s string) string {
	segments := strings.Split(s, "`")
	for i := range segments {
		if i%2 == 1 {
			continue // inline code
		}
		t := segments[i]
		t = bulletStars.ReplaceAllString(t, "$1• ")
		t = heading.ReplaceAllString(t, "*$1*")
		t = boldStars.ReplaceAllString(t, "*$1*")
		t = boldUnder.ReplaceAllString(t, "*$1*")
		t = strike.ReplaceAllString(t, "~$1~")
		t = link.ReplaceAllString(t, "<$2|$1>")
		segments[i] = t
	}
	return strings.Join(segments, "`")
}

func truncate(s string) string {
	if len(s) <= MaxMessageLen {
		return s
	}
	cut := s[:MaxMessageLen]
	if strings.Count(cut, "```")%2 == 1 {
		cut += "\n```"
	}
	return cut + "\n… (answer truncated)"
}

// StripMentions removes <@U123> mentions (the bot's own name in an app_mention) and trims the text.
func StripMentions(text string) string {
	return strings.TrimSpace(mention.ReplaceAllString(text, ""))
}
