package http

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"

	"github.com/clearnature/trha/packages/go-haskell-bridge/go/error"
	"github.com/clearnature/trha/packages/go-haskell-bridge/go/protocol"
)

// Server represents an HTTP server for Go-Haskell communication
type Server struct {
	addr     string
	mux      *http.ServeMux
	server   *http.Server
	handlers map[string]http.HandlerFunc
	mu       sync.RWMutex
}

// NewServer creates a new HTTP server
func NewServer(addr string) *Server {
	return &Server{
		addr:     addr,
		mux:      http.NewServeMux(),
		handlers: make(map[string]http.HandlerFunc),
	}
}

// Start starts the HTTP server
func (s *Server) Start() error {
	s.server = &http.Server{
		Addr:         s.addr,
		Handler:      s.mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	// Register default handlers
	s.registerDefaultHandlers()

	log.Printf("HTTP server starting on %s", s.addr)
	return s.server.ListenAndServe()
}

// Stop stops the HTTP server
func (s *Server) Stop() error {
	return s.server.Close()
}

// Handle registers a handler for a pattern
func (s *Server) Handle(pattern string, handler http.HandlerFunc) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlers[pattern] = handler
	s.mux.HandleFunc(pattern, handler)
}

// registerDefaultHandlers registers default handlers
func (s *Server) registerDefaultHandlers() {
	// Health check
	s.Handle("/health", s.healthHandler)

	// Echo handler
	s.Handle("/echo", s.echoHandler)

	// Error handler
	s.Handle("/error", s.errorHandler)
}

// healthHandler handles health check requests
func (s *Server) healthHandler(w http.ResponseWriter, r *http.Request) {
	response := map[string]interface{}{
		"status":    "ok",
		"timestamp": time.Now().Unix(),
	}
	s.writeJSON(w, http.StatusOK, response)
}

// echoHandler handles echo requests
func (s *Server) echoHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		s.writeError(w, http.StatusMethodNotAllowed, "Method not allowed")
		return
	}

	var request protocol.Request
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		s.writeError(w, http.StatusBadRequest, "Invalid request body")
		return
	}

	response := protocol.Response{
		ID:      request.ID,
		Success: true,
		Data:    request.Data,
	}
	s.writeJSON(w, http.StatusOK, response)
}

// errorHandler handles error requests
func (s *Server) errorHandler(w http.ResponseWriter, r *http.Request) {
	appError := error.NewAppError(
		error.ErrorTypeServerError,
		"Test error",
		fmt.Errorf("test error details"),
	)
	s.writeAppError(w, appError)
}

// writeJSON writes a JSON response
func (s *Server) writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

// writeError writes an error response
func (s *Server) writeError(w http.ResponseWriter, status int, message string) {
	response := protocol.ErrorResponse{
		Code:    status,
		Message: message,
	}
	s.writeJSON(w, status, response)
}

// writeAppError writes an application error response
func (s *Server) writeAppError(w http.ResponseWriter, err *error.AppError) {
	response := protocol.ErrorResponse{
		Code:    err.Code(),
		Message: err.Message(),
		Details: err.Details(),
	}
	s.writeJSON(w, err.Code(), response)
}