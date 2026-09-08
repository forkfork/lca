"""Optional independent check: uv run --with botocore tests/check_bedrock_signing.py

No credentials or network calls (apart from uv fetching the test dependency).
Reference: https://github.com/boto/botocore/blob/develop/botocore/auth.py
"""
import hashlib
import hmac
import json
import subprocess

import botocore
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials

LUA = r'''
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local json = require("agent.util.json")
local bedrock = require("agent.providers.bedrock")
local input = json.decode(io.read("*a"))
local headers, signing = bedrock._signed_headers(input.host, input.path,
    input.body, input.credentials, input.timestamp)
print(json.encode({headers = headers, signing = signing}))
'''


def reference(case):
    c = case["credentials"]
    headers = {"Content-Type": "application/json", "X-Amz-Date": case["timestamp"]}
    if c.get("session_token"):
        headers["X-Amz-Security-Token"] = c["session_token"]
    # Match LCA's declared signed-header subset. Accept need not be signed.
    request = AWSRequest(method="POST", url="https://" + case["host"] + case["path"],
                         data=case["body"].encode(), headers=headers)
    request.context["timestamp"] = case["timestamp"]
    signer = SigV4Auth(Credentials(c["access_key"], c["secret_key"], c.get("session_token")),
                       "bedrock", c["region"])
    canonical = signer.canonical_request(request)
    signature = signer.signature(signer.string_to_sign(request, canonical), request)
    return hashlib.sha256(canonical.encode()).hexdigest(), signature


count = 0
for region in ("us-east-1", "ap-southeast-2"):
    for token in (None, "IQoJfake/token+with=padding"):
        for body in ('', '{"model":"global.openai.gpt-5.6-sol"}',
                     json.dumps({"input": "héllo\n\u0000" + "x" * 1000000}, ensure_ascii=False)):
            case = dict(host=f"bedrock-runtime.{region}.amazonaws.com",
                        path="/openai/v1/responses", body=body, timestamp="20260908T120000Z",
                        credentials=dict(access_key="AKIDEXAMPLE", secret_key="fake/secret+key=",
                                         region=region))
            if token:
                case["credentials"]["session_token"] = token
            result = json.loads(subprocess.run(["lua", "-e", LUA], input=json.dumps(case),
                                              text=True, capture_output=True, check=True).stdout)
            expected_hash, expected_sig = reference(case)
            assert result["signing"]["canonical_hash"] == expected_hash
            assert hmac.compare_digest(result["signing"]["signature"], expected_sig)
            auth = dict(result["headers"])["Authorization"]
            names = "content-type;host;x-amz-date" + (";x-amz-security-token" if token else "")
            assert auth == (f"AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20260908/{region}/bedrock/aws4_request, "
                            f"SignedHeaders={names}, Signature={expected_sig}")
            for field in ("body", "region", "session_token", "timestamp"):
                changed = json.loads(json.dumps(case))
                if field in ("region", "session_token"):
                    changed["credentials"][field] = "different"
                else:
                    changed[field] += "x"
                assert not hmac.compare_digest(reference(changed)[1], expected_sig), field
            corrupt = ("0" if expected_sig[0] != "0" else "1") + expected_sig[1:]
            assert not hmac.compare_digest(corrupt, expected_sig)
            count += 1
print(f"PASS: {count} full signatures/Authorization headers match botocore {botocore.__version__}; "
      f"{count * 5} tampering checks differ. Offline only; AWS acceptance not tested.")
