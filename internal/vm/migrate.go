package vm

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"syscall"

	continuityfs "github.com/containerd/continuity/fs"

	"github.com/sylvinus/agent-vm/third_party/lima/pkg/instance"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/dirnames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/limatype/filenames"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/osutil"
	"github.com/sylvinus/agent-vm/third_party/lima/pkg/store"
)

// OldVM is a VM agent-vm 0.2 left in another Lima home.
type OldVM struct {
	Name    string
	Running bool
}

// FindOld lists the VMs named prefix* in the Lima home old, that a move
// would take: those with a lima.yaml.
func FindOld(old, prefix string) ([]OldVM, error) {
	ents, err := os.ReadDir(old)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []OldVM
	for _, e := range ents {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), prefix) {
			continue
		}
		dir := filepath.Join(old, e.Name())
		if _, err := os.Stat(filepath.Join(dir, filenames.LimaYAML)); err != nil {
			continue
		}
		pid, _ := store.ReadPIDFile(filepath.Join(dir, filenames.HostAgentPID))
		out = append(out, OldVM{Name: e.Name(), Running: pid != 0})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

// withLimaHome runs fn with LIMA_HOME set to home and the VMs in it, as
// Lima's packages read them in the layout of 0.2 and 0.3.0, and puts the
// environment back.
func withLimaHome(home string, fn func() error) error {
	saved, had := os.LookupEnv("LIMA_HOME")
	savedVMs, hadVMs := os.LookupEnv(dirnames.InstancesEnv)
	if err := os.Setenv("LIMA_HOME", home); err != nil {
		return err
	}
	os.Unsetenv(dirnames.InstancesEnv)
	defer func() {
		if had {
			os.Setenv("LIMA_HOME", saved)
		} else {
			os.Unsetenv("LIMA_HOME")
		}
		if hadVMs {
			os.Setenv(dirnames.InstancesEnv, savedVMs)
		} else {
			os.Unsetenv(dirnames.InstancesEnv)
		}
	}()
	return fn()
}

// LegacyRunning reports whether the VM name, kept in the Lima home home as
// 0.3.0 did, is running or half there: either way it cannot move.
func LegacyRunning(ctx context.Context, home, name string) bool {
	running := true
	_ = withLimaHome(home, func() error {
		inst, err := store.Inspect(ctx, name)
		running = err != nil || inst.Status != limatype.StatusStopped && inst.Config != nil
		return nil
	})
	return running
}

// StopLegacy stops the VM name kept in the Lima home home as 0.3.0 did,
// through its hostagent, whichever Lima started it; by force when the
// hostagent is gone.
func StopLegacy(ctx context.Context, home, name string) error {
	return withLimaHome(home, func() error {
		inst, err := store.Inspect(ctx, name)
		if err != nil {
			return err
		}
		if inst.HostAgentPID == 0 {
			instance.StopForcibly(inst)
			return nil
		}
		return instance.StopGracefully(ctx, inst, false)
	})
}

// MoveOld moves the VM name from the Lima home old to the Lima home now, as
// to: stopped first, through its hostagent, whichever Lima started it; then
// its folder moved as Lima's rename moves one (no lock, pid, socket or
// temporary file; vz's identifier emptied). Its shares and the rest of its
// config go with it. Lima's own config in old (_config) does not.
func MoveOld(ctx context.Context, old, now, name, to string) error {
	src, dst := filepath.Join(old, name), filepath.Join(now, to)
	if sock := filepath.Join(dst, filenames.LongestSock); len(sock) >= osutil.UnixPathMax {
		return fmt.Errorf("its name is too long for %s: Lima's sockets there would need %d characters, more than %d", now, len(sock), osutil.UnixPathMax-1)
	}
	if _, err := os.Lstat(dst); err == nil {
		return fmt.Errorf("%s already exists", dst)
	}
	err := withLimaHome(old, func() error {
		inst, err := store.Inspect(ctx, name)
		if err != nil {
			return err
		}
		if inst.Status != limatype.StatusRunning {
			return nil
		}
		if err := instance.StopGracefully(ctx, inst, false); err != nil {
			return fmt.Errorf("could not stop it: %w", err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if err := os.MkdirAll(now, 0o700); err != nil {
		return err
	}
	if err := os.Rename(src, dst); err != nil {
		var le *os.LinkError
		if !errors.As(err, &le) || !errors.Is(le.Err, syscall.EXDEV) {
			return err
		}
		if err := copyTree(src, dst); err != nil {
			os.RemoveAll(dst)
			return err
		}
		if err := os.RemoveAll(src); err != nil {
			// The copy is whole: what is left of src is the leftover.
			return fmt.Errorf("copied to %s, but %s could not be removed (%w): remove it, then run agent-vm again", dst, src, err)
		}
	}
	return tidyMoved(dst)
}

// tidyMoved removes from the moved folder what Lima's rename does not move,
// and empties what it nullifies.
func tidyMoved(dir string) error {
	return filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == dir {
			return err
		}
		base := d.Name()
		skip := slices.Contains(filenames.SkipOnClone, base)
		for _, ext := range filenames.TmpFileSuffixes {
			skip = skip || strings.HasSuffix(base, ext)
		}
		switch {
		case skip:
			if err := os.RemoveAll(p); err != nil {
				return err
			}
			if d.IsDir() {
				return fs.SkipDir
			}
		case slices.Contains(filenames.NullifyOnClone, base):
			return os.WriteFile(p, nil, 0o666)
		}
		return nil
	})
}

// copyTree copies src to dst, copy-on-write where the file system can, as
// Lima's clone does.
func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		t := filepath.Join(dst, rel)
		switch {
		case d.IsDir():
			return os.MkdirAll(t, d.Type().Perm()|0o700)
		case d.Type()&fs.ModeSymlink != 0:
			l, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(l, t)
		case d.Type().IsRegular():
			return continuityfs.CopyFile(t, p)
		}
		return nil // sockets and the like are recreated
	})
}
