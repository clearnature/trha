package goroutine

import (
	"sync"
)

// Pool represents a goroutine pool
type Pool struct {
	workers    int
	taskQueue  chan func()
	wg         sync.WaitGroup
	quit       chan struct{}
}

// NewPool creates a new goroutine pool
func NewPool(workers int) *Pool {
	return &Pool{
		workers:   workers,
		taskQueue: make(chan func(), workers*2),
		quit:      make(chan struct{}),
	}
}

// Start starts the goroutine pool
func (p *Pool) Start() {
	for i := 0; i < p.workers; i++ {
		p.wg.Add(1)
		go p.worker()
	}
}

// Stop stops the goroutine pool
func (p *Pool) Stop() {
	close(p.quit)
	p.wg.Wait()
}

// Submit submits a task to the pool
func (p *Pool) Submit(task func()) {
	p.taskQueue <- task
}

// worker is the worker goroutine
func (p *Pool) worker() {
	defer p.wg.Done()

	for {
		select {
		case task := <-p.taskQueue:
			task()
		case <-p.quit:
			return
		}
	}
}

// Size returns the number of workers
func (p *Pool) Size() int {
	return p.workers
}

// Pending returns the number of pending tasks
func (p *Pool) Pending() int {
	return len(p.taskQueue)
}