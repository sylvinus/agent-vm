//go:build linux || darwin

package reversesshfs

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// Opening a FIFO must fail, not block the server: it handles one request at a time.
func TestRootedFifo(t *testing.T) {
	c, root := setupRooted(t, false)
	fifo := filepath.Join(root, "src", "fifo")
	if err := unix.Mkfifo(fifo, 0o644); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() {
		if f, err := c.Open(fifo); err == nil {
			f.Close()
			done <- errors.New("Open (read) succeeded")
			return
		}
		if f, err := c.OpenFile(fifo, os.O_WRONLY); err == nil {
			f.Close()
			done <- errors.New("OpenFile (write) succeeded")
			return
		}
		if _, err := c.ReadDir(fifo); err == nil {
			done <- errors.New("ReadDir succeeded")
			return
		}
		_, err := c.Stat(filepath.Join(root, "src", "main.go"))
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the server blocked on a FIFO")
	}
}

func TestRenameNoReplace(t *testing.T) {
	dir := t.TempDir()
	for _, n := range []string{"a", "b"} {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(n), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	fd, err := unix.Open(dir, unix.O_RDONLY|unix.O_DIRECTORY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	if err := renameNoReplace(fd, "a", fd, "b"); !errors.Is(err, unix.EEXIST) {
		t.Fatalf("over an existing file: %v", err)
	}
	if err := renameNoReplace(fd, "a", fd, "c"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "b")); err != nil || string(b) != "b" {
		t.Fatalf("b: %q, %v", b, err)
	}
}
