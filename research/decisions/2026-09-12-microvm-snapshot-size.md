# Prepared-image snapshot size: calibration

Rebuilt the same frozen AL2027 ARM64 artifact in Sydney, with 1024 MiB baseline
memory and the managed AL2023 base. Both chipset builds succeeded; the polling
script observed completion after 164 seconds. No MicroVM was launched and no
model credentials, calls or tokens were used.

AWS `get-microvm-image-build` returned these exact byte counts:

| Component | Graviton 3 | Graviton 4 |
|---|---:|---:|
| memorySnapshotSizeInBytes | 476426240 | 474320896 |
| diskSnapshotSizeInBytes | 22482944 | 22482944 |
| codeInstallSizeInBytes | 767414272 | 767414272 |
| Memory + disk | 498909184 | 496803840 |

Memory plus disk is approximately 0.499/0.497 decimal GB (0.465/0.463 GiB).
Installed code is a separately reported 0.767 decimal GB. Adding all three
fields would yield 1.266/1.264 decimal GB, but the API documentation does not
establish whether that is the billable total or whether components overlap.
Do not label either sum as a verified billable size, or assume that chipset
variants are billed once or twice, without billing evidence. Earlier advice
to exclude installed code categorically was not established by the docs.

Decision: retain the component measurements; further billing validation is
needed to map them to charged storage. No runtime or packaging changes were
made. Build/storage costs were not measured. The temporary image was submitted
for deletion; artifact, bucket and build role were removed after capture.

Registration, frozen measurement script, raw AWS build responses and cleanup
records are preserved at
`/home/tim/.local/state/lca/experiments/20260912-snapshot-size/`.
The artifact SHA256 was
`341b6b15146c14f2795f0872fda987bc8b6b57db68b22bdbad9f8a9842bac801`.
