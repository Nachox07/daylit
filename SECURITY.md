# Security

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/Nachox07/daylit/security/advisories/new),
not in a public issue. Include the version, OS and steps to reproduce. Never include your Home
Assistant token.

Daylit stores the Home Assistant token in the macOS keychain or Windows Credential Manager, never in
the config file. See [docs/setup.md](docs/setup.md) for the security notes.
