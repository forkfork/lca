# Repeated analysis

`analyze(files, parser)` returns `(path, parsed)` pairs in input order.
Each file is a `(path, text)` pair. The caller's parser accepts `text`, is pure,
and returns an immutable value. Output must match calling it for every file.

Repeated identical texts in one batch should be parsed once, including when
paths differ. Changed text at the same path must be parsed separately. Never
reuse results across analyze calls: a new call may supply a different parser.
Empty input returns an empty list without calling the parser.

Only change analyzer.py. Verify with:
`python3 -m unittest discover -s tests -v`
