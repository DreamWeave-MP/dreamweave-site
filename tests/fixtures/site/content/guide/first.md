+++
title = "First steps"
description = "Start <here> & now"
weight = 2
date = "2024-03-01"
updated = "2024-04-02"
aliases = ["old/first", "legacy/first.html", ""]
authors = ["Ada", "Grace"]

[taxonomies]
tags = ["Intro", "Deep Dive"]

[extra]
level = "beginner"
+++

The summary paragraph, before the fold.

<!-- more -->

# First heading #

## Second `heading` with *marks*

### Second heading with marks

Intra_word_underscores stay, _emphasis_ does not, __strong__ too, and snake_case_name survives.
A hard break follows  
after two spaces. Escapes: \* \_ \# \< and a lone \ backslash.

Auto link <https://example.test/auto> and raw <span class="x">html</span> inline, an unclosed < bracket.

![An image](pictures/one.png "Titled") and ![plain](@/guide/deep/beta/index.md) and [a (nested) link](https://example.test/a_(b)).

- one
- two with `code`
- three

1. first
2) second

+ plus list
   + deeper item

> A quote
> over two lines
>
> - with a list

| Name | Value |
|:-----|------:|
| `a`  | 1 \| 2 |
| b    | *two* |

```luau
local value = '<&>'
print(value)
```

~~~
tilde fence
~~~

---

<div class="raw">
  <b>kept</b> as is
</div>

Unclosed `code and *emphasis and [link](nowhere and ![image](nowhere.

{{ note(value="Second shortcode, with (parens) and a, comma", level=3) }}

Final paragraph & an ampersand.
