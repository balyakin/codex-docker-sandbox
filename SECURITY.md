# Security Policy

## Reporting a Vulnerability

Please use GitHub's private vulnerability reporting for this repository. Do not open a public issue with exploit
details, credentials, proof-of-concept payloads, or a working isolation bypass.

Include the affected platform, Docker Engine and Compose versions, the exact command, the observed network or filesystem
access, and the smallest safe reproduction you can provide.

Reports about arbitrary code execution inside the selected workspace are not isolation bypasses by themselves. Reports
that reach another host path, the Docker socket, host or LAN services, cloud metadata, or a non-allowlisted internet
destination are in scope.

## Supported Version

Security fixes are applied to the latest commit on `main`. Until tagged releases exist, older snapshots are not
maintained.
