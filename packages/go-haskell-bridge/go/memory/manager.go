package memory

import (
	"fmt"
	"sync"
	"unsafe"
)

// Manager manages shared memory
type Manager struct {
	blocks map[string]*MemoryBlock
	mu     sync.RWMutex
}

// MemoryBlock represents a shared memory block
type MemoryBlock struct {
	ID       string
	Data     []byte
	Size     int
	RefCount int
	mu       sync.RWMutex
}

// NewManager creates a new memory manager
func NewManager() *Manager {
	return &Manager{
		blocks: make(map[string]*MemoryBlock),
	}
}

// Allocate allocates a shared memory block
func (m *Manager) Allocate(id string, size int) (*MemoryBlock, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, exists := m.blocks[id]; exists {
		return nil, fmt.Errorf("memory block %s already exists", id)
	}

	block := &MemoryBlock{
		ID:       id,
		Data:     make([]byte, size),
		Size:     size,
		RefCount: 1,
	}

	m.blocks[id] = block
	return block, nil
}

// Get gets a shared memory block
func (m *Manager) Get(id string) (*MemoryBlock, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	block, exists := m.blocks[id]
	if !exists {
		return nil, fmt.Errorf("memory block %s not found", id)
	}

	block.mu.Lock()
	block.RefCount++
	block.mu.Unlock()

	return block, nil
}

// Release releases a shared memory block
func (m *Manager) Release(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	block, exists := m.blocks[id]
	if !exists {
		return fmt.Errorf("memory block %s not found", id)
	}

	block.mu.Lock()
	block.RefCount--
	if block.RefCount <= 0 {
		delete(m.blocks, id)
	}
	block.mu.Unlock()

	return nil
}

// Read reads data from a shared memory block
func (m *Manager) Read(id string, offset, length int) ([]byte, error) {
	block, err := m.Get(id)
	if err != nil {
		return nil, err
	}

	block.mu.RLock()
	defer block.mu.RUnlock()

	if offset+length > block.Size {
		return nil, fmt.Errorf("read out of bounds")
	}

	result := make([]byte, length)
	copy(result, block.Data[offset:offset+length])
	return result, nil
}

// Write writes data to a shared memory block
func (m *Manager) Write(id string, offset int, data []byte) error {
	block, err := m.Get(id)
	if err != nil {
		return err
	}

	block.mu.Lock()
	defer block.mu.Unlock()

	if offset+len(data) > block.Size {
		return fmt.Errorf("write out of bounds")
	}

	copy(block.Data[offset:offset+len(data)], data)
	return nil
}

// GetPointer gets a pointer to the shared memory block
func (m *Manager) GetPointer(id string) (unsafe.Pointer, error) {
	block, err := m.Get(id)
	if err != nil {
		return nil, err
	}

	return unsafe.Pointer(&block.Data[0]), nil
}

// List lists all shared memory blocks
func (m *Manager) List() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	ids := make([]string, 0, len(m.blocks))
	for id := range m.blocks {
		ids = append(ids, id)
	}
	return ids
}

// Close closes the memory manager
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()

	m.blocks = make(map[string]*MemoryBlock)
}