# Contributing to Vedivox

Thanks for looking. Vedivox is one person's daily tool, shared as is.

Pull requests with code are welcome once you agree to the
[contributor licence agreement](#contributor-licence-agreement) below: Vedivox may later get paid
parts that are not open source, and a pull request is merged only under those terms. For a larger
change, open an issue first so we can agree on the approach.

Issues are welcome: bug reports, ideas, a place where Vedivox confused you. They are read when
there is time, and an idea that does not fit how Vedivox is meant to work may be declined.

The rest of this page is how the code is built and kept, for anyone building Vedivox themselves
or keeping a fork.

## Build and test

You need macOS 14.4+ on Apple Silicon, Xcode 16 or later and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The
`vedivox` CLI and the MCP server are a Swift package (`VedivoxMCP/`) with the same macOS 14.4 minimum.

```bash
make test TEAM=-            # headless logic suite — the gate, the same one CI runs
make test-snapshots TEAM=-  # main screens rendered offscreen in every palette × theme
make install TEAM=-         # Release build into /Applications, CLI into ~/.local/bin
```

`TEAM=-` signs ad hoc, with no Apple account; pass your own team ID instead to keep the
privacy permissions across rebuilds. `Vedivox/Vedivox.xcodeproj` is generated from
`Vedivox/project.yml` (`make generate`) — never edit it by hand. The README has the details.

The first launch downloads the speech models (about 1 GB); the test suite does not need them.

## Before a change is committed

- `make test TEAM=-` passes.
- A visual change re-records its snapshot references (`make test-snapshots RECORD=1`), and
  you have looked at the new images: a wrong reference locks the bug in.
- A change a user can see adds a line to `CHANGELOG.md` → `## Unreleased`. Non-obvious
  behaviour (a modifier click, a hidden key, a settings file) also goes into
  `docs/GUIDE.md`. Both are in English.
- Views take colours only from the design-system tokens (`Color.Vedivox.*`); a test enforces it.
- No recordings, transcripts, voice embeddings or real people's names anywhere — code,
  tests, fixtures or screenshots. Test data is made up.

## Commits

One change per commit, with a subject that says what changed, optionally prefixed by the
area: `dictation: pause playback while speaking`, `docs: install from Homebrew`. The body
says why, when it is not obvious.

## Licence

Vedivox is licensed under the [GNU General Public License, version 3 or any later
version](LICENSE) (GPL-3.0-or-later).

### Contributor licence agreement

Vedivox may later get a paid or closed edition next to the open-source one. For that
the maintainer needs more rights in your contribution than GPL-3.0-or-later gives, so
a pull request is merged only after you agree to the terms below (version 1,
2026-11-19).

"The maintainer" is Dmitrii Cherkashin and anyone the project later passes to: a
company he sets up, a successor or an heir. "Your contribution" is anything you submit
for inclusion in Vedivox, in a pull request or any other way.

1. You keep the copyright in your contribution and may use it elsewhere as you like.
2. You grant the maintainer a perpetual, worldwide, non-exclusive, royalty-free,
   irrevocable licence to reproduce, modify, publicly display, perform and distribute
   your contribution and works based on it, in source or binary form, and to
   sublicense these rights to others under GPL-3.0-or-later or any other terms,
   including commercial and proprietary ones.
3. You grant the maintainer, and everyone who receives Vedivox from the maintainer
   under any licence, a perpetual, worldwide, non-exclusive, royalty-free, irrevocable
   licence to make, use, sell and import your contribution under any patent claims you
   own or control that the contribution, alone or combined with Vedivox, would
   infringe.
4. The contribution is your own work and you are legally able to agree to these terms.
   If your employer or anyone else has rights in it, you have their permission to
   submit it under these terms. If part of it is someone else's work, the pull request
   says which part and under what licence.
5. Where the law allows, you will not enforce moral rights in your contribution
   against the maintainer or anyone who receives it from the maintainer.
6. You provide the contribution as is, without warranty of any kind.

In return, every merged contribution is published in this repository under
GPL-3.0-or-later, and what has been released under that licence stays under it.
