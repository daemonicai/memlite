#!/usr/bin/env bash

zig build -Doptimize=ReleaseFast
install -m 0755 zig-out/bin/memlite ~/.local/bin/memlite
