# Local reader engine changes

The foliate-js commit in `dependencies.json` identifies the upstream base. Leaf modifies `LeafReader/Resources/Reader/foliate/paginator.js` for page-turn feedback:

- Settling animation lasts 360 ms. The app enables it for paginated reading unless Reduce Motion is enabled.
- Swipe settling shares the navigation lock, preventing overlapping turns. Locks are released in `finally` blocks.
- A release more than 80 ms after the last movement ignores stale flick velocity; the existing distance threshold remains unchanged.
- System-canceled touches return to the original page. Taps without a drag do not start a settling animation.
- Touch velocity handles equal timestamps, and snapping checks adjacent section bounds.

`ReaderEngineTests.testPageTurnsAnimateAndCancelledSwipesKeepThePassage` measures intermediate positions, elapsed time, cancellation, forward/backward navigation, and overlapping input in WebKit. The immersive UI test also checks short drags and forward/backward swipes using real synthesized iOS gestures.
