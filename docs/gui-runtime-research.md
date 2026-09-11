# Native GUI runtime research

Status: research checkpoint, 2026-08-28. No GUI implementation decision has been made.

## Objective

The prospective GUI is a thin interactive front end to fx, not a second harness. It must preserve fx's ownership of sessions, models, tools, permissions, processes, persistence, and Fixer orchestration.

The acceptance bar is intentionally severe:

- The window must feel instantaneous, including cold startup and first useful frame.
- An unchanged window must consume no measurable idle CPU. A permanent frame loop is disqualifying.
- Incremental memory and binary size must be counted honestly, including runtimes, helper processes, drivers, and dynamically loaded libraries.
- The GUI must not embed a browser or WebView.
- Typing, scrolling, selection, resizing, and long transcripts must remain responsive under realistic load.
- Text must eventually support shaping, bidirectional paragraphs, grapheme-aware editing, line breaking, fallback fonts, emoji, and input methods.
- Linux-only is acceptable for the first implementation if the architecture does not make later platforms impossible.
- The visual direction is already established separately. This investigation concerns runtime technology, not visual design.

"Small" and "fast enough" are not substitutes for measurements. The target is the class of result demonstrated by Blick: a polished native application with unusually little distribution and runtime overhead.

## Test environment

Local measurements in this document were collected on:

- Linux 7.2, x86-64, native Wayland under Hyprland
- Intel Core i5-4670, four cores at up to 3.8 GHz
- NVIDIA GeForce GTX 1060 3 GB
- The current fx binary was 12,525,480 bytes when this checkpoint was recorded

These are comparative observations from one older desktop, not portable performance guarantees. First-frame probes were inserted at the application's first visible surface commit or present where source access allowed it. Memory is proportional set size from Linux `smaps_rollup`, which apportions shared pages instead of charging every process their full mapped size. Idle CPU checks compare process CPU ticks across a five-second quiescent interval.

## Strongest finding

There is no evidence that a full general-purpose GUI framework is required for this product. There is direct evidence that the desired Linux runtime class is possible.

A reduced build of [fuzzel](https://codeberg.org/dnkl/fuzzel), a mature direct-Wayland C application, produced:

| Measurement | Result |
| --- | ---: |
| Stripped executable | 452,600 bytes |
| First visible surface commit | 22.9 to 24.7 ms |
| Idle proportional set size | about 9.0 MB |
| Idle anonymous proportional memory | about 3.3 MB |
| CPU ticks during five idle seconds | 0 |

Fuzzel blocks in `epoll_wait`, uses Wayland shared-memory buffers, schedules surface frames only when needed, and supports the Wayland `text-input-v3` protocol for input method preedit and commit. Its text path uses [fcft](https://codeberg.org/dnkl/fcft), Fontconfig, FreeType, HarfBuzz, and Pixman. [foot](https://codeberg.org/dnkl/foot) provides a larger, mature example of the same family of techniques with terminal rendering, detailed damage tracking, clipboard integration, and input methods.

Fuzzel is not a suitable conversation GUI framework. Its interface is much simpler than the proposed product, and fcft does not provide complete paragraph layout. The result is important because it falsifies the assumption that a desktop GUI inherently requires GTK, Electron, a WebView, a GPU abstraction, a continuous renderer, or tens of megabytes of application code.

## Text layout investigation

Text is the decisive technical risk. A conversation surface needs substantially more than glyph rasterization.

### fcft

Fcft provides a compact and mature font and glyph layer. It uses HarfBuzz for shaping and can segment grapheme clusters when built with utf8proc. Its source explicitly leaves two relevant responsibilities to the caller:

- It does not implement the Unicode Bidirectional Algorithm for mixed-direction paragraphs.
- It does not provide multiline paragraph wrapping and layout.

Fcft remains useful as evidence and possibly as a lower-level component, but it is not the whole text answer.

### Pango without GTK

[Pango](https://docs.gtk.org/Pango/pango_rendering.html) can be used directly through its FreeType backend. GTK and a widget toolkit are not required. Pango supplies itemization, font fallback, shaping, bidirectional handling, break opportunities, and paragraph layout.

A local C probe laid out mixed English, Arabic, Hebrew, Hindi, Thai, Japanese, and emoji text at a 760-pixel width:

| Input | Fresh process through first layout | Forced full relayout |
| --- | ---: | ---: |
| 283 bytes | 31 to 39 ms | about 0.15 ms |
| 2,264 bytes | 34 to 36 ms | about 1.2 ms |
| 6,792 bytes | 36 to 39 ms | about 3.6 ms |
| 22,640 bytes | 48 to 51 ms | about 12.7 ms |

With the 6,792-byte layout retained, the process used about 12.2 MB PSS, of which about 5.9 MB was anonymous, and consumed zero CPU ticks during five idle seconds.

The forced-relayout column is deliberately pessimistic. A conversation view can retain one immutable layout per message and relayout only changed messages or messages affected by width changes. That claim still needs to be verified inside a real surface with scrolling, selection, and edits.

### Runa, the pure-Odin text engine vendored by Skald

[Skald](https://github.com/BuLEEto/Skald) vendors a pure-Odin text engine named Runa. Excluding Unicode test data, its Odin source is about 0.5 MB. The code includes OpenType parsing and shaping, Unicode bidirectional resolution, grapheme and word segmentation, line breaking, fallback fonts, rasterization, an atlas, and a bounded shape cache.

Runa is attractive architecturally but not yet evidence-grade for this product. Direct source inspection found stale milestone comments, approximate cluster tracking, incomplete OpenType lookup coverage, explicit approximations, and effectively no vendored unit-test body despite claims of Unicode conformance. It should not replace HarfBuzz or Pango merely because it is pure Odin. It can remain a measured challenger if its conformance and behavior are independently established.

## Accessibility

Custom rendering does not create a native accessibility tree automatically. [AccessKit](https://github.com/AccessKit/accesskit) is designed for custom and immediate-mode toolkits and supplies a Unix AT-SPI adapter plus C bindings.

The current prebuilt x86-64 C library was 21,637,968 bytes with debug and symbol data and 1,814,400 bytes after stripping. A minimal inactive Unix adapter probe measured:

| Measurement | Result |
| --- | ---: |
| Initialization | about 0.06 ms |
| Idle proportional set size | about 1.73 MB |
| Idle anonymous proportional memory | about 0.37 MB |
| CPU ticks during five idle seconds | 0 |
| Sleeping process threads | 4 |

This is much smaller than the release artifact initially suggests, but it is not free. AccessKit also states that its platform adapters do not yet support rich text or hypertext. The next runtime probe should keep accessibility behind a clean boundary and measure both an inactive adapter and an active screen-reader session. A direct AT-SPI implementation could avoid Rust and extra threads, but that would add substantial correctness burden and is not justified without measurement.

## Application and framework results

The following projects were investigated as implementations rather than as marketing claims.

| Project | Relevant result | Assessment |
| --- | --- | --- |
| [Blick](https://blickeditor.com/) | Native video editor under 30 MB, written in Odin with an internal renderer and UI system | Product-level proof of ambition; its framework is not open source |
| [fuzzel](https://codeberg.org/dnkl/fuzzel) | 453 KB stripped, 23 to 25 ms first surface, 9 MB PSS, zero measured idle CPU | Best runtime proof; application, not reusable conversation framework |
| [foot](https://codeberg.org/dnkl/foot) | Mature direct-Wayland terminal with damage, input methods, clipboard, and event-driven rendering | Strong source reference for hard runtime problems |
| [Odek](https://github.com/chrishayen/odin-ui) | 518 KB executable and about 20 to 23 ms warm first present | Confirms tiny Odin and software-rendered Wayland is possible; currently redraws every compositor frame, crashed in testing, and lacks production text and accessibility |
| [Lite XL](https://github.com/lite-xl/lite-xl) | 608 KB executable and about 86 to 93 ms warm first present | Excellent compact custom-editor precedent; text completeness and accessibility fall short |
| [Skald](https://github.com/BuLEEto/Skald) | 7.94 MB hello example, 9.38 MB chat stress example | Interesting Odin Vulkan UI and one-frame update model; about 105 MB idle RSS on this NVIDIA system and immature text/accessibility boundaries |
| [Makepad](https://github.com/makepad/makepad) | Counter example about 13.39 MB stripped | Innovative custom GPU stack, but the incremental artifact and integration surface are not thin |
| [DVUI](https://github.com/david-vanderson/dvui) | SDL example about 11.35 MB | Useful Zig work, but current text, input method, bidirectional, and accessibility limitations are disqualifying |
| [Slint](https://github.com/slint-ui/slint) | Default template about 17.06 MB stripped | Mature product framework, but too much framework and dependency surface for this goal |
| [WarpUI](https://github.com/warpdotdev/warp) | Open-source GPU conversation and terminal UI with wgpu, winit, and cosmic-text | Highly relevant source reference; dependency and build surface are far beyond a nearly free fx front end |
| [GPUI and Zed](https://github.com/zed-industries/zed) | High-performance custom GPU editor architecture | Valuable ideas and evidence for retained scene rendering; not a thin embeddable answer for fx |
| GTK 4 | Minimal local window reached first paint in roughly 125 to 138 ms when warm | Useful control measurement, not a leading candidate |
| WebView and Electron stacks | Depend on an external browser runtime and often multiple processes | Rejected by the runtime and accounting criteria before visual design |

Sokol, Mach, Dear ImGui, egui, Iced, Floem, Xilem, Vizia, Capy, zigui, FLTK, and libui-ng were also screened. They either provide only a substrate, impose a material runtime or dependency layer, target tools rather than a polished text application, or lack the text, input method, accessibility, or maturity needed here. None currently clears all gates as an off-the-shelf choice.

## Current conclusion

No existing open-source framework found so far satisfies all of the requirements as a complete package.

That does not imply building a general-purpose framework from nothing. The most credible path exposed by the research is a very small, product-specific retained UI layer over mature Linux primitives:

- direct Wayland surface and input protocols;
- a blocking file-descriptor event loop;
- shared-memory buffers and damage-limited redraws;
- a mature paragraph and shaping engine;
- immutable, independently cached message layouts;
- the existing fx process and state as the sole harness;
- an accessibility adapter with its runtime cost measured separately.

This is closer to owning a focused conversation surface than owning a framework. Fuzzel and foot demonstrate that the windowing, input, clipboard, scheduling, and rendering substrate can stay extremely small. Pango demonstrates that complete text layout can be purchased without GTK. The combination has not yet been proven under the actual conversation workload, so it remains a hypothesis rather than a recommendation.

## Next intended step

Build a disposable measurement probe, not the product GUI and not its visual design.

The probe should combine direct Wayland, an `epoll`-blocked event loop, shared-memory rendering, Pixman, and PangoFT2. It should render a realistic fx transcript with hundreds of messages while virtualizing off-screen content. It should include a multiline composer using `text-input-v3`, selection, clipboard, mixed-direction text, emoji, resize-driven reflow, incremental streaming append, and scroll damage.

The probe should record, at minimum:

1. Process start to first useful frame, both cold and warm.
2. Binary delta relative to the same fx commit without the probe.
3. PSS, anonymous PSS, thread count, and mapped libraries at idle.
4. CPU ticks over at least 30 unchanged seconds.
5. Typing-to-present latency, scroll frame time, resize reflow time, and streamed-token append time.
6. Allocation count and bytes for startup, one typed character, one token append, and one viewport scroll.
7. Correctness screenshots and cursor or selection round trips for Arabic, Hebrew, Indic, Thai, CJK, combining sequences, emoji, and input method preedit.
8. The same measurements with an inactive and active accessibility adapter.

The probe passes only if it remains in the runtime class established by fuzzel while handling the harder conversation workload. If Pango is the material regression, the next comparison is the same probe with a narrowly scoped HarfBuzz, FriBidi, and line-break layout path. Runa should enter that comparison only after independent Unicode and OpenType conformance checks. No product architecture should be committed before this probe identifies where the real cost lies.
