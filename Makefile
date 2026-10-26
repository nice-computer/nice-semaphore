.PHONY: build test test-hooks test-swift clean

build:
	swift build -c release

test: test-hooks test-swift

test-hooks:
	bats tests/

test-swift:
	swift test

clean:
	swift package clean
