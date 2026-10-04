package sftp

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"testing"
	"time"
)

type fuzzConn struct {
	io.Reader
}

func (fuzzConn) Write(p []byte) (int, error) { return len(p), nil }
func (fuzzConn) Close() error                { return nil }

func fuzzFrame(typ byte, payload ...[]byte) []byte {
	body := append([]byte{typ}, bytes.Join(payload, nil)...)
	return append(binary.BigEndian.AppendUint32(nil, uint32(len(body))), body...)
}

func fuzzU32(v uint32) []byte { return binary.BigEndian.AppendUint32(nil, v) }

// fuzzHandler keeps nothing: what is fuzzed is the protocol, not a handler
// (InMemHandler grows a buffer to whatever offset a WRITE names).
type fuzzHandler struct{}

type discardAt struct{}

func (discardAt) WriteAt(p []byte, _ int64) (int, error) { return len(p), nil }

type fuzzLister struct{}

func (fuzzLister) ListAt([]os.FileInfo, int64) (int, error) { return 0, io.EOF }

func (fuzzHandler) Fileread(*Request) (io.ReaderAt, error)  { return bytes.NewReader([]byte("content")), nil }
func (fuzzHandler) Filewrite(*Request) (io.WriterAt, error) { return discardAt{}, nil }
func (fuzzHandler) Filecmd(*Request) error                  { return nil }
func (fuzzHandler) Filelist(*Request) (ListerAt, error)     { return fuzzLister{}, nil }
func fuzzStr(s string) []byte { return append(fuzzU32(uint32(len(s))), s...) }

// FuzzRequestServer sends what a hostile client could, after INIT: any
// bytes, framed or not. The server, as the hostagent runs it (sshocker's
// options), never panics and never hangs: in the hostagent, either takes the
// VM down.
func FuzzRequestServer(f *testing.F) {
	open := fuzzFrame(sshFxpOpen, fuzzU32(1), fuzzStr("/f"), fuzzU32(sshFxfWrite|sshFxfCreat|sshFxfTrunc), fuzzU32(0))
	write := fuzzFrame(sshFxpWrite, fuzzU32(2), fuzzStr("1"), make([]byte, 8), fuzzStr("data"))
	read := fuzzFrame(sshFxpRead, fuzzU32(3), fuzzStr("1"), make([]byte, 8), fuzzU32(4))
	closeH := fuzzFrame(sshFxpClose, fuzzU32(4), fuzzStr("1"))
	mkdir := fuzzFrame(sshFxpMkdir, fuzzU32(5), fuzzStr("/d"), fuzzU32(0))
	f.Add(bytes.Join([][]byte{open, write, read, closeH}, nil))
	f.Add(bytes.Join([][]byte{mkdir, fuzzFrame(sshFxpOpendir, fuzzU32(6), fuzzStr("/d")), fuzzFrame(sshFxpReaddir, fuzzU32(7), fuzzStr("1"))}, nil))
	f.Add(fuzzFrame(sshFxpSetstat, fuzzU32(8), fuzzStr("/f"), fuzzU32(0xffffffff)))
	f.Add(fuzzFrame(sshFxpExtended, fuzzU32(9), fuzzStr("posix-rename@openssh.com"), fuzzStr("/a"), fuzzStr("/b")))
	f.Add([]byte{0xff, 0xff, 0xff, 0xff, 1})
	init := fuzzFrame(sshFxpInit, fuzzU32(3))
	f.Fuzz(func(t *testing.T, data []byte) {
		conn := fuzzConn{bytes.NewReader(append(append([]byte(nil), init...), data...))}
		h := fuzzHandler{}
		srv := NewRequestServer(conn, Handlers{FileGet: h, FilePut: h, FileCmd: h, FileList: h},
			WithRSSequential(), WithRSMaxHandles(16), WithRSMaxTxPacket(64*1024))
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = srv.Serve()
		}()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Fatalf("the server hangs on %q", data)
		}
		srv.Close()
	})
}
