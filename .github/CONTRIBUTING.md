# Contributing to AshBilling

Thank you for your interest in contributing to `AshBilling`! We welcome contributions of all kinds, including bug reports, documentation improvements, feature requests, and pull requests.

---

## Code of Conduct

We are committed to providing a welcoming, inclusive, and harassment-free environment for everyone. Please be respectful and constructive in all discussions and interactions.

---

## How Can I Contribute?

### Reporting Bugs

Before reporting a bug, please search existing issues to check if it has already been reported. When filing an issue, please include:
- A clear and descriptive title.
- Steps to reproduce the behavior.
- Expected vs. actual behavior.
- Elixir, OTP, and Ash versions.
- Any relevant logs or stacktraces.

### Suggesting Enhancements

Feature requests and architectural proposals are welcome! Please open an issue to discuss your ideas, especially if you plan to implement support for additional payment providers (e.g., Paddle, LemonSqueezy, Polar).

### Pull Requests

1. **Fork the repository** on GitHub.
2. **Clone your fork** locally:
   ```bash
   git clone https://github.com/your-username/ash_billing.git
   cd ash_billing
   ```
3. **Install dependencies**:
   ```bash
   mix deps.get
   ```
4. **Create a feature branch**:
   ```bash
   git checkout -b feat/your-feature-name
   ```
5. **Implement your changes** and add tests.
6. **Ensure all quality checks pass**:
   ```bash
   mix format --check-formatted
   mix compile --warnings-as-errors
   mix test
   ```
7. **Commit your changes**:
   ```bash
   git commit -m "feat: description of changes"
   ```
8. **Push to your fork and submit a Pull Request**.

---

## Questions and Support

- Join the discussion on the [Ash Discord](https://discord.gg/HTHRaaVPUc).
- Ask questions on the [Ash Framework Forum](https://elixirforum.com/c/ash-framework-forum/).
