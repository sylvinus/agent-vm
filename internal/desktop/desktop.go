// Package desktop reaches the user out of any terminal: notifications and
// yes/no dialogs, where the desktop has a way (osascript on macOS; notify-send,
// zenity or kdialog on Linux). Text always goes as arguments, never as script.
package desktop

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// Notify shows a notification, without waiting; nothing where there is no
// way.
func Notify(title, msg string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("osascript", "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", title, msg)
	case "linux":
		if _, err := exec.LookPath("notify-send"); err != nil {
			return
		}
		cmd = exec.Command("notify-send", "--", title, msg)
	default:
		return
	}
	if cmd.Start() == nil {
		go func() { _ = cmd.Wait() }()
	}
}

// Ask shows a dialog with Deny (the default) and Allow, until ctx ends (a
// refusal). ok is false when no dialog could be shown.
func Ask(ctx context.Context, title, msg string) (allow, ok bool) {
	switch runtime.GOOS {
	case "darwin":
		out, err := exec.CommandContext(ctx, "osascript", "-e", "on run argv",
			"-e", `display dialog (item 2 of argv) with title (item 1 of argv) buttons {"Deny", "Allow"} default button "Deny" with icon caution`,
			"-e", "end run", title, msg).Output()
		if err != nil {
			// Deny is "user canceled" (error -128), an exit status: an answer.
			return false, isExit(err)
		}
		return strings.Contains(string(out), "button returned:Allow"), true
	case "linux":
		if os.Getenv("DISPLAY") == "" && os.Getenv("WAYLAND_DISPLAY") == "" {
			return false, false
		}
		if _, err := exec.LookPath("zenity"); err == nil {
			err := exec.CommandContext(ctx, "zenity", "--question", "--title", title, "--text", msg,
				"--ok-label=Allow", "--cancel-label=Deny", "--default-cancel", "--no-markup").Run()
			return err == nil, err == nil || isExit(err)
		}
		if _, err := exec.LookPath("kdialog"); err == nil {
			err := exec.CommandContext(ctx, "kdialog", "--title", title, "--warningyesno", msg,
				"--yes-label", "Allow", "--no-label", "Deny").Run()
			return err == nil, err == nil || isExit(err)
		}
	}
	return false, false
}

func isExit(err error) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee)
}
