# Git workflow

- For every change, work on a feature branch and create a pull request targeting `main`.
- Never push directly to remote `main`.
- Agents may merge their pull requests after the required checks pass; no additional user confirmation is needed.

# Simulator coordination

The user requests two simulator test slots running in parallel to reduce waiting.

- Coordinate ownership with the other active Leaf chats before using a slot; report the assigned device UUID and release it when the test process exits. Keep at most two simulator test jobs active, one per device.
- Slot A: iOS 26.5 iPhone 17 Pro, `20E63AE6-36C3-4BC1-B319-06A2FDB902EC`. Slot B: iOS 26.5 Leaf Floating Button QA, `F42C5A14-2B1E-48DE-8B14-B1B46A9C4F34`. Verify availability before use; coordinate a replacement if either device is unavailable.
- Pin each test job to its assigned UUID with `-parallel-testing-enabled NO`; use separate DerivedData and result-bundle paths. Split independent checks between the two slots rather than launching duplicate suites.
- Never install, launch, terminate, erase, or shut down another slot's device while it is owned. Do not reset the shared CoreSimulator service or shut down all devices while either slot is running.
- Phone installation has one coordinator so an older feature build cannot overwrite the combined preview. Generic builds may run independently of simulator ownership.

# Leaf reader verification

The user explicitly requires all reading modes to be tested for future reader changes.

For changes to reading layout, navigation, appearance, or the floating chat UI:

- Exercise both Pages and Scroll with actual rendered books. Passing tests in one mode does not validate the other.
- Check forward and backward chapter boundaries, the beginning/end of the book, and restoration of the saved passage after closing and reopening.
- Check portrait and landscape, the affected fonts and margin settings, and Day/Paper/Night appearance. Typography or text-exclusion changes must cover the full 12–32 pt size range in both flows.
- Keep Ask Leaf open during book taps, text selection, and navigation. Dismiss it only with Close or an intentional downward swipe on the chat’s top bar.
- Check chat closed, open, and composing with the keyboard. The floating button is a translucent, draggable overlay. All lines must retain their normal reading width; do not reserve a gutter or reflow text around it. Exercise long-press, repeated dragging, tap-away dismissal, position restoration, and rotation in both flows.
- Inspect screenshots as well as text geometry. Verify that text remains visible through the button and there is no unnecessary reserved space.
- Include meaningful regression coverage for any discovered mode-specific failure. Report exactly which modes were tested and any remaining limitations.

Keep chapter loading lazy and preserve EPUB CFI meaning, bookmarks, and conversation history when changing text layout.
