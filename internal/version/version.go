// Package version is agent-vm's semantic version.
package version

import "strings"

// Version is set at build time (-ldflags -X); integrators gate on it with
// `agent-vm version --min`.
var Version = "0.3.0-dev"

// AtLeast reports whether version have is want or later. Only the numbers
// count: a suffix after "-" is dropped, and so is anything but digits in a
// component. A missing component is 0, so 1.2 is 1.2.0.
func AtLeast(have, want string) bool {
	a, _, _ := strings.Cut(have, "-")
	b, _, _ := strings.Cut(want, "-")
	for a != "" || b != "" {
		var x, y string
		x, a, _ = strings.Cut(a, ".")
		y, b, _ = strings.Cut(b, ".")
		x, y = number(x), number(y)
		if len(x) != len(y) {
			return len(x) > len(y)
		}
		if x != y {
			return x > y
		}
	}
	return true
}

// number is the digits of s, without leading zeros: compared by length,
// then as text, it compares as a number of any size.
func number(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	return strings.TrimLeft(b.String(), "0")
}
