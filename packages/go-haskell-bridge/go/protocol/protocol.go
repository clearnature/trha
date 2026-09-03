package protocol

import (
	"encoding/json"
	"time"
)

// Request represents a request from Haskell to Go
type Request struct {
	ID      string          `json:"id"`
	Method  string          `json:"method"`
	Path    string          `json:"path"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    json.RawMessage `json:"body,omitempty"`
}

// Response represents a response from Go to Haskell
type Response struct {
	ID      string      `json:"id"`
	Success bool        `json:"success"`
	Data    interface{} `json:"data,omitempty"`
	Error   *Error      `json:"error,omitempty"`
}

// ErrorResponse represents an error response
type ErrorResponse struct {
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Details interface{} `json:"details,omitempty"`
}

// Error represents an error in the protocol
type Error struct {
	Type    string `json:"type"`
	Message string `json:"message"`
	Details string `json:"details,omitempty"`
}

// Message represents a message for channel communication
type Message struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Channel   string          `json:"channel"`
	Payload   json.RawMessage `json:"payload"`
	Timestamp time.Time       `json:"timestamp"`
}

// ChannelConfig represents channel configuration
type ChannelConfig struct {
	Name      string `json:"name"`
	BufferSize int   `json:"buffer_size"`
	Type      string `json:"type"` // "unbuffered", "buffered"
}

// MemoryBlock represents a shared memory block
type MemoryBlock struct {
	ID     string `json:"id"`
	Size   int    `json:"size"`
	Data   []byte `json:"data"`
	RefCount int  `json:"ref_count"`
}

// NewRequest creates a new request
func NewRequest(method, path string, body interface{}) (*Request, error) {
	bodyBytes, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	return &Request{
		ID:      generateID(),
		Method:  method,
		Path:    path,
		Headers: map[string]string{"Content-Type": "application/json"},
		Body:    bodyBytes,
	}, nil
}

// NewResponse creates a new response
func NewResponse(id string, data interface{}) *Response {
	return &Response{
		ID:      id,
		Success: true,
		Data:    data,
	}
}

// NewErrorResponse creates a new error response
func NewErrorResponse(id string, err *Error) *Response {
	return &Response{
		ID:      id,
		Success: false,
		Error:   err,
	}
}

// NewMessage creates a new message
func NewMessage(channel string, payload interface{}) (*Message, error) {
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}

	return &Message{
		ID:        generateID(),
		Type:      "message",
		Channel:   channel,
		Payload:   payloadBytes,
		Timestamp: time.Now(),
	}, nil
}

// generateID generates a unique ID
func generateID() string {
	return time.Now().Format("20060102150405") + "-" + randomString(8)
}

// randomString generates a random string
func randomString(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[time.Now().UnixNano()%int64(len(letters))]
	}
	return string(b)
}