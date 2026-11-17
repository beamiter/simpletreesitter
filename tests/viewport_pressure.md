# Default-configuration viewport pressure diagnostic

Run `make vim-scroll-pressure` with a full Vim and the debug daemon. Unlike the
regular `vim-scroll` regression, this mode does not override the production
scroll debounce (300 ms), viewport margin (120), or span budget (20000).
It drives Normal-mode scrolling through a PTY and reports observations, not a
performance pass. Add `--strict` to `python3 tests/viewport_scroll.py --pressure`
to assert the desired behavior; it fails on the baseline below.

The driver scrolls beyond the prefetched margin for approximately 2.4 seconds,
counts changes to the applied range during input, and reports settling latency
after the last sample. Sampling/PTY overhead is included: this is not a precise
prop_add_list benchmark or a p95 latency measurement. It then places two windows
of the same 20000-line Rust buffer around lines 100 and 19000, waits for pending
requests to finish, and counts highlighted visible lines. The distant window
alone is a control for grammar support and daemon liveness. Timings are reported,
not thresholded, to avoid machine-speed-dependent CI failures.

Baseline c9d6223, cloud Linux, locally built full Vim, debug daemon:
three repeated runs observed no refresh during continuous scrolling. Stopping
allowed refresh after approximately 300 ms. The distant split had 0/22 visible
lines highlighted while the near split had 22/22; the combined applied range was
[1, 19131]. The distant single-window control had nonzero bottom-line properties.
These are reproduced findings, not assertions that the diagnostic command
succeeding means the product behavior is correct. The diagnostic itself never changes runtime defaults. The initial test-only
commit deliberately left the regular regression gate unchanged while recording
these failures.

After the split-range and bounded-scroll-scheduling fixes, `make check` includes
`vim-scroll-pressure-strict`. The same unchanged defaults produced 7 observed
refreshes during approximately 2.5 seconds of input, with both distant viewports
highlighting 22/22 lines. This is one fixture's measurement, not a broad
performance claim. The strict mode asserts progress and coverage, not those
exact timing/count values. A stop sample already covered by prefetch can report
near-zero settling time; this is not the latency of a new request.
