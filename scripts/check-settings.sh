#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p target

# The mechanism on its own, against fixtures that stand in for a settings file
# changing shape between releases.
swiftc \
	-O \
	-target arm64-apple-macos14.0 \
	-o target/settings-check \
	apps/AstroCat/Sources/Settings.swift \
	scripts/settings-check/main.swift
target/settings-check

# The same guarantee on the app's real settings types. Every source but
# App.swift, whose @main cannot coexist with a check's own entry point.
#
# StackModel builds its renderers in init, so the shader library has to sit
# beside the binary — makeDefaultLibrary looks in the bundle, which for a
# command-line tool is the directory it is in.
xcrun -sdk macosx metal -O -c apps/AstroCat/Shaders.metal -o target/Shaders.air
xcrun -sdk macosx metallib target/Shaders.air -o target/default.metallib

mapfile -t SOURCES < <(ls apps/AstroCat/Sources/*.swift | grep -v '/App\.swift$')
swiftc \
	-O \
	-target arm64-apple-macos14.0 \
	-import-objc-header include/astrocat.h \
	-o target/app-check \
	"${SOURCES[@]}" \
	scripts/app-check/main.swift \
	-L target/release -lastrocat_ffi \
	-framework AppKit -framework Metal -framework MetalKit -framework SwiftUI

# An optional master reports what its settings file on disk actually restores
# to, read through a copy so nothing is written back.
target/app-check "$@"
