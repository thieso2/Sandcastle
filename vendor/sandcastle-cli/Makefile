BINARY_NAME=sandcastle
VERSION?=$(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")

.PHONY: build clean install

build:
	go build -ldflags="-s -w -X github.com/sandcastle/cli/cmd.Version=$(VERSION)" -o $(BINARY_NAME) .

clean:
	rm -f $(BINARY_NAME)

install: build
	cp $(BINARY_NAME) /usr/local/bin/$(BINARY_NAME)
