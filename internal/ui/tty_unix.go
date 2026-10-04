//go:build !windows

package ui

import (
	"io"
	"os"
)

func openTTY() (io.ReadCloser, error) {
	return os.Open("/dev/tty")
}
