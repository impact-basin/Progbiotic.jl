# NEWS

## v0.11.0

- Bars are lock-free, except for rendering.
- FPS cap to avoid wasting cycles.
- Exceptions thrown in progress loops now cause the bar to render where the failure occurred.
- Proper gutter-based rendering; stops trampling of old text.
