BINARY_NAME=sandcastle
VERSION?=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS=-s -w -X github.com/sandcastle/cli/cmd.Version=$(VERSION)
DIST=dist

PLATFORMS=linux/amd64 linux/arm64 darwin/amd64 darwin/arm64

.PHONY: build clean install build-all $(PLATFORMS)

build:
	go build -ldflags="$(LDFLAGS)" -o $(BINARY_NAME) .

build-all: $(PLATFORMS)

$(PLATFORMS):
	@mkdir -p $(DIST)
	GOOS=$(word 1,$(subst /, ,$@)) GOARCH=$(word 2,$(subst /, ,$@)) \
		go build -ldflags="$(LDFLAGS)" -o $(DIST)/$(BINARY_NAME)-$(word 1,$(subst /, ,$@))-$(word 2,$(subst /, ,$@)) .

clean:
	rm -f $(BINARY_NAME)
	rm -rf $(DIST)

install: build
	cp $(BINARY_NAME) /usr/local/bin/$(BINARY_NAME)
