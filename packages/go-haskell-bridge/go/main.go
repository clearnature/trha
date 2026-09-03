package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/gh-harness/go-haskell-bridge/http"
	"github.com/gh-harness/go-haskell-bridge/grpc"
	"github.com/gh-harness/go-haskell-bridge/channel"
	"github.com/gh-harness/go-haskell-bridge/memory"
	"github.com/gh-harness/go-haskell-bridge/goroutine"
)

func main() {
	// Create managers
	channelManager := channel.NewManager()
	memoryManager := memory.NewManager()
	goroutinePool := goroutine.NewPool(10)

	// Start goroutine pool
	goroutinePool.Start()
	defer goroutinePool.Stop()

	// Create HTTP server
	httpServer := http.NewServer(":8080")
	go func() {
		if err := httpServer.Start(); err != nil {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	// Create gRPC server
	grpcServer := grpc.NewServer(":9090")
	go func() {
		if err := grpcServer.Start(); err != nil {
			log.Printf("gRPC server error: %v", err)
		}
	}()

	// Create channels
	_, err := channelManager.Create("haskell-to-go", 100)
	if err != nil {
		log.Printf("Failed to create channel: %v", err)
	}

	_, err = channelManager.Create("go-to-haskell", 100)
	if err != nil {
		log.Printf("Failed to create channel: %v", err)
	}

	// Allocate shared memory
	_, err = memoryManager.Allocate("shared-data", 1024*1024) // 1MB
	if err != nil {
		log.Printf("Failed to allocate memory: %v", err)
	}

	fmt.Println("Go-Haskell bridge started")
	fmt.Println("HTTP server: http://localhost:8080")
	fmt.Println("gRPC server: localhost:9090")

	// Wait for interrupt signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan

	fmt.Println("Shutting down...")

	// Cleanup
	httpServer.Stop()
	grpcServer.Stop()
	channelManager.CloseAll()
	memoryManager.Close()
}