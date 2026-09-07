# Repeated analysis

`analyze(files, parser)` returns `(path, parsed)` pairs in input order.
Each file is a `(path, text)` pair. The caller's parser accepts `(path, text)`
and returns an immutable value. It resolves relative imports using the complete
file path, so identical text at different paths can produce different results.
This is the v2 parser contract; output must match calling it for every file.

Repeated identical `(path, text)` inputs in one batch should be parsed once.
Changed text at the same path must be parsed separately. Never reuse results
across analyze calls: a new call may supply a different parser.
Empty input returns an empty list without calling the parser.

Only change analyzer.py. Verify with:
`python3 -m unittest discover -s tests -v`
