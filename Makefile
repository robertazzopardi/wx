.PHONY: build run test clean install

build:
	zig build

run:
	zig build run

test:
	zig build test

install:
	zig build install -Doptimize=ReleaseFast -p ~/.local

clean:
	rm -rf zig-out .zig-cache
