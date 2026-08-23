# Pipeline configuration task

The three pipelines in `pipelines/rules.py` intentionally contain similar step
definitions. Change only the `transform` step in the `export` pipeline so its timeout
is 90 seconds and its retry count is 4.

Do not change the `ingest` or `archive` pipelines, do not reformat unrelated code, and
do not modify README or tests. Verify with:

```bash
python3 -m unittest discover -s tests -v
```
