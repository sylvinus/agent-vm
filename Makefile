# agent-vm, the Go binary, with Lima built in from third_party/.
#
#   make              _output/bin/agent-vm, with the guest agent and templates
#   make install      build it, then link it onto the PATH (AGENT_VM_BIN_DIR
#                     to choose where; ~/.local/bin by default)
#   make limactl      Lima's own limactl from third_party/, for debugging
#   make test         the Go tests
#   make test-example the example program that embeds the library, built
#                     against this checkout
#   make check-windows      the Windows build and tests compile and vet, from any OS
#   make test-third-party   the tests of the modules in third_party/, patched
#   make check-third-party  third_party/ is upstream plus patches/, nothing else

GO ?= go
GOOS ?= $(shell $(GO) env GOOS)
GOARCH ?= $(shell $(GO) env GOARCH)
# The tag when HEAD has one, else the next release's: a build after 0.3.0 is
# 0.3.1-dev, not 0.3.0-N after the last tag (version --min).
NEXT_VERSION := 0.3.1
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
MOD := github.com/sylvinus/agent-vm
LDFLAGS := -s -w \
	-X $(MOD)/internal/version.Version=$(VERSION) \
	-X $(MOD)/third_party/lima/pkg/version.Version=$(LIMA_VERSION)
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

.PHONY: all agent-vm install limactl assets test test-go test-example check-windows test-third-party check-third-party fuzz clean

all: agent-vm

agent-vm: assets
	$(GO_BUILD) -o _output/bin/agent-vm$(EXE) ./cmd/agent-vm
ifeq ($(GOOS),darwin)
	codesign -f -v --entitlements third_party/lima/vz.entitlements -s - _output/bin/agent-vm
endif

# For developers: the binary install puts on the PATH, with its own
# wording, replacement of earlier installs and next steps.
install: agent-vm
	./_output/bin/agent-vm$(EXE) install

limactl:
	$(GO_BUILD) -o _output/bin/limactl$(EXE) ./third_party/lima/cmd/limactl
	mkdir -p _output/share/lima
	CGO_ENABLED=0 GOOS=linux GOARCH=$(GOARCH) $(GO) build -trimpath -ldflags "-s -w" \
		-o _output/share/lima/lima-guestagent.Linux-$(GUEST_ARCH) ./third_party/lima/cmd/lima-guestagent
	rm -rf _output/share/lima/templates && cp -R third_party/lima/templates _output/share/lima/templates
ifeq ($(GOOS),darwin)
	codesign -f -v --entitlements third_party/lima/vz.entitlements -s - _output/bin/limactl
endif

# The guest agent runs in the Linux guest: built for it, without cgo. The same
# tool a program that embeds agentvm runs (cmd/agent-vm-assets), run for this
# machine whatever GOOS and GOARCH build the binary for.
assets:
	env -u GOOS -u GOARCH $(GO) run ./cmd/agent-vm-assets -o $(ASSETS) -arch $(GUEST_ARCH)

# The example program that embeds agentvm, built against this checkout in a
# copy of its module, to which the replace is added (it has none: it requires
# the released agent-vm), and its test.
test-example:
	rm -rf _output/example && mkdir -p _output && cp -R examples/consumer _output/example
	cd _output/example && $(GO) mod edit -replace $(MOD)=$(CURDIR) && GOFLAGS=-mod=mod $(GO) mod tidy \
		&& env -u GOOS -u GOARCH $(GO) generate ./... \
		&& $(GO) vet ./... && $(GO) build -o ../sandbox$(EXE) . && $(GO) test ./...

test: test-go

test-go:
	$(GO) test -tags $(TAGS) . ./agents/... ./cmd/... ./internal/... ./policy/... ./provision/...

# The Windows build and its tests compile and vet, from any OS. The Windows
# paths' logic is tested everywhere (paths.Windows); the tests themselves
# run on Windows in CI (windows-latest).
check-windows:
	GOOS=windows GOARCH=amd64 $(GO) vet -tags $(TAGS) . ./agents/... ./cmd/... ./internal/... ./policy/... ./provision/...
	GOOS=windows GOARCH=arm64 $(GO) vet -tags $(TAGS) . ./agents/... ./cmd/... ./internal/... ./policy/... ./provision/...

test-third-party:
	$(GO) test -vet=off -race ./third_party/sftp/...
	$(GO) test -race ./third_party/sshocker/pkg/...
	$(GO) test ./third_party/lima/pkg/...
	$(GO) test ./third_party/gvisor-tap-vsock/pkg/...

check-third-party:
	scripts/third-party-sync all --check

# Each fuzzer for FUZZTIME (their seeds run with the tests).
FUZZTIME ?= 1m
FUZZ = ./third_party/sshocker/pkg/reversesshfs ./third_party/sftp ./internal/env ./internal/gitguard \
	./internal/mounts ./internal/paths ./internal/runscript ./internal/ui ./internal/vmname
fuzz:
	@set -e; for pkg in $(FUZZ); do \
	  fs=$$($(GO) test -vet=off -list '^Fuzz' $$pkg) || { echo "$$fs"; exit 1; }; \
	  for f in $$(echo "$$fs" | grep '^Fuzz'); do \
	    echo "== $$pkg $$f"; \
	    $(GO) test -vet=off -run '^$$' -fuzz "^$$f$$" -fuzztime $(FUZZTIME) $$pkg; \
	  done; \
	done

clean:
	rm -rf _output
	find $(ASSETS) -mindepth 1 ! -name README -exec rm -rf {} +
