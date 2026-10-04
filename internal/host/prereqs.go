package host

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
)

// qemuBinary is QEMU's emulator for this host's architecture, and the
// Debian package that has it.
func qemuBinary() (bin, pkg string) {
	switch runtime.GOARCH {
	case "amd64":
		return "qemu-system-x86_64", "qemu-system-x86"
	case "arm64":
		return "qemu-system-aarch64", "qemu-system-arm"
	}
	return "qemu-system-" + runtime.GOARCH, "qemu-system"
}

// WSLVersion is 2 or 1 under WSL, from the kernel release, 0 elsewhere.
func WSLVersion() int {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	rel := string(b)
	switch {
	case err != nil:
		return 0
	case strings.Contains(rel, "WSL2"):
		return 2
	case strings.Contains(strings.ToLower(rel), "microsoft"):
		return 1
	}
	return 0
}

// LinuxPrereqs checks what Lima needs to run a QEMU VM on Linux, and says
// how to get it: without this, a failed start says only that it failed. True
// elsewhere.
func LinuxPrereqs(w io.Writer) bool {
	if runtime.GOOS != "linux" {
		return true
	}
	ok := true
	bin, pkg := qemuBinary()
	if _, err := exec.LookPath(bin); err != nil {
		fmt.Fprintf(w, "Error: Lima needs '%s' on PATH (not found).\n  Install with: sudo apt-get install %s\n", bin, pkg)
		ok = false
	}
	_, err := os.Stat("/dev/kvm")
	switch {
	case err != nil:
		fmt.Fprintln(w, "Error: /dev/kvm does not exist (KVM unavailable).")
		// Inside WSL the fix is on the Windows side: WSL1 can never run VMs,
		// and WSL2 needs the host to let KVM through.
		switch WSLVersion() {
		case 1:
			fmt.Fprintln(w, "  This looks like WSL1, which cannot run VMs.\n  Upgrade the distribution to WSL2: wsl --set-version <distro> 2")
		case 2:
			fmt.Fprintln(w, "  This looks like WSL2 without nested virtualization: KVM is not\n  passed through from the Windows host. Update WSL (wsl --update),\n  enable virtualization on the host, then retry.")
		default:
			fmt.Fprintln(w, "  Hardware virtualization may be disabled in BIOS, or the kernel\n  lacks KVM support (nested virt in a guest VM, etc.).")
		}
		ok = false
	case !canReadWrite("/dev/kvm"):
		fmt.Fprintln(w, "Error: /dev/kvm exists but you don't have read/write access.")
		if !inGroup("kvm") {
			fmt.Fprintln(w, "  Fix: sudo usermod -aG kvm \"$USER\"\n  Then log out and back in (or run 'newgrp kvm') so the new\n  group membership takes effect.")
		} else {
			fmt.Fprintln(w, "  You're already in the kvm group but /dev/kvm denies access.\n  Check ownership/mode: ls -l /dev/kvm")
		}
		ok = false
	}
	return ok
}

// canReadWrite: opening it, which /dev/kvm allows without doing anything.
func canReadWrite(p string) bool {
	f, err := os.OpenFile(p, os.O_RDWR, 0)
	if err != nil {
		return false
	}
	f.Close()
	return true
}

func inGroup(name string) bool {
	u, err := user.Current()
	if err != nil {
		return false
	}
	ids, _ := u.GroupIds()
	g, err := user.LookupGroup(name)
	return err == nil && slices.Contains(ids, g.Gid)
}

// WindowsPrereqs checks for QEMU, which Lima runs on Windows. Whether the
// "Windows Hypervisor Platform" feature is on cannot be read without
// administrator rights: a host without it fails at the first start, where
// WindowsStartHint explains it. winget's QEMU does not add itself to PATH:
// its default folder goes on PATH for this process. True elsewhere.
func WindowsPrereqs(out, w io.Writer) bool {
	if runtime.GOOS != "windows" {
		return true
	}
	bin, _ := qemuBinary()
	if _, err := exec.LookPath(bin); err == nil {
		return true
	}
	dir := os.Getenv("AGENT_VM_QEMU_DIR")
	if dir == "" {
		dir = `C:\Program Files\qemu`
	}
	if _, err := os.Stat(filepath.Join(dir, bin+".exe")); err == nil {
		os.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
		return true
	}
	fmt.Fprintf(w, "Error: Lima needs '%s' on PATH (not found).\n  Install QEMU with: winget install SoftwareFreedom.QEMU\n  QEMU also needs the 'Windows Hypervisor Platform' Windows feature (see 'agent-vm doctor').\n", bin)
	return false
}

// WHPXOn is what an administrator runs, once, then reboots, for QEMU to use
// WHPX.
const WHPXOn = "DISM /Online /Enable-Feature /FeatureName:HypervisorPlatform /All"

// WindowsStartHint explains, after a failed start on Windows whose logs
// show QEMU could not use WHPX, how to turn it on.
func WindowsStartHint(w io.Writer, logs ...string) {
	if runtime.GOOS != "windows" {
		return
	}
	for _, l := range logs {
		if b, err := os.ReadFile(l); err == nil && strings.Contains(strings.ToLower(string(b)), "whpx") {
			fmt.Fprintf(w, `QEMU could not use the Windows hypervisor. It needs the "Windows Hypervisor
Platform" Windows feature, which an administrator turns on once, followed by
a reboot: in Windows Features, or from an administrator terminal:
  %s
On a managed laptop, that is a request to your IT department.
`, WHPXOn)
			return
		}
	}
}
