//go:build darwin

package main

import "runtime"

func init() {
	// The host agent runs the VM on the process's first thread (vz needs it):
	// see cmd/agent-vm/main_darwin_gui.go in agent-vm. The binary is also
	// signed with the entitlements of third_party/lima/vz.entitlements:
	//
	//	codesign -f --entitlements vz.entitlements -s - sandbox
	runtime.LockOSThread()
}
