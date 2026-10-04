package cli

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// VMOpts are agent-vm's own options, for the commands that start a VM.
type VMOpts struct {
	Disk, Memory, CPUs int // 0: not given
	SSHPort            int // -1: not given; 0 gives the port back to Lima
	Reset              bool
	ReadOnly           bool
	Scratch            bool
	UnsafeWritableGit  bool
	UnsafeNoPrompts    bool
	RM                 bool // --rm: delete the VM after the command
}

func newVMOpts() VMOpts {
	return VMOpts{SSHPort: -1}
}

var positiveRe = regexp.MustCompile(`^[1-9][0-9]*$`)

// take reads the option at the start of args, if it is one of agent-vm's,
// and returns how many words it used: 0 when args[0] is not an option. A
// value is checked here, so `--disk 10G` is one clear error.
func (o *VMOpts) take(args []string) (int, error) {
	if len(args) == 0 {
		return 0, nil
	}
	opt, val, n := args[0], "", 0
	switch opt {
	case "--disk", "--memory", "--ram", "--cpus", "--ssh-port":
		if len(args) < 2 {
			return 0, fmt.Errorf("%s needs a value.", opt)
		}
		val, n = args[1], 2
	case "--reset":
		o.Reset = true
		return 1, nil
	case "--readonly":
		o.ReadOnly = true
		return 1, nil
	case "--scratch":
		o.Scratch = true
		return 1, nil
	case "--unsafe-writable-git", "--unsafe-writable-git=1":
		o.UnsafeWritableGit = true
		return 1, nil
	case "--unsafe-disable-security-prompts":
		o.UnsafeNoPrompts = true
		return 1, nil
	case "--rm":
		o.RM = true
		return 1, nil
	default:
		name, v, ok := strings.Cut(opt, "=")
		switch {
		case !ok:
			return 0, nil
		case name == "--disk", name == "--memory", name == "--ram", name == "--cpus", name == "--ssh-port":
			opt, val, n = name, v, 1
		default:
			return 0, nil
		}
	}
	if opt == "--ram" {
		opt = "--memory"
	}
	if opt == "--ssh-port" {
		p, err := strconv.Atoi(val)
		if val != "0" && (!positiveRe.MatchString(val) || err != nil || p < 1024 || p > 65535) {
			return 0, fmt.Errorf("--ssh-port must be 0 or a port from 1024 to 65535 (got: '%s')", val)
		}
		o.SSHPort = p
		return n, nil
	}
	v, err := strconv.Atoi(val)
	if !positiveRe.MatchString(val) || err != nil {
		return 0, fmt.Errorf("%s must be a positive integer (got: '%s')", opt, val)
	}
	switch opt {
	case "--disk":
		o.Disk = v
	case "--memory":
		o.Memory = v
	default:
		o.CPUs = v
	}
	return n, nil
}

// takeAll reads options from the start of args, and returns the words
// they used and the rest.
func (o *VMOpts) takeAll(args []string) (taken, rest []string, err error) {
	for {
		n, err := o.take(args)
		if err != nil {
			return nil, nil, err
		}
		if n == 0 {
			return taken, args, nil
		}
		taken = append(taken, args[:n]...)
		args = args[n:]
	}
}

// split reads agent-vm's options before a command's own words: from the
// first other word on, everything belongs to the command, so `run docker run
// --rm x` keeps its --rm. `--` ends the options, and --tty asks for a
// terminal.
func (o *VMOpts) split(args []string) (cmd []string, tty bool, err error) {
	for {
		n, err := o.take(args)
		if err != nil {
			return nil, false, err
		}
		if n > 0 {
			args = args[n:]
			continue
		}
		if len(args) > 0 && args[0] == "--tty" {
			tty = true
			args = args[1:]
			continue
		}
		if len(args) > 0 && args[0] == "--" {
			args = args[1:]
		}
		return args, tty, nil
	}
}
