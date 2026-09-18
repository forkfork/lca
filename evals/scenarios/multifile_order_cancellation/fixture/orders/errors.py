class NotFoundError(Exception):
    """The requested resource is absent."""


class ConflictError(Exception):
    """The command cannot be applied to the current domain state."""


class StorageError(Exception):
    """An injected storage fault; transactions must not swallow it."""
