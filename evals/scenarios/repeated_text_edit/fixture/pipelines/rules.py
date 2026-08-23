from dataclasses import dataclass


@dataclass(frozen=True)
class Step:
    name: str
    timeout_seconds: int
    retries: int


@dataclass(frozen=True)
class Pipeline:
    name: str
    steps: tuple[Step, ...]


PIPELINES = {
    "ingest": Pipeline(
        name="ingest",
        steps=(
            Step("validate", timeout_seconds=30, retries=1),
            Step("transform", timeout_seconds=60, retries=2),
            Step("publish", timeout_seconds=30, retries=1),
        ),
    ),
    "export": Pipeline(
        name="export",
        steps=(
            Step("validate", timeout_seconds=30, retries=1),
            Step("transform", timeout_seconds=60, retries=2),
            Step("publish", timeout_seconds=30, retries=1),
        ),
    ),
    "archive": Pipeline(
        name="archive",
        steps=(
            Step("validate", timeout_seconds=30, retries=1),
            Step("transform", timeout_seconds=60, retries=2),
            Step("publish", timeout_seconds=30, retries=1),
        ),
    ),
}
