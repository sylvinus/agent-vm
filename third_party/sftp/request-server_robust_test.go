//go:build !plan9
// +build !plan9

package sftp

import (
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// osHandlers serves dir with *os.File handles, write-only opens get an O_WRONLY file.
// Stat of "/panic" panics, Stat of "/slow" takes 100ms.
type osHandlers struct {
	dir string
}

func (h *osHandlers) p(r *Request) string { return filepath.Join(h.dir, r.Filepath) }

func (h *osHandlers) Fileread(r *Request) (io.ReaderAt, error) { return os.Open(h.p(r)) }
func (h *osHandlers) Filewrite(r *Request) (io.WriterAt, error) {
	return os.OpenFile(h.p(r), os.O_WRONLY|os.O_CREATE, 0o644)
}
func (h *osHandlers) OpenFile(r *Request) (WriterAtReaderAt, error) {
	return os.OpenFile(h.p(r), os.O_RDWR|os.O_CREATE, 0o644)
}
func (h *osHandlers) Filecmd(r *Request) error { return ErrSSHFxOpUnsupported }
func (h *osHandlers) Filelist(r *Request) (ListerAt, error) {
	switch r.Filepath {
	case "/panic":
		panic("handler bug")
	case "/slow":
		time.Sleep(100 * time.Millisecond)
	}
	if r.Method == "List" {
		f, err := os.Open(h.p(r))
		if err != nil {
			return nil, err
		}
		defer f.Close()
		fis, err := f.Readdir(-1)
		return listerat(fis), err
	}
	fi, err := os.Stat(h.p(r))
	if err != nil {
		return nil, err
	}
	return listerat{fi}, nil
}

// rawClient sends packets a well-behaved client would not.
type rawClient struct {
	t  *testing.T
	c  net.Conn
	rs *RequestServer
	id uint32
}

func newRawClient(t *testing.T, h Handlers, opts ...RequestServerOption) *rawClient {
	a, b := net.Pipe()
	rs := NewRequestServer(a, h, append([]RequestServerOption{WithRSSequential()}, opts...)...)
	go rs.Serve()
	t.Cleanup(func() { b.Close() })
	return &rawClient{t: t, c: b, rs: rs}
}

type rawPacket []byte

func (b rawPacket) MarshalBinary() ([]byte, error) { return b, nil }

func (r *rawClient) send(typ byte, fields ...any) uint32 {
	r.id++
	b := []byte{0, 0, 0, 0, typ}
	b = marshalUint32(b, r.id)
	for _, f := range fields {
		b = marshal(b, f)
	}
	require.NoError(r.t, sendPacket(r.c, rawPacket(b)))
	return r.id
}

func (r *rawClient) recv() (fxp, []byte) {
	require.NoError(r.t, r.c.SetReadDeadline(time.Now().Add(5*time.Second)))
	typ, data, err := recvPacket(r.c, nil, 0)
	require.NoError(r.t, err)
	return typ, data
}

// status returns the code of a STATUS response, or fails.
func (r *rawClient) status() uint32 {
	typ, data := r.recv()
	require.Equal(r.t, fxp(sshFxpStatus), typ)
	_, data = unmarshalUint32(data)
	code, _ := unmarshalUint32(data)
	return code
}

func (r *rawClient) handle(typ byte, path string, fields ...any) string {
	r.send(typ, append([]any{path}, fields...)...)
	rtyp, data := r.recv()
	require.Equal(r.t, fxp(sshFxpHandle), rtyp)
	_, data = unmarshalUint32(data)
	h, _ := unmarshalString(data)
	return h
}

// A handle only answers the packets of what it was opened for.
func TestRequestHandlePacketMismatch(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "f"), []byte("hello"), 0o644))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "g"), nil, 0o644))
	h := &osHandlers{dir: dir}
	c := newRawClient(t, Handlers{h, h, h, h})

	wh := c.handle(sshFxpOpen, "/f", uint32(sshFxfWrite), uint32(0))
	rh := c.handle(sshFxpOpen, "/f", uint32(sshFxfRead), uint32(0))
	dh := c.handle(sshFxpOpendir, "/")

	c.send(sshFxpRead, wh, uint64(10), uint32(100))
	assert.NotEqual(t, uint32(sshFxOk), c.status(), "READ on a write-only handle")
	c.send(sshFxpWrite, rh, uint64(0), "XXXX")
	assert.NotEqual(t, uint32(sshFxOk), c.status(), "WRITE on a read-only handle")
	c.send(sshFxpReaddir, rh)
	assert.NotEqual(t, uint32(sshFxOk), c.status(), "READDIR on a file handle")
	c.send(sshFxpRead, dh, uint64(0), uint32(100))
	assert.NotEqual(t, uint32(sshFxOk), c.status(), "READ on a directory handle")

	b, err := os.ReadFile(filepath.Join(dir, "f"))
	require.NoError(t, err)
	assert.Equal(t, "hello", string(b))
	c.send(sshFxpReaddir, dh)
	typ, data := c.recv()
	require.Equal(t, fxp(sshFxpName), typ, "the READ must not have consumed the entries")
	_, data = unmarshalUint32(data)
	n, _ := unmarshalUint32(data)
	assert.Equal(t, uint32(2), n)
}

func TestRequestServerMaxHandles(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "f"), nil, 0o644))
	h := &osHandlers{dir: dir}
	c := newRawClient(t, Handlers{h, h, h, h}, WithRSMaxHandles(2))

	first := c.handle(sshFxpOpen, "/f", uint32(sshFxfRead), uint32(0))
	c.handle(sshFxpOpendir, "/")
	c.send(sshFxpOpen, "/f", uint32(sshFxfRead), uint32(0))
	assert.Equal(t, uint32(sshFxFailure), c.status(), "OPEN over the limit")
	c.send(sshFxpOpendir, "/")
	assert.Equal(t, uint32(sshFxFailure), c.status(), "OPENDIR over the limit")
	c.send(sshFxpClose, first)
	require.Equal(t, uint32(sshFxOk), c.status())
	c.handle(sshFxpOpen, "/f", uint32(sshFxfRead), uint32(0))
}

// A panic in a handler fails its request, the server keeps serving.
func TestRequestServerHandlerPanic(t *testing.T) {
	h := &osHandlers{dir: t.TempDir()}
	c := newRawClient(t, Handlers{h, h, h, h})
	c.send(sshFxpStat, "/panic")
	assert.Equal(t, uint32(sshFxFailure), c.status())
	c.send(sshFxpStat, "/")
	typ, _ := c.recv()
	assert.Equal(t, fxp(sshFxpAttrs), typ)
}

type syncCounter struct {
	*os.File
	n *atomic.Int32
}

func (s syncCounter) Sync() error {
	s.n.Add(1)
	return s.File.Sync()
}

type syncHandlers struct {
	*osHandlers
	n atomic.Int32
}

func (h *syncHandlers) Filewrite(r *Request) (io.WriterAt, error) {
	f, err := os.OpenFile(h.p(r), os.O_WRONLY|os.O_CREATE, 0o644)
	if err != nil {
		return nil, err
	}
	return syncCounter{f, &h.n}, nil
}

func TestRequestFsync(t *testing.T) {
	h := &syncHandlers{osHandlers: &osHandlers{dir: t.TempDir()}}
	c := newRawClient(t, Handlers{h, h, h, h})
	c.send(sshFxpInit) // INIT has a version where other packets have an id
	typ, data := c.recv()
	require.Equal(t, fxp(sshFxpVersion), typ)
	assert.Contains(t, string(data), "fsync@openssh.com")

	wh := c.handle(sshFxpOpen, "/f", uint32(sshFxfWrite|sshFxfCreat), uint32(0))
	c.send(sshFxpExtended, "fsync@openssh.com", wh)
	assert.Equal(t, uint32(sshFxOk), c.status())
	assert.Equal(t, int32(1), h.n.Load())

	dh := c.handle(sshFxpOpendir, "/")
	c.send(sshFxpExtended, "fsync@openssh.com", dh)
	assert.Equal(t, uint32(sshFxOPUnsupported), c.status())
	c.send(sshFxpExtended, "fsync@openssh.com", "nope")
	assert.NotEqual(t, uint32(sshFxOk), c.status())
}

// Responses keep their order when orderIDs wrap around.
func TestRequestServerOrderIDWrap(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "slow"), nil, 0o644))
	h := &osHandlers{dir: dir}
	a, b := net.Pipe()
	rs := NewRequestServer(a, Handlers{h, h, h, h})
	rs.pktMgr.packetCount = math.MaxUint32 - 1
	go rs.Serve()
	t.Cleanup(func() { b.Close() })
	c := &rawClient{t: t, c: b, rs: rs}

	id1 := c.send(sshFxpStat, "/slow")
	id2 := c.send(sshFxpStat, "/")
	_, d1 := c.recv()
	_, d2 := c.recv()
	g1, _ := unmarshalUint32(d1)
	g2, _ := unmarshalUint32(d2)
	assert.Equal(t, []uint32{id1, id2}, []uint32{g1, g2})
}

func TestStatusFromErrorErrno(t *testing.T) {
	for _, tc := range []struct {
		err  error
		code uint32
	}{
		{&os.LinkError{Op: "rename", Old: "a", New: "b", Err: syscall.EACCES}, sshFxPermissionDenied},
		{&os.SyscallError{Syscall: "x", Err: syscall.EPERM}, sshFxPermissionDenied},
		{&os.PathError{Op: "open", Path: "x", Err: syscall.ENOTDIR}, sshFxNoSuchFile},
		{&os.PathError{Op: "open", Path: "x", Err: syscall.ELOOP}, sshFxNoSuchFile},
		{&os.PathError{Op: "open", Path: "x", Err: syscall.ENAMETOOLONG}, sshFxBadMessage},
		{syscall.EINVAL, sshFxBadMessage},
		{syscall.ENOSYS, sshFxOPUnsupported},
		{syscall.EEXIST, sshFxFailure},
	} {
		assert.Equal(t, tc.code, statusFromError(1, tc.err).Code, "%v", tc.err)
	}
}
