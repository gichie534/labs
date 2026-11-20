package worker

import (
	"context"
	"errors"

	"github.com/slack-go/slack"
)

// SlackAPI adapts the slack-go client to the Slack interface.
type SlackAPI struct {
	Client *slack.Client
}

// Reply posts text in the thread.
func (s SlackAPI) Reply(ctx context.Context, channel, threadTS, text string) error {
	_, _, err := s.Client.PostMessageContext(ctx, channel,
		slack.MsgOptionText(text, false),
		slack.MsgOptionTS(threadTS),
		slack.MsgOptionDisableLinkUnfurl(),
	)
	return err
}

// React adds an emoji reaction to a message. "already_reacted" is not an error.
func (s SlackAPI) React(ctx context.Context, channel, messageTS, emoji string) error {
	err := s.Client.AddReactionContext(ctx, emoji, slack.NewRefToMessage(channel, messageTS))
	return ignoreSlackError(err, "already_reacted")
}

// Unreact removes an emoji reaction. "no_reaction" is not an error.
func (s SlackAPI) Unreact(ctx context.Context, channel, messageTS, emoji string) error {
	err := s.Client.RemoveReactionContext(ctx, emoji, slack.NewRefToMessage(channel, messageTS))
	return ignoreSlackError(err, "no_reaction")
}

func ignoreSlackError(err error, code string) error {
	var slackErr slack.SlackErrorResponse
	if errors.As(err, &slackErr) && slackErr.Err == code {
		return nil
	}
	if err != nil && err.Error() == code {
		return nil
	}
	return err
}
