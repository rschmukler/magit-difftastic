# difftastic-status

Render unstaged/staged changes in the `magit-status` buffer using
[difftastic](https://github.com/Wilfred/difftastic), while keeping them as
collapsible, navigable Magit sections with full staging support.

`difftastic-status` builds on top of [difftastic.el][difftastic-el]. Where
difftastic.el gives you beautiful, syntax-aware diffs in dedicated buffers,
`difftastic-status` brings that rendering *into* `magit-status` itself — and
keeps everything you expect from Magit: collapsible sections, navigation, and
stage / unstage / discard at the file, chunk, **and** line-range level.

## What it looks like

Each changed file becomes a Magit `file` section. Its body is the
difftastic-rendered diff, split on difftastic's own `FILE --- N/M --- LANG`
chunk headers into collapsible per-chunk sub-sections with a minimal,
native-looking `@@ line N @@` heading.

```
Unstaged changes (2)
  src/app.clj
    @@ line 12 @@
      12 (defn handler ...        ; difftastic-rendered, syntax-highlighted
    @@ line 40 @@
      ...
  README.md
    @@ line 3 @@
      ...
```

## Features

- **Difftastic rendering inside `magit-status`** — unstaged and staged
  sections are replaced with difftastic output, using difftastic's own colour
  vectors so it matches `difftastic-magit-diff`.
- **Collapsible, navigable sections** — files and chunks are real Magit
  sections, so `TAB`, section motion, etc. all work.
- **Multi-level staging** that maps difftastic's display back onto real git
  hunks (so every applied patch is a valid git patch):
  - **File level** — `s` / `u` on a file heading stage / unstage the whole file.
  - **Chunk level** — `s` / `u` / `k` on a chunk act on just that chunk.
  - **Line-range level** — with an active region inside a chunk, the same keys
    act on only the selected lines.
- **Beyond `magit-status`** — the same difftastic chunks also render in
  `magit-diff-mode` buffers (including the diff Magit shows while you compose a
  commit message) and in `magit-revision-mode` (viewing a commit). Per-chunk /
  line-range staging stays available where it is meaningful — the worktree
  (unstaged) and `--cached` (staged) diffs — while diffs that merely compare two
  revisions (a range diff, or a commit being viewed) are rendered display-only.
  Anything difftastic can't render (`--no-index` diffs, merge commits shown as a
  combined diff) falls straight back to Magit's stock rendering.
- **Toggleable** — `difftastic-status-mode` is a global minor mode. Turn it off
  and Magit's stock unstaged/staged sections come right back, so you always
  have a fallback. The diff- and revision-buffer integrations can be scoped
  independently with `difftastic-status-diff-buffers` and
  `difftastic-status-revision-buffers`.
- **Optional, graceful Evil integration** — if [Evil][evil] is present the
  staging keys are bound in the relevant magit maps; if not, nothing is
  assumed and the package works with stock Emacs keybindings.

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
(package! difftastic-status
  :recipe (:host github :repo "rschmukler/difftastic-status"))
```

In `config.el`:

```elisp
(use-package! difftastic-status
  :after magit
  :config
  (difftastic-status-mode +1))
```

Then run `doom sync`.

### `straight.el` + `use-package`

```elisp
(use-package difftastic-status
  :straight (:host github :repo "rschmukler/difftastic-status")
  :after magit
  :config
  (difftastic-status-mode +1))
```

### Manual

Clone the repo, put it on your `load-path`, and:

```elisp
(require 'difftastic-status)
(with-eval-after-load 'magit
  (difftastic-status-mode +1))
```

> **Note:** the package does **not** enable itself on load. Enabling
> `difftastic-status-mode` is left to you (see above), so installing the
> package never changes your `magit-status` behaviour until you opt in.

## Usage

Enable the mode with `M-x difftastic-status-mode` (or via your config). It is a
global minor mode; toggling it refreshes any visible `magit-status` buffers
immediately. While it is on:

| Key   | On a file heading        | On a chunk (or selected region)          |
|-------|--------------------------|------------------------------------------|
| `s`   | stage the whole file     | stage the chunk / the selected lines     |
| `u`   | unstage the whole file   | unstage the chunk / the selected lines   |
| `k`   | discard the file         | discard the chunk / the selected lines   |
| `TAB` | collapse / expand file   | collapse / expand the chunk              |
| `RET` | visit the file           | visit the file at the chunk's change     |

These are the standard Magit keys — `difftastic-status` advises Magit's
`magit-stage` / `magit-unstage` / `magit-discard` / `magit-visit-thing`
commands so that, while point is on a difftastic chunk, they operate on that
chunk; otherwise they behave exactly as usual.

The following interactive commands are also available for direct binding or
`M-x`:

- `difftastic-status-stage-chunk`
- `difftastic-status-unstage-chunk`
- `difftastic-status-discard-chunk`
- `difftastic-status-visit-file-dwim`

### Evil integration

If Evil is loaded when the mode is enabled, `s` / `u` / `x` are bound in
`magit-mode-map` and `magit-section-mode-map` for both normal and visual
states, so chunk staging and region (line-range) staging behave identically
and predictably under `evil-collection-magit`. If Evil is not present, this
step is skipped entirely — no hard dependency, nothing assumed.

## Configuration

| Variable                                 | Default      | Description                                                                 |
|------------------------------------------|--------------|-----------------------------------------------------------------------------|
| `difftastic-status-display`              | `"inline"`   | Value passed to `difft --display`. `inline` is strongly recommended; line-range staging relies on its one-row-per-line layout. |
| `difftastic-status-chunk-heading-face`   | `magit-hash` | Face for the per-chunk `@@ line N @@` headings.                             |
| `difftastic-status-apply-context`        | `1`          | Context lines for the git hunks used to stage/unstage chunks. Must be `>= 1`. |
| `difftastic-status-diff-buffers`         | `t`          | Render `magit-diff-mode` buffers (including the commit-message preview) with difftastic chunks. |
| `difftastic-status-revision-buffers`     | `t`          | Render `magit-revision-mode` buffers (viewing a commit) with difftastic chunks. |

## How it works

difftastic is used for **display only**. Git's own unified diff stays the
source of truth for any patch that gets applied, so every applied patch is a
valid git patch:

1. read the chunk's `(file, index, staged)` from the section value;
2. lazily run `difft --display json` for that file to get the chunk's exact
   old/new line numbers;
3. run `git diff --no-ext-diff -U1` for fine-grained hunks;
4. select the git hunk(s) overlapping the chunk's lines (region staging
   transforms the hunk the same way `magit-diff-hunk-region-patch` does);
5. apply that mini-patch with `git apply [--cached] [--reverse]`.

Chunk sub-sections use a custom `difftastic-hunk` section type (deliberately
*not* Magit's real `hunk` type, which would repaint lines and clobber
difftastic's colours). Because that custom type is not one Magit's apply
machinery understands — and because `evil-collection-magit` makes
`magit-mode-map` an overriding map — per-chunk commands are wired by *advising*
the magit commands, which is binding- and evil-state-agnostic.

## Known limitations

- Region staging operates within a single chunk at a time. A region spanning
  multiple chunks/files only affects the chunk that contains it. Whole-chunk
  staging snaps to the underlying git-hunk boundary — the same boundary
  Magit's own per-hunk staging uses.
- `difft` is run synchronously, once per changed file, on every status refresh
  (plus one extra `difft --display json` per staging action). On large change
  sets this can make `magit-status` sluggish. The same cost applies to the
  difftastic-rendered diff and revision buffers.
- Untracked files are still rendered by the stock
  `magit-insert-untracked-files`.
- In `magit-diff-mode` / `magit-revision-mode` buffers the difftastic rendering
  replaces Magit's diff section wholesale, so the usual diffstat header is not
  shown there. Merge commits (shown as a combined diff) and `--no-index` diffs
  are left to Magit's stock rendering.

## License

[MIT](./LICENSE).

[difftastic-el]: https://github.com/pkryger/difftastic.el
[evil]: https://github.com/emacs-evil/evil
