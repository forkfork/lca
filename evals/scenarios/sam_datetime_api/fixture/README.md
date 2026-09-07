# Datetime API task

Build a small AWS SAM Python 3.12 project using only the Python standard library at runtime.
Create template.yaml, src/app.py exposing lambda_handler(event, context), local unittest tests, and usage documentation.

Contract:
- SAM transform AWS::Serverless-2016-10-31; a Python 3.12 function with CodeUri src/, Handler app.lambda_handler; HttpApi GET /datetime event (payload v2).
- GET /datetime accepts optional query parameters `timezone` (IANA name, default UTC) and `at` (ISO 8601 timestamp with an explicit offset or Z; default current time).
- Return statusCode 200, application/json content type, and a JSON string body with `datetime` (ISO 8601 with offset), `timezone` (requested zone), and `unix` (integer epoch seconds).
- Convert the same instant into the requested zone, including DST. Missing/null queryStringParameters means defaults.
- Unknown/empty timezone, invalid/empty/naive `at` return 400 with a nonempty JSON `error` string. Unknown query parameters may be ignored.
- Unknown path returns 404; non-GET on /datetime returns 405. Both have a JSON error string.
- Use API Gateway v2 rawPath and requestContext.http.method.
- Write and run local unit tests, including valid conversion, invalid input, and routing. Document local tests, sam build, sam local start-api, and curl examples.
- Work only in this workspace. No deployment, AWS calls, network browsing, package installation, or subagents. SAM CLI/Docker execution is optional and not required; local Python tests are required.

Frozen infrastructure reference: AWS SAM Function HttpApi events specify Type: HttpApi, Properties: {Path: /datetime, Method: GET}; payload format defaults to 2.0. Source checked 2026-09-05: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/sam-property-function-httpapi.html
