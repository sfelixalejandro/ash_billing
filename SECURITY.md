# Security Policy

The `AshBilling` project takes the security of financial transactions, customer data, and webhook infrastructure seriously.

---

## Supported Versions

Active maintenance and security updates are provided for the latest minor release (`0.7.x`), with critical security fixes backported to the previous minor series (`0.6.x`). Earlier releases are no longer supported.

| Version | Supported           |
| ------- | ------------------- |
| 0.7.x   | Yes                 |
| 0.6.x   | Security fixes only |
| < 0.6.0 | No                  |

---

## Reporting a Vulnerability

If you discover a security vulnerability, potential bypass, or sensitive data leak in `AshBilling`, please **do NOT report it as a public GitHub issue**.

Instead, please report it via one of the following private channels:

1. **GitHub Security Advisory**: Open a private draft security advisory at [sfelixalejandro/ash_billing/security/advisories](https://github.com/sfelixalejandro/ash_billing/security/advisories).
2. **Direct Security Email**: Send details directly to `SFelixAlejandro@hotmail.com` with the subject `[SECURITY] AshBilling Vulnerability Report`.

### What to Include in Your Report

To help us triage and patch the issue promptly, please include:
- A clear description of the vulnerability.
- Steps to reproduce the issue (proof-of-concept code, HTTP request examples, or a minimal reproduction repository).
- Affected versions of `ash_billing`, `ash`, and `elixir`.
- Any potential impact on customer billing data, payment sessions, or webhook signature verification.

### Disclosure Timeline

- **Acknowledgment**: You will receive an initial response within 48 business hours acknowledging receipt of your report.
- **Triage & Remediation**: If verified, a patch will be prepared and tested privately.
- **Coordinated Release**: A patched release and security advisory will be published, granting appropriate credit to the reporter.
