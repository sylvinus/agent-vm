//go:build darwin
// +build darwin

package sftp

import "syscall"

func statAtime(st *syscall.Stat_t) (int64, bool) {
	return int64(st.Atimespec.Sec), true
}
