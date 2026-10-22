# Git workflow

- For every change, work on a feature branch and create a pull request targeting `main`.
- Never push directly to remote `main`.
- Agents may merge their pull requests after the required checks pass; no additional user confirmation is needed.

# Leaf reader verification

The user explicitly requires all reading modes to be tested for future reader changes.

For changes to reading layout, navigation, appearance, or the floating chat UI:

- Exercise both Pages and Scroll with actual rendered books. Passing tests in one mode does not validate the other.
- Check forward and backward chapter boundaries, the beginning/end of the book, and restoration of the saved passage after closing and reopening.
- Check portrait and landscape, the affected fonts and margin settings, and Day/Paper/Night appearance. Typography or text-exclusion changes must cover the full 12–32 pt size range in both flows.
- Check chat closed, open, and composing with the keyboard. Unaffected lines must retain their full reading width; a full-height gutter is not an acceptable substitute for the selected circular text-wrap design in reflowable text.
- Inspect screenshots as well as text geometry. Assert both absence of overlap and absence of unnecessary reserved space.
- Include meaningful regression coverage for any discovered mode-specific failure. Report exactly which modes were tested and any remaining limitations.

Keep chapter loading lazy and preserve EPUB CFI meaning, bookmarks, and conversation history when changing text layout.
