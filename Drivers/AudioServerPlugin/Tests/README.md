# USB playback regression tests

The normal driver suite checks the production factory's channel descriptions,
preferred stereo pair, and serialized layout. It also checks the live measurement
assertions against known-good and deliberately incorrect samples, without playing
audio or contacting the proxy:

```bash
./Drivers/AudioServerPlugin/run-tests.sh
```

The existing production proxy render tests cover unity gain at center balance,
channel preservation, and the buffer layouts used by the proxy:

```bash
./Drivers/VolumeProxy/run-tests.sh
```

## Optional installed playback check

Pause other computer audio first. With the Symphony and signed Maestro USB driver
and proxy installed, explicitly opt into three short, quiet test signals:

```bash
./Drivers/AudioServerPlugin/run-live-tests.sh --run-live
```

This sends audio to physical outputs. The test checks the live preferred layout
and stereo pair, refuses to start a test while other post-proxy audio is present,
and measures digital peaks after the production proxy render callback:

- Mono reaches outputs 1/2 equally with the expected mono-to-stereo split; the
  remaining outputs stay silent.
- Stereo preserves both source levels; the remaining outputs stay silent.
- Sixteen indexed signals preserve their individually assigned levels and indices.

The test uses the current hardware sample rate. It does not change sample rate,
gain, routing, default device, saved layout, or music-player state. A stale saved
HAL layout is reported as a precondition failure rather than silently corrected.
It does not verify physical analog levels, ADAT cable transport, or a particular DAW.

Running `run-live-tests.sh` without arguments runs only the silent assertion
self-test. Negative controls cover mono on one channel, mono on output 3,
stereo attenuation, swapped indexed channels, and invalid measurements, so a
broken checker cannot pass merely by accepting everything.
