# CStemmer provenance

Vendored from [snowballstem/snowball](https://github.com/snowballstem/snowball)
release **v3.2.0** (commit `6389c79f91cd67ed2de3ebdcf84ec8c2d2d23c11`),
license BSD-3 (see `COPYING`).

Included, for the languages decision 0026 selects:

- `src/api.c`, `src/api.h` — the `libstemmer` API
- `src/snowball_runtime.c`, `src/snowball_runtime.h` — the shared Snowball runtime
- `src/stem_UTF_8_<lang>.c` and `include/stem_UTF_8_<lang>.h` — generated
  stemmers for english, german, russian, french, spanish, italian, dutch,
  portuguese, danish, norwegian, swedish, finnish
- `snowball-src/<lang>.sbl` — the upstream stemmer definitions, kept so the
  generated C can be regenerated and diffed

Generation (upstream `make` builds the compiler, then generates per
algorithm and charset):

    make snowball
    ./snowball algorithms/<lang>.sbl -o src_c/stem_UTF_8_<lang>.c \
        -eprefix <lang>_UTF_8_ -r ../runtime -u

Mechanical changes applied after generation:

- the `#include "../runtime/snowball_runtime.h"` line in each generated
  `stem_UTF_8_*.c` was changed to `#include "snowball_runtime.h"` to match
  this target's flat layout. Nothing else was modified.

To regenerate a stemmer from upstream, fetch the pinned version, run the
commands above, apply the same include-path change, and diff against the
committed files.
