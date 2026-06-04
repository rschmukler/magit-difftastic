# magit-difftastic

[![CI](https://github.com/rschmukler/magit-difftastic/actions/workflows/ci.yml/badge.svg)](https://github.com/rschmukler/magit-difftastic/actions/workflows/ci.yml)

Render diffs with [difftastic](https://github.com/Wilfred/difftastic) *inside*
Magit's own buffers (`magit-status`, `magit-diff-mode`, `magit-revision-mode`),
as collapsible, navigable Magit sections with full staging support. Builds on,
and complements, [difftastic.el][difftastic-el].


## What it looks like

Each changed file is a Magit `file` section; its body is the difftastic diff,
split into collapsible per-chunk sub-sections with a native-looking
`@@ line N @@` heading.

<img width="3366" height="1728" alt="image" src="https://github.com/user-attachments/assets/0dfc46ea-d638-4802-9290-670ab729a609" />

## Features

- **In-place difftastic rendering** — replaces Magit's diff sections, using
  difftastic's colour vectors so it matches `difftastic-magit-diff`.
- **Multi-level staging** — `s` / `u` / `k` work on the whole **file**, a single
  **chunk**, or just the **selected lines**, mapped back onto real git hunks so
  every applied patch is valid.
- **Real Magit sections** — files and chunks are genuine sections, so `TAB`,
  navigation, and the rest of Magit work as usual.
- **Works beyond `magit-status`** — also renders in `magit-diff-mode` (including
  the commit-message preview) and `magit-revision-mode`; staging stays available
  on the worktree and `--cached` diffs, with revision-only diffs shown
  display-only. Anything difftastic can't render falls back to stock Magit.
- **Per-file toggle** — `magit-difftastic-toggle-file-rendering` (`C-c C-d`)
  switches a single file between difftastic and stock Magit rendering (the
  latter giving Magit's own per-line staging); buffer-local and refresh-safe.
- **Configurable display** — inline or side-by-side, optional major-mode syntax
  highlighting, optional line-number gutters.
- **Drop-in and reversible** — `magit-difftastic-mode` is a global minor mode;
  turn it off and stock Magit returns.
- **Optional Evil integration** — staging keys are bound in the magit maps when
  [Evil][evil] is present, and skipped entirely when it isn't.

## How this differs from difftastic.el

[difftastic.el][difftastic-el] also integrates difftastic with Magit, via the
`difftastic-magit-diff` / `difftastic-magit-show` commands. Those render into a
**dedicated, read-only buffer** — great for *viewing* a structural diff, but
with no Magit sections and no staging.

`magit-difftastic` instead renders *in place* in Magit's own buffers, as real
sections you can **stage at the file, chunk, or line level**. It's a drop-in
minor mode (not commands you invoke), and reuses difftastic.el under the hood
for rendering and colours.

In short: use **difftastic.el** to *view* a diff in its own buffer; use
**`magit-difftastic`** to *review and stage* changes without leaving Magit.

## Requirements

- Emacs 28.1+
- [`magit`](https://github.com/magit/magit) 3.3.0+
- [`difftastic`][difftastic-el] (the Emacs package) 0.5.0+
- The [`difft`](https://github.com/Wilfred/difftastic) executable on your `PATH`
- (optional) [`evil`][evil] for the Vim-style staging keys

## Installation

### Doom Emacs

In `packages.el`:

```elisp
(package! magit-difftastic
  :recipe (:host github :repo "rschmukler/magit-difftastic"))
```

In `config.el`:

```elisp
(use-package! magit-difftastic
  :after magit
  :config
  (magit-difftastic-mode +1))
```

Then run `doom sync`.

### `straight.el` + `use-package`

```elisp
(use-package magit-difftastic
  :straight (:host github :repo "rschmukler/magit-difftastic")
  :after magit
  :config
  (magit-difftastic-mode +1))
```

### Manual

Clone the repo, put it on your `load-path`, and:

```elisp
(require 'magit-difftastic)
(with-eval-after-load 'magit
  (magit-difftastic-mode +1))
```

> **Note:** the package does **not** enable itself on load — enabling
> `magit-difftastic-mode` is left to you, so installing it never changes Magit
> until you opt in.

## Usage

Enable the mode with `M-x magit-difftastic-mode` (or via your config); toggling
it refreshes visible Magit buffers immediately. While it is on:

| Key   | On a file heading        | On a chunk (or selected region)          |
|-------|--------------------------|------------------------------------------|
| `s`   | stage the whole file     | stage the chunk / the selected lines     |
| `u`   | unstage the whole file   | unstage the chunk / the selected lines   |
| `k`   | discard the file         | discard the chunk / the selected lines   |
| `TAB` | collapse / expand file   | collapse / expand the chunk              |
| `RET` | visit the file           | visit the file at the chunk's change     |

These are the standard Magit keys: `magit-difftastic` advises `magit-stage` /
`magit-unstage` / `magit-discard` / `magit-visit-thing` so that, on a difftastic
chunk, they act on that chunk — otherwise they behave as usual.

These interactive commands are also available for direct binding or `M-x`:

- `magit-difftastic-stage-chunk`
- `magit-difftastic-unstage-chunk`
- `magit-difftastic-discard-chunk`
- `magit-difftastic-visit-file-dwim`

### Evil integration

If Evil is loaded when the mode is enabled, `s` / `u` / `x` are bound in
`magit-mode-map` and `magit-section-mode-map` (normal and visual states) so
chunk and region staging behave predictably under `evil-collection-magit`. If
Evil is absent, this is skipped entirely — no hard dependency.

## Configuration

| Variable                                 | Default      | Description                                                                 |
|------------------------------------------|--------------|-----------------------------------------------------------------------------|
| `magit-difftastic-display`              | `"side-by-side"` | Layout passed to `difft --display`: `"inline"`, `"side-by-side"`, or `"side-by-side-show-both"`. All support per-chunk and line-range staging. |
| `magit-difftastic-line-numbers`         | `t`          | Whether difft's per-line number gutters are shown. When `nil` they are hidden; staging works the same either way. |
| `magit-difftastic-syntax-highlight`     | `t`          | Layer the file's Emacs major-mode font-lock faces onto each chunk's code (difft only emphasizes keywords/comments). Diff colors keep precedence. Adds per-file fontification cost; set `nil` to disable. |
| `magit-difftastic-width`                | `window`     | Column width passed to difft, controlling where it wraps long lines: `window` (fit the window) or an integer (fixed columns; larger wraps less). |
| `magit-difftastic-min-width`            | `40`         | Minimum column width requested from difft. |
| `magit-difftastic-render-jobs`          | `nil`        | Maximum number of `difft` processes run concurrently per refresh. `nil` uses the processor count (capped); a positive integer sets a fixed limit (`1` renders serially). |
| `magit-difftastic-cache`                | `t`          | Cache rendered difft output across refreshes, keyed on the compared blobs (plus display and width), so unchanged files are not re-rendered. Clear with `magit-difftastic-clear-cache`. |
| `magit-difftastic-chunk-heading-face`   | `magit-diff-hunk-heading` | Face for the per-chunk `@@ line N @@` headings. Defaults to Magit's hunk-heading face (a full-width bar); set to e.g. `magit-hash` for understated headings. |
| `magit-difftastic-apply-context`        | `1`          | Context lines for the git hunks used to stage/unstage chunks. Must be `>= 1`. |
| `magit-difftastic-diff-buffers`         | `t`          | Render `magit-diff-mode` buffers (including the commit-message preview) with difftastic chunks. |
| `magit-difftastic-revision-buffers`     | `t`          | Render `magit-revision-mode` buffers (viewing a commit) with difftastic chunks. |
| `magit-difftastic-toggle-rendering-key` | `"C-c C-d"`  | Key bound on difftastic/stock sections to `magit-difftastic-toggle-file-rendering` (switch the file at point between difftastic and stock Magit rendering). `nil` binds no key. |

## How it works

difftastic is used for **display only** — git's own unified diff stays the
source of truth for every applied patch:

1. read the chunk's `(file, index, staged)` from the section value;
2. lazily run `difft --display json` for that file to get the chunk's exact
   old/new line numbers;
3. run `git diff --no-ext-diff -U1` for fine-grained hunks;
4. select the git hunk(s) overlapping the chunk's lines (region staging
   transforms the hunk the same way `magit-diff-hunk-region-patch` does);
5. apply that mini-patch with `git apply [--cached] [--reverse]`.

Chunk sub-sections use a custom `magit-difftastic-hunk` section type (not
Magit's real `hunk` type, which would repaint lines and clobber difftastic's
colours). Since Magit's apply machinery doesn't understand that type, per-chunk
commands are wired by *advising* the magit commands — binding- and
evil-state-agnostic.

## Known limitations

- Region staging operates within a single chunk; whole-chunk staging snaps to
  the underlying git-hunk boundary (the same one Magit's per-hunk staging uses).
- `difft` runs once per changed file when its content first needs rendering.
  Files in a section are rendered concurrently (up to `magit-difftastic-render-jobs`
  at a time) and the output is cached across refreshes keyed on the compared
  blobs (`magit-difftastic-cache`), so unchanged files are not re-rendered — a
  refresh costs roughly the slowest file that actually changed. A very large set
  of first-time changes can still feel sluggish, since the refresh waits for that
  initial batch. Clear the cache with `M-x magit-difftastic-clear-cache`.
- Untracked files use the stock `magit-insert-untracked-files`.
- In `magit-diff-mode` / `magit-revision-mode`, difftastic replaces Magit's diff
  section wholesale, so the diffstat header isn't shown. Merge commits and
  `--no-index` diffs fall back to stock Magit.

## Testing

The test suite ([`test/magit-difftastic-test.el`](./test/magit-difftastic-test.el))
uses ERT and is run with [Eldev][eldev]:

```sh
eldev test
```

It mixes fast unit tests with integration tests that drive the real rendering
and staging pipeline against a throwaway git repo. The integration tests need
`difft` and `git` on `PATH`, and are skipped automatically when either is
missing.

## License

[MIT](./LICENSE).

[difftastic-el]: https://github.com/pkryger/difftastic.el
[evil]: https://github.com/emacs-evil/evil
[eldev]: https://github.com/emacs-eldev/eldev
