# AirBridge verification

Run `./Scripts/test-airbridge.sh` from the repository root. It compiles production HAL and renderer code in Swift 6 release mode, executes deterministic buffer tests, and performs read-only Core Audio discovery. It does not create taps, record audio, alter devices, or request privacy permissions. Pass `--skip-hardware` to omit device discovery on a headless runner.

Coverage: stereo and planar channels, duplicate and mono output routing, exclusion of device input channels, gain ramps, non-finite samples, clipping, short output buffers, null input buffers, and silence after a stream-format change. These checks exercise the actual realtime render function against allocated AudioBufferLists.

Hardware acceptance still requires a signed Bezel build with system audio recording permission. Test two applications routed simultaneously to different outputs, a mirrored second output, Bluetooth disconnect/reconnect, output sample-rate changes, rapid Start/Stop All, quitting a source application, and sleep/wake. Stopping a route must immediately return that application to its original output; sleeping stops routes and requires an explicit restart after wake. Audio protected by the source application may not be capturable. This harness cannot establish physical playback latency or audibility.
