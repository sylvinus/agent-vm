package ui

import (
	"io"
	"os"
)

// The console's input, whatever stdin is.
func openTTY() (io.ReadCloser, error) {
	return os.Open("CONIN$")
}
