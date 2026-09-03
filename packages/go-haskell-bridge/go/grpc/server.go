package grpc

import (
	"context"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/reflection"

	pb "github.com/gh-harness/go-haskell-bridge/proto"
)

// Server represents a gRPC server for Go-Haskell communication
type Server struct {
	addr   string
	server *grpc.Server
}

// NewServer creates a new gRPC server
func NewServer(addr string) *Server {
	return &Server{
		addr: addr,
	}
}

// Start starts the gRPC server
func (s *Server) Start() error {
	lis, err := net.Listen("tcp", s.addr)
	if err != nil {
		return fmt.Errorf("failed to listen: %v", err)
	}

	s.server = grpc.NewServer()
	pb.RegisterHaskellBridgeServer(s.server, &bridgeServer{})
	reflection.Register(s.server)

	log.Printf("gRPC server starting on %s", s.addr)
	return s.server.Serve(lis)
}

// Stop stops the gRPC server
func (s *Server) Stop() {
	s.server.GracefulStop()
}

// bridgeServer implements the HaskellBridge gRPC service
type bridgeServer struct {
	pb.UnimplementedHaskellBridgeServer
}

// GetData implements the GetData RPC
func (s *bridgeServer) GetData(ctx context.Context, req *pb.GetDataRequest) (*pb.GetDataResponse, error) {
	// Implementation for getting data
	return &pb.GetDataResponse{
		Value: "data from Go",
		Code:  200,
	}, nil
}

// SetData implements the SetData RPC
func (s *bridgeServer) SetData(ctx context.Context, req *pb.SetDataRequest) (*pb.SetDataResponse, error) {
	// Implementation for setting data
	return &pb.SetDataResponse{
		Success: true,
		Message: "Data set successfully",
	}, nil
}

// StreamData implements the StreamData RPC
func (s *bridgeServer) StreamData(req *pb.StreamDataRequest, stream pb.HaskellBridge_StreamDataServer) error {
	// Implementation for streaming data
	for i := 0; i < 10; i++ {
		err := stream.Send(&pb.StreamDataResponse{
			Data: fmt.Sprintf("Stream data %d", i),
		})
		if err != nil {
			return err
		}
	}
	return nil
}