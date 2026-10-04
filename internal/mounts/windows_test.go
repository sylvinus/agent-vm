package mounts

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/sylvinus/agent-vm/internal/paths"
)

// A repository's own folder is found up to the drive, the drive's root
// excepted, as "/" is elsewhere.
func TestWindowsGitDirShare(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	t.Chdir(t.TempDir())
	for _, d := range []string{"C:/objects", "C:/refs", "C:/proj", "C:/bare/objects", "C:/bare/refs", "C:/bare/sub"} {
		os.MkdirAll(d, 0o755)
	}
	os.WriteFile("C:/HEAD", nil, 0o644)
	os.WriteFile("C:/bare/HEAD", nil, 0o644)
	if why, bad := GitDirShare("C:/proj"); bad {
		t.Errorf("the root taken for a repository: %s", why)
	}
	if why, bad := GitDirShare("C:/bare/sub"); !bad || !strings.Contains(why, "(C:/bare)") {
		t.Errorf("inside a bare repository: %q %v", why, bad)
	}
}

// The volumes file and the shares on Windows, on any host: paths.Windows on,
// and, from a temporary folder, C:/... a relative path that exists.
func TestWindowsVolumes(t *testing.T) {
	old := paths.Windows
	paths.Windows = func() bool { return true }
	t.Cleanup(func() { paths.Windows = old })
	t.Chdir(t.TempDir())
	for _, d := range []string{"C:/Users/me/proj", "C:/data", "C:/data2", "C:/data3", "C:/data4", "C:/data5", "C:/data6", "C:/st"} {
		os.MkdirAll(d, 0o755)
	}
	os.WriteFile("C:/f.txt", []byte("x"), 0o644)

	if got := hideDrives(`C:/data:/mnt/d:rw:C:/work/*`); got != "C"+driveColon+"/data:/mnt/d:rw:C"+driveColon+"/work/*" {
		t.Errorf("hideDrives: %q", got)
	}
	if got := hideDrives(`C:\data:x`); got != "C"+driveColon+`\data:x` {
		t.Errorf(`hideDrives(C:\data): %q`, got)
	}

	vols := strings.Join([]string{
		"C:/data",                              // its own path in the VM: /c/data
		`C:\data2:/mnt/d2:rw`,                  // backslashes
		"/c/data3",                             // 0.2's Git Bash spelling
		"C:/data4:sub:ro:C:/Users/me/*",        // a filter with a drive, matched
		"C:/data5:/mnt/x:ro:C:/other/*",        // not matched
		"C:/data6:/mnt/d6:ro:/c/Users/me/proj", // 0.2's filter spelling, matched
		"C:/data6:C:/x",                        // a destination with a drive: refused
		"C:/f.txt",                             // a single file, bound at /c/f.txt
		"C:/Users",                             // at /c/Users: over the project, refused
	}, "\n") + "\n"
	os.WriteFile("vols", []byte(vols), 0o644)
	var warn bytes.Buffer
	es := Entries("vols", "C:/Users/me/proj", "C:/Users/me", nil, &warn)
	var got []string
	for _, e := range es {
		got = append(got, e.Src+">"+e.Dst+">"+e.Mode)
	}
	want := "C:/data>>ro C:/data2>/mnt/d2>rw C:/data3>>ro C:/data4>sub>ro C:/data6>/mnt/d6>ro C:/f.txt>>ro"
	if strings.Join(got, " ") != want {
		t.Errorf("entries:\n got  %s\n want %s\n%s", strings.Join(got, " "), want, warn.String())
	}
	if !strings.Contains(warn.String(), "'C:/data6:C:/x'") || !strings.Contains(warn.String(), "'C:/Users' (from ~/.agent-vm/volumes) would be mounted at /c/Users, which covers the project") ||
		strings.Count(warn.String(), "Warning") != 2 {
		t.Errorf("warnings: %s", warn.String())
	}

	ms, files := Build(Shares{VM: "v", Dir: "C:/Users/me/proj", Writable: true, Entries: es, StateDir: "C:/st", Warn: &warn})
	var mounts []string
	for _, m := range ms[:len(ms)-1] {
		mounts = append(mounts, m.Location+">"+m.MountPoint)
	}
	if want := "C:/Users/me/proj>/c/Users/me/proj C:/data>/c/data C:/data2>/mnt/d2 C:/data3>/c/data3 C:/data4>/c/Users/me/proj/sub C:/data6>/mnt/d6"; strings.Join(mounts, " ") != want {
		t.Errorf("mounts:\n got  %s\n want %s", strings.Join(mounts, " "), want)
	}
	if len(files) != 1 || files[0].BindDst != "/c/f.txt" || !strings.HasPrefix(files[0].Staging, "C:/st/file-mounts/v/") || ms[len(ms)-1].MountPoint != "/tmp/.agent-vm-file-mounts/0" {
		t.Errorf("single file: %+v %+v", files, ms[len(ms)-1])
	}
}
