# Site generator benchmarks

`bench/bench.luau` times the package through what it exports: loading a site (scan, shortcodes,
Markdown), the whole build from load to the last file written, and each stage on its own over the
same site's text. Each workload is warmed up, sized to a batch of about a tenth of a second, and
reported as the median of seven batches, with a full collection between them. Every call of a
workload must return what its first call did, and what it returned is digested outside the time
and printed on a `#` line, so two runs over one site can be told to have done the same work. With
no site root the bench builds the suite's fixture site and checks the build against the tree the
suite pins.

```sh
jess run --package jpk/dreamweave-site --package-path jpk \
  --capability filesystem.read --capability filesystem.write \
  jpk/dreamweave-site/bench/bench.luau <scratch folder> [site root] [filter]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-13.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.2 (Luau 0.742), the same one for
  both sides.
- Site: Jess's own, `site/` in the Jess repository: 96 pages and 12 sections, 1.3 MB of Markdown,
  22 templates, 11 Sass files, 135 files in the built site.
- Base: `31cfcfa`, the package before the move, with this bench (the bench file itself is head's
  on both sides: it digests outside the time, which base's copy did inside it). Head: `9f46cd2`.
- Protocol: the whole bench run against base, then head, three times over, back to back under one
  lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change. All 16 digests were the same on both sides in every round, and the site head builds is
  byte for byte the site base builds.

| Workload | Base, ms | Head, ms | Base / head |
|---|---:|---:|---:|
| load: scan, shortcodes and markdown | 207.989 | 87.589 | 2.37x |
| build: the whole site, load to last write | 569.764 | 357.179 | 1.60x |
| render: every item through its template | 107.189 | 75.085 | 1.43x |
| markdown: every item's source as a document | 116.314 | 47.764 | 2.44x |
| markdown: every line as inline text | 54.606 | 26.996 | 2.02x |
| sass: every stylesheet, imports expanded | 17.117 | 10.499 | 1.63x |
| search: clean every body and encode the index | 75.965 | 25.261 | 3.01x |
| json: every item's metadata, compact and pretty | 80.239 | 23.313 | 3.44x |
| tera: parse every template | 2.480 | 2.060 | 1.20x |
| expr: fifteen expressions against every item | 3.244 | 3.290 | no change |
| util: escapeHtml over every line | 6.277 | 3.029 | 2.07x |
| util: trim over every line | 15.920 | 1.088 | 14.63x |
| util: slugify over every line | 49.184 | 15.345 | 3.21x |
| util: split every line on spaces | 19.015 | 19.264 | no change |
| util: five globs against every content path | 2.412 | 1.623 | 1.49x |
| util: walk the content folder | 0.644 | 0.663 | no change |
| `jess run` of the whole build, cold | 672.3 | 480.5 | 1.40x |

The last row is not the bench's: it is `jess run tools/site/build.luau site <scratch>` as
`buildSite` runs it, process start to exit, the median of seven runs a side, alternating, under the
same lock.

None of this came from comprehensions, which lower to the loops they replaced; the package has a
handful now, where a list is built from a list, and they moved nothing (`util: split` is one). What
moved is where the text is searched. `@dream/bytes` does it in the search body (elements blanked by
regexes, lines squeezed by two `translate` calls, 3x), in JSON strings (the bytes to escape found
by a regex, not by a loop over every byte, most of 3.4x), in inline Markdown (the next byte of
syntax found by a regex, not by a pattern's character class), in slugs (one `translate`), and in
word counts. The rest is ordinary Luau done less often: `trim` is one anchored match, and none at
all for text that starts and ends on a letter (14.6x); a Markdown
line is asked only the block questions its first byte allows; inline shortcodes are searched for
from where the last one ended, not from the top of the page again for each; a template's nodes
and a JSON value are written into one list of pieces, not joined at every level of nesting. The
expression evaluator is unchanged, and so is its row.

What is left of the build is mostly not Luau. `jess.fs.write` replaces a file through a synced
temporary, about 1 ms a file here, so 119 written files are roughly 125 ms of head's 357: a third
of the build, and the reason it moved 1.6x where loading moved 2.4x. The package still writes
through it.
