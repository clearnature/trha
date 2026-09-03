package serializer

import (
	"encoding/json"
	"fmt"
)

// Serializer handles serialization and deserialization
type Serializer struct {
	format string
}

// NewSerializer creates a new serializer
func NewSerializer(format string) *Serializer {
	return &Serializer{
		format: format,
	}
}

// Serialize serializes data
func (s *Serializer) Serialize(data interface{}) ([]byte, error) {
	switch s.format {
	case "json":
		return json.Marshal(data)
	default:
		return nil, fmt.Errorf("unsupported format: %s", s.format)
	}
}

// Deserialize deserializes data
func (s *Serializer) Deserialize(data []byte, target interface{}) error {
	switch s.format {
	case "json":
		return json.Unmarshal(data, target)
	default:
		return fmt.Errorf("unsupported format: %s", s.format)
	}
}

// SerializeToString serializes data to string
func (s *Serializer) SerializeToString(data interface{}) (string, error) {
	bytes, err := s.Serialize(data)
	if err != nil {
		return "", err
	}
	return string(bytes), nil
}

// DeserializeFromString deserializes data from string
func (s *Serializer) DeserializeFromString(data string, target interface{}) error {
	return s.Deserialize([]byte(data), target)
}