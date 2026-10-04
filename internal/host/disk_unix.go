//go:build !windows

package host

import "golang.org/x/sys/unix"

// FreeGiB is the space free for an unprivileged user on dir's file system.
func FreeGiB(dir string) (int, bool) {
	var st unix.Statfs_t
	if err := unix.Statfs(dir+"/.", &st); err != nil {
		return 0, false
	}
	return int(uint64(st.Bavail) * uint64(st.Bsize) >> 30), true
}
