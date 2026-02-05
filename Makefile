.PHONY: build test clean

build:
	swift build -c release

test:
	bats tests/

clean:
	swift package clean
