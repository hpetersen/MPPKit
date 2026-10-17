# Contributing to MPPKit

Thank you for helping. `.mpp` has no published specification, so most of what
MPPKit knows comes from real files. The most useful contribution is a file that
MPPKit reads or writes wrongly.

## Reporting a file that goes wrong

Open an issue with:

- what you did (read, edit, save) and what went wrong;
- the Microsoft Project version and language that last saved the file;
- the output of `swift run mppdump tree <file.mpp>` and
  `swift run mppdump meta <file.mpp>`. These show the file's structure and
  record counts, not its contents.

Real project files carry names, e-mail addresses and the path they were saved
from (`swift run mppdump strings <file.mpp>` shows everything readable in a
file). Please do not attach a client's file to a public issue. If the problem
only shows with the file itself, say so in the issue and we will arrange a
private way to send it. You can also try to reproduce the problem in a new,
empty plan saved by Project.

## Pull requests

- Keep a change to one thing, with a test where the behaviour can be tested
  without a private file (see `Tests/MPP14Tests/Fixture.swift` for tests that
  use one).
- Run `swift test` before opening the pull request.
- Follow the style of the code around the change, including the doc comments:
  say what a field is and why it is read the way it is.
- New source files start with the same licence header as the existing ones.

## Contributor licence agreement

MPPKit is released under the GPL v3, and the same code is used in MPP Studio,
which is not open source. So that a contribution can go into both,
contributions are accepted on these terms:

> By submitting a contribution to MPPKit (code, documentation, tests or
> sample files), you confirm that you wrote it, or have the right to submit it,
> and you grant Henrik Petersen a perpetual, worldwide, non-exclusive,
> royalty-free, irrevocable licence to use, copy, modify, sublicense and
> distribute it, under the GPL v3 and under any other licence, including in
> closed-source software. You keep the copyright in your contribution, and you
> may use it however you like.

Please state in your first pull request that you agree to these terms.

## Questions

For anything that is not a bug or a pull request, write to
hello@mppstudio.com.
