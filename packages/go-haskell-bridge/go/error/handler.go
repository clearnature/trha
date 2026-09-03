package error

import (
	"fmt"
	"time"
)

// ErrorType represents the type of error
type ErrorType string

const (
	ErrorTypeServerError   ErrorType = "ServerError"
	ErrorTypeClientError   ErrorType = "ClientError"
	ErrorTypeTimeoutError  ErrorType = "TimeoutError"
	ErrorTypeNetworkError  ErrorType = "NetworkError"
	ErrorTypeError         ErrorType = "Error"
)

// AppError represents an application error
type AppError struct {
	errorType ErrorType
	message   string
	details   interface{}
	timestamp time.Time
}

// NewAppError creates a new application error
func NewAppError(errorType ErrorType, message string, details interface{}) *AppError {
	return &AppError{
		errorType: errorType,
		message:   message,
		details:   details,
		timestamp: time.Now(),
	}
}

// Type returns the error type
func (e *AppError) Type() ErrorType {
	return e.errorType
}

// Message returns the error message
func (e *AppError) Message() string {
	return e.message
}

// Details returns the error details
func (e *AppError) Details() interface{} {
	return e.details
}

// Timestamp returns the error timestamp
func (e *AppError) Timestamp() time.Time {
	return e.timestamp
}

// Code returns the HTTP status code for the error
func (e *AppError) Code() int {
	switch e.errorType {
	case ErrorTypeClientError:
		return 400
	case ErrorTypeServerError:
		return 500
	case ErrorTypeTimeoutError:
		return 408
	case ErrorTypeNetworkError:
		return 503
	default:
		return 500
	}
}

// Error implements the error interface
func (e *AppError) Error() string {
	return fmt.Sprintf("%s: %s", e.errorType, e.message)
}

// ErrorHandler handles errors
type ErrorHandler struct {
	handlers map[ErrorType]func(*AppError)
}

// NewErrorHandler creates a new error handler
func NewErrorHandler() *ErrorHandler {
	return &ErrorHandler{
		handlers: make(map[ErrorType]func(*AppError)),
	}
}

// Register registers an error handler for a type
func (h *ErrorHandler) Register(errorType ErrorType, handler func(*AppError)) {
	h.handlers[errorType] = handler
}

// Handle handles an error
func (h *ErrorHandler) Handle(err *AppError) {
	if handler, ok := h.handlers[err.Type()]; ok {
		handler(err)
	}
}

// Wrap wraps an error with additional context
func Wrap(err error, message string) *AppError {
	if appErr, ok := err.(*AppError); ok {
		return NewAppError(appErr.Type(), message, appErr)
	}
	return NewAppError(ErrorTypeError, message, err)
}