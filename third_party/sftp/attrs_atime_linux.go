//go:build !android && linux
// +build !android,linux

package sftp

import "syscall"

func statAtime(st *syscall.Stat_t) (int64, bool) {
	return int64(st.Atim.Sec), true
}
