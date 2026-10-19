+++
title = "DreamWeave Site"
description = "The static site generator every DreamWeave site, and Jess's own documentation, is built with."
date = 2026-10-19

[taxonomies]
tags = ["Jess", "Luau"]

[extra]
sections = ["overview", "releases", "credits"]
+++

The static site generator every DreamWeave site, and Jess's own documentation, is built with.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.site`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.site" = "0.1"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
