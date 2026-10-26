PYTHON ?= python3

.DEFAULT_GOAL := all

VALAC ?= valac
UNCRUSTIFY ?= uncrustify
VALA_PACKAGES = --pkg gtk4 --pkg gstreamer-1.0 --pkg gio-unix-2.0 --pkg posix
VALA_CAPTURE = vala/camera-controls.vala vala/capture-utils.vala vala/Input.vala vala/Camera.vala vala/DesktopCapture.vala
VALA_CORE = $(VALA_CAPTURE) vala/Registry.vala vala/test-sources.vala \
	vala/RollingFramerate.vala vala/VideoTrack.vala vala/Recorder.vala vala/Application.vala
VALA_NATIVE = vala/native.vapi vala/v4l2.vapi
VALA_FLAGS = -g $(VALA_PACKAGES) -X -Ivala -X -lX11 -X -lm

.PHONY: all run test vala run-vala test-vala format
all: build/studio-recorder

format:
	$(UNCRUSTIFY) -c uncrustify.cfg -l VALA --replace --no-backup $(wildcard vala/*.vala)

vala: all

run-vala: run

test-vala: test

build/studio-recorder: $(VALA_CORE) $(VALA_NATIVE) vala/main.vala
	mkdir -p build/app
	$(VALAC) $(VALA_FLAGS) --directory build/app -o $(abspath $@) $(VALA_CORE) $(VALA_NATIVE) vala/main.vala

build/test-vala: $(VALA_CORE) $(VALA_NATIVE) vala/tests.vala
	mkdir -p build/unit
	$(VALAC) $(VALA_FLAGS) --directory build/unit -o $(abspath $@) $(VALA_CORE) $(VALA_NATIVE) vala/tests.vala

run: all
	./build/studio-recorder $(ARGS)

test: all build/test-vala build/test-vala-portal
	G_DEBUG=fatal-criticals ./build/test-vala
	$(PYTHON) vala/check_recording.py
	$(PYTHON) vala/check_portal.py

build/test-vala-portal: $(VALA_CAPTURE) $(VALA_NATIVE) vala/portal-test.vala
	mkdir -p build/portal
	$(VALAC) $(VALA_FLAGS) --directory build/portal -o $(abspath $@) $(VALA_CAPTURE) $(VALA_NATIVE) vala/portal-test.vala
