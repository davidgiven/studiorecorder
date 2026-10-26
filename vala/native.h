#pragma once
#include <gst/gst.h>
void studio_lock_framerate(GstElement *source);
double studio_level_rms(const GstStructure *structure);
int studio_xinit_threads(void);
char *studio_realpath(const char *path);
