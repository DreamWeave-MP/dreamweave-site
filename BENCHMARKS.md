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
  on both sides: it digests outside the time, which base's copy did inside it). Head: `212aa8e`.
- Protocol: the whole bench run against base, then head, three times over, back to back under one
  lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change. All 16 digests were the same on both sides in every round, and the site head builds is
  byte for byte the site base builds.

| Workload | Base, ms | Head, ms | Base / head |
|---|---:|---:|---:|
| load: scan, shortcodes and markdown | 198.068 | 86.493 | 2.29x |
| build: the whole site, load to last write | 570.593 | 356.523 | 1.60x |
| render: every item through its template | 99.998 | 73.909 | 1.35x |
| markdown: every item's source as a document | 108.834 | 47.869 | 2.27x |
| markdown: every line as inline text | 51.888 | 26.501 | 1.96x |
| sass: every stylesheet, imports expanded | 16.599 | 10.407 | 1.59x |
| search: clean every body and encode the index | 76.352 | 25.143 | 3.04x |
| json: every item's metadata, compact and pretty | 77.406 | 23.182 | 3.34x |
| tera: parse every template | 2.512 | 2.036 | 1.23x |
| expr: fifteen expressions against every item | 3.228 | 3.166 | no change |
| util: escapeHtml over every line | 6.238 | 3.033 | 2.06x |
| util: trim over every line | 15.917 | 1.106 | 14.39x |
| util: slugify over every line | 50.300 | 13.506 | 3.72x |
| util: split every line on spaces | 18.805 | 18.646 | no change |
| util: five globs against every content path | 2.422 | 1.550 | 1.56x |
| util: walk the content folder | 0.640 | 0.652 | no change |
| `jess run` of the whole build, cold | 675.7 | 483.7 | 1.40x |

The last row is not the bench's: it is `jess run tools/site/build.luau site <scratch>` as
`buildSite` runs it, process start to exit, the median of seven runs a side, alternating, under the
same lock.

None of this came from comprehensions, which lower to the loops they replaced; the package has a
handful now, where a list is built from a list, and no row here is one of them (`util: split` cuts
on a space, which is the loop it always was). What moved is where the text is searched.
`@dream/bytes` does it in the search body (elements blanked by regexes, lines squeezed by two
`translate` calls, 3x), in JSON strings (the bytes to escape found by a regex, not by a loop over
every byte, most of 3.3x), in inline Markdown (the next byte of syntax found by a regex, not by a
pattern's character class), in slugs (one `translate`), and in word counts. The rest is ordinary
Luau done less often: `trim` is one anchored match, and none at all for text that starts and ends
on a letter (14.4x); a Markdown line is asked only the block questions its first byte allows;
inline shortcodes are searched for from where the last one ended, not from the top of the page
again for each; a template's nodes and a JSON value are written into one list of pieces, not
joined at every level of nesting. The expression evaluator is unchanged, and so is its row.

Each change made for speed was also run against the commit before it, three rounds a side under
the same lock, on the rows it names. All but one moved its row by more than the noise. Evaluating
a template expression under `pcall` with no closure made for it (`9ab47f9`) did not: `render` went
from 98.6 ms to 95.2 ms, which is no change. It is kept for being the plainer call.

What is left of the build is mostly not Luau. `jess.fs.write` replaces a file through a synced
temporary, about 1 ms a file here, so 119 written files are roughly 125 ms of head's 357: a third
of the build, and the reason it moved 1.6x where loading moved 2.3x. The package still writes
through it.
