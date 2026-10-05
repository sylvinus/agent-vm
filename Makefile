# agent-vm 0.3, the Go binary, with Lima built in from third_party/.
#
#   make              _output/bin/agent-vm, with the guest agent and templates
#   make limactl      Lima's own limactl from third_party/, for debugging
#   make test         the Go tests
#   make check-windows      the Windows build and tests compile and vet, from any OS
#   make test-third-party   the tests of the modules in third_party/, patched
#   make check-third-party  third_party/ is upstream plus patches/, nothing else

GO ?= go
GOOS ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)
# The tag when HEAD has one, else the next release's: a build of the 0.3
# branch is 0.3.0-dev, not 0.2.0-N after the last tag (version --min).
NEXT_VERSION := 0.3.0
VERSION ?= $(shell t=$$(git describe --tags --match 'v[0-9]*' --exact-match --dirty=.m 2>/dev/null) && echo "$$t" | sed 's/^v//' || \
	echo "$(NEXT_VERSION)-dev.$$(git rev-parse --short HEAD 2>/dev/null || echo unknown)")
LIMA_VERSION := $(shell awk '$$1 == "lima" { print $$4 }' third_party/SOURCES)

ifeq ($(GOARCH),amd64)
GUEST_ARCH := x86_64
else ifeq ($(GOARCH),arm64)
GUEST_ARCH := aarch64
else
GUEST_ARCH := $(GOARCH)
endif
ifeq ($(GOOS),windows)
EXE := .exe
endif

ASSETS := internal/limaembed/assets
LDFLAGS := -s -w \
	-X github.com/sylvinus/agent-vm/internal/version.Version=$(VERSION) \
	-X github.com/lima-vm/lima/v2/pkg/version.Version=$(LIMA_VERSION)
# yq only edits Lima's YAML here: without its other formats (Lua, HCL, TOML,
# XML...), 10% smaller. Tests run with the same tags.
TAGS := yq_noxml,yq_nolua,yq_noini,yq_nohcl,yq_notoml,yq_noprops,yq_nocsv,yq_nouri,yq_nobase64,yq_nosh,yq_noshell
# cgo on macOS only, where vz and Lima's file watcher need it. On Linux the
# hostagent's DNS server uses Go's resolver (Lima builds it with the
# system's), and the binary cross-compiles with no C compiler.
ifeq ($(GOOS),darwin)
CGO_ENABLED ?= 1
else
CGO_ENABLED ?= 0
endif
GO_BUILD := CGO_ENABLED=$(CGO_ENABLED) $(GO) build -trimpath -tags $(TAGS) -ldflags "$(LDFLAGS)"

.PHONY: all agent-vm limactl assets test test-go check-windows test-third-party check-third-party fuzz clean

all: agent-vm

agent-vm: assets
	$(GO_BUILD) -o _output/bin/agent-vm$(EXE) ./cmd/agent-vm
ifeq ($(GOOS),darwin)
	codesign -f -v --entitlements third_party/lima/vz.entitlements -s - _output/bin/agent-vm
endif

limactl:
	$(GO_BUILD) -o _output/bin/limactl$(EXE) github.com/lima-vm/lima/v2/cmd/limactl
	mkdir -p _output/share/lima
	CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags "-s -w" \
		-o _output/share/lima/lima-guestagent.Linux-$(GUEST_ARCH) github.com/lima-vm/lima/v2/cmd/lima-guestagent
	rm -rf _output/share/lima/templates && cp -R third_party/lima/templates _output/share/lima/templates
ifeq ($(GOOS),darwin)
	codesign -f -v --entitlements third_party/lima/vz.entitlements -s - _output/bin/limactl
endif

# The guest agent runs in the Linux guest: built for it, without cgo.
assets:
	CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) $(GO) build -trimpath \
		-ldflags "-s -w -X github.com/lima-vm/lima/v2/pkg/version.Version=$(LIMA_VERSION)" \
		-o $(ASSETS)/lima-guestagent.Linux-$(GUEST_ARCH) github.com/lima-vm/lima/v2/cmd/lima-guestagent
	gzip -9 -n -f $(ASSETS)/lima-guestagent.Linux-$(GUEST_ARCH)
	rm -rf $(ASSETS)/templates && cp -R third_party/lima/templates $(ASSETS)/templates

test: test-go

test-go:
	$(GO) test -tags $(TAGS) . ./cmd/... ./internal/...

# The Windows build and its tests compile and vet, from any OS. The Windows
# paths' logic is tested everywhere (paths.Windows); the tests themselves
# run on Windows in CI (windows-latest).
check-windows:
	GOOS=windows GOARCH=amd64 $(GO) vet -tags $(TAGS) . ./cmd/... ./internal/...
	GOOS=windows GOARCH=arm64 $(GO) vet -tags $(TAGS) . ./cmd/... ./internal/...

# From this module, so that each library is built with the others patched.
# Lima's MCP packages and sshocker's command are not part of agent-vm (-e:
# listing them needs sums nothing built here uses; grep keeps them out of
# the tests).
test-third-party:
	$(GO) test -vet=off -race github.com/pkg/sftp/...
	$(GO) test -race github.com/lima-vm/sshocker/pkg/...
	$(GO) test $$($(GO) list -e github.com/lima-vm/lima/v2/pkg/... | grep -v /mcp)
	$(GO) test github.com/containers/gvisor-tap-vsock/pkg/...

check-third-party:
	scripts/third-party-sync all --check

# Each fuzzer for FUZZTIME (their seeds run with the tests). The vendored
# sshocker's through tests/fuzz/go.work, which makes it fuzzable.
FUZZTIME ?= 1m
FUZZ = github.com/lima-vm/sshocker/pkg/reversesshfs github.com/pkg/sftp ./internal/env ./internal/gitguard \
	./internal/mounts ./internal/paths ./internal/runscript ./internal/ui ./internal/vmname
fuzz:
	@set -e; for pkg in $(FUZZ); do \
	  case $$pkg in ./*) work=off ;; *) work=$(CURDIR)/tests/fuzz/go.work ;; esac; \
	  fs=$$(GOWORK=$$work $(GO) test -vet=off -list '^Fuzz' $$pkg) || { echo "$$fs"; exit 1; }; \
	  for f in $$(echo "$$fs" | grep '^Fuzz'); do \
	    echo "== $$pkg $$f"; \
	    GOWORK=$$work $(GO) test -vet=off -run '^$$' -fuzz "^$$f$$" -fuzztime $(FUZZTIME) $$pkg; \
	  done; \
	done

clean:
	rm -rf _output
	find $(ASSETS) -mindepth 1 ! -name README -exec rm -rf {} +
