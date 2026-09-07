# Finch Search

Finch uses the OpenAI Responses API hosted `web_search` tool. Product answers must
retain inline source citations. This is a local CLI and we do not want an AWS
deployment or AWS operational dependency merely to perform search.

The adapter is in `src/search.lua`.
