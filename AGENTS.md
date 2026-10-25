StudioRecorder is a simple program for doing multitrack recordings from the Linux desktop.

It uses gstreamer to automatically capture all available video devices, plus their associated audio devices (this may be manually overridden by the user). Video is encoded using a hardware-accelerated H264 or H265 codec. Audio is PCM float32. The program displays a live preview window containing a set of thumbnails for each source, plus a full-sized version of a selected source; clicking on a thumbnail selects it as the source for the full-sized view. A VU meter for the audio is displayed over the top of the thumbnail.

