# Emoji metadata

`emoji_17_0_ordering.json` comes unchanged from
[googlefonts/emoji-metadata](https://github.com/googlefonts/emoji-metadata),
under the Apache License 2.0 in `LICENSE`.

It describes Google's emoji picker, the one Meet uses: its groups, its order
and each emoji's shortcodes (`:United-Kingdom-flag:`). Nesso Hub searches Meet's
picker by those shortcodes, and lays out its own Reactions window the same way.

Meet loads Noto Emoji 17.0 (its image URLs say `notoemoji/17.0`). When that
moves on, replace the file with the matching `emoji_*_ordering.json`.
