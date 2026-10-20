package tap

import (
	"context"
	"net"
	"sync"
	"testing"

	"github.com/containers/gvisor-tap-vsock/pkg/types"
	"github.com/stretchr/testify/require"
)

// readingConn says when it is first read.
type readingConn struct {
	net.Conn
	reading chan struct{}
	once    sync.Once
}

func (c *readingConn) Read(b []byte) (int, error) {
	c.once.Do(func() { close(c.reading) })
	return c.Conn.Read(b)
}

// A connection that ends because the program cancelled the context is not an
// error; one that ends by itself is.
func TestAcceptEndedByContext(t *testing.T) {
	for _, cancelled := range []bool{true, false} {
		s := NewSwitch(false)
		ours, theirs := net.Pipe()
		conn := &readingConn{Conn: ours, reading: make(chan struct{})}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- s.Accept(ctx, conn, types.VfkitProtocol) }()
		<-conn.reading
		if cancelled {
			cancel()
		}
		theirs.Close()
		err := <-done
		cancel()
		if cancelled {
			require.NoError(t, err)
		} else {
			require.Error(t, err)
		}
	}
}
