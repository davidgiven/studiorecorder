PYTHON ?= python3

.DEFAULT_GOAL := all

VALAC ?= valac
UNCRUSTIFY ?= uncrustify
VALA_PACKAGES = --pkg gtk4 --pkg gstreamer-1.0 --pkg gio-unix-2.0 --pkg posix
VALA_CAPTURE = src/camera-controls.vala src/capture-utils.vala src/Input.vala src/Camera.vala src/DesktopCapture.vala
VALA_CORE = $(VALA_CAPTURE) src/Registry.vala src/test-sources.vala \
	src/RollingFramerate.vala src/VideoTrack.vala src/Recorder.vala src/Application.vala
VALA_NATIVE = src/native.vapi src/v4l2.vapi
VALA_FLAGS = -g $(VALA_PACKAGES) -X -Isrc -X -lX11 -X -lm

.PHONY: all run test format clean
all: studio-recorder

clean:
	$(RM) -r .obj studio-recorder

format:
	$(UNCRUSTIFY) -c uncrustify.cfg -l VALA --replace --no-backup $(wildcard src/*.vala tests/*.vala)

studio-recorder: $(VALA_CORE) $(VALA_NATIVE) src/main.vala
	mkdir -p .obj/app
	$(VALAC) $(VALA_FLAGS) --directory .obj/app -o $(abspath $@) $(VALA_CORE) $(VALA_NATIVE) src/main.vala

.obj/test-unit: $(VALA_CORE) $(VALA_NATIVE) tests/tests.vala
	mkdir -p .obj/unit
	$(VALAC) $(VALA_FLAGS) --directory .obj/unit -o $(abspath $@) $(VALA_CORE) $(VALA_NATIVE) tests/tests.vala

run: all
	./studio-recorder $(ARGS)

test: all .obj/test-unit .obj/test-portal
	G_DEBUG=fatal-criticals ./.obj/test-unit
	$(PYTHON) tests/check_recording.py
	$(PYTHON) tests/check_portal.py

.obj/test-portal: $(VALA_CAPTURE) $(VALA_NATIVE) tests/portal-test.vala
	mkdir -p .obj/portal
	$(VALAC) $(VALA_FLAGS) --directory .obj/portal -o $(abspath $@) $(VALA_CAPTURE) $(VALA_NATIVE) tests/portal-test.vala
