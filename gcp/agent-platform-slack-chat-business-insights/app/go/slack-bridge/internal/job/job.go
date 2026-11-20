// Package job is the message the ingress queues and the worker consumes.
package job

import (
	"encoding/json"
	"errors"
)

// Question is one Slack message addressed to the bot.
type Question struct {
	EventID   string `json:"event_id"`
	Team      string `json:"team"`
	Channel   string `json:"channel"`
	User      string `json:"user"`
	Text      string `json:"text"`
	MessageTS string `json:"message_ts"`
	// ThreadTS is the thread the answer goes to: the parent message for replies, the message itself otherwise.
	ThreadTS string `json:"thread_ts"`
}

// Validate reports whether the question has everything the worker needs.
func (q Question) Validate() error {
	switch {
	case q.Team == "" || q.Channel == "" || q.User == "":
		return errors.New("question is missing team, channel or user")
	case q.ThreadTS == "" || q.MessageTS == "":
		return errors.New("question is missing timestamps")
	case q.Text == "":
		return errors.New("question has no text")
	}
	return nil
}

// Marshal encodes the question for Pub/Sub.
func (q Question) Marshal() ([]byte, error) { return json.Marshal(q) }

// Unmarshal decodes a question from a Pub/Sub message payload.
func Unmarshal(data []byte) (Question, error) {
	var q Question
	if err := json.Unmarshal(data, &q); err != nil {
		return q, err
	}
	return q, q.Validate()
}
