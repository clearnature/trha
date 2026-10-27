package channel

import (
	"fmt"
	"sync"
)

// Manager manages channels for Go-Haskell communication
type Manager struct {
	channels map[string]chan interface{}
	mu       sync.RWMutex
}

// NewManager creates a new channel manager
func NewManager() *Manager {
	return &Manager{
		channels: make(map[string]chan interface{}),
	}
}

// Create creates a new channel
func (m *Manager) Create(name string, bufferSize int) (chan interface{}, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.channels[name]; exists {
		return nil, fmt.Errorf("channel %s already exists", name)
	}

	ch := make(chan interface{}, bufferSize)
	m.channels[name] = ch
	return ch, nil
}

// Get gets a channel by name
func (m *Manager) Get(name string) (chan interface{}, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	ch, exists := m.channels[name]
	if !exists {
		return nil, fmt.Errorf("channel %s not found", name)
	}

	return ch, nil
}

// Send sends a message to a channel
func (m *Manager) Send(name string, message interface{}) error {
	ch, err := m.Get(name)
	if err != nil {
		return err
	}

	select {
	case ch <- message:
		return nil
	default:
		return fmt.Errorf("channel %s is full", name)
	}
}

// Receive receives a message from a channel
func (m *Manager) Receive(name string) (interface{}, error) {
	ch, err := m.Get(name)
	if err != nil {
		return nil, err
	}

	select {
	case message := <-ch:
		return message, nil
	default:
		return nil, fmt.Errorf("channel %s is empty", name)
	}
}

// Close closes a channel
func (m *Manager) Close(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	ch, exists := m.channels[name]
	if !exists {
		return fmt.Errorf("channel %s not found", name)
	}

	close(ch)
	delete(m.channels, name)
	return nil
}

// List lists all channels
func (m *Manager) List() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	names := make([]string, 0, len(m.channels))
	for name := range m.channels {
		names = append(names, name)
	}
	return names
}

// CloseAll closes all channels
func (m *Manager) CloseAll() {
	m.mu.Lock()
	defer m.mu.Unlock()

	for name, ch := range m.channels {
		close(ch)
		delete(m.channels, name)
	}
}