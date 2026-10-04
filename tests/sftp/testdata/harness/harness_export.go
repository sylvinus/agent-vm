package reversesshfs

import "io"

// HarnessServer exposes newRootedServer to the harness. tests/sftp/run copies
// it into a copy of third_party/sshocker, never into third_party itself.
func HarnessServer(rwc io.ReadWriteCloser, localPath string, names []string) (interface{ Serve() error }, error) {
	srv, h, err := newRootedServer(rwc, localPath, false, names)
	if err != nil {
		return nil, err
	}
	return serveCloser{srv, h}, nil
}

type serveCloser struct {
	srv interface{ Serve() error }
	h   *rootedHandlers
}

func (s serveCloser) Serve() error {
	defer s.h.Close()
	return s.srv.Serve()
}
